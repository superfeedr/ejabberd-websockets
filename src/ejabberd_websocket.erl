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
-include("jlib.hrl").
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
	    inet:setopts(Socket1, [{packet, http}, {recbuf, 8192}]);
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
    case State#state.sockmod of
        gen_tcp ->
            NewState = process_header(State, Data),
            case NewState#state.end_of_request of
                true ->
                    ok;
                _ ->
                    receive_headers(NewState)
            end;
        _ ->
            case Data of
                {ok, Binary} ->
                    ?DEBUG("not gen_tcp ~p~n", [Binary]);
                Req ->
                    ?DEBUG("not gen_tcp or ok: ~p~n", [Req]),
                    ok
            end
    end.

process_header(State, Data) ->
    case Data of
	{ok, {http_request, Method, Uri, Version}} ->
            KeepAlive = case Version of
		{1, 1} ->
		    true;
		_ ->
		    false
	    end,
	    Path = case Uri of
	        {absoluteURI, _Scheme, _Host, _Port, P} -> {abs_path, P};
	        _ -> Uri
	    end,
	    State#state{request_method = Method,
			request_version = Version,
			request_path = Path,
			request_keepalive = KeepAlive};
        {ok, {http_header, _, 'Connection'=Name, _, Conn}} ->
	    KeepAlive1 = case jlib:tolower(Conn) of
			     "keep-alive" ->
				 true;
			     "close" ->
				 false;
			     _ ->
				 State#state.request_keepalive
			 end,
	    State#state{request_keepalive = KeepAlive1,
			request_headers=add_header(Name, Conn, State)};
	{ok, {http_header, _, 'Content-Length'=Name, _, SLen}} ->
	    case catch list_to_integer(SLen) of
		Len when is_integer(Len) ->
		    State#state{request_content_length = Len,
				request_headers=add_header(Name, SLen, State)};
		_ ->
		    State
	    end;
	{ok, {http_header, _, 'Host'=Name, _, Host}} ->
	    State#state{request_host = Host,
			request_headers=add_header(Name, Host, State)};
	{ok, {http_header, _, Name, _, Value}} ->
	    State#state{request_headers=add_header(Name, Value, State)};
	{ok, http_eoh} when State#state.request_host == undefined ->
	    ?WARNING_MSG("An HTTP request without 'Host' HTTP header was received.", []),
	    throw(http_request_no_host_header);
        {ok, http_eoh} ->
	    ?DEBUG("(~w) http query: ~w ~s~n",
		   [State#state.socket,
		    State#state.request_method,
		    element(2, State#state.request_path)]),
            %% Test for web socket
            case is_websocket_upgrade(State) of
                true ->
                    ?DEBUG("Websocket!",[]);
                _ ->
                    ?DEBUG("Regular HTTP",[])
            end;
        _ ->
            ?DEBUG("Not expected: ~p~n",[Data]),
            #state{end_of_request = true,
                   request_handlers = State#state.request_handlers}
    end.

add_header(Name, Value, State) ->
    [{Name, Value} | State#state.request_headers].

is_websocket_upgrade(State) ->
    Connection = {'Connection', 
                  "Upgrade"} == lists:keyfind('Connection', 1, 
                                              State#state.request_headers),
    Upgrade = {'Upgrade', 
               "WebSocket"} == lists:keyfind('Upgrade', 1,
                                             State#state.request_headers),
    Connection and Upgrade.
