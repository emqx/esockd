%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(esockd_connection_sup).

-behaviour(gen_server).

-import(proplists, [get_value/3]).

-export([start_link/2, start_connection/3, count_connections/1]).
-export([get_max_connections/1, set_max_connections/2]).
-export([get_shutdown_count/1]).

%% Allow, Deny
-export([access_rules/1, allow/2, deny/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-define(DEFAULT_MAX_CONNS, 1024).
-define(Transport, esockd_transport).

-record(state, {curr_connections = 0,
                max_connections  = ?DEFAULT_MAX_CONNS,
                access_rules     = [],
                shutdown         = brutal_kill,
                mfargs           :: mfa()}).

%% @doc Start connection supervisor.
-spec(start_link([esockd:option()], esockd:mfargs()) -> {ok, pid()} | ignore | {error, term()}).
start_link(Opts, MFA) ->
    gen_server:start_link(?MODULE, [Opts, MFA], []).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

%% @doc Start connection.
start_connection(Sup, Sock, UpgradeFuns) ->
    case call(Sup, {start_connection, Sock}) of
        {ok, ConnPid} ->
            %% Transfer controlling from acceptor to connection
            _ = ?Transport:controlling_process(Sock, ConnPid),
            _ = ?Transport:ready(ConnPid, Sock, UpgradeFuns),
            {ok, ConnPid};
        ignore -> ignore;
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Start the connection process.
-spec(start_connection_proc(esockd:mfargs(), esockd_transport:sock())
      -> {ok, pid()} | ignore | {error, term()}).
start_connection_proc(M, Sock) when is_atom(M) ->
    M:start_link(?Transport, Sock);
start_connection_proc({M, F}, Sock) when is_atom(M), is_atom(F) ->
    M:F(?Transport, Sock);
start_connection_proc({M, F, Args}, Sock) when is_atom(M), is_atom(F), is_list(Args) ->
    erlang:apply(M, F, [?Transport, Sock | Args]).

-spec(count_connections(pid()) -> integer()).
count_connections(Sup) ->
    call(Sup, count_connections).

-spec(get_max_connections(pid()) -> integer()).
get_max_connections(Sup) when is_pid(Sup) ->
    call(Sup, get_max_connections).

-spec(set_max_connections(pid(), integer()) -> ok).
set_max_connections(Sup, MaxConns) when is_pid(Sup) ->
    call(Sup, {set_max_connections, MaxConns}).

-spec(get_shutdown_count(pid()) -> integer()).
get_shutdown_count(Sup) ->
    call(Sup, get_shutdown_count).

access_rules(Sup) ->
    call(Sup, access_rules).

allow(Sup, CIDR) ->
    call(Sup, {add_rule, {allow, CIDR}}).

deny(Sup, CIDR) ->
    call(Sup, {add_rule, {deny, CIDR}}).

call(Sup, Req) ->
    gen_server:call(Sup, Req, infinity).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([Opts, MFA]) ->
    process_flag(trap_exit, true),
    Shutdown = get_value(shutdown, Opts, brutal_kill),
    MaxConns = get_value(max_connections, Opts, ?DEFAULT_MAX_CONNS),
    RawRules = get_value(access_rules, Opts, [{allow, all}]),
    AccessRules = [esockd_access:compile(Rule) || Rule <- RawRules],
    {ok, #state{curr_connections = 0, max_connections  = MaxConns,
                access_rules = AccessRules, shutdown = Shutdown, mfargs = MFA}}.

handle_call({start_connection, _Sock}, _From,
            State = #state{curr_connections = CurrConns, max_connections  = MaxConns})
    when CurrConns >= MaxConns ->
    {reply, {error, maxlimit}, State};

handle_call({start_connection, Sock}, _From, State = #state{mfargs = MFA, curr_connections = Count, access_rules = Rules}) ->
    case esockd_transport:peername(Sock) of
        {ok, {Addr, _Port}} ->
            case allowed(Addr, Rules) of
                true  -> case catch start_connection_proc(MFA, Sock) of
                             {ok, Pid} when is_pid(Pid) ->
                                 put(Pid, true),
                                 {reply, {ok, Pid}, State#state{curr_connections = Count+1}};
                             ignore ->
                                 {reply, ignore, State};
                             {error, Reason} ->
                                 {reply, {error, Reason}, State};
                             What ->
                                {reply, {error, What}, State}
                         end;
                false -> {reply, {error, forbidden}, State}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(count_connections, _From, State = #state{curr_connections = Count}) ->
    {reply, Count, State};

handle_call(get_max_connections, _From, State = #state{max_connections = MaxConns}) ->
    {reply, MaxConns, State};

handle_call({set_max_connections, MaxConns}, _From, State) ->
    {reply, ok, State#state{max_connections = MaxConns}};

handle_call(get_shutdown_count, _From, State) ->
    {reply, [{Reason, Count} || {{shutdown, Reason}, Count} <- get()], State};

handle_call(access_rules, _From, State = #state{access_rules = Rules}) ->
    {reply, [raw(Rule) || Rule <- Rules], State};

handle_call({add_rule, RawRule}, _From, State = #state{access_rules = Rules}) ->
    case catch esockd_access:compile(RawRule) of
        {'EXIT', _Error} ->
            {reply, {error, bad_access_rule}, State};
        Rule ->
            case lists:member(Rule, Rules) of
                true ->
                    {reply, {error, alread_existed}, State};
                false ->
                    {reply, ok, State#state{access_rules = [Rule | Rules]}}
            end
    end;

handle_call(Req, _From, State) ->
    error_logger:error_msg("[~s] unexpected call: ~p", [?MODULE, Req]),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    error_logger:error_msg("[~s] unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State = #state{curr_connections = Count}) ->
    case erase(Pid) of
        true ->
            connection_crashed(Pid, Reason, State),
            {noreply, State#state{curr_connections = Count-1}};
        undefined ->
            error_logger:error_msg("[~s] unexpected 'EXIT': ~p, reason: ~p", [?MODULE, Pid, Reason]),
            {noreply, State}
    end;

handle_info(Info, State) ->
    error_logger:error_msg("[~s] unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.

terminate(_Reason, State) ->
    terminate_children(State).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

allowed(Addr, Rules) ->
    case esockd_access:match(Addr, Rules) of
        nomatch          -> true;
        {matched, allow} -> true;
        {matched, deny}  -> false
    end.

raw({allow, CIDR = {_Start, _End, _Len}}) ->
     {allow, esockd_cidr:to_string(CIDR)};
raw({deny, CIDR = {_Start, _End, _Len}}) ->
     {deny, esockd_cidr:to_string(CIDR)};
raw(Rule) ->
     Rule.

connection_crashed(_Pid, normal, _State) ->
    ok;
connection_crashed(_Pid, shutdown, _State) ->
    ok;
connection_crashed(_Pid, {shutdown, Reason}, _State) when is_atom(Reason) ->
    count_shutdown(Reason);
connection_crashed(Pid, {shutdown, Reason}, State) ->
    report_error(connection_shutdown, Reason, Pid, State);
connection_crashed(Pid, Reason, State) ->
    report_error(connection_crashed, Reason, Pid, State).

count_shutdown(Reason) ->
    case get({shutdown, Reason}) of
        undefined ->
            put({shutdown, Reason}, 1);
        Count     ->
            put({shutdown, Reason}, Count+1)
    end.

terminate_children(State = #state{shutdown = Shutdown}) ->
    {Pids, EStack0} = monitor_children(),
    Sz = sets:size(Pids),
    EStack = case Shutdown of
                 brutal_kill ->
                     sets:fold(fun(P, _) -> exit(P, kill) end, ok, Pids),
                     wait_children(Shutdown, Pids, Sz, undefined, EStack0);
                 infinity ->
                     sets:fold(fun(P, _) -> exit(P, shutdown) end, ok, Pids),
                     wait_children(Shutdown, Pids, Sz, undefined, EStack0);
                 Time when is_integer(Time) ->
                     sets:fold(fun(P, _) -> exit(P, shutdown) end, ok, Pids),
                     TRef = erlang:start_timer(Time, self(), kill),
                     wait_children(Shutdown, Pids, Sz, TRef, EStack0)
             end,
    %% Unroll stacked errors and report them
    dict:fold(fun(Reason, Pid, _) ->
                  report_error(connection_shutdown_error, Reason, Pid, State)
              end, ok, EStack).

monitor_children() ->
    lists:foldl(fun(P, {Pids, EStack}) ->
        case monitor_child(P) of
            ok ->
                {sets:add_element(P, Pids), EStack};
            {error, normal} ->
                {Pids, EStack};
            {error, Reason} ->
                {Pids, dict:append(Reason, P, EStack)}
        end
    end, {sets:new(), dict:new()}, get_keys(true)).

%% Help function to shutdown/2 switches from link to monitor approach
monitor_child(Pid) ->
    %% Do the monitor operation first so that if the child dies
    %% before the monitoring is done causing a 'DOWN'-message with
    %% reason noproc, we will get the real reason in the 'EXIT'-message
    %% unless a naughty child has already done unlink...
    erlang:monitor(process, Pid),
    unlink(Pid),

    receive
	%% If the child dies before the unlik we must empty
	%% the mail-box of the 'EXIT'-message and the 'DOWN'-message.
	{'EXIT', Pid, Reason} ->
	    receive
		{'DOWN', _, process, Pid, _} ->
		    {error, Reason}
	    end
    after 0 ->
	    %% If a naughty child did unlink and the child dies before
	    %% monitor the result will be that shutdown/2 receives a
	    %% 'DOWN'-message with reason noproc.
	    %% If the child should die after the unlink there
	    %% will be a 'DOWN'-message with a correct reason
	    %% that will be handled in shutdown/2.
	    ok
    end.

wait_children(_Shutdown, _Pids, 0, undefined, EStack) ->
    EStack;
wait_children(_Shutdown, _Pids, 0, TRef, EStack) ->
	%% If the timer has expired before its cancellation, we must empty the
	%% mail-box of the 'timeout'-message.
    erlang:cancel_timer(TRef),
    receive
        {timeout, TRef, kill} ->
            EStack
    after 0 ->
            EStack
    end;

%%TODO: Copied from supervisor.erl, rewrite it later.
wait_children(brutal_kill, Pids, Sz, TRef, EStack) ->
    receive
        {'DOWN', _MRef, process, Pid, killed} ->
            wait_children(brutal_kill, del(Pid, Pids), Sz-1, TRef, EStack);

        {'DOWN', _MRef, process, Pid, Reason} ->
            wait_children(brutal_kill, del(Pid, Pids),
                          Sz-1, TRef, dict:append(Reason, Pid, EStack))
    end;

wait_children(Shutdown, Pids, Sz, TRef, EStack) ->
    receive
        {'DOWN', _MRef, process, Pid, shutdown} ->
            wait_children(Shutdown, del(Pid, Pids), Sz-1, TRef, EStack);
        {'DOWN', _MRef, process, Pid, normal} ->
            wait_children(Shutdown, del(Pid, Pids), Sz-1, TRef, EStack);
        {'DOWN', _MRef, process, Pid, Reason} ->
            wait_children(Shutdown, del(Pid, Pids), Sz-1,
                          TRef, dict:append(Reason, Pid, EStack));
        {timeout, TRef, kill} ->
            sets:fold(fun(P, _) -> exit(P, kill) end, ok, Pids),
            wait_children(Shutdown, Pids, Sz-1, undefined, EStack)
    end.

report_error(Error, Reason, Pid, #state{mfargs = MFA}) ->
    SupName  = list_to_atom("esockd_connection_sup - " ++ pid_to_list(self())),
    ErrorMsg = [{supervisor, SupName},
                {errorContext, Error},
                {reason, Reason},
                {offender, [{pid, Pid},
                            {name, connection},
                            {mfargs, MFA}]}],
    error_logger:error_report(supervisor_report, ErrorMsg).

del(Pid, Pids) ->
    erase(Pid), sets:del_element(Pid, Pids).

