package Plugins::SoundCloud::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

sub name {
	return 'PLUGIN_YOUTUBE';
}

sub page {
	return 'plugins/SoundCloud/settings/basic.html';
}

sub prefs {
	return (preferences('plugin.youtube'), qw(prefer_lowbitrate));
}

1;
