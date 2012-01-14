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
use LWP::Simple;
use LWP::UserAgent;
use File::Spec::Functions qw(:ALL);
use List::Util qw(min max);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Data::Dumper;

my $log;
my $compat;
my $CLIENT_ID = "ff21e0d51f1ea3baf9607a1d072c564f";

my %METADATA_CACHE= {};

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

  Slim::Formats::RemoteMetadata->registerProvider(
    match => qr/soundcloud\.com/,
    func => \&metadata_provider,
  );
}

sub defaultMeta {
	my ( $client, $url ) = @_;
	
	return {
		title => Slim::Music::Info::getCurrentTitle($url)
	};
}

# TODO: make this async
sub metadata_provider {
  my ( $client, $url ) = @_;
  if (exists $METADATA_CACHE{$url}) {
    #$log->warn(Dumper($METADATA_CACHE{$url}));
    return $METADATA_CACHE{$url};
  } elsif ($url =~ /ak-media.soundcloud.com\/(.*\.mp3)/) {
    #$log->warn($1);
    #$log->warn($METADATA_CACHE{$1});
    return $METADATA_CACHE{$1};
  } elsif ( !$client->master->pluginData('webapifetchingMeta') ) {
		# Fetch metadata in the background
		Slim::Utils::Timers::killTimers( $client, \&fetchMetadata );
    $client->master->pluginData( webapifetchingMeta => 1 );
		fetchMetadata( $client, $url );
	}
	
	return defaultMeta( $client, $url );
}

sub fetchMetadata {
  my ( $client, $url ) = @_;
  $log->warn($url);
 
  if ($url =~ /tracks\/\d+\/stream/) {
    my $queryUrl = $url;
    $queryUrl =~ s/\/stream/.json/;
    $log->warn($queryUrl);

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
      \&_gotMetadata,
      \&_gotMetadataError,
      {
        client     => $client,
        url        => $url,
        timeout    => 30,
      },
    );

    $http->get($queryUrl);
  }
}

sub _gotMetadata {
	my $http      = shift;
	my $client    = $http->params('client');
	my $url       = $http->params('url');
	my $content   = $http->content;


	if ( $@ ) {
		$http->error( $@ );
		_gotMetadataError( $http );
		return;
	}

	$client->master->pluginData( webapifetchingMeta => 0 );
    
  my $json = eval { from_json($content) };

  my $DATA = {
    #duration => $json->{'duration'} / 1000,
    name => $json->{'title'},
    title => $json->{'title'},
    artist => $json->{'user'}->{'username'},
    type => 'audio',
    #url  => $json->{'permalink_url'},
    link => $json->{'permalink_url'},
    icon => $json->{'artwork_url'} || "",
    image => $json->{'artwork_url'} || "",
    cover => $json->{'artwork_url'} || "",
  };

  my $ua = LWP::UserAgent->new(
    requests_redirectable => [],
  );

  my $res = $ua->get( addClientId($json->{'stream_url'}) );

  my $stream = $res->header( 'location' );

  if ($stream =~ /ak-media.soundcloud.com\/(.*\.mp3)/) {
    $METADATA_CACHE{$1} = $DATA;
    $METADATA_CACHE{$url} = $DATA;
  }

  return;
}

sub _gotMetadataError {
	my $http   = shift;
	my $client = $http->params('client');
	my $url    = $http->params('url');
	my $error  = $http->error;
	
	$log->is_debug && $log->debug( "Error fetching Web API metadata: $error" );
	
	$client->master->pluginData( webapifetchingMeta => 0 );
	
	# To avoid flooding the BBC servers in the case of errors, we just ignore further
	# metadata for this station if we get an error
	my $meta = defaultMeta( $client, $url );
	$meta->{_url} = $url;
	
	$client->master->pluginData( webapimetadata => $meta );
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
    push(@$callbacks, 
      { name => string('PLUGIN_SOUNDCLOUD_FRIENDS_FAVORITES'), type => 'link',
		  url  => \&tracksHandler, passthrough => [ { type => 'friends', parser => \&_parseFriends} ] },
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

  # TODO: url escape this
  my $queryUrl = "http://api.soundcloud.com/resolve.json?url=$url&client_id=$CLIENT_ID";
  $log->warn($queryUrl);

  my $fetch = sub {
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $json = eval { from_json($http->content) };
				
# TODO: combine this with parseTrack
        $callback->({
          items => [ {
            name => $json->{'title'},
            type => 'audio',
            url  => $json->{'permalink_url'},
            play => addClientId($json->{'stream_url'}),
            icon => $json->{'artwork_url'} || "",
            image => $json->{'artwork_url'} || "",
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
    
    my $method = "https";
	
    my $authenticated = 0;
    my $resource = "tracks.json";
    if ($searchType eq 'playlists') {
      my $id = $passDict->{'pid'} || '';
      if ($id eq '') {
        $resource = "playlists.json";
        $quantity = 10;
      } else {
        $resource = "playlists/$id.json";
      }
    } elsif ($searchType eq 'favorites') {
      my $id = $passDict->{'uid'} || '';
      if ($id eq '') {
        $resource = "me/favorites.json";
      } else {
        $resource = "users/$id/favorites.json";
      }
      $authenticated = 1;
    } elsif ($searchType eq 'friends') {
      $resource = "me/followings.json";
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
        if (exists $passDict->{'total'}) {
          $total = $passDict->{'total'}
        }
				
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
    if (0 && $prefs->get('apiKey')) {
      $log->info($url . "&oauth_token=" . $prefs->get('apiKey'));
      return $url . "&oauth_token=" . $prefs->get('apiKey');
    } else {
      return $url . "&client_id=$CLIENT_ID";
    }
  } else {
    if (0 && $prefs->get('apiKey')) {
      $log->info($url . "?oauth_token=" . $prefs->get('apiKey'));
      return $url . "?oauth_token=" . $prefs->get('apiKey');
    } else {
      return $url . "?client_id=$CLIENT_ID";
    }
  }
}

sub _parseTracks {
	my ($json, $menu) = @_;
  for my $entry (@$json) {
    if ($entry->{'streamable'}) {
      my $stream = addClientId($entry->{'stream_url'});
      $stream =~ s/https/http/;
      push @$menu, {
        name => $entry->{'title'},
        type => 'audio',
        on_select => 'play',
        playall => 0,
        url  => $entry->{'permalink_url'},
        play => $stream,
        icon => $entry->{'artwork_url'} || "",
        image => $entry->{'artwork_url'} || "",
        cover => $entry->{'artwork_url'} || "",
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

sub _parseFriends {
	my ($json, $menu) = @_;
  for my $entry (@$json) {
    my $image = $entry->{'avatar_url'};
    my $name = $entry->{'full_name'} || $entry->{'username'};
    my $favorite_count = $entry->{'public_favorites_count'};
    my $id = $entry->{'id'};

    #if ($favorite_count != 0) {
      push @$menu, {
        name => $name. " (" . $favorite_count . " favorites)",
        icon => $image,
        image => $image,
        type => 'link',
        url => \&tracksHandler,
        passthrough => [ { type => 'favorites', uid => $id, max => $favorite_count }],
      };
    #}
  }
}


1;
