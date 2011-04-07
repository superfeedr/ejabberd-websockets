# Websocket Module for Ejabberd

This is a module that adds websocket support for the [ejabberd](http://www.ejabberd.im/) XMPP server. It's a more elegant, modern and faster replacement to Bosh.

It is an implementation of the [XMPP Over Websocket Draft](http://tools.ietf.org/html/draft-moffitt-xmpp-over-websocket-00) proposed by Jack Moffitt and Eric Cstari. The Websocket implementation is based on this [draft specification](http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-03).

**You need to use the apt version of ejabberd, as the binary install comes with an old version of erlang. **

## Install

### Build
<code>./build.sh</code>

### Install
<code>cp ebin/*.beam /path/to/ejabberd/lib/ebin/</code>

### Configure
In the listeners section add the following line:

<code>{5288, ejabberd_websocket, [{request_handlers, [{["ws-xmpp"], mod_websocket}]}]},</code>

Make sure you also add this line in the <code>Modules</code>

<code>{mod_websocket, []}</code>
		
		
## Usage

Just connect to the websocket using your browser's API, and send your XMPP traffic over it.

You may find it convenient to use directly [Strophejs](https://github.com/metajack/strophejs) as it's a full XMPP library in Javascript. However, you will have to use [this branch](https://github.com/superfeedr/strophejs) for now, as it adds support for websocket, as the underlying protocol (instead of Bosh).

To setup a connection :	
<code>
	// WS_SERVICE should be http://host.tld:5288/ws-xmpp, based on the configuration you chose.
	connection = new Strophe.Connection({protocol: new Strophe.Websocket(WS_SERVICE) }); 
</code>


## TODO

The most 'urgent' thing to do is to provide fallback mechanisms in this module. For example, support for [socket.io](http://socket.io/) would be amazing, as erlang has its own [implementation](https://github.com/yrashk/socket.io-erlang). Feel free to fork and make it better!		

## Thank you

Sponsored by [Superfeedr](http://superfeedr.com). Special thanks to [Nathan](http://unclenaynay.com/) for his awesome work, [Jack](http://metajack.im/) for his help. 

## License

See [License.markdown](./ejabberd-websockets/blob/master/License.markdown).
