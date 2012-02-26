package Plugins::SoundCloud::ProtocolHandler;

use strict;

use base qw(Slim::Player::Protocols::HTTP);

use List::Util qw(min max);
use LWP::Simple;
use LWP::UserAgent;
use HTML::Parser;
use URI::Escape;
use JSON::XS::VersionOneAndTwo;
use XML::Simple;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;
use Scalar::Util qw(blessed);

my $log   = logger('plugin.soundcloud');
my $prefs = preferences('plugin.soundcloud');

my %fetching; # hash of ids we are fetching metadata for to avoid multiple fetches

Slim::Player::ProtocolHandlers->registerHandler('soundcloud', __PACKAGE__);

use strict;
use base 'Slim::Player::Protocols::HTTP';

sub canSeek { 1 }

sub _makeMetadata {
  my ($json) = shift;
  my $stream = addClientId($json->{'stream_url'});
  $stream =~ s/https/http/;
  my $DATA = {
    duration => int($json->{'duration'} / 1000),
    name => $json->{'title'},
    title => $json->{'title'},
    artist => $json->{'user'}->{'username'},
    #type => 'soundcloud',
    #play => $stream,
    #url  => $json->{'permalink_url'},
    #link => "soundcloud://" . $json->{'id'},
    bitrate   => '128k',
  	type      => 'MP3 (Soundcloud)',
    #info_link => $json->{'permalink_url'},
    icon => $json->{'artwork_url'} || "",
    image => $json->{'artwork_url'} || "",
    cover => $json->{'artwork_url'} || "",
  };
}

my $CLIENT_ID = "ff21e0d51f1ea3baf9607a1d072c564f";
my $prefs = preferences('plugin.soundcloud');

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

sub getFormatForURL () { 'mp3' }

sub isRemote { 1 }

sub scanUrl {
  my ($class, $url, $args) = @_;
  $args->{cb}->( $args->{song}->currentTrack() );
}

