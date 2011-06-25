if (!window.WebSocket)
{
    alert("WebSocket not supported by this browser");
}
var WsDemo = function() {
    var ws;
    var obj = {
        go: function () {
            ws = new WebSocket("ws://xmpp.mekarena.net:5288/ws-xmpp", "xmpp");
            ws.onerror = function() {
                $('#connstate').html('ERROR');
            };
            ws.onopen = function() {
                $('#connstate').html('CONNECTED');
            };
            ws.onclose = function() {
                $('#connstate').html('CLOSED');
            };
            ws.onmessage = function(e) {
                console.log("Data:");console.log(e.data);
                $('#msgs').html($('#msgs').html() +
                                "<pre>"+
                                e.data +
                                "</pre>");
            };
        },
        close: function() {
            ws.close();
        },
        send: function(text) {
            ws.send(text);
        }
    };
    return obj;
}();
$(function() {
    $('#buttonConnect').click(function(event) {
        WsDemo.go();
    });
    $('#buttonClose').click(function(event) {
        WsDemo.close();
    });
    $('#buttonSend').click(function(event) {
        WsDemo.send($('#phrase').val());
        $('#phrase').val('');
    });  
});
