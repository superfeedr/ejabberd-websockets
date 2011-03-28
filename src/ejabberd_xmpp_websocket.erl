%%%----------------------------------------------------------------------
%%% File    : ejabberd_xmpp_websocket.erl
%%% Author  : Nathan Zorn (nathan.zorn@gmail.com)
%%% Purpose : Implements XMPP over WebSockets 
%%%----------------------------------------------------------------------
-module(ejabberd_xmpp_websocket).

-behaviour(gen_fsm).

-export([start_link/3,
	 init/1,
	 handle_event/3,
	 handle_sync_event/4,
	 code_change/4,
	 handle_info/3,
	 terminate/3,
	 send/2,
	 send_xml/2,
	 sockname/1,
	 peername/1,
	 setopts/2,
	 controlling_process/2,
	 become_controller/2,
	 custom_receiver/1,
	 reset_stream/1,
	 change_shaper/2,
	 monitor/1,
	 close/1,
	 start/4,
	 process_request/5]).

-include("ejabberd.hrl").

%% Module constants
-define(NULL_PEER, {{0, 0, 0, 0}, 0}).
-define(MAX_INACTIVITY, 30000000). % msecs to wait before terminating
                                % idle sessions
-define(MAX_PAUSE, 120). % may num of sec a client is allowed to pause
                         % the session
-define(NS_CLIENT, "jabber:client").
-define(NS_STREAM, "http://etherx.jabber.org/streams").
%%  Erlang Records for state
-record(wsr, {socket, sockmod, key, out}).

-record(state, {id,
		key,
		socket,
		output = "",
		input = queue:new(),
		waiting_input = false,
		shaper_state,
		shaper_timer,
		last_receiver,
		last_poll,
                websocket_sockmod,
                websocket_s,
		websocket_receiver,
		wait_timer,
		ctime = 0,
		timer,
		pause=0,
		unprocessed_req_list = [], % list of request that have been delayed for proper reordering: {Request, PID}
		req_list = [], % list of requests (cache)
		max_inactivity,
		max_pause,
		ip = ?NULL_PEER
	       }).

start(Host, Sid, Key, IP) ->
    Proc = gen_mod:get_module_proc(Host, ejabberd_mod_websocket),
    case catch supervisor:start_child(Proc, [Sid, Key, IP]) of
    	{ok, Pid} -> {ok, Pid};
	Reason ->
            ?ERROR_MSG("~p~n",[Reason]),
            {error, "Cannot start XMPP, Websocket session"}
    end.

start_link(Sid, Key, IP) ->
    gen_fsm:start_link(?MODULE, [Sid, Key, IP], []).

send({xmpp_websocket, FsmRef, _IP}, Packet) ->
    gen_fsm:sync_send_all_state_event(FsmRef, {send, Packet}).

send_xml({xmpp_websocket, FsmRef, _IP}, Packet) ->
    gen_fsm:sync_send_all_state_event(FsmRef, {send_xml, Packet}).

setopts({xmpp_websocket, FsmRef, _IP}, Opts) ->
    case lists:member({active, once}, Opts) of
	true ->
	    gen_fsm:send_all_state_event(FsmRef, {activate, self()});
	_ ->
	    ok
    end.

controlling_process(_Socket, _Pid) ->
    ok.

custom_receiver({xmpp_websocket, FsmRef, _IP}) ->
    {receiver, ?MODULE, FsmRef}.

become_controller(FsmRef, C2SPid) ->
    gen_fsm:send_all_state_event(FsmRef, {become_controller, C2SPid}).

reset_stream({xmpp_websocket, _FsmRef, _IP}) ->
    ok.

change_shaper({xmpp_websocket, FsmRef, _IP}, Shaper) ->
    gen_fsm:send_all_state_event(FsmRef, {change_shaper, Shaper}).

monitor({xmpp_websocket, FsmRef, _IP}) ->
    erlang:monitor(process, FsmRef).

close({xmpp_websocket, FsmRef, _IP}) ->
    catch gen_fsm:sync_send_all_state_event(FsmRef, {stop, close}).

sockname(_Socket) ->
    {ok, ?NULL_PEER}.

peername({xmpp_websocket, _FsmRef, IP}) ->
    {ok, IP}.

