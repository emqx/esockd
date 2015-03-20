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
%%% eSockd connection supervisor. As you know, I love process dictionary...
%%% Notice: Some code is copied from OTP supervisor.erl.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_connection_sup).

-author('feng@emqtt.io').

-behaviour(gen_server).

%% API Exports
-export([start_link/3, start_connection/4, count_connections/1]).

%% Max Clients
-export([get_max_clients/1, set_max_clients/2]).

%% Allow, Deny
-export([access_rules/1, allow/2, deny/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(MAX_CLIENTS, 1024).

-record(state, {callback,
                curr_clients = 0,
                max_clients  = ?MAX_CLIENTS,
                access_rules = [],
                logger,
                shutdown = brutal_kill}).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% Start connection supervisor.
%%
%% @end
%%------------------------------------------------------------------------------
-spec start_link(Options, Callback, Logger) -> {ok, Pid :: pid()} | ignore | {error, any()} when
    Options  :: [esockd:option()],
    Callback :: esockd:callback(),
    Logger   :: gen_logger:logmod().
start_link(Options, Callback, Logger) ->
	gen_server:start_link(?MODULE, [Options, Callback, Logger], []).

%%------------------------------------------------------------------------------
%% @doc
%% Start connection.
%%
%% @end
%%------------------------------------------------------------------------------
start_connection(Sup, Mod, Sock, SockFun) ->
    SockArgs = {esockd_transport, Sock, SockFun},
    case call(Sup, {start_connection, SockArgs}) of
        {ok, ConnPid} ->
            Mod:controlling_process(Sock, ConnPid),
            esockd_connection:ready(ConnPid, SockArgs),
            {ok, ConnPid};
        {error, Error} ->
            {error, Error}
    end.

count_connections(Sup) ->
	call(Sup, count_connections).

get_max_clients(Sup) when is_pid(Sup) ->
    call(Sup, get_max_clients).

set_max_clients(Sup, MaxClients) when is_pid(Sup) ->
    call(Sup, {set_max_clients, MaxClients}).

access_rules(Sup) ->
    call(Sup, access_rules).

allow(Sup, CIDR) ->
    call(Sup, {add_rule, {allow, CIDR}}).

deny(Sup, CIDR) ->
    call(Sup, {add_rule, {deny, CIDR}}).

call(Sup, Req) ->
    gen_server:call(Sup, Req, infinity).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([Options, Callback, Logger]) ->
	process_flag(trap_exit, true),
    Shutdown = proplists:get_value(shutdown, Options, brutal_kill),
    MaxClients = proplists:get_value(max_clients, Options, ?MAX_CLIENTS),
    AccessRules = [esockd_access:rule(Rule) || 
            Rule <- proplists:get_value(access, Options, [{allow, all}])],
    {ok, #state{callback = Callback, max_clients = MaxClients,
                access_rules = AccessRules, logger = Logger,
                shutdown = Shutdown}}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%------------------------------------------------------------------------------
handle_call({start_connection, _SockArgs}, _From, State = #state{curr_clients = CurrClients,
                                                                 max_clients = MaxClients})
        when CurrClients >= MaxClients ->
    {reply, {error, maxlimit}, State};

handle_call({start_connection, SockArgs = {_, Sock, _SockFun}}, _From, 
            State = #state{callback = Callback, curr_clients = Count, access_rules = Rules}) ->
    {ok, {Addr, _Port}} = inet:peername(Sock),
    case allowed(Addr, Rules) of
        true ->
            case catch esockd_connection:start_link(SockArgs, Callback) of
                {ok, Pid} when is_pid(Pid) -> 
                    put(Pid, true),
                    {reply, {ok, Pid}, State#state{curr_clients = Count+1}};
                ignore ->
                    {reply, ignore, State};
                {error, Reason} ->
                    {reply, {error, Reason}, State};
                What ->
                    {reply, {error, What}, State}
            end;
        false -> 
            {reply, {error, fobidden}, State}
    end;

handle_call(count_connections, _From, State = #state{curr_clients = Count}) ->
    {reply, Count, State};

handle_call(get_max_clients, _From, State = #state{max_clients = MaxClients}) ->
    {reply, MaxClients, State};

handle_call({set_max_clients, MaxClients}, _From, State) ->
    {reply, ok, State#state{max_clients = MaxClients}};

handle_call(access_rules, _From, State = #state{access_rules = Rules}) ->
    {reply, [raw(Rule) || Rule <- Rules], State};

handle_call({add_rule, RawRule}, _From, State = #state{access_rules = Rules}) ->
    case catch esockd_access:rule(RawRule) of
        {'EXIT', _Error} -> 
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
    {stop, {error, badreq}, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%------------------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @end
%%------------------------------------------------------------------------------
handle_info({'EXIT', Pid, Reason}, State = #state{curr_clients = Count, logger = Logger}) ->
    case erase(Pid) of
        true ->
            connection_terminated(Pid, Reason, State),
            {noreply, State#state{curr_clients = Count-1}};
        undefined ->
            Logger:error("Unexpected EXIT from ~p: ~p", [Pid, Reason]),
            {noreply, State}
    end;

handle_info(Info, State = #state{logger = Logger}) ->
    Logger:error("Unexpected INFO: from: ~p", [Info]),
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
terminate(_Reason, #state{shutdown = Shutdown}) ->
    shutdown_children(Shutdown),
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

allowed(Addr, Rules) ->
    case esockd_access:match(Addr, Rules) of
        nomatch          -> true;
        {matched, allow} -> true;
        {matched, deny}  -> false
    end.

raw({allow, {CIDR, _, _}}) ->
     {allow, CIDR};
raw({deny, {CIDR, _, _}}) ->
     {deny, CIDR};
raw(Rule) ->
     Rule.

connection_terminated(_Pid, normal, _State) ->
    ok;
connection_terminated(_Pid, shutdown, _State) ->
    ok;
connection_terminated(_Pid, {shutdown, _Reason}, _State) ->
    ok;
connection_terminated(Pid, Reason, #state{callback = Callback}) ->
    SupName  = list_to_atom("esockd_connection_sup - " ++ pid_to_list(self())),
    ErrorMsg = [{supervisor, SupName},
                {errorContext, connection_terminated},
                {reason, Reason},
                {offender, [{pid, Pid},
                            {name, connection},
                            {mfargs, Callback}]}],
    error_logger:error_report(supervisor_report, ErrorMsg).

shutdown_children(brutal_kill) ->
    ?SETS:fold(fun(P, _) -> exit(P, kill) end, ok, Pids),
    wait_dynamic_children(Child, Pids, Sz, undefined, EStack0);
    todo;

shutdown_children(infinity) ->
    ?SETS:fold(fun(P, _) -> exit(P, shutdown) end, ok, Pids),
    wait_dynamic_children(Child, Pids, Sz, undefined, EStack0);
    todo;

shutdown_children(Time) when is_integer(Time) ->
    ?SETS:fold(fun(P, _) -> exit(P, shutdown) end, ok, Pids),
    TRef = erlang:start_timer(Time, self(), kill),
    wait_dynamic_children(Child, Pids, Sz, TRef, EStack0)
    todo.


