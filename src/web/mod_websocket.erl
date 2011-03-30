%%%----------------------------------------------------------------------
%%% File    : mod_websocket.erl
%%% Author  : Nathan Zorn <nathan.zorn@gmail.com>
%%% Purpose : XMPP over websockets
%%%----------------------------------------------------------------------

-module(mod_websocket).
-author('nathan.zorn@gmail.com').

-define(MOD_WEBSOCKET_VERSION, "0.1").
-define(TEST, ok).
-define(PROCNAME_MHB, ejabberd_mod_websocket).

-behaviour(gen_mod).

-export([
         start/2,
         stop/1,
         process/2
        ]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("ejabberd_websocket.hrl").
-record(wsdatastate, {legacy=true, 
                      ft=undefined,
                      flen,
                      packet= <<>>,
                      buffer= <<>>,
                      partial= <<>> 
                     }).
%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
process(Path, Req) ->
    ?DEBUG("Request data:~p:", [Path, Req]),
    %% Validate Origin
    case validate_origin(Req#wsrequest.headers) of
        true ->
            Data = case Req#wsrequest.data of
                       [] -> <<>>;
                       X when is_list(X) ->
                           list_to_binary(X);
                       Y ->
                           Y
                   end,
            ?DEBUG("Origin is valid.",[]),
            DState = #wsdatastate {legacy=true, 
                                   buffer=Data,
                                   ft=undefined,                             
                                   partial= <<>> },
            case process_data(DState) of
                {<<>>, Part} when is_binary(Part) -> 
                    {<<>>, Part};
                {Out, <<>>} when is_binary(Out) ->
                    IP = Req#wsrequest.ip,
                    %% websocket frame is finished process request
                    ejabberd_xmpp_websocket:process_request(
                      Req#wsrequest.wsockmod,
                      Req#wsrequest.wsocket,
                      Req#wsrequest.fsmref, 
                      Out, 
                      IP);
                Error -> Error  %% pass the errors through
            end;
        _ ->
            ?DEBUG("Invalid Origin in Request: ~p~n",[Req]),
            false
    end.

%%%----------------------------------------------------------------------
%%% BEHAVIOUR CALLBACKS
%%%----------------------------------------------------------------------
start(Host, _Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME_MHB),
    ChildSpec =
        {Proc,
         {ejabberd_tmp_sup, start_link,
          [Proc, ejabberd_xmpp_websocket]},
         permanent,
         infinity,
         supervisor,
         [ejabberd_tmp_sup]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME_MHB),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).
%% Origin validator - Ejabberd configuration should contain a fun
%% validating the origin for this request handler? Default is to
%% always validate.
validate_origin([]) ->
    true;
validate_origin(Headers) ->
    is_tuple(lists:keyfind("Origin", 1, Headers)).

