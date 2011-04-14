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
-include("ejabberd_websocket.hrl").
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
                partial = <<>>,
                websocket_pid,
                trail = ""
               }).
-define(MAXKEY_LENGTH, 4294967295).
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
                    ?DEBUG("not gen_tcp, ssl? ~p~n", [Binary]),
                    {Request, Trail} = parse_request(
                                         State,
					 State#state.trail ++ 
                                         binary_to_list(Binary)),
		    State1 = State#state{trail = Trail},
		    NewState = lists:foldl(
				 fun(D, S) ->
                                         case S#state.end_of_request of
                                             true ->
                                                 S;
                                             _ ->
                                                 process_header(S, D)
                                         end
				 end, State1, Request),
		    case NewState#state.end_of_request of
			true ->
			    ok;
			_ ->
			    receive_headers(NewState)
		    end;
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
            Out = process_request(State),
            %% Test for web socket
            case (Out =/= false) and is_websocket_upgrade(State#state.request_headers) of
                true ->
                    ?DEBUG("Websocket!",[]),
                    SockMod = State#state.sockmod,
                    Socket = State#state.socket,
                    case SockMod of
                        gen_tcp ->
                            inet:setopts(Socket, [{packet, raw}]);
                        _ ->
                            ok
                    end,
                    %% handle hand shake
                    case handshake(State) of
                        true ->
                            case sub_protocol(State#state.request_headers) of
                                "xmpp" ->
                                    %% send the state back
                                    #state{sockmod = SockMod,
                                           socket = Socket,
                                           request_handlers = State#state.request_handlers};
                                _ ->
                                    ?DEBUG("Bad sub protocol",[]),
                                    #state{end_of_request = true,
                                           request_handlers = State#state.request_handlers} 
                            end;    
                        _ ->
                            ?DEBUG("Bad Handshake",[]),
                            #state{end_of_request = true,
                                   request_handlers = State#state.request_handlers}
                    end;
                _ ->
                    ?DEBUG("Regular HTTP",[]),
                    #state{end_of_request = true,
                           request_handlers = State#state.request_handlers}
            end;
        {error, closed} ->
            ?ERROR_MSG("Socket closed", [State]),
            process_data(State, socket_closed),
            #state{end_of_request = true,
                   request_handlers = State#state.request_handlers};
        {error, timeout} ->
            ?DEBUG("Socket recv timed out. Return the same State.",[]),
            State;
        {ok, HData} ->
            PData = case State#state.partial of
                        <<>> -> 
                            HData;
                        <<X/binary>> -> 
                            <<X, HData>>
                    end,
            {_Out, Partial, Pid} = case process_data(State, PData) of 
                                       {O, P} -> 
                                           {O, P, false};
                                       {Output, Part, ProcId} -> 
                                           {Output, Part, ProcId};
                                       Error ->
                                           {Error, undefined, undefined}
                                   end,
            ?DEBUG("C2SPid:~p~n",[Pid]),
            case Pid of
                false ->
                    #state{sockmod = State#state.sockmod,
                           socket = State#state.socket,
                           partial = Partial,                
                           request_handlers = State#state.request_handlers};
                _ ->
                    #state{sockmod = State#state.sockmod,
                           socket = State#state.socket,
                           partial = Partial,
                           websocket_pid = Pid,
                           request_handlers = State#state.request_handlers}
            end;
        _ ->
            ?DEBUG("Not expected: ~p~n",[Data]),
            #state{end_of_request = true,
                   request_handlers = State#state.request_handlers}
    end.

add_header(Name, Value, State) ->
    [{Name, Value} | State#state.request_headers].

is_websocket_upgrade(RequestHeaders) ->
    Connection = {'Connection', "Upgrade"} == lists:keyfind('Connection', 1, 
                                                            RequestHeaders),
    Upgrade = {'Upgrade', "WebSocket"} == lists:keyfind('Upgrade', 1,
                                                        RequestHeaders),
    Connection and Upgrade.

handshake(State) ->
    SockMod = State#state.sockmod,
    Socket = State#state.socket,
    Data = SockMod:recv(Socket, 0, 300000),
    case Data of 
        {ok, BinData} ->
            ?DEBUG("Handshake data received.", [State#state.request_headers]),
            {_, Host} = lists:keyfind('Host', 1, State#state.request_headers),
            {_, Origin} = lists:keyfind("Origin", 
                                        1, State#state.request_headers),
            SubProto = sub_protocol(State#state.request_headers),
            {_, Key1} = lists:keyfind("Sec-Websocket-Key1", 
                                      1, 
                                      State#state.request_headers),
            {_, Key2} = lists:keyfind("Sec-Websocket-Key2", 
                                      1, 
                                      State#state.request_headers),
            case websocket_verify_keys(Key1, Key2) of
                {Part1, Part2} ->
                    Sig = websocket_sign(Part1, Part2, BinData),
                    %% Build response
                    Res = build_handshake_response(State#state.socket, 
                                                   Host,
                                                   Origin, 
                                                   State#state.request_path, 
                                                   SubProto, 
                                                   Sig),
                    ?DEBUG("Sending handshake response:~p~n",[Res]),
                    %% send response
                    case send_text(State, Res) of
                        ok -> true;
                        E ->
                            ?DEBUG("ERROR Sending text:~p~n",[E]),
                            false
                    end;
                false ->
                    ?ERROR_MSG("Error during handshake verification:~p~n",
                               [State]),
                    false
            end;
        {error, Res} ->
            %% report error and close connection by returning false
            ?ERROR_MSG("Error during handshake:~p~n",[Res]),
            false;
        D ->
            ?DEBUG("Unexpected Data in handshake:~p~n", [D]),
            false
    end.
process_data(State, Data) ->
    SockMod = State#state.sockmod,
    Socket = State#state.socket,
    RequestHeaders = State#state.request_headers,
    Host = State#state.request_host,
    Path = case State#state.request_path of
               undefined -> ["ws-xmpp"];
               X -> X
           end,
    PeerRet = case SockMod of
                  gen_tcp ->
                      inet:peername(Socket);
                  _ ->
                      SockMod:peername(Socket)
              end,
    IP = case PeerRet of 
             {ok, IPHere} ->
                 XFF = proplists:get_value('X-Forwarded-For', 
                                           RequestHeaders, []),
                 analyze_ip_xff(IPHere, XFF, Host);
             {error, _Error} ->
                 undefined
         end,
    Request = #wsrequest{method = State#state.request_method,
                         path = Path,
                         headers = State#state.request_headers,
                         data = Data,
                         fsmref = State#state.websocket_pid,
                         wsocket = Socket,
                         wsockmod = SockMod,
                         ip = IP
                      },
    process(State#state.request_handlers, Request).

process_request(#state{request_method = Method,
                       request_path = {abs_path, Path},
		       request_handlers = RequestHandlers,
		       request_headers = RequestHeaders,
		       sockmod = SockMod,
		       socket = Socket
                      } = State) when Method=:='GET' ->
    case (catch url_decode_q_split(Path)) of
        {'EXIT', _} ->
            process_request(false);
        {NPath, _Query} ->
            %% Build Request
            LPath = [path_decode(NPE) || NPE <- string:tokens(NPath, 
                                                              "/")],
            Request = #wsrequest{method = Method,
                                 path = LPath,
                                 headers = RequestHeaders,
                                 wsocket = Socket,
                                 wsockmod = SockMod
                                },
            ?INFO_MSG("Processing request:~p:~p~n",[Request, State]),
            process(RequestHandlers, Request)        
    end;
process_request(State) ->
    ?DEBUG("Not a handshake: ~p~n", [State]),
    false.
%% process web socket requests, if no handler found return false.
process([], _) ->
    false;
process(RequestHandlers, Request) ->
    [{HandlerPathPrefix, HandlerModule} | HandlersLeft] = RequestHandlers,    
    case (lists:prefix(HandlerPathPrefix, Request#wsrequest.path) or
          (HandlerPathPrefix==Request#wsrequest.path)) of
	true ->
            ?DEBUG("~p matches ~p", 
                   [Request#wsrequest.path, HandlerPathPrefix]),
            %% LocalPath is the path "local to the handler", i.e. if
            %% the handler was registered to handle "/test/" and the
            %% requested path is "/test/foo/bar", the local path is
            %% ["foo", "bar"]
            LocalPath = lists:nthtail(length(HandlerPathPrefix), 
                                      Request#wsrequest.path),
            HandlerModule:process(LocalPath, Request);            
	false ->
	    process(HandlersLeft, Request)
    end.
%% send data
send_text(State, Text) ->
    case catch (State#state.sockmod):send(State#state.socket, Text) of
        ok -> ok;
	{error, timeout} ->
	    ?INFO_MSG("Timeout on ~p:send",[State#state.sockmod]),
	    exit(normal);
        Error ->
	    ?DEBUG("Error in ~p:send: ~p",[State#state.sockmod, Error]),
	    exit(normal)
    end.
%% sign data
websocket_sign(Part1, Part2, Key3) ->
    crypto:md5( <<Part1:32/unsigned-integer, Part2:32/unsigned-integer,
                 Key3/binary>> ).
%% verify websocket keys
websocket_verify_keys(Key1, Key2) ->
    P1 = parse_seckey(Key1),
    P2 = parse_seckey(Key2),
    websocket_verify_parsed_sec(P1, P2).
websocket_verify_parsed_sec({N1,S1}, {N2,S2}) ->
    case N1 > ?MAXKEY_LENGTH orelse 
        N2 > ?MAXKEY_LENGTH orelse 
        S1 == 0 orelse
        S2 == 0 of
        true ->
            %%  This is a symptom of an attack.
            false;
        false ->
            case N1 rem S1 /= 0 orelse N2 rem S2 /= 0 of
                true ->
                    %% This can only happen if the client is not a conforming
                    %% WebSocket client.
                    false;
                false ->
                    {erlang:round(N1/S1), erlang:round(N2/S2)}
            end
    end.
%% websocket seckey parser:
%% extract integer by only looking at [0-9]+ in the string
%% count spaces in the string
%% returns: {int, numspaces}
parse_seckey(Str) ->
    parse_seckey1(Str, {"",0}).
parse_seckey1("", {NumStr,NumSpaces}) ->
    {list_to_integer(lists:reverse(NumStr)), NumSpaces};
parse_seckey1([32|T], {Ret,NumSpaces}) -> % ASCII/dec space
    parse_seckey1(T, {Ret, 1+NumSpaces});
parse_seckey1([N|T],  {Ret,NumSpaces}) when N >= $0, N =< $9 -> 
    parse_seckey1(T, {[N|Ret], NumSpaces});
parse_seckey1([_|T], Acc) -> 
    parse_seckey1(T, Acc).

%% build the handshake response
build_handshake_response(Socket, Host, Origin, Path, SubProto, Sig) ->
    Proto = case Socket of 
                {ssl,_}   -> "wss://"; 
                _         -> "ws://" 
            end,
    SubProtoHeader = case SubProto of 
                         undefined  -> ""; 
                         P          -> ["Sec-WebSocket-Protocol: ", P, "\r\n"]
                     end,
    {abs_path, APath} = Path,
    ["HTTP/1.1 101 Web Socket Protocol Handshake\r\n",
     "Upgrade: WebSocket\r\n",
     "Connection: Upgrade\r\n",
     "Sec-WebSocket-Location: ", Proto, Host, APath, "\r\n",
     "Sec-WebSocket-Origin: ", Origin, "\r\n",
     SubProtoHeader,
     "\r\n",
     <<Sig/binary>>
    ].
sub_protocol(Headers) ->
    SubProto = case lists:keyfind("Sec-WebSocket-Protocol", 1, Headers) of
                   {"Sec-WebSocket-Protocol", SubP} -> SubP;
                   _ -> "xmpp"
               end,
    SubProto.
%% Support for X-Forwarded-From
analyze_ip_xff(IP, [], _Host) ->
    IP;
analyze_ip_xff({IPLast, Port}, XFF, Host) ->
    [ClientIP | ProxiesIPs] = string:tokens(XFF, ", ")
	++ [inet_parse:ntoa(IPLast)],
    TrustedProxies = case ejabberd_config:get_local_option(
			    {trusted_proxies, Host}) of
			 undefined -> [];
			 TPs -> TPs
		     end,
    IPClient = case is_ipchain_trusted(ProxiesIPs, TrustedProxies) of
		   true ->
		       {ok, IPFirst} = inet_parse:address(ClientIP),
		       ?DEBUG("The IP ~w was replaced with ~w due to header "
			      "X-Forwarded-For: ~s", [IPLast, IPFirst, XFF]),
		       IPFirst;
		   false ->
		       IPLast
	       end,
    {IPClient, Port}.
is_ipchain_trusted(_UserIPs, all) ->
    true;
is_ipchain_trusted(UserIPs, TrustedIPs) ->
    [] == UserIPs -- ["127.0.0.1" | TrustedIPs].
% Code below is taken (with some modifications) from the yaws webserver, which
% is distributed under the folowing license:
%
% This software (the yaws webserver) is free software.
% Parts of this software is Copyright (c) Claes Wikstrom <klacke@hyber.org>
% Any use or misuse of the source code is hereby freely allowed.
%
% 1. Redistributions of source code must retain the above copyright
%    notice as well as this list of conditions.
%
% 2. Redistributions in binary form must reproduce the above copyright
%    notice as well as this list of conditions.
url_decode_q_split(Path) ->
    url_decode_q_split(Path, []).
url_decode_q_split([$?|T], Ack) ->
    %% Don't decode the query string here, that is parsed separately.
    {path_norm_reverse(Ack), T};
url_decode_q_split([H|T], Ack) when H /= 0 ->
    url_decode_q_split(T, [H|Ack]);
url_decode_q_split([], Ack) ->
    {path_norm_reverse(Ack), []}.
%% @doc Decode a part of the URL and return string()
path_decode(Path) ->
    path_decode(Path, []).
path_decode([$%, Hi, Lo | Tail], Ack) ->
    Hex = hex_to_integer([Hi, Lo]),
    if Hex  == 0 -> exit(badurl);
       true -> ok
    end,
    path_decode(Tail, [Hex|Ack]);
path_decode([H|T], Ack) when H /= 0 ->
    path_decode(T, [H|Ack]);
path_decode([], Ack) ->
    lists:reverse(Ack).

path_norm_reverse("/" ++ T) -> start_dir(0, "/", T);
path_norm_reverse(       T) -> start_dir(0,  "", T).

start_dir(N, Path, ".."       ) -> rest_dir(N, Path, "");
start_dir(N, Path, "/"   ++ T ) -> start_dir(N    , Path, T);
start_dir(N, Path, "./"  ++ T ) -> start_dir(N    , Path, T);
start_dir(N, Path, "../" ++ T ) -> start_dir(N + 1, Path, T);
start_dir(N, Path,          T ) -> rest_dir (N    , Path, T).

rest_dir (_N, Path, []         ) -> case Path of
				       [] -> "/";
				       _  -> Path
				   end;
rest_dir (0, Path, [ $/ | T ] ) -> start_dir(0    , [ $/ | Path ], T);
rest_dir (N, Path, [ $/ | T ] ) -> start_dir(N - 1,        Path  , T);
rest_dir (0, Path, [  H | T ] ) -> rest_dir (0    , [  H | Path ], T);
rest_dir (N, Path, [  _H | T ] ) -> rest_dir (N    ,        Path  , T).

%% hex_to_integer


hex_to_integer(Hex) ->
    case catch erlang:list_to_integer(Hex, 16) of
	{'EXIT', _} ->
	    old_hex_to_integer(Hex);
	X ->
	    X
    end.


old_hex_to_integer(Hex) ->
    DEHEX = fun (H) when H >= $a, H =< $f -> H - $a + 10;
		(H) when H >= $A, H =< $F -> H - $A + 10;
		(H) when H >= $0, H =< $9 -> H - $0
	    end,
    lists:foldl(fun(E, Acc) -> Acc*16+DEHEX(E) end, 0, Hex).

% The following code is mostly taken from yaws_ssl.erl

parse_request(State, Data) ->
    case Data of
	[] ->
	    {[], []};
	_ ->
	    ?DEBUG("GOT ssl data ~p~n", [Data]),
	    {R, Trail} = case State#state.request_method of
			     undefined ->
				 {R1, Trail1} = get_req(Data),
				 ?DEBUG("Parsed request ~p~n", [R1]),
				 {[R1], Trail1};
			     _ ->
				 {[], Data}
			 end,
	    {H, Trail2} = get_headers(Trail),
	    {R ++ H, Trail2}
    end.

get_req("\r\n\r\n" ++ _) ->
    bad_request;
get_req("\r\n" ++ Data) ->
    get_req(Data);
get_req(Data) ->
    {FirstLine, Trail} = lists:splitwith(fun not_eol/1, Data),
    R = parse_req(FirstLine),
    {R, Trail}.


not_eol($\r)->
    false;
not_eol($\n) ->
    false;
not_eol(_) ->
    true.


get_word(Line)->
    {Word, T} = lists:splitwith(fun(X)-> X /= $\  end, Line),
    {Word, lists:dropwhile(fun(X) -> X == $\  end, T)}.


parse_req(Line) ->
    {MethodStr, L1} = get_word(Line),
    ?DEBUG("Method: ~p~n", [MethodStr]),
    case L1 of
	[] ->
	    bad_request;
	_ ->
	    {URI, L2} = get_word(L1),
	    {VersionStr, L3} = get_word(L2),
	    ?DEBUG("URI: ~p~nVersion: ~p~nL3: ~p~n",
		[URI, VersionStr, L3]),
	    case L3 of
		[] ->
		    Method = case MethodStr of
				 "GET" -> 'GET';
				 "POST" -> 'POST';
				 "HEAD" -> 'HEAD';
				 "OPTIONS" -> 'OPTIONS';
				 "TRACE" -> 'TRACE';
				 "PUT" -> 'PUT';
				 "DELETE" -> 'DELETE';
				 S -> S
			     end,
		    Path = case URI of
			       "*" ->
			       % Is this correct?
				   "*";
			       _ ->
				   case string:str(URI, "://") of
				       0 ->
				           % Relative URI
				           % ex: /index.html
				           {abs_path, URI};
				       N ->
				           % Absolute URI
				           % ex: http://localhost/index.html

				           % Remove scheme
				           % ex: URI2 = localhost/index.html
				           URI2 = string:substr(URI, N + 3),
				           % Look for the start of the path
				           % (or the lack of a path thereof)
				           case string:chr(URI2, $/) of
				               0 -> {abs_path, "/"};
				               M -> {abs_path,
				                   string:substr(URI2, M + 1)}
				           end
				   end
			   end,
		    case VersionStr of
			[] ->
			    {ok, {http_request, Method, Path, {0,9}}};
			"HTTP/1.0" ->
			    {ok, {http_request, Method, Path, {1,0}}};
			"HTTP/1.1" ->
			    {ok, {http_request, Method, Path, {1,1}}};
			_ ->
			    bad_request
		    end;
		_ ->
		    bad_request
	    end
    end.


get_headers(Tail) ->
    get_headers([], Tail).

get_headers(H, Tail) ->
    case get_line(Tail) of
	{incomplete, Tail2} ->
	    {H, Tail2};
	{line, Line, Tail2} ->
	    get_headers(H ++ parse_line(Line), Tail2);
	{lastline, Line, Tail2} ->
	    {H ++ parse_line(Line) ++ [{ok, http_eoh}], Tail2}
    end.


parse_line("Connection:" ++ Con) ->
    [{ok, {http_header,  undefined, 'Connection', undefined, strip_spaces(Con)}}];
parse_line("Host:" ++ Con) ->
    [{ok, {http_header,  undefined, 'Host', undefined, strip_spaces(Con)}}];
parse_line("Accept:" ++ Con) ->
    [{ok, {http_header,  undefined, 'Accept', undefined, strip_spaces(Con)}}];
parse_line("If-Modified-Since:" ++ Con) ->
    [{ok, {http_header,  undefined, 'If-Modified-Since', undefined, strip_spaces(Con)}}];
parse_line("If-Match:" ++ Con) ->
    [{ok, {http_header,  undefined, 'If-Match', undefined, strip_spaces(Con)}}];
parse_line("If-None-Match:" ++ Con) ->
    [{ok, {http_header,  undefined, 'If-None-Match', undefined, strip_spaces(Con)}}];
parse_line("If-Range:" ++ Con) ->
    [{ok, {http_header,  undefined, 'If-Range', undefined, strip_spaces(Con)}}];
parse_line("If-Unmodified-Since:" ++ Con) ->
    [{ok, {http_header,  undefined, 'If-Unmodified-Since', undefined, strip_spaces(Con)}}];
parse_line("Range:" ++ Con) ->
    [{ok, {http_header,  undefined, 'Range', undefined, strip_spaces(Con)}}];
parse_line("User-Agent:" ++ Con) ->
    [{ok, {http_header,  undefined, 'User-Agent', undefined, strip_spaces(Con)}}];
parse_line("Accept-Ranges:" ++ Con) ->
    [{ok, {http_header,  undefined, 'Accept-Ranges', undefined, strip_spaces(Con)}}];
parse_line("Authorization:" ++ Con) ->
    [{ok, {http_header,  undefined, 'Authorization', undefined, strip_spaces(Con)}}];
parse_line("Keep-Alive:" ++ Con) ->
    [{ok, {http_header,  undefined, 'Keep-Alive', undefined, strip_spaces(Con)}}];
parse_line("Referer:" ++ Con) ->
    [{ok, {http_header,  undefined, 'Referer', undefined, strip_spaces(Con)}}];
parse_line("Content-type:"++Con) ->
    [{ok, {http_header,  undefined, 'Content-Type', undefined, strip_spaces(Con)}}];
parse_line("Content-Type:"++Con) ->
    [{ok, {http_header,  undefined, 'Content-Type', undefined, strip_spaces(Con)}}];
parse_line("Content-Length:"++Con) ->
    [{ok, {http_header,  undefined, 'Content-Length', undefined, strip_spaces(Con)}}];
parse_line("Content-length:"++Con) ->
    [{ok, {http_header,  undefined, 'Content-Length', undefined, strip_spaces(Con)}}];
parse_line("Cookie:"++Con) ->
    [{ok, {http_header,  undefined, 'Cookie', undefined, strip_spaces(Con)}}];
parse_line("Accept-Language:"++Con) ->
    [{ok, {http_header,  undefined, 'Accept-Language', undefined, strip_spaces(Con)}}];
parse_line("Accept-Encoding:"++Con) ->
    [{ok, {http_header,  undefined, 'Accept-Encoding', undefined, strip_spaces(Con)}}];
parse_line(S) ->
    case lists:splitwith(fun(C)->C /= $: end, S) of
	{Name, [$:|Val]} ->
	    [{ok, {http_header,  undefined, Name, undefined, strip_spaces(Val)}}];
	_ ->
	    []
    end.


is_space($\s) ->
    true;
is_space($\r) ->
    true;
is_space($\n) ->
    true;
is_space($\t) ->
    true;
is_space(_) ->
    false.


strip_spaces(String) ->
    strip_spaces(String, both).

strip_spaces(String, left) ->
    drop_spaces(String);
strip_spaces(String, right) ->
    lists:reverse(drop_spaces(lists:reverse(String)));
strip_spaces(String, both) ->
    strip_spaces(drop_spaces(String), right).

drop_spaces([]) ->
    [];
drop_spaces(YS=[X|XS]) ->
    case is_space(X) of
	true ->
	    drop_spaces(XS);
	false ->
	    YS
    end.

is_nb_space(X) ->
    lists:member(X, [$\s, $\t]).


% ret: {line, Line, Trail} | {lastline, Line, Trail}

get_line(L) ->
    get_line(L, []).
get_line("\r\n\r\n" ++ Tail, Cur) ->
    {lastline, lists:reverse(Cur), Tail};
get_line("\r\n" ++ Tail, Cur) ->
    case Tail of
	[] ->
	    {incomplete, lists:reverse(Cur) ++ "\r\n"};
	_ ->
	    case is_nb_space(hd(Tail)) of
		true ->  %% multiline ... continue
		    get_line(Tail, [$\n, $\r | Cur]);
		false ->
		    {line, lists:reverse(Cur), Tail}
	    end
    end;
get_line([H|T], Cur) ->
    get_line(T, [H|Cur]).
