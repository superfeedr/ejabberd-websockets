var StropheDemo = function() {
    var connection = null;
    var obj = {
        go: function() {
            Strophe.log = function(level, log) {
                console.log("Logger:"+log);
            };
            console.log("connecting...");
            connection = new Strophe.Connection("ws://localhost:5288/ws-xmpp");
            connection.rawInput = function(log) {
                console.log("RECV:"+log);
            };
            connection.rawOutput = function(log) {
                console.log("SENT:"+log);
            };
            connection.connect("localhost",
                               null,
                               function(cond, status) {
                                   console.log("Connection handler:");
                                   if (cond === 0) {
                                       console.log("Error");
                                       $('#connstate').html('ERROR');
                                   } else if (cond === 1) {
                                       console.log("Connecting");
                                       $('#connstate').html('Connecting');
                                   } else if (cond === 2) {
                                       console.log("Connection Failed");
                                       $('#connstate').html('Connection Failed');
                                   } else if (cond === 3) {
                                       console.log("Authenticating");
                                       $('#connstate').html('Authenticating');
                                   } else if (cond === 4) {
                                       console.log("Auth Failed");
                                       $('#connstate').html('Auth Failed');
                                   } else if (cond === 5) {
                                       console.log("Connected");
                                       $('#connstate').html('Connected');
                                   } else if (cond === 6) {
                                       console.log("disconnected");
                                       $('#connstate').html('Disconnected');
                                   } else if (cond === 7) {
                                       console.log("disconnecting");
                                       $('#connstate').html('Disconnecting');
                                   } else if (cond === 8) {
                                       console.log("Attached");
                                       $('#connstate').html('Attached');
                                   }
                                   if (status) {
                                       console.log(status);
                                   }
                                   return true;
                               });
            connection.addHandler(function(stanza) {
                console.log("Stanza handler.");
                console.log(stanza);
                return true;
            }, null, 'message', null, null, null);
        },
        close: function() {
            connection.disconnect();
        },
        send: function(message) {
            var msg = $msg({to: "thepug@localhost",
                            from: connection.jid,
                            type: "chat"})
                .c("body",
                   {xmlns: Strophe.NS.CLIENT}).t(message);
            msg.up().c("x", {xmlns: "jabber:x:event"}).c("composing");
            connection.send(msg);
        }
    };
    return obj;
}();
$(function() {
    $('#buttonConnect').click(function(event) {
        StropheDemo.go();
    });
    $('#buttonClose').click(function(event) {
        StropheDemo.close();
    });
    $('#buttonSend').click(function(event) {
        StropheDemo.send($('#phrase').val());
        $('#phrase').val('');
    });  
});