sub getNextTrack {
	  my ($class, $song, $successCb, $errorCb) = @_;
	  
	  my $client = $song->master();
	  my $url    = $song->currentTrack()->url;
	  
	  # Get next track
	  my ($id) = $url =~ m{^soundcloud://(.*)$};
	  
	  # Talk to SN and get the next track to play
	  my $trackURL = addClientId("http://api.soundcloud.com/tracks/" . $id . ".json");
	  
	  my $http = Slim::Networking::SimpleAsyncHTTP->new(
	          \&gotNextTrack,
	          \&gotNextTrackError,
	          {
	                  client        => $client,
	                  song          => $song,
	                  callback      => $successCb,
	                  errorCallback => $errorCb,
	                  timeout       => 35,
	          },
	  );
	  
	  main::DEBUGLOG && $log->is_debug && $log->debug("Getting track from soundcloud for $id");
	  
	  $http->get( $trackURL );
}

sub gotNextTrack {
  my $http   = shift;
  my $client = $http->params->{client};
  my $song   = $http->params->{song};     
  my $url    = $song->currentTrack()->url;
  my $track  = eval { from_json( $http->content ) };
  
  if ( $@ || $track->{error} ) {
    # We didn't get the next track to play
    if ( $log->is_warn ) {
      $log->warn( 'Soundcloud error getting next track: ' . ( $@ || $track->{error} ) );
    }
    
    if ( $client->playingSong() ) {
      $client->playingSong()->pluginData( {
          songName => $@ || $track->{error},
      } );
    }
    
    $http->params->{'errorCallback'}->( 'PLUGIN_SOUNDCLOUD_NO_INFO', $track->{error} );
    return;
  }
  
  # Save metadata for this track
  $song->pluginData( $track );

  my $stream = addClientId($track->{'stream_url'});
  $stream =~ s/https/http/;
  $log->info($stream);
  $song->streamUrl($stream);

  my $meta = _makeMetadata($track);
  $song->duration( $meta->{duration} );
  
  my $cache = Slim::Utils::Cache->new;
  $log->info("setting ". 'soundcloud_meta_' . $track->{id});
  $cache->set( 'soundcloud_meta_' . $track->{id}, $meta, 86400 );

  $http->params->{callback}->();
}

sub gotNextTrackError {
  my $http = shift;
  
  $http->params->{errorCallback}->( 'PLUGIN_SOUNDCLOUD_ERROR', $http->error );
}

# To support remote streaming (synced players, slimp3/SB1), we need to subclass Protocols::HTTP
sub new {
  my $class  = shift;
  my $args   = shift;

  my $client = $args->{client};
  
  my $song      = $args->{song};
  my $streamUrl = $song->streamUrl() || return;
  my $track     = $song->pluginData();
  
  $log->info( 'Remote streaming Soundcloud track: ' . $streamUrl );

  my $sock = $class->SUPER::new( {
    url     => $streamUrl,
    song    => $song,
    client  => $client,
  } ) || return;
  
  ${*$sock}{contentType} = 'audio/mpeg';

  return $sock;
}


# Track Info menu
sub trackInfo {
  my ( $class, $client, $track ) = @_;
  
  my $url = $track->url;
  $log->info("trackInfo: " . $url);
}

# Track Info menu
sub trackInfoURL {
  my ( $class, $client, $url ) = @_;
  $log->info("trackInfoURL: " . $url);
}

use Data::Dumper;
# Metadata for a URL, used by CLI/JSON clients
sub getMetadataFor {
  my ( $class, $client, $url ) = @_;
    
  return {} unless $url;

  #$log->info("metadata: " . $url);

  my $icon = $class->getIcon();
  my $cache = Slim::Utils::Cache->new;

	# If metadata is not here, fetch it so the next poll will include the data
	my ($trackId) = $url =~ m{soundcloud://(.+)};
	#$log->info("looking for  ". 'soundcloud_meta_' . $trackId );
	my $meta      = $cache->get( 'soundcloud_meta_' . $trackId );

	if ( !$meta && !$client->master->pluginData('fetchingMeta') ) {
    # Go fetch metadata for all tracks on the playlist without metadata
    my @need;
    
    for my $track ( @{ Slim::Player::Playlist::playList($client) } ) {
	    my $trackURL = blessed($track) ? $track->url : $track;
	    if ( $trackURL =~ m{soundcloud://(.+)} ) {
        my $id = $1;
        if ( !$cache->get("soundcloud_meta_$id") ) {
                push @need, $id;
        }
	    }
    }
    
    if ( main::DEBUGLOG && $log->is_debug ) {
      $log->debug( "Need to fetch metadata for: " . join( ', ', @need ) );
    }
    
    # $client->master->pluginData( fetchingMeta => 1 );
    
    # my $metaUrl = Slim::Networking::SqueezeNetwork->url(
    #         "/api/classical/v1/playback/getBulkMetadata"
    # );
    
    # my $http = Slim::Networking::SqueezeNetwork->new(
    #         \&_gotBulkMetadata,
    #         \&_gotBulkMetadataError,
    #         {
    #                 client  => $client,
    #                 timeout => 60,
    #         },
    # );

    # $http->post(
    #         $metaUrl,
    #         'Content-Type' => 'application/x-www-form-urlencoded',
    #         'trackIds=' . join( ',', @need ),
    # );
	}

	#$log->debug( "Returning metadata for: $url" . ($meta ? '' : ': default') );

	return $meta || {
	        type      => 'MP3 (Classical.com)',
	        icon      => $icon,
	        cover     => $icon,
	};
}

sub canDirectStreamSong {
  my ( $class, $client, $song ) = @_;
  
  # We need to check with the base class (HTTP) to see if we
  # are synced or if the user has set mp3StreamingMethod
	return $class->SUPER::canDirectStream( $client, $song->streamUrl(), $class->getFormatForURL() );
}

# If an audio stream fails, keep playing
sub handleDirectError {
  my ( $class, $client, $url, $response, $status_line ) = @_;
  
  main::INFOLOG && $log->info("Direct stream failed: $url [$response] $status_line");
  
  $client->controller()->playerStreamingFailed( $client, 'PLUGIN_CLASSICAL_STREAM_FAILED' );
}

1;
