package Plugins::SqueezeCloud::Plugin;

# Plugin to stream audio from SoundCloud streams
#
# Released under GPLv2

use strict;
use utf8;

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

use Plugins::SqueezeCloud::ProtocolHandler;

my $log;
my $compat;
my $CLIENT_ID = "ff21e0d51f1ea3baf9607a1d072c564f";

my %METADATA_CACHE= {};


BEGIN {
	$log = Slim::Utils::Log->addLogCategory({
		'category'     => 'plugin.squeezecloud',
		'defaultLevel' => 'DEBUG',
		'description'  => string('PLUGIN_SQUEEZECLOUD'),
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

my $prefs = preferences('plugin.squeezecloud');

$prefs->init({ apiKey => "" });

sub defaultMeta {
	my ( $client, $url ) = @_;
	
	return {
		title => Slim::Music::Info::getCurrentTitle($url)
	};
}

sub addClientId {
        my ($url) = shift;

        my $prefix = "?";

        if ($url =~ /\?/) {
                my $prefix = "&";
        }

        my $decorated = $url . $prefix . "client_id=$CLIENT_ID";

        if (0 && $prefs->get('apiKey')) {
                my $decorated = $url . $prefix . "oauth_token=" . $prefs->get('apiKey');
                $log->info($decorated);
        }
        return $decorated;
}

sub _makeMetadata {
	my ($json) = shift;

  	my $stream = addClientId($json->{'stream_url'});
  	$stream =~ s/https/http/;

	my $icon = "";
	if (defined $json->{'artwork_url'}) {
		$icon = $json->{'artwork_url'};		
	}

  	my $DATA = {
    		#duration => $json->{'duration'} / 1000,
    		name => $json->{'title'},
    		title => $json->{'title'},
    		artist => $json->{'user'}->{'username'} || $json->{'artist_sqz'},
    		play => "soundcloud://" . $json->{'id'},
    		#url  => $json->{'permalink_url'},
    		#link => "soundcloud://" . $json->{'id'},
    		icon => $icon,
    		image => $icon,
    		cover => $icon,
  	};
   
  	my %DATA1 = %$DATA;
  	my %DATA2 = %$DATA;
  	my %DATA3 = %$DATA;

  	$METADATA_CACHE{$DATA->{'play'}} = \%DATA1;
  	$METADATA_CACHE{$DATA->{'link'}} = \%DATA2;

  	return \%DATA3;
}

sub _gotMetadataError {
	my $http   = shift;
	my $client = $http->params('client');
	my $url    = $http->params('url');
	my $error  = $http->error;
	
	$log->is_debug && $log->debug( "Error fetching Web API metadata: $error" );
	
	$client->master->pluginData( webapifetchingMeta => 0 );
	
	# To avoid flooding the SOUNDCLOUD servers in the case of errors, we just ignore further
	# metadata for this track if we get an error
	my $meta = defaultMeta( $client, $url );
	$meta->{_url} = $url;
	
	$client->master->pluginData( webapimetadata => $meta );
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
	my $user_name = $json->{'user'}->{'username'};

  	my $DATA = _makeMetadata($json);

  	my $ua = LWP::UserAgent->new(
    		requests_redirectable => [],
  	);

  	my $res = $ua->get( addClientId($json->{'stream_url'}) );

  	my $stream = $res->header( 'location' );

  	if ($stream =~ /ak-media.soundcloud.com\/(.*\.mp3)/) {
    		my %DATA1 = %$DATA;
    		my %DATA2 = %$DATA;
    		my %DATA3 = %$DATA;
    		$METADATA_CACHE{$1} = \%DATA1;
    		$METADATA_CACHE{$json->{'stream_url'}} = \%DATA2;
    		$METADATA_CACHE{addClientId($json->{'stream_url'})} = \%DATA3;
  	}

  	return;
}

sub fetchMetadata {
  	my ( $client, $url ) = @_;
 
  	if ($url =~ /tracks\/\d+\/stream/) {

    		my $queryUrl = $url;
    		$queryUrl =~ s/\/stream/.json/;

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

sub _parseTracks {
	$log->info("parsing tracks");
	my ($json, $menu) = @_;

  	for my $entry (@$json) {
    		if ($entry->{'streamable'}) {
      			push @$menu, _makeMetadata($entry);
    		}
  	}
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
    		$log->warn("i: " . $i);
		my $max = min($quantity - scalar @$menu, 200); # api allows max of 200 items per response
    		$log->warn("max: " . $max);
    
    		my $method = "https";
    		my $uid = $passDict->{'uid'} || '';
	
    		my $authenticated = 0;
    		my $resource = "tracks.json";
    		if ($searchType eq 'playlists') {
      			my $id = $passDict->{'pid'} || '';
      			$authenticated = 1;

        		$resource = "playlists/$id.json";
      			if ($id eq '') {

  				$resource = "users/$uid/playlists.json";
        			if ($uid eq '') {
          				$resource = "playlists.json";
          				$quantity = 30;
				}
	      		}
    		}
		if ($searchType eq 'tracks') {
      			$authenticated = 1;
      			$resource = "users/$uid/tracks.json";
    		} elsif ($searchType eq 'favorites') {
      			$authenticated = 1;
       			$resource = "users/$uid/favorites.json";
      			if ($uid eq '') {
        			$resource = "me/favorites.json";
      			}
    		} elsif ($searchType eq 'friends') {
      			$authenticated = 1;
      			$resource = "me/followings.json";
    		} elsif ($searchType eq 'friend') {
      			$authenticated = 1;
      			$resource = "users/$uid.json";
    		} elsif ($searchType eq 'activities') {
      			$authenticated = 1;
      			$resource = "me/activities/all.json";
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

# TODO: make this async
sub metadata_provider {
  	my ( $client, $url ) = @_;
  	
	if (exists $METADATA_CACHE{$url}) {
    		return $METADATA_CACHE{$url};
  	}
	
	if ($url =~ /ak-media.soundcloud.com\/(.*\.mp3)/) {
    		return $METADATA_CACHE{$1};
  	} 
	
	if ( !$client->master->pluginData('webapifetchingMeta') ) {
		# Fetch metadata in the background
		Slim::Utils::Timers::killTimers( $client, \&fetchMetadata );
    		$client->master->pluginData( webapifetchingMeta => 1 );
		fetchMetadata( $client, $url );
	}
	
	return defaultMeta( $client, $url );
}

sub urlHandler {
	my ($client, $callback, $args) = @_;

	my $url = $args->{'search'};
	# awful hacks, why are periods being replaced?
  	$url =~ s/ com/.com/;
  	$url =~ s/www /www./;

  	# TODO: url escape this
  	my $queryUrl = "http://api.soundcloud.com/resolve.json?url=$url&client_id=$CLIENT_ID";

  	my $fetch = sub {
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $json = eval { from_json($http->content) };

        			if (exists $json->{'tracks'}) {
          				$callback->({ items => [ _parsePlaylist($json) ] });
        			} else {
          				$callback->({
            				items => [ _makeMetadata($json) ]
          				});
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

sub _parsePlaylistTracks {
	my ($json, $menu) = @_;
	_parseTracks($json->{'tracks'}, $menu, 1);
}

sub _parsePlaylist {
	my ($entry) = @_;

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

	my $icon = $entry->{'artwork_url'} || "";

  	$title .= " ($titleInfo)";	

  	return {
    		name => $title,
    		type => 'playlist',
		icon => $icon,
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

sub _parseActivities {
	my ($json, $menu) = @_;
  	my $collection = $json->{'collection'};

  	for my $entry (@$collection) {
    		my $created_at = $entry->{'created_at'};
    		my $origin = $entry->{'origin'};
    		my $tags = $entry->{'tags'};
    		my $type = $entry->{'type'};

    		if ($type =~ /playlist.*/) {
      			my $playlistItem = _parsePlaylist($origin);
      			my $user = $origin->{'user'};
      			my $user_name = $user->{'full_name'} || $user->{'username'};

      			$playlistItem->{'name'} = $playlistItem->{'name'} . " shared by " . $user_name;
      			push @$menu, $playlistItem;
    		} else {
      			my $track = $origin->{'track'} || $origin;
      			my $user = $origin->{'user'} || $track->{'user'};
      			my $user_name = $user->{'full_name'} || $user->{'username'};
			$track->{'artist_sqz'} = $user_name;

      			my $subtitle = "";
      			if ($type eq "favoriting") {
        			$subtitle = "favorited by $user_name";
      			} elsif ($type eq "comment") {
        			$subtitle = "commented on by $user_name";
      			} elsif ($type =~ /track/) {
        			$subtitle = "new track by $user_name";
      			} else {
        			$subtitle = "shared by $user_name";
      			}

      			my $trackentry = _makeMetadata($track);
      			$trackentry->{'name'} = $track->{'title'} . " " . $subtitle;
      
      			push @$menu, $trackentry;
    		}
  	}
}

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(
		feed   => \&toplevel,
		tag    => 'squeezecloud',
		menu   => 'radios',
		is_app => $class->can('nonSNApps') ? 1 : undef,
		weight => 10,
	);

	if (!$::noweb) {
		require Plugins::SqueezeCloud::Settings;
		Plugins::SqueezeCloud::Settings->new;
	}

  	Slim::Formats::RemoteMetadata->registerProvider(
    		match => qr/soundcloud\.com/,
    		func => \&metadata_provider,
  	);

  	Slim::Player::ProtocolHandlers->registerHandler(
    		soundcloud => 'Plugins::SqueezeCloud::ProtocolHandler'
  	);
}

sub shutdownPlugin {
	my $class = shift;
}

sub getDisplayName { 'PLUGIN_SQUEEZECLOUD' }

sub playerMenu { shift->can('nonSNApps') ? undef : 'RADIO' }

sub toplevel {
	my ($client, $callback, $args) = @_;

  	my $callbacks = [
		{ name => string('PLUGIN_SQUEEZECLOUD_HOT'), type => 'link',   
		  url  => \&tracksHandler, passthrough => [ { params => 'order=hotness' } ], },

    		{ name => string('PLUGIN_SQUEEZECLOUD_NEW'), type => 'link',   
		  url  => \&tracksHandler, passthrough => [ { params => 'order=created_at' } ], },

    		{ name => string('PLUGIN_SQUEEZECLOUD_SEARCH'), type => 'search',   
		  url  => \&tracksHandler, passthrough => [ { params => 'order=hotness' } ], },

    		{ name => string('PLUGIN_SQUEEZECLOUD_TAGS'), type => 'search',   
		  url  => \&tracksHandler, passthrough => [ { type => 'tags', params => 'order=hotness' } ], },

		# new playlists change too quickly for this to work reliably, the way xmlbrowser needs to replay the requests
		# from the top.
		#    { name => string('PLUGIN_SOUNDCLOUD_PLAYLIST_BROWSE'), type => 'link',
		#		  url  => \&tracksHandler, passthrough => [ { type => 'playlists', parser => \&_parsePlaylists } ] },

		{ name => string('PLUGIN_SQUEEZECLOUD_PLAYLIST_SEARCH'), type => 'search',
   	  	url  => \&tracksHandler, passthrough => [ { type => 'playlists', parser => \&_parsePlaylists } ] },
	];

  	if ($prefs->get('apiKey') ne '') {
    		push(@$callbacks, 
      			{ name => string('PLUGIN_SQUEEZECLOUD_ACTIVITIES'), type => 'link',
		    	url  => \&tracksHandler, passthrough => [ { type => 'activities', parser => \&_parseActivities} ] }
    		);

    		push(@$callbacks, 
      			{ name => string('PLUGIN_SQUEEZECLOUD_FAVORITES'), type => 'link',
		    	url  => \&tracksHandler, passthrough => [ { type => 'favorites' } ] }
    		);
    		push(@$callbacks, 
      			{ name => string('PLUGIN_SQUEEZECLOUD_FRIENDS'), type => 'link',
		  	url  => \&tracksHandler, passthrough => [ { type => 'friends', parser => \&_parseFriends} ] },
    		);
  	}

  	push(@$callbacks, 
		{ name => string('PLUGIN_SQUEEZECLOUD_URL'), type => 'search', url  => \&urlHandler, }
  	);

	$callback->($callbacks);
}

1;
