%%%----------------------------------------------------------------------
%%% File    : ejabberd_websocket.erl
%%% Author  : Nathan Zorn <nathan.zorn@gmail.com>
%%% Purpose : Listener for XMPP over websockets
%%%----------------------------------------------------------------------

-module(ejabberd_websocket).
-author('nathan.zorn@gmail.com').

%% External Exports
-export([start/2,
         start_link/2,
         become_controller/1,
         socket_type/0,
         receive_headers/1]).
%% Callbacks
-export([init/2]).
%% Includes
-include("ejabberd.hrl").
%% record used to keep track of listener state
-record(state, {sockmod,
		socket,
		request_method,
		request_version,
		request_path,
		request_auth,
		request_keepalive,
		request_content_length,
		request_lang = "en",
		request_handlers = [],
		request_host,
		request_port,
		request_tp,
		request_headers = [],
		end_of_request = false,
                trail = ""
               }).
%% Supervisor Start
start(SockData, Opts) ->
    supervisor:start_child(ejabberd_websocket_sup, [SockData, Opts]).

start_link(SockData, Opts) ->
    {ok, proc_lib:spawn_link(ejabberd_websocket, init, [SockData, Opts])}.

init({SockMod, Socket}, Opts) ->
    TLSEnabled = lists:member(tls, Opts),
    TLSOpts1 = lists:filter(fun({certfile, _}) -> true;
			      (_) -> false
			   end, Opts),
    TLSOpts = [verify_none | TLSOpts1],
    {SockMod1, Socket1} =
	if
	    TLSEnabled ->
		inet:setopts(Socket, [{recbuf, 8192}]),
		{ok, TLSSocket} = tls:tcp_to_tls(Socket, TLSOpts),
		{tls, TLSSocket};
	    true ->
		{SockMod, Socket}
	end,
    case SockMod1 of
	gen_tcp ->
	    inet:setopts(Socket1, [{packet, raw}, {recbuf, 8192}]);
	_ ->
	    ok
    end,
    RequestHandlers =
	case lists:keysearch(request_handlers, 1, Opts) of
	    {value, {request_handlers, H}} -> H;
	    false -> []
        end,
    ?DEBUG("Handlers: ~p~n", [RequestHandlers]),
    ?INFO_MSG("started: ~p", [{SockMod1, Socket1}]),
    State = #state{sockmod = SockMod1,
                   socket = Socket1,
                   request_handlers = RequestHandlers},
    receive_headers(State).

become_controller(_Pid) ->
    ok.
socket_type() ->
    raw.

receive_headers(State) ->
    SockMod = State#state.sockmod,
    Socket = State#state.socket,
    Data = SockMod:recv(Socket, 0, 300000),
    ?DEBUG("Data in ~p: headers : ~p",[State, Data]),
    #state{end_of_request = true,
           request_handlers = State#state.request_handlers}.


