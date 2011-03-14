if (!window.WebSocket)
{
    alert("WebSocket not supported by this browser");
}
var WsDemo = function() {
    var ws;
    var obj = {
        go: function () {
            ws = new WebSocket("wss://localhost:5280/");
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
                $('#msgs').html($('#msgs').html() +
                                "<pre>"+
                                e.data +
                                "</pre>");
            };
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
    $('#buttonSend').click(function(event) {
        WsDemo.send($('phrase').value);
        $('phrase').value='';
    });  
});