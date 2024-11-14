%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
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
%%--------------------------------------------------------------------

-module(esockd_connection_sup).

-behaviour(gen_server).

-import(proplists, [get_value/3, get_value/2]).

-export([start_link/1, start_supervised/1, stop/1]).

-export([ start_connection/3
        , count_connections/1
        ]).

-export([ get_max_connections/1
        , get_shutdown_count/1
        , get_options/1
        , set_options/2
        ]).

%% Allow, Deny
-export([ access_rules/1
        , allow/2
        , deny/2
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-include("esockd.hrl").

-type(shutdown() :: brutal_kill | infinity | pos_integer()).

-type option() :: {shutdown, shutdown()}
                | {max_connections, pos_integer()}
                | {access_rules, list()}.

-record(state, {
          curr_connections :: map(),
          max_connections :: pos_integer(),
          access_rules :: list(),
          shutdown :: shutdown(),
          mfargs :: esockd:mfargs()
         }).

-define(TRANSPORT, esockd_transport).
-define(ERROR_MSG(Format, Args),
        error_logger:error_msg("[~s] " ++ Format, [?MODULE | Args])).

%% @doc Start connection supervisor.
-spec start_link([esockd:option()])
      -> {ok, pid()} | ignore | {error, term()}.
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-spec start_supervised(esockd:listener_ref())
      -> {ok, pid()} | ignore | {error, term()}.
start_supervised(ListenerRef) ->
    Opts = esockd_server:get_listener_prop(ListenerRef, options),
    case start_link(Opts) of
        {ok, Pid} ->
            _ = esockd_server:set_listener_prop(ListenerRef, connection_sup, Pid),
            {ok, Pid};
        {error, _} = Error ->
            Error
    end.

-spec(stop(pid()) -> ok).
stop(Pid) -> gen_server:stop(Pid).

-spec get_options(pid()) -> [option()].
get_options(Pid) ->
    call(Pid, get_options).

-spec set_options(pid(), [option()]) -> ok | {error, _Reason}.
set_options(Pid, Opts) ->
    call(Pid, {set_options, Opts}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Start connection.
start_connection(Sup, Sock, UpgradeFuns) ->
    case call(Sup, {start_connection, Sock}) of
        {ok, ConnPid} ->
            %% Transfer controlling from acceptor to connection
            _ = ?TRANSPORT:controlling_process(Sock, ConnPid),
            _ = ?TRANSPORT:ready(ConnPid, Sock, UpgradeFuns),
            {ok, ConnPid};
        ignore -> ignore;
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Start the connection process.
-spec start_connection_proc(esockd:mfargs(), esockd_transport:socket())
      -> {ok, pid()} | ignore | {error, term()}.
start_connection_proc(MFA, Sock) ->
    esockd:start_mfargs(MFA, ?TRANSPORT, Sock).

-spec(count_connections(pid()) -> integer()).
count_connections(Sup) ->
    call(Sup, count_connections).

-spec get_max_connections(pid()) -> pos_integer().
get_max_connections(Sup) when is_pid(Sup) ->
    proplists:get_value(max_connections, get_options(Sup)).

-spec(get_shutdown_count(pid()) -> [{atom(), integer()}]).
get_shutdown_count(Sup) ->
    call(Sup, get_shutdown_count).

access_rules(Sup) ->
    proplists:get_value(access_rules, get_options(Sup)).

allow(Sup, CIDR) ->
    call(Sup, {add_rule, {allow, CIDR}}).

deny(Sup, CIDR) ->
    call(Sup, {add_rule, {deny, CIDR}}).

call(Sup, Req) ->
    gen_server:call(Sup, Req, infinity).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init(Opts) ->
    process_flag(trap_exit, true),
    Shutdown = get_value(shutdown, Opts, brutal_kill),
    MaxConns = resolve_max_connections(get_value(max_connections, Opts)),
    RawRules = get_value(access_rules, Opts, [{allow, all}]),
    AccessRules = [esockd_access:compile(Rule) || Rule <- RawRules],
    MFA = get_value(connection_mfargs, Opts),
    {ok, #state{curr_connections = #{},
                max_connections  = MaxConns,
                access_rules     = AccessRules,
                shutdown         = Shutdown,
                mfargs           = MFA}}.

handle_call({start_connection, _Sock}, _From,
            State = #state{curr_connections = Conns, max_connections = MaxConns})
    when map_size(Conns) >= MaxConns ->
    {reply, {error, ?ERROR_MAXLIMIT}, State};

handle_call({start_connection, Sock}, _From,
            State = #state{curr_connections = Conns, access_rules = Rules, mfargs = MFA}) ->
    case esockd_transport:peername(Sock) of
        {ok, {Addr, _Port}} ->
            case allowed(Addr, Rules) of
                true ->
                    try start_connection_proc(MFA, Sock) of
                        {ok, Pid} when is_pid(Pid) ->
                            NState = State#state{curr_connections = maps:put(Pid, true, Conns)},
                            {reply, {ok, Pid}, NState};
                        ignore ->
                            {reply, ignore, State};
                        {error, Reason} ->
                            {reply, {error, Reason}, State}
                    catch
                        _Error:Reason:ST ->
                            {reply, {error, {Reason, ST}}, State}
                    end;
                false ->
                    {reply, {error, forbidden}, State}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(count_connections, _From, State = #state{curr_connections = Conns}) ->
    {reply, maps:size(Conns), State};

handle_call(get_shutdown_count, _From, State) ->
    Counts = [{Reason, Count} || {{shutdown_count, Reason}, Count} <- get()],
    {reply, Counts, State};

handle_call({add_rule, RawRule}, _From, State = #state{access_rules = Rules}) ->
    try esockd_access:compile(RawRule) of
        Rule ->
            case lists:member(Rule, Rules) of
                true ->
                    {reply, {error, already_exists}, State};
                false ->
                    {reply, ok, State#state{access_rules = [Rule | Rules]}}
            end
    catch
        error:Reason ->
            logger:log(error, #{msg => "bad_access_rule",
                                rule => RawRule,
                                compile_error => Reason
                               }),
            {reply, {error, bad_access_rule}, State}
    end;

handle_call(get_options, _From, State) ->
    Options = [
        {shutdown, get_state_option(shutdown, State)},
        {max_connections, get_state_option(max_connections, State)},
        {access_rules, get_state_option(access_rules, State)},
        {connection_mfargs, get_state_option(connection_mfargs, State)}
    ],
    {reply, Options, State};

handle_call({set_options, Options}, _From, State) ->
    case set_state_options(Options, State) of
        NState = #state{} ->
            {reply, ok, NState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

%% mimic the supervisor's which_children reply
handle_call(which_children, _From, State = #state{curr_connections = Conns, mfargs = MFA}) ->
    Mod = get_module(MFA),
    {reply, [{undefined, Pid, worker, [Mod]}
              || Pid <- maps:keys(Conns), erlang:is_process_alive(Pid)], State};

handle_call(Req, _From, State) ->
    ?ERROR_MSG("Unexpected call: ~p", [Req]),
    {reply, ignore, State}.

handle_cast(Msg, State) ->
    ?ERROR_MSG("Unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State = #state{curr_connections = Conns}) ->
    case maps:take(Pid, Conns) of
        {true, Conns1} ->
            connection_crashed(Pid, Reason, State),
            {noreply, State#state{curr_connections = Conns1}};
        error ->
            ?ERROR_MSG("Unexpected 'EXIT': ~p, reason: ~p", [Pid, Reason]),
            {noreply, State}
    end;

handle_info(Info, State) ->
    ?ERROR_MSG("Unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, State) ->
    terminate_children(State).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

allowed(Addr, Rules) ->
    case esockd_access:match(Addr, Rules) of
        nomatch          -> true;
        {matched, allow} -> true;
        {matched, deny}  -> false
    end.

get_state_option(max_connections, #state{max_connections = MaxConnections}) ->
    MaxConnections;
get_state_option(shutdown, #state{shutdown = Shutdown}) ->
    Shutdown;
get_state_option(access_rules, #state{access_rules = Rules}) ->
    [raw(Rule) || Rule <- Rules];
get_state_option(connection_mfargs, #state{mfargs = MFA}) ->
    MFA.

set_state_option({max_connections, MaxConns}, State) ->
    case resolve_max_connections(MaxConns) of
        MaxConns ->
            State#state{max_connections = MaxConns};
        _ ->
            {error, bad_max_connections}
    end;
set_state_option({shutdown, Shutdown}, State) ->
    State#state{shutdown = Shutdown};
set_state_option({access_rules, Rules}, State) ->
    try
        CompiledRules = [esockd_access:compile(Rule) || Rule <- Rules],
        State#state{access_rules = CompiledRules}
    catch
        error:_Reason -> {error, bad_access_rules}
    end;
set_state_option({connection_mfargs, MFA}, State) ->
    State#state{mfargs = MFA};
set_state_option(_, State) ->
    State.

set_state_options(Options, State) ->
    lists:foldl(fun
        (Option, St = #state{}) -> set_state_option(Option, St);
        (_, Error) -> Error
    end, State, Options).

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
connection_crashed(_Pid, killed, _State) ->
    ok;
connection_crashed(_Pid, Reason, _State) when is_atom(Reason) ->
    count_shutdown(Reason);
connection_crashed(_Pid, {shutdown, Reason}, _State) when is_atom(Reason) ->
    count_shutdown(Reason);
connection_crashed(Pid, {shutdown, {ssl_error, Reason}}, State) ->
    count_shutdown(ssl_error),
    log(info, ssl_error, Reason, Pid, State);
connection_crashed(Pid, {shutdown, #{shutdown_count := Key} = Reason}, State) when is_atom(Key) ->
    count_shutdown(Key),
    log(info, Key, maps:without([shutdown_count], Reason), Pid, State);
connection_crashed(Pid, {shutdown, Reason}, State) ->
    %% unidentified shutdown, cannot keep a counter of it,
    %% ideally we should try to add a 'shutdown_count' filed to the reason.
    log(error, connection_shutdown, Reason, Pid, State);
connection_crashed(Pid, Reason, State) ->
    %% unexpected crash, probably deserve a fix
    log(error, connection_crashed, Reason, Pid, State).

count_shutdown(Reason) ->
    Key = {shutdown_count, Reason},
    put(Key, case get(Key) of undefined -> 1; Cnt -> Cnt+1 end).

terminate_children(State = #state{curr_connections = Conns, shutdown = Shutdown}) ->
    {Pids, EStack0} = monitor_children(Conns),
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
                  log(error, connection_shutdown_error, Reason, Pid, State)
              end, ok, EStack).

monitor_children(Conns) ->
    lists:foldl(fun(P, {Pids, EStack}) ->
        case monitor_child(P) of
            ok ->
                {sets:add_element(P, Pids), EStack};
            {error, normal} ->
                {Pids, EStack};
            {error, Reason} ->
                {Pids, dict:append(Reason, P, EStack)}
        end
    end, {sets:new(), dict:new()}, maps:keys(Conns)).

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
    _ = erlang:cancel_timer(TRef),
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
            wait_children(brutal_kill, sets:del_element(Pid, Pids), Sz-1, TRef, EStack);

        {'DOWN', _MRef, process, Pid, Reason} ->
            wait_children(brutal_kill, sets:del_element(Pid, Pids),
                          Sz-1, TRef, dict:append(Reason, Pid, EStack))
    end;

wait_children(Shutdown, Pids, Sz, TRef, EStack) ->
    receive
        {'DOWN', _MRef, process, Pid, shutdown} ->
            wait_children(Shutdown, sets:del_element(Pid, Pids), Sz-1, TRef, EStack);
        {'DOWN', _MRef, process, Pid, normal} ->
            wait_children(Shutdown, sets:del_element(Pid, Pids), Sz-1, TRef, EStack);
        {'DOWN', _MRef, process, Pid, Reason} ->
            wait_children(Shutdown, sets:del_element(Pid, Pids), Sz-1,
                          TRef, dict:append(Reason, Pid, EStack));
        {timeout, TRef, kill} ->
            sets:fold(fun(P, _) -> exit(P, kill) end, ok, Pids),
            wait_children(Shutdown, Pids, Sz-1, undefined, EStack)
    end.

log(Level, Error, Reason, Pid, #state{mfargs = MFA}) ->
    ErrorMsg = [{supervisor, {?MODULE, Pid}},
                {errorContext, Error},
                {reason, Reason},
                {offender, [{pid, Pid},
                            {name, connection},
                            {mfargs, MFA}]}],
    case Level of
        info ->
            error_logger:info_report(supervisor_report, ErrorMsg);
        error ->
            error_logger:error_report(supervisor_report, ErrorMsg)
    end.

get_module({M, _F, _A}) -> M;
get_module({M, _F}) -> M;
get_module(M) -> M.

resolve_max_connections(Desired) ->
    MaxFds = esockd:ulimit(),
    MaxProcs = erlang:system_info(process_limit),
    resolve_max_connections(Desired, MaxFds, MaxProcs).

resolve_max_connections(undefined, MaxFds, MaxProcs) ->
    %% not configured
    min(MaxFds, MaxProcs);
resolve_max_connections(Desired, MaxFds, MaxProcs) when is_integer(Desired) ->
    Res = lists:min([Desired, MaxFds, MaxProcs]),
    case Res < Desired of
        true ->
            logger:log(error,
                       #{msg => "max_connections_config_ignored",
                         max_fds => MaxFds,
                         max_processes => MaxProcs,
                         desired => Desired
                        }
                      );
        false ->
            ok
    end,
    Res.