%% entry point for websocket data
process_request(WSockMod, WSock, FsmRef, Data, IP) ->
    Opts1 = ejabberd_c2s_config:get_c2s_limits(),
    Opts = [{xml_socket, true} | Opts1],
    MaxStanzaSize =
	case lists:keysearch(max_stanza_size, 1, Opts) of
	    {value, {_, Size}} -> Size;
	    _ -> infinity
	end,
    PayloadSize = iolist_size(Data),
    case validate_request(Data, PayloadSize, MaxStanzaSize) of
        {ok, ParsedPayload} ->
            case stream_start(ParsedPayload) of
                {Host, Sid, Key} when (FsmRef =:= false) or 
                                      (FsmRef =:= undefined) ->
                    case start(Host, Sid, Key, IP) of
                        {ok, Pid} -> 
                            ?DEBUG("Session Pid:~p~n",[Pid]),
                            gen_fsm:sync_send_all_state_event(
                              Pid, 
                              #wsr{sockmod=WSockMod, 
                                   socket=WSock, 
                                   out=[ParsedPayload]}),
                            {<<"session started">>,<<>>,Pid};
                        S -> 
                            ?ERROR_MSG("Error starting session:~p~n", [S])
                    end;
                false ->
                    ?DEBUG("session pid:~p~n",[FsmRef]),
                    case FsmRef of
                        false ->
                            ?DEBUG("No session started.",[]);
                        _ ->
                            ?DEBUG("Writing data!.",[]),
                            %% write data to c2s            
                            gen_fsm:sync_send_all_state_event(
                              FsmRef, 
                              #wsr{sockmod=WSockMod, 
                                   socket=WSock, 
                                   out=[ParsedPayload]})
                    end,
                    {Data, <<>>};
                _ ->
                    ?ERROR_MSG("Stream Start with no FSM reference: ~p~n",
                               [FsmRef]),
                    {Data, <<>>}
            end;
        _ ->
            ?DEBUG("Bad Request: ~p~n", [Data]),
            {<<"bad request">>, <<>>}
    end.    

%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}
%%----------------------------------------------------------------------
init([Sid, Key, IP]) ->
    ?DEBUG("started: ~p", [{Sid, Key, IP}]),

    %% Read c2s options from the first ejabberd_c2s configuration in
    %% the config file listen section
    %% TODO: We should have different access and shaper values for
    %% each connector. The default behaviour should be however to use
    %% the default c2s restrictions if not defined for the current
    %% connector.
    Opts1 = ejabberd_c2s_config:get_c2s_limits(),
    Opts = [{xml_socket, true} | Opts1],

    Shaper = none,
    ShaperState = shaper:new(Shaper),
    Socket = {xmpp_websocket, self(), IP},
    ejabberd_socket:start(ejabberd_c2s, ?MODULE, Socket, Opts),
    Timer = erlang:start_timer(?MAX_INACTIVITY, self(), []),
    {ok, loop, #state{id = Sid,
		      key = Key,
		      socket = Socket,
		      shaper_state = ShaperState,
		      max_inactivity = ?MAX_INACTIVITY,
		      max_pause = ?MAX_PAUSE,
		      timer = Timer}}.

%%----------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------
handle_event({become_controller, C2SPid}, StateName, StateData) ->
    ?DEBUG("C2SPid:~p~nStateName:~p~nData:~p~n", 
           [C2SPid, StateName, StateData#state.input]),
    case StateData#state.input of
	cancel ->
	    {next_state, StateName, StateData#state{
				      waiting_input = C2SPid}};
	Input ->
	    lists:foreach(
	      fun([]) ->
                      %% skip
                      ?DEBUG("Empty input queue.",[]);
                 (Event) ->
                      C2SPid ! Event
	      end, queue:to_list(Input)),
	    {next_state, StateName, StateData#state{
				      input = queue:new(),
				      waiting_input = C2SPid}}
    end;

