## A SoundCloud plugin for Logitech SqueezeBox media server.
----
> Install via settings -> plugins -> third party sources -> 

> http://grobbie.github.io/SqueezeCloud/public.xml

*good to know*

You need SSL support in perl for this plugin (soundcloud links are all over HTTPS), so you will need to install some SSL development headers on your server before installing this plugin.

You can do that on debian linux (raspian, ubuntu, mint etc.) like this:

	sudo apt-get install libssl-dev
	sudo perl -MCPAN -e 'install IO::Socket::SSL'
	sudo service logitechmediaserver restart