process_data(DState = #wsdatastate{buffer=undefined}) -> 
    {DState#wsdatastate.packet, DState#wsdatastate.partial};
process_data(DState = #wsdatastate{buffer= <<>>}) -> 
    {DState#wsdatastate.packet, DState#wsdatastate.partial};
process_data(DState = #wsdatastate{buffer= <<FrameType:8,Buffer/binary>>, 
                                   ft=undefined}) ->
    Buffer0 = << <<FrameType>>/binary, Buffer/binary>>,
    process_data(DState#wsdatastate{buffer=Buffer0, 
                                    ft=FrameType, 
                                    partial= <<>>});
%% "Legacy" frames, 0x00...0xFF
%% or modern closing handshake 0x00{8}
process_data(DState = #wsdatastate{buffer= <<0, Buffer/binary>>, 
                                   ft=0}) ->
    process_data(DState#wsdatastate{buffer=Buffer, ft=undefined});

process_data(DState = #wsdatastate{buffer= <<255, Rest/binary>>}) ->
    %% message received in full
    #wsdatastate {partial=OPartial} = DState,
    process_data(DState#wsdatastate{partial= <<>>, 
                                    packet=OPartial, 
                                    ft=undefined, 
                                    buffer=Rest});
process_data(DState = #wsdatastate{buffer= <<Byte:8, Rest/binary>>, 
                                   ft=0,
                                   partial=Partial}) ->
    NewPartial = case Partial of 
                     <<>> -> <<Byte>>; 
                     _    -> <<Partial/binary, <<Byte>>/binary>> 
                                 end,
    process_data(DState#wsdatastate{buffer=Rest, partial=NewPartial});
process_data(DState = #wsdatastate{buffer= <<Byte:8, Rest/binary>>, 
                                   legacy=true,
                                   partial=Partial}) ->

    NewPartial = case Partial of 
                     <<>> -> <<Byte>>; 
                     _    -> <<Partial/binary, <<Byte>>/binary>> 
                                 end,
    process_data(DState#wsdatastate{buffer=Rest, partial=NewPartial});
%% "Modern" frames, starting with 0xFF, followed by 64 bit length
process_data(DState = #wsdatastate{buffer= <<Len:64/unsigned-integer,
                                            Buffer/binary>>, 
                                   ft=255, 
                                   flen=undefined}) ->
    BitsLen = Len*8,
    case Buffer of
        <<Frame:BitsLen/binary, Rest/binary>> ->                        
            process_data(DState#wsdatastate{ft=undefined, 
                                            flen=undefined,
                                            packet=Frame,
                                            buffer=Rest});

        _ ->
            DState#wsdatastate{flen=Len, buffer=Buffer}
    end;
process_data(DState = #wsdatastate{buffer=Buffer, 
                                   ft=255, 
                                   flen=Len}) when is_integer(Len) ->
    BitsLen = Len*8,
    case Buffer of
        <<Frame:BitsLen/binary, Rest/binary>> ->            
            process_data(DState#wsdatastate{ft=undefined, 
                                            flen=undefined,
                                            packet=Frame,
                                            buffer=Rest});

        _ ->
            DState#wsdatastate{flen=Len, buffer=Buffer}
    end.
%%
%% Tests
%%
-include_lib("eunit/include/eunit.hrl").
-ifdef(TEST).

websocket_process_data_test() ->
    %% Test frame arrival.
    Packets = [<<0,"<tagname>",255>>,
               <<0,"<startag> ">>,
               <<"cdata in startag ">>,
               <<"more cdata </startag>",255>>,
               <<0,"something about tests",255>>,
               <<0,"fragment">>],
    FakeState = #wsdatastate{ legacy=true,
                              ft=undefined,                             
                              buffer= <<>>,
                              partial= <<>> },

    Buffer = <<>>,
    Packet = lists:nth(1,Packets),
    FinalState = process_data(FakeState#wsdatastate{buffer= <<Buffer/binary,Packet/binary>>}),
    {<<"<tagname>">>,<<>>} = FinalState,
    Packet0 = lists:nth(2,Packets),
    {_,Buffer0} = FinalState,
    FinalState0 = process_data(FakeState#wsdatastate{buffer= <<Buffer0/binary,Packet0/binary>>}),
    {<<>>,<<"<startag> ">>} = FinalState0,
    Packet1 = lists:nth(3,Packets),
    {_,Buffer1} = FinalState0,
    FinalState1 = process_data(FakeState#wsdatastate{buffer= <<Buffer1/binary,Packet1/binary>>}),
    {<<>>,<<"<startag> cdata in startag ">>} = FinalState1,
    Packet2 = lists:nth(4,Packets),
    {_, Buffer2} = FinalState1,
    FinalState2 = process_data(FakeState#wsdatastate{buffer= <<Buffer2/binary,Packet2/binary>>}),
    {<<"<startag> cdata in startag more cdata </startag>">>,<<>>} = FinalState2,
    Packet3 = lists:nth(5,Packets),
    {_,Buffer3} = FinalState2,
    FinalState3 = process_data(FakeState#wsdatastate{buffer= <<Buffer3/binary,Packet3/binary>>}),
    {<<"something about tests">>,<<>>} = FinalState3,
    ok.

-endif.