handle_event({change_shaper, Shaper}, StateName, StateData) ->
    NewShaperState = shaper:new(Shaper),
    {next_state, StateName, StateData#state{shaper_state = NewShaperState}};
handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}
%%----------------------------------------------------------------------
handle_sync_event({send_xml, Packet}, _From, StateName,
		  #state{websocket_s = undefined} = StateData) ->
    Output = [Packet | StateData#state.output],
    Reply = ok,
    ?DEBUG("Data from C2S:~p:~p~n",[Output,StateData]),
    {reply, Reply, StateName, StateData#state{output = Output}};
handle_sync_event({send_xml, Packet}, _From, StateName, StateData) ->
    Output = [Packet | StateData#state.output],
    ?DEBUG("Data from C2S(timer):~p:~p~n",[Output,StateData]),
    cancel_timer(StateData#state.timer),
    Timer = set_inactivity_timer(StateData#state.pause,
				 StateData#state.max_inactivity),
    lists:foreach(fun ({xmlstreamstart, Name, Attrs}) ->
                          send_element(StateData, 
                                       {xmlelement, Name, Attrs, []});
                      ({xmlstreamend, Name, Attrs}) ->
                          send_element(StateData, 
                                       {xmlelement, Name, Attrs, []});
                      ({_Name, Element}) ->
                          send_element(StateData, Element)
                  end, Output),
    cancel_timer(StateData#state.wait_timer),
    ReqList = [#wsr{
		    key = StateData#state.key,
		    out = Output
		   } |
	       [El || El <- StateData#state.req_list ]
	      ],
    Reply = ok,
    {reply, Reply, StateName,
     StateData#state{output = [],
		     websocket_receiver = undefined,
		     req_list = ReqList,
		     wait_timer = undefined,
		     timer = Timer}};
%% Handle writing to c2s 
handle_sync_event(#wsr{out=Payload, socket=WSocket, sockmod=WSockmod}, 
                  _From, StateName, StateData) ->
    Reply = ok,
    case StateData#state.waiting_input of
        false ->
            ?DEBUG("No c2spid.",[]),
            {reply, Reply, StateName, StateData};
        C2SPid ->
            ?DEBUG("really sending now: ~p", [Payload]),
            lists:foreach(
              fun({xmlstreamend, End}) ->
                      gen_fsm:send_event(
                        C2SPid, {xmlstreamend, End});
                 ({xmlelement, "stream:stream", Attrs, _}) ->
                      StreamTo = case lists:keyfind("to", 1, Attrs) of
                                     {"to", Ato} ->
                                         case lists:keyfind("version", 
                                                            1, Attrs) of
                                             {"version", AVersion} ->
                                                 {Ato, AVersion};
                                             _ ->
                                                 {Ato, ""}
                                         end
                                 end,
                      case StreamTo of
                          {To, ""} ->
                              gen_fsm:send_event(
                                C2SPid,
                                {xmlstreamstart, "stream:stream",
                                 [{"to", To},
                                  {"xmlns", ?NS_CLIENT},
                                  {"xmlns:stream", ?NS_STREAM}]});
                          {To, Version} ->
                              gen_fsm:send_event(
                                C2SPid,
                                {xmlstreamstart, "stream:stream",
                                 [{"to", To},
                                  {"xmlns", ?NS_CLIENT},
                                  {"version", Version},
                                  {"xmlns:stream", ?NS_STREAM}]})
                      end;
                 (El) ->
                      gen_fsm:send_event(
                        C2SPid, {xmlstreamelement, El})
              end, Payload),
            {reply, Reply, StateName,
             StateData#state{websocket_s=WSocket, websocket_sockmod=WSockmod}}
    end;
handle_sync_event({stop,close}, _From, _StateName, StateData) ->
    Reply = ok,
    {stop, normal, Reply, StateData};
handle_sync_event({stop,stream_closed}, _From, _StateName, StateData) ->
    Reply = ok,
    {stop, normal, Reply, StateData};
handle_sync_event({stop,Reason}, _From, _StateName, StateData) ->
    ?DEBUG("Closing websocket session ~p - Reason: ~p", 
           [StateData#state.id, Reason]),
    Reply = ok,
    {stop, normal, Reply, StateData};

handle_sync_event(peername, _From, StateName, StateData) ->
    Reply = {ok, StateData#state.ip},
    {reply, Reply, StateName, StateData};

handle_sync_event(_Event, _From, StateName, StateData) ->
    Reply = ok,
    {reply, Reply, StateName, StateData}.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_info/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------
%% We reached the max_inactivity timeout:
handle_info({timeout, Timer, _}, _StateName,
	    #state{id=SID, timer = Timer} = StateData) ->
    ?INFO_MSG("Session timeout. Closing the websocket session: ~p", [SID]),
    {stop, normal, StateData};

handle_info({timeout, WaitTimer, _}, StateName,
	    #state{wait_timer = WaitTimer} = StateData) ->
    if
	StateData#state.websocket_receiver /= undefined ->
	    cancel_timer(StateData#state.timer),
	    Timer = set_inactivity_timer(StateData#state.pause,
					 StateData#state.max_inactivity),
	    gen_fsm:reply(StateData#state.websocket_receiver, {ok, empty}),
	    ReqList = [#wsr{key = StateData#state.key,
			    out = []
			   } |
		       [El || El <- StateData#state.req_list]
		      ],
	    {next_state, StateName,
	     StateData#state{websocket_receiver = undefined,
			     req_list = ReqList,
			     wait_timer = undefined,
			     timer = Timer}};
	true ->
	    {next_state, StateName, StateData}
    end;

handle_info({timeout, ShaperTimer, _}, StateName,
	    #state{shaper_timer = ShaperTimer} = StateData) ->
    {next_state, StateName, StateData#state{shaper_timer = undefined}};

handle_info(_, StateName, StateData) ->
    {next_state, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: terminate/3
%% Purpose: Shutdown the fsm
%% Returns: any
%%----------------------------------------------------------------------
terminate(_Reason, _StateName, StateData) ->
    ?DEBUG("terminate: Deleting session ~s", [StateData#state.id]),
    send_receiver_reply(StateData#state.websocket_receiver, {ok, terminate}),
    case StateData#state.waiting_input of
	false ->
	    ok;
	C2SPid ->
	    gen_fsm:send_event(C2SPid, closed)
    end,
    ok.
%%%
%% Internal functions
%%%
stream_start(ParsedPayload) ->
    ?DEBUG("~p~n",[ParsedPayload]),
    case ParsedPayload of
        {xmlelement, "stream:stream", Attrs, _} ->
            {"to",Host} = lists:keyfind("to", 1, Attrs),
            Sid = sha:sha(term_to_binary({now(), make_ref()})),
            Key = "",
            {Host, Sid, Key};
        _ ->
            false
    end.
%% validate request sent. ensure that its parsable XMPP
validate_request(Data, PayloadSize, MaxStanzaSize) ->
    ?DEBUG("--- incoming data --- ~n~s~n --- END --- ", [Data]),
    case xml_stream:parse_element(Data) of
        {error, Reason} ->
            ?ERROR_MSG("Bad xml data: ~p~n", [Reason]),
            {error, bad_request};
        ParsedData ->
            if PayloadSize =< MaxStanzaSize ->
                    {ok, ParsedData};
               true ->
                    {size_limit, {}}
            end
    end.
send_receiver_reply(undefined, _Reply) ->
    ok;
send_receiver_reply(Receiver, Reply) ->
    gen_fsm:reply(Receiver, Reply).

%% send data to socket
send_text(StateData, Text) ->
    ?DEBUG("Send XML on stream = ~p", [Text]),
    (StateData#state.websocket_sockmod):send(StateData#state.websocket_s,
                                             [0, Text, 255]).

send_element(StateData, El) ->
    send_text(StateData, xml:element_to_binary(El)).

%% Cancel timer and empty message queue.
cancel_timer(undefined) ->
    ok;
cancel_timer(Timer) ->
    erlang:cancel_timer(Timer),
    receive
	{timeout, Timer, _} ->
	    ok
    after 0 ->
	    ok
    end.

%% If client asked for a pause (pause > 0), we apply the pause value
%% as inactivity timer:
set_inactivity_timer(Pause, _MaxInactivity) when Pause > 0 ->
    erlang:start_timer(Pause*1000, self(), []);
%% Otherwise, we apply the max_inactivity value as inactivity timer:
set_inactivity_timer(_Pause, MaxInactivity) ->
    erlang:start_timer(MaxInactivity, self(), []).
