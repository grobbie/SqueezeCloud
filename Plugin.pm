package Plugins::SoundCloud::Plugin;

# Plugin to stream audio from SoundCloud streams
#
# Released under GPLv2

# TODO
# playall, sucks

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
  #$log->warn($url);
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
  $log->warn("fetching metadata for: " + $url);
 
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
    mime => 'audio/mpeg',
    play => addClientId($json->{'stream_url'}),
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

		{ name => string('PLUGIN_SOUNDCLOUD_PLAYLIST_SEARCH'), type => 'search',
   	  url  => \&tracksHandler, passthrough => [ { type => 'playlists', parser => \&_parsePlaylists } ] },
	];

  if ($prefs->get('apiKey') ne '') {
    push(@$callbacks, 
      { name => string('PLUGIN_SOUNDCLOUD_ACTIVITIES'), type => 'link',
		    url  => \&tracksHandler, passthrough => [ { type => 'activities', parser => \&_parseActivities} ] }
    );

    push(@$callbacks, 
      { name => string('PLUGIN_SOUNDCLOUD_FAVORITES'), type => 'link',
		    url  => \&tracksHandler, passthrough => [ { type => 'favorites' } ] }
    );
    push(@$callbacks, 
      { name => string('PLUGIN_SOUNDCLOUD_FRIENDS'), type => 'link',
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
  #$log->warn($queryUrl);

  my $fetch = sub {
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $json = eval { from_json($http->content) };

        if (exists $json->{'tracks'}) {
          $callback->({ items => [ _parsePlaylist($json) ] });
        } else {
          $callback->({
            items => [ {
              name => $json->{'title'},
              type => 'audio',
              #url  => $json->{'permalink_url'},
              play => addClientId($json->{'stream_url'}),
              icon => $json->{'artwork_url'} || "",
              image => $json->{'artwork_url'} || "",
              cover => $json->{'artwork_url'} || "",
            } ]
          })
        }
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
    my $uid = $passDict->{'uid'} || '';
	
    my $authenticated = 0;
    my $resource = "tracks.json";
    if ($searchType eq 'playlists') {
      my $id = $passDict->{'pid'} || '';
      $authenticated = 1;
      if ($id eq '') {
        if ($uid eq '') {
          $resource = "playlists.json";
          $quantity = 30;
        } else {
          $resource = "users/$uid/playlists.json";
        }
      } else {
        $resource = "playlists/$id.json";
      }
    } if ($searchType eq 'tracks') {
      $authenticated = 1;
      $resource = "users/$uid/tracks.json";
    } elsif ($searchType eq 'favorites') {
      if ($uid eq '') {
        $resource = "me/favorites.json";
      } else {
        $resource = "users/$uid/favorites.json";
      }
      $authenticated = 1;
    } elsif ($searchType eq 'friends') {
      $resource = "me/followings.json";
      $authenticated = 1;
    } elsif ($searchType eq 'friend') {
      $resource = "users/$uid.json";
      $authenticated = 1;
    } elsif ($searchType eq 'activities') {
      $resource = "me/activities/all.json";
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
       
        # awful hack
        if ($searchType eq 'friend' && (defined $args->{'index'})) {
          my @tmpmenu = $menu->[$index];
          $menu = \@tmpmenu;
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
  $log->info("parsing tracks");
	my ($json, $menu) = @_;

  for my $entry (@$json) {
    if ($entry->{'streamable'}) {
      my $stream = addClientId($entry->{'stream_url'});
      $stream =~ s/https/http/;
      push @$menu, {
        name => $entry->{'title'},
        type => 'audio',
        on_select => 'play',
        # url  => $entry->{'permalink_url'},
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

sub _parsePlaylist {
	my ($entry) = @_;
  $log->info(Dumper($entry));
  my $title = $entry->{'title'};
  $log->info($title);
  my $numTracks = 0;
  my $titleInfo = "";
  if (exists $entry->{'tracks'}) {
    $numTracks = scalar(@{$entry->{'tracks'}});
    $titleInfo .= "$numTracks tracks";
  }

  my $totalSeconds = ($entry->{'duration'} || 0) / 1000;
  if ($totalSeconds != 0) {
    my $minutes = int($totalSeconds / 60);
    my $seconds = $totalSeconds % 60;
    if (length($titleInfo) > 0) {
      $titleInfo .= " ";
    }
    $titleInfo .= "${minutes}m${seconds}s";
  }

  $title .= " ($titleInfo)";
  $log->info($title);

  return {
    name => $title,
    type => 'playlist',
    url => \&tracksHandler,
    passthrough => [ { type => 'playlists', pid => $entry->{'id'}, parser => \&_parsePlaylistTracks }],
  };
}

sub _parsePlaylists {
	my ($json, $menu) = @_;
  for my $entry (@$json) {
    push @$menu, _parsePlaylist($entry);
  }
}

sub _parseActivities {
	my ($json, $menu) = @_;
  my $collection = $json->{'collection'};
  for my $entry (@$collection) {
    my $created_at = $entry->{'created_at'};
    my $origin = $entry->{'origin'};
    my $tags = $entry->{'tags'};
    my $type = $entry->{'type'};

    if ($type =~ /playlist.*/) {
      my $playlist = $origin->{'playlist'};
      my $playlistItem = _parsePlaylist($playlist);
      
      my $user = $playlist->{'user'};
      my $user_name = $user->{'full_name'} || $user->{'username'};

      $playlistItem->{'name'} = $playlistItem->{'name'} . " shared by " . $user_name;
      push @$menu, $playlistItem;
    } else {
      my $track = $origin->{'track'};
      my $user = $origin->{'user'};
      my $user_name = $user->{'full_name'} || $user->{'username'};

      my $subtitle = "";
      if ($type == "favoriting") {
        $subtitle = "favorited by $user_name";
      } elsif ($type == "comment") {
        $subtitle = "commented on by $user_name";
      } elsif ($type =~ /track/) {
        $subtitle = "new track by $user_name";
      } else {
        $subtitle = "shared by $user_name";
      }


      push @$menu, {
        name => $track->{'title'} . " " . $subtitle,
        #artist => $subtitle,
        type => 'audio',
        'mime' => 'audio/mpeg',
        url  => $track->{'permalink_url'},
        play => addClientId($track->{'stream_url'}),
        icon => $track->{'artwork_url'} || "",
        image => $track->{'artwork_url'} || "",
        cover => $track->{'artwork_url'} || "",
      }
    }
  }
}

sub _parseFriends {
	my ($json, $menu) = @_;
  my $i = 0;
  for my $entry (@$json) {
    my $image = $entry->{'avatar_url'};
    my $name = $entry->{'full_name'} || $entry->{'username'};
    my $favorite_count = $entry->{'public_favorites_count'};
    my $track_count = $entry->{'track_count'};
    my $playlist_count = $entry->{'playlist_count'};
    my $id = $entry->{'id'};

    push @$menu, {
      name => sprintf("%s (%d favorites, %d tracks, %d sets)",
        $name, $favorite_count, $track_count, $playlist_count),
      icon => $image,
      image => $image,
      type => 'link',
      url => \&tracksHandler,
      passthrough => [ { type => 'friend', uid => $id, parser => \&_parseFriend} ]
    };
  }
}

sub _parseFriend {
	my ($entry, $menu) = @_;

  my $image = $entry->{'avatar_url'};
  my $name = $entry->{'full_name'} || $entry->{'username'};
  my $favorite_count = $entry->{'public_favorites_count'};
  my $track_count = $entry->{'track_count'};
  my $playlist_count = $entry->{'playlist_count'};
  my $id = $entry->{'id'};

  push @$menu, {
    name => sprintf("%d Favorites", $favorite_count),
    icon => $image,
    image => $image,
    type => 'playlist',
    url => \&tracksHandler,
    passthrough => [ { type => 'favorites', uid => $id, max => $favorite_count }],
  };

  push @$menu, {
    name => sprintf("%d Tracks", $favorite_count),
    icon => $image,
    image => $image,
    type => 'playlist',
    url => \&tracksHandler,
    passthrough => [ { type => 'tracks', uid => $id, max => $track_count }],
  };

  push @$menu, {
    name => sprintf("%d Playlists", $playlist_count),
    icon => $image,
    image => $image,
    type => 'link',
    url => \&tracksHandler,
    passthrough => [ { type => 'playlists', uid => $id, max => $playlist_count,
      parser => \&_parsePlaylists } ]
  };
}

1;
