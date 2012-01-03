package Plugins::SoundCloud::Plugin;

# Plugin to stream audio from SoundCloud streams
#
# Released under GPLv2

# TODO
# debug playlist search offset
# [12-01-02 23:01:44.7847] Slim::Web::Settings::handler (153) Preference names must be prefixed by "pref_" in the page template: apiKey (PLUGIN_SOUNDCLOUD)
# fix titles
# uri escape things
# add optional user to title
# can we show description?
# is there pagination for /tracks
# get accounts working <-- long way off

use strict;

use vars qw(@ISA);

use URI::Escape;
use JSON::XS::VersionOneAndTwo;
use File::Spec::Functions qw(:ALL);
use List::Util qw(min max);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Data::Dumper;

my $log;
my $compat;
my $CLIENT_ID = "ff21e0d51f1ea3baf9607a1d072c564f";

BEGIN {
	$log = Slim::Utils::Log->addLogCategory({
		'category'     => 'plugin.soundcloud',
		'defaultLevel' => 'INFO',
		'description'  => string('PLUGIN_SOUNDCLOUD'),
	}); 

	# Always use OneBrowser version of XMLBrowser by using server or packaged version included with plugin
	if (exists &Slim::Control::XMLBrowser::findAction) {
		$log->info("using server XMLBrowser");
		require Slim::Plugin::OPMLBased;
		push @ISA, 'Slim::Plugin::OPMLBased';
	} else {
		$log->info("using packaged XMLBrowser: Slim76Compat");
		require Slim76Compat::Plugin::OPMLBased;
		push @ISA, 'Slim76Compat::Plugin::OPMLBased';
		$compat = 1;
	}
}

my $prefs = preferences('plugin.soundcloud');

$prefs->init({ apiKey => "" });

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(
		feed   => \&toplevel,
		tag    => 'soundcloud',
		menu   => 'radios',
		is_app => $class->can('nonSNApps') ? 1 : undef,
		weight => 10,
	);

	if (!$::noweb) {
		require Plugins::SoundCloud::Settings;
		Plugins::SoundCloud::Settings->new;
	}
}

sub shutdownPlugin {
	my $class = shift;
}

sub getDisplayName { 'PLUGIN_SOUNDCLOUD' }

sub playerMenu { shift->can('nonSNApps') ? undef : 'RADIO' }

sub toplevel {
	my ($client, $callback, $args) = @_;

  my $callbacks = [
		{ name => string('PLUGIN_SOUNDCLOUD_HOT'), type => 'link',   
		  url  => \&tracksHandler, passthrough => [ { params => 'order=hotness' } ], },

    { name => string('PLUGIN_SOUNDCLOUD_NEW'), type => 'link',   
		  url  => \&tracksHandler, passthrough => [ { params => 'order=created_at' } ], },

    { name => string('PLUGIN_SOUNDCLOUD_SEARCH'), type => 'search',   
		  url  => \&tracksHandler, passthrough => [ { params => 'order=hotness' } ], },

    { name => string('PLUGIN_SOUNDCLOUD_TAGS'), type => 'search',   
		  url  => \&tracksHandler, passthrough => [ { type => 'tags', params => 'order=hotness' } ], },

# new playlists change too quickly for this to work reliably, the way xmlbrowser needs to replay the requests
# from the top.
#    { name => string('PLUGIN_SOUNDCLOUD_PLAYLIST_BROWSE'), type => 'link',
#		  url  => \&tracksHandler, passthrough => [ { type => 'playlists', parser => \&_parsePlaylists } ] },

#		{ name => string('PLUGIN_SOUNDCLOUD_PLAYLIST_SEARCH'), type => 'search',
#		  url  => \&tracksHandler, passthrough => [ { type => 'playlists', parser => \&_parsePlaylists } ] },
	];

  if ($prefs->get('apiKey') ne '') {
    push(@$callbacks, 
      { name => string('PLUGIN_SOUNDCLOUD_FAVORITES'), type => 'link',
		    url  => \&tracksHandler, passthrough => [ { type => 'favorites' } ] }
    );
  }

  push(@$callbacks, 
		{ name => string('PLUGIN_SOUNDCLOUD_URL'), type => 'search', url  => \&urlHandler, }
  );

	$callback->($callbacks);
}

sub urlHandler {
	my ($client, $callback, $args) = @_;

	my $url = $args->{'search'};
# awful hacks, why are periods being replaced?
  $url =~ s/ com/.com/;
  $url =~ s/www /www./;

  $log->warn($args->{'search'});
  # TODO: url escape this
  my $queryUrl = "http://api.soundcloud.com/resolve.json?url=$url&client_id=$CLIENT_ID";
  $log->warn($queryUrl);

  my $fetch = sub {
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $json = eval { from_json($http->content) };
				
				if ($@) {
					$log->warn($@);
				}
				
# TODO: combine this with parseTrack
        $callback->({
          items => [ {
            name => $json->{'title'},
            type => 'link',
            # type => 'audio',
            url  => $json->{'permalink_url'},
            play => addClientId($json->{'stream_url'}),
            icon => $json->{'artwork_url'} || "",
            cover => $json->{'artwork_url'} || "",
          } ]
        })
			},
			sub {
				$log->warn("error: $_[1]");
				$callback->([ { name => $_[1], type => 'text' } ]);
			},
		)->get($queryUrl);
	};
		
	$fetch->();
}

