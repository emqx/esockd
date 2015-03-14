%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2014-2015, Feng Lee <feng@emqtt.io>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% eSockd manager to controll max clients.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_manager).

-author("feng@emqtt.io").

-behaviour(gen_server).

%% API
-export([start_link/2, new_connection/4]).

%% Manage
-export([get_max_clients/1, set_max_clients/2]).

%% Allow, Deny
-export([access_rules/1, allow/2, deny/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(MAX_CLIENTS, 1024).

-record(state, {conn_sup, max_clients = 1024, access_rules = []}).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% Start esockd manager.
%%
%% @end
%%------------------------------------------------------------------------------
-spec start_link(Options, ConnSup) -> {ok, Pid :: pid()} | ignore | {error, any()} when
    Options :: [esockd:option()],
    ConnSup :: pid().
start_link(Options, ConnSup) ->
    gen_server:start_link(?MODULE, [Options, ConnSup], []).

%%------------------------------------------------------------------------------
%% @doc
%% New connection.
%%
%% @end
%%------------------------------------------------------------------------------
new_connection(Manager, Mod, Sock, SockFun) ->
    case gen_server:call(Manager, new_connection) of
        {ok, ConnSup} ->
            SockArgs = {esockd_transport, Sock, SockFun},
            case esockd_connection_sup:start_connection(ConnSup, SockArgs) of
            {ok, ConnPid} ->
                Mod:controlling_process(Sock, ConnPid),
                esockd_connection:ready(ConnPid, SockArgs),
                {ok, ConnPid};
            {error, Error} ->
                {error, Error}
            end;
        {reject, Reason} ->
            {error, {reject, Reason}};
        fobidden ->
            {error, fobidden}
    end.

get_max_clients(Manager) when is_pid(Manager) ->
    gen_server:call(Manager, get_max_clients).

set_max_clients(Manager, MaxClients) when is_pid(Manager) ->
    gen_server:call(Manager, {set_max_clients, MaxClients}).

access_rules(Manager) ->
    gen_server:call(Manager, access_rules).

allow(Manager, CIDR) ->
    gen_server:call(Manager, {add_rule, {allow, CIDR}}).

deny(Manager, CIDR) ->
    gen_server:call(Manager, {add_rule, {deny, CIDR}}).

%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @end
%%------------------------------------------------------------------------------
init([Options, ConnSup]) ->
    MaxClients = proplists:get_value(max_clients, Options, ?MAX_CLIENTS),
    {ok, #state{conn_sup = ConnSup, max_clients = MaxClients}}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%------------------------------------------------------------------------------
handle_call({new_connection, Sock}, _From, State = #state{conn_sup = ConnSup, max_clients = MaxClients, access_rules = Rules}) ->
    Count = esockd_connection_sup:count_connection(ConnSup),
    Reply =
    if
        Count >= MaxClients ->
            {reject, limit};
        true -> 
            {ok, {Addr, _Port}} = inet:peername(Sock),
            case esockd_access:match(Addr, Rules) of
                nomatch          -> {ok, ConnSup};
                {matched, allow} -> {ok, ConnSup};
                {matched, deny}   -> fobidden
            end
    end,
    {reply, Reply, State};

handle_call(get_max_clients, _From, State = #state{max_clients = MaxClients}) ->
    {reply, MaxClients, State};

handle_call({set_max_clients, MaxClients}, _From, State) ->
    {reply, ok, State#state{max_clients = MaxClients}};

handle_call(access_rules, _From, State = #state{access_rules = Rules}) ->
    {reply, [raw(Rule) || Rule <- Rules], State};

handle_call({add_rule, RawRule}, _From, State = #state{access_rules = Rules}) ->
    case catch esockd_access:rule(RawRule) of
        {'EXIT', Error} -> 
            lager:error("Access Rule Error: ~p", [Error]),
            {reply, {error, bad_cidr}, State};
        Rule -> 
            case lists:member(Rule, Rules) of
                true ->
                    {reply, {error, alread_existed}, State};
                false ->
                    {reply, ok, State#state{access_rules = [Rule | Rules]}}
            end
    end;

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%------------------------------------------------------------------------------
handle_cast(_Request, State) ->
    {noreply, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @end
%%------------------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%------------------------------------------------------------------------------
-spec terminate(Reason, State) -> any() when
    Reason  :: normal | shutdown | {shutdown, term()} | term(),
    State :: #state{}.
terminate(_Reason, _State) ->
    ok.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @end
%%------------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

raw({allow, {CIDR, _, _}}) ->
     {allow, CIDR};
raw({deny, {CIDR, _, _}}) ->
     {deny, CIDR};
raw(Rule) ->
     Rule.

