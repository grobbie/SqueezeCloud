package Plugins::SoundCloud::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

sub name {
	return 'PLUGIN_SOUNDCLOUD';
}

sub page {
	return 'plugins/SoundCloud/settings/basic.html';
}

sub prefs {
	return (preferences('plugin.soundcloud'), qw(apikey));
}

1;