sub tracksHandler {
	my ($client, $callback, $args, $passDict) = @_;

	my $index    = ($args->{'index'} || 0); # ie, offset
	my $quantity = $args->{'quantity'} || 200;
  my $searchType = $passDict->{'type'};
  my $searchStr = ($searchType eq 'tags') ? "tags=$args->{search}" : "q=$args->{search}";
	my $search   = $args->{'search'} ? $searchStr : '';

  my $parser = $passDict->{'parser'} || \&_parseTracks;
  my $params = $passDict->{'params'} || '';
  $log->warn($params);

  $log->warn('search type: ' . $searchType);
  $log->warn("index: " . $index);
  $log->warn("quantity: " . $quantity);
	
	my $menu = [];
	
	# fetch in stages as api only allows 50 items per response, cli clients require $quantity responses which can be more than 50
	my $fetch;
	
	# FIXME: this could be sped up by performing parallel requests once the number of responses is known??

	$fetch = sub {
    # in case we've already fetched some of this page, keep going
		my $i = $index + scalar @$menu;
    $log->warn("i: " + $i);
		my $max = min($quantity - scalar @$menu, 200); # api allows max of 200 items per response
    $log->warn("max: " + $max);
    
    my $method = "http";
	
    my $authenticated = 0;
    my $resource = "tracks.json";
    if ($searchType eq 'playlists') {
      $log->warn("id? " .$passDict->{'pid'});
      my $id = $passDict->{'pid'} || '';
      if ($id eq '') {
        $resource = "playlists.json";
        $quantity = 10;
      } else {
        $resource = "playlists/$id.json";
      }
    } elsif ($searchType eq 'favorites') {
      $resource = "me/favorites.json";
      $authenticated = 1;
    } else {
      $params .= "&filter=streamable";
    }

    if ($authenticated && $prefs->get('apiKey')) {
      $method = "https";
      $params .= "&oauth_token=" . $prefs->get('apiKey');
    } else {
      $params .= "&client_id=$CLIENT_ID";
    }

		my $queryUrl = "$method://api.soundcloud.com/$resource?offset=$i&limit=$quantity&" . $params . "&" . $search;

		$log->warn("fetching: $queryUrl");
		
		Slim::Networking::SimpleAsyncHTTP->new(
			
			sub {
				my $http = shift;
				my $json = eval { from_json($http->content) };
				
				if ($@) {
					$log->warn($@);
				}

        $parser->($json, $menu); 
  
        # max offset = 8000, max index = 200 sez soundcloud http://developers.soundcloud.com/docs#pagination
        my $total = 8000 + $quantity;
				
				$log->info("this page: " . scalar @$menu . " total: $total");

        # TODO: check this logic makes sense
				if (scalar @$menu < $quantity) {
          $total = $index + @$menu;
          $log->debug("short page, truncate total to $total");
        }
					
					$callback->({
						items  => $menu,
						offset => $index,
						total  => $total,
					});
			},
			
			sub {
				$log->warn("error: $_[1]");
				$callback->([ { name => $_[1], type => 'text' } ]);
			},
			
		)->get($queryUrl);
	};
		
	$fetch->();
}

sub addClientId {
  my ($url) = shift;
  if ($url =~ /\?/) {
    return $url . "&client_id=$CLIENT_ID";
  } else {
    return $url . "?client_id=$CLIENT_ID";
  }
}

sub _parseTracks {
	my ($json, $menu) = @_;
  for my $entry (@$json) {
    if ($entry->{'streamable'}) {
      push @$menu, {
        name => $entry->{'title'},
        type => 'link',
        #type => 'audio',
        on_select => 'play',
        playall => 0,
        url  => $entry->{'permalink_url'},
        play => addClientId($entry->{'stream_url'}),
        icon => $entry->{'artwork_url'} || "",
      };
    }
  }
}

sub _parsePlaylistTracks {
	my ($json, $menu) = @_;
  _parseTracks($json->{'tracks'}, $menu, 1);
}

sub _parsePlaylists {
	my ($json, $menu) = @_;
  for my $entry (@$json) {
    if ($entry->{'streamable'}) {
      my $title = $entry->{'title'};
      my $numTracks = length(@{$entry->{'tracks'}} || []);
      my $titleInfo .= "$numTracks tracks";

      my $totalSeconds = ($entry->{'duration'} || 0) / 1000;
      if ($totalSeconds != 0) {
        my $minutes = int($totalSeconds / 60);
        my $seconds = $totalSeconds % 60;
        $titleInfo .= " ${minutes}m${seconds}s";
      }

      $title .= " ($titleInfo)";

      push @$menu, {
        name => $title,
        type => 'playlist',
        url => \&tracksHandler,
        playall => 0,
        passthrough => [ { type => 'playlists', pid => $entry->{'id'}, parser => \&_parsePlaylistTracks }],
      };
    }
  }
}

1;
