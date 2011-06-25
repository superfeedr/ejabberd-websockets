var StropheDemo = function() {
  var connection = null;
  var obj = {
    go: function(un, pw) {
      Strophe.log = function(level, log) {
        console.log("Logger:"+log);
      };

      console.log("connecting...");

      var server = $("#server").val();
      connection = new Strophe.Connection({proto : new Strophe.Websocket("ws://" + server + ":5288/ws-xmpp")});

      connection.rawInput = function(log) {
        var xml = $($.parseXML(log));
        
        if(xml.find("body").length){
          var from = xml.find("message").attr("from").split("/")[0];
          var msg = xml.find("body").text();
          $("#msgs").prepend("<p><strong>" + from + "</strong>: " + msg + "</p>");
        }
      };

      connection.rawOutput = function(log) {
        console.log("SENT:"+log);
      };

      connection.connect(un, pw, function(cond, status) {
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
                                 console.log("sending presence tree...");
                                 connection.send($pres().tree());
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

    setPresence: function(){
      connection.send($pres().tree());
    },

    send: function(message, to) {
      var msg = $msg({to: to, from: connection.jid, type: "chat"}).c("body", {xmlns: Strophe.NS.CLIENT}).t(message); 
      msg.up().c("x", {xmlns: "jabber:x:event"}).c("composing");
      connection.send(msg);
    }
  };

  return obj;
}();

$(function() {
  $('#connect').submit(function(e) {
    e.preventDefault();
    var un = $('#un').val() + "@" + $('#un_server').val();
    var pw = $('#pw').val();
    StropheDemo.go(un, pw);
  });

  $('#buttonClose').click(function(e) {
    StropheDemo.close();
  });

  $('#sendMessage').submit(function(e) {
    e.preventDefault();

    var msg = $("#phrase").val();
    var to = $("#to").val() + "@" + $('#to_server').val();
    var from = $('#un').val() + "@" + $('#un_server').val();
    StropheDemo.send(msg, to);
    $('#phrase').val('');
    $("#msgs").prepend("<p><strong>" + from + "</strong>: " + msg + "</p>");
  });

  $("#server").bind("change", function(){
    var server = $(this).val();
    var unServer = $("#un_server");
    var toServer = $("#to_server");
    if((unServer.val() == server && toServer.val() == server) || (!unServer.val() && !toServer.val())){
      $('#un_server, #to_server').val($(this).val());
    }
  });
});
