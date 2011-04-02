Support for XMPP over websockets.

Proposal Draft -
http://tools.ietf.org/html/draft-moffitt-xmpp-over-websocket-00
Web Sockets -
http://tools.ietf.org/html/draft-ietf-hybi-thewebsocketprotocol-03


Build -
Run ./build.sh

Install -
cp ebin/*.beam /path/to/ejabberd/lib/ebin/

Configuration -

In the listeners section add the following line:
{5288, ejabberd_websocket, [
                              {request_handlers, [
                                                  {["ws-xmpp"],mod_websocket}
                                                 ]}
                             ]
  },
