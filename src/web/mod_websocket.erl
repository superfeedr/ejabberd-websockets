%%%----------------------------------------------------------------------
%%% File    : mod_websocket.erl
%%% Author  : Nathan Zorn <nathan.zorn@gmail.com>
%%% Purpose : XMPP over websockets
%%%----------------------------------------------------------------------

-module(mod_websocket).
-author('nathan.zorn@gmail.com').

-define(MOD_WEBSOCKET_VERSION, "0.1").

-behaviour(gen_mod).

-export([
         start/2,
         stop/1,
         process/2
        ]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("ejabberd_http.hrl").


%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

process(Path, Req) ->
    ?DEBUG("Request data:~p:", [Path, Req]),
    {400, [], {xmlelement, "h1", [],
               [{xmlcdata, "400 Bad Request"}]}}.


%%%----------------------------------------------------------------------
%%% BEHAVIOUR CALLBACKS
%%%----------------------------------------------------------------------
start(_Host, _Opts) ->
    WebSocketSupervisor =
        {ejabberd_websocket_sup,
         {ejabberd_tmp_sup, start_link,
          [ejabberd_websocket_sup, ejabberd_websocket]},
         permanent,
         infinity,
         supervisor,
         [ejabberd_tmp_sup]},
    case supervisor:start_child(ejabberd_sup, WebSocketSupervisor) of
        {ok, _Pid} ->
            ok;
        {ok, _Pid, _Info} ->
            ok;
        {error, {already_started, _PidOther}} ->
            ok;
        {error, Error} ->
            {'EXIT', {start_child_error, Error}}
    end.

stop(_Host) ->
    case supervisor:terminate_child(ejabberd_sup, ejabberd_websocket) of
        ok ->
            ok;
        {error, Error} ->
            {'EXIT', {terminate_child_error, Error}}
    end.

