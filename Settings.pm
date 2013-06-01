package Plugins::SqueezeCloud::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

sub name {
	return 'PLUGIN_SQUEEZECLOUD';
}

sub page {
	return 'plugins/SqueezeCloud/settings/basic.html';
}

sub prefs {
	return (preferences('plugin.squeezecloud'), qw(apiKey));
}

1;
