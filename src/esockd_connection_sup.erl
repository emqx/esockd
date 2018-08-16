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

%% API Exports
-export([start_link/3, start_connection/4, count_connections/1]).

%% Max Clients
-export([get_max_clients/1, set_max_clients/2]).

%% Shutdown Count
-export([get_shutdown_count/1]).

%% Allow, Deny
-export([access_rules/1, allow/2, deny/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(DICT, dict).
-define(SETS, sets).
-define(MAX_CLIENTS, 1024).

-record(state,
        { curr_clients = 0,
          max_clients  = ?MAX_CLIENTS,
          conn_opts    = [],
          access_rules = [],
          shutdown     = brutal_kill,
          mfargs,
          logger
        }).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

%% @doc Start connection supervisor.
-spec(start_link(Options, MFArgs, Logger) -> {ok, pid()} | ignore | {error, term()} when
    Options :: [esockd:option()],
    MFArgs  :: esockd:mfargs(),
    Logger  :: gen_logger:logmod()).
start_link(Options, MFArgs, Logger) ->
    gen_server:start_link(?MODULE, [Options, MFArgs, Logger], []).

%% @doc Start connection.
start_connection(Sup, Mod, Sock, SockFun) ->
    case call(Sup, {start_connection, Sock, SockFun}) of
        {ok, Pid, Conn} ->
            % transfer controlling from acceptor to connection
            Mod:controlling_process(Sock, Pid),
            Conn:go(Pid),
            {ok, Pid};
        {error, Error} ->
            {error, Error}
    end.

count_connections(Sup) ->
    call(Sup, count_connections).

get_max_clients(Sup) when is_pid(Sup) ->
    call(Sup, get_max_clients).

set_max_clients(Sup, MaxClients) when is_pid(Sup) ->
    call(Sup, {set_max_clients, MaxClients}).

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

init([Options, MFArgs, Logger]) ->
    process_flag(trap_exit, true),
    Shutdown    = get_value(shutdown, Options, brutal_kill),
    MaxClients  = get_value(max_clients, Options, ?MAX_CLIENTS),
    ConnOpts    = get_value(connopts, Options, []),
    RawRules    = get_value(access, Options, [{allow, all}]),
    AccessRules = [esockd_access:compile(Rule) || Rule <- RawRules],
    {ok, #state{max_clients  = MaxClients,
                conn_opts    = ConnOpts,
                access_rules = AccessRules,
                shutdown     = Shutdown,
                mfargs       = MFArgs,
                logger       = Logger}}.

handle_call({start_connection, _Sock, _SockFun}, _From,
            State = #state{curr_clients = CurrClients, max_clients = MaxClients})
        when CurrClients >= MaxClients ->
    {reply, {error, maxlimit}, State};

handle_call({start_connection, Sock, SockFun}, _From, 
            State = #state{conn_opts = ConnOpts, mfargs = MFArgs,
                           curr_clients = Count, access_rules = Rules}) ->
    case inet:peername(Sock) of
        {ok, {Addr, _Port}} ->
            case allowed(Addr, Rules) of
                true ->
                    Conn = esockd_connection:new(Sock, SockFun, ConnOpts),
                    case catch Conn:start_link(MFArgs) of
                        {ok, Pid} when is_pid(Pid) ->
                            put(Pid, true),
                            {reply, {ok, Pid, Conn}, State#state{curr_clients = Count+1}};
                        ignore ->
                            {reply, ignore, State};
                        {error, Reason} ->
                            {reply, {error, Reason}, State};
                        What ->
                            {reply, {error, What}, State}
                    end;
                false ->
                    {reply, {error, forbidden}, State}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(count_connections, _From, State = #state{curr_clients = Count}) ->
    {reply, Count, State};

handle_call(get_max_clients, _From, State = #state{max_clients = MaxClients}) ->
    {reply, MaxClients, State};

handle_call({set_max_clients, MaxClients}, _From, State) ->
    {reply, ok, State#state{max_clients = MaxClients}};

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

handle_call(_Req, _From, State) ->
    {stop, {error, badreq}, State}.

handle_cast(Msg, State = #state{logger = Logger}) ->
    Logger:error("Bad MSG: ~p", [Msg]),
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State = #state{curr_clients = Count, logger = Logger}) ->
    case erase(Pid) of
        true ->
            connection_crashed(Pid, Reason, State),
            {noreply, State#state{curr_clients = Count-1}};
        undefined ->
            Logger:error("'EXIT' from unkown ~p: ~p", [Pid, Reason]),
            {noreply, State}
    end;

handle_info(Info, State = #state{logger = Logger}) ->
    Logger:error("Bad INFO: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, State) ->
    terminate_children(State).

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
    Sz = ?SETS:size(Pids),
    EStack = case Shutdown of
                 brutal_kill ->
                     ?SETS:fold(fun(P, _) -> exit(P, kill) end, ok, Pids),
                     wait_children(Shutdown, Pids, Sz, undefined, EStack0);
                 infinity ->
                     ?SETS:fold(fun(P, _) -> exit(P, shutdown) end, ok, Pids),
                     wait_children(Shutdown, Pids, Sz, undefined, EStack0);
                 Time when is_integer(Time) ->
                     ?SETS:fold(fun(P, _) -> exit(P, shutdown) end, ok, Pids),
                     TRef = erlang:start_timer(Time, self(), kill),
                     wait_children(Shutdown, Pids, Sz, TRef, EStack0)
             end,
    %% Unroll stacked errors and report them
    ?DICT:fold(fun(Reason, Pid, _) ->
        report_error(connection_shutdown_error, Reason, Pid, State)
    end, ok, EStack).

monitor_children() ->
    lists:foldl(fun(P, {Pids, EStack}) ->
        case monitor_child(P) of
            ok ->
                {?SETS:add_element(P, Pids), EStack};
            {error, normal} ->
                {Pids, EStack};
            {error, Reason} ->
                {Pids, ?DICT:append(Reason, P, EStack)}
        end
    end, {?SETS:new(), ?DICT:new()}, get_keys(true)).

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

%%TODO: copied from supervisor.erl, rewrite it later.
wait_children(brutal_kill, Pids, Sz, TRef, EStack) ->
    receive
        {'DOWN', _MRef, process, Pid, killed} ->
            wait_children(brutal_kill, del(Pid, Pids), Sz-1, TRef, EStack);

        {'DOWN', _MRef, process, Pid, Reason} ->
            wait_children(brutal_kill, del(Pid, Pids),
                          Sz-1, TRef, ?DICT:append(Reason, Pid, EStack))
    end;

wait_children(Shutdown, Pids, Sz, TRef, EStack) ->
    receive
        {'DOWN', _MRef, process, Pid, shutdown} ->
            wait_children(Shutdown, del(Pid, Pids), Sz-1, TRef, EStack);
        {'DOWN', _MRef, process, Pid, normal} ->
            wait_children(Shutdown, del(Pid, Pids), Sz-1, TRef, EStack);
        {'DOWN', _MRef, process, Pid, Reason} ->
            wait_children(Shutdown, del(Pid, Pids), Sz-1,
                          TRef, ?DICT:append(Reason, Pid, EStack));
        {timeout, TRef, kill} ->
            ?SETS:fold(fun(P, _) -> exit(P, kill) end, ok, Pids),
            wait_children(Shutdown, Pids, Sz-1, undefined, EStack)
    end.

report_error(Error, Reason, Pid, #state{mfargs = MFArgs}) ->
    SupName  = list_to_atom("esockd_connection_sup - " ++ pid_to_list(self())),
    ErrorMsg = [{supervisor, SupName},
                {errorContext, Error},
                {reason, Reason},
                {offender, [{pid, Pid},
                            {name, connection},
                            {mfargs, MFArgs}]}],
    error_logger:error_report(supervisor_report, ErrorMsg).

del(Pid, Pids) ->
    erase(Pid), ?SETS:del_element(Pid, Pids).

