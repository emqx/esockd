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

-module(esockd_udp_router_monitor).

-behaviour(gen_server).

%% API
-export([start_link/1,
         create/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/2]).

-record(state, {pool_id :: pool_id(),
                monitors :: #{reference() => {router_module(), sourceid()}}}).

-type pool_id() :: non_neg_integer().
-type router_module() :: esockd_udp_router:router_module().
-type sourceid() :: esockd_udp_router:sourceid().

-define(POOL, ?MODULE).
-define(PNAME(Id), {?POOL, Id}).
-define(ERROR_MSG(Format, Args),
        error_logger:error_msg("[~s]: " ++ Format, [?MODULE | Args])).

%%--------------------------------------------------------------------
%%- API
%%--------------------------------------------------------------------
create(Transport, Peer, Sid, Behaviour) ->
    %% Use affinity to resolve potential concurrent conflicts
    call(Sid, {?FUNCTION_NAME, Transport, Peer, Sid, Behaviour}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
-spec start_link(pool_id()) -> {ok, Pid :: pid()} |
          {error, Error :: {already_started, pid()}} |
          {error, Error :: term()} |
          ignore.
start_link(Id) ->
    gen_server:start_link({local, proc_name(Id)}, ?MODULE, [Id], [{hibernate_afterr, 1000}]).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) -> {ok, State :: term()} |
          {ok, State :: term(), Timeout :: timeout()} |
          {ok, State :: term(), hibernate} |
          {stop, Reason :: term()} |
          ignore.
init([PoolId]) ->
    gproc_pool:connect_worker(?POOL, ?PNAME(PoolId)),
    {ok, #state{pool_id = PoolId,
                monitors = #{}}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------
-spec handle_call(Request :: term(), From :: {pid(), term()}, State :: term()) ->
          {reply, Reply :: term(), NewState :: term()} |
          {reply, Reply :: term(), NewState :: term(), Timeout :: timeout()} |
          {reply, Reply :: term(), NewState :: term(), hibernate} |
          {noreply, NewState :: term()} |
          {noreply, NewState :: term(), Timeout :: timeout()} |
          {noreply, NewState :: term(), hibernate} |
          {stop, Reason :: term(), Reply :: term(), NewState :: term()} |
          {stop, Reason :: term(), NewState :: term()}.

handle_call({create, Transport, Peer, Sid, Behaviour}, _From,
            #state{monitors = Monitors} = State) ->
    case esockd_udp_router_db:lookup(Sid) of
        {ok, Pid} ->
            {reply, {ok, Pid}, State};
        _ ->
            {ok, Pid} = Behaviour:create(Transport, Peer),
            Ref = erlang:monitor(process, Pid),
            true = esockd_udp_router_db:insert(Sid, Pid),
            {reply, {ok, Pid}, State#state{monitors = Monitors#{Ref => {Behaviour, Sid}}}}
    end;

handle_call(Request, _From, State) ->
    ?ERROR_MSG("Unexpected call: ~p", [Request]),
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Request :: term(), State :: term()) ->
          {noreply, NewState :: term()} |
          {noreply, NewState :: term(), Timeout :: timeout()} |
          {noreply, NewState :: term(), hibernate} |
          {stop, Reason :: term(), NewState :: term()}.
handle_cast(Request, State) ->
    ?ERROR_MSG("Unexpected cast: ~p", [Request]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Info :: timeout() | term(), State :: term()) ->
          {noreply, NewState :: term()} |
          {noreply, NewState :: term(), Timeout :: timeout()} |
          {noreply, NewState :: term(), hibernate} |
          {stop, Reason :: normal | term(), NewState :: term()}.

%% connection closed
handle_info({'DOWN', Ref, process, _, _},
            #state{monitors = Monitors} = State) ->
    case maps:get(Ref, Monitors, undefined) of
        undefined ->
            {noreply, State};
        {_Behaviour, Sid} ->
            Monitors2 = maps:remove(Ref, Monitors),
            esockd_udp_router_db:delete_out(Sid),
            {noreply, State#state{monitors = Monitors2}}
    end;

handle_info(Info, State) ->
    ?ERROR_MSG("Unexpected info: ~p", [Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason :: normal | shutdown | {shutdown, term()} | term(),
                State :: term()) -> any().
terminate(_Reason, #state{pool_id = PoolId,
                          monitors = Monitors}) ->
    gproc_pool:disconnect_worker(?POOL, ?PNAME(PoolId)),
    _ = maps:fold(fun(Ref, {Behaviour, Sid}, _) ->
                          erlang:demonitor(Ref),
                          case esockd_udp_router_db:lookup(Sid) of
                                undefined ->
                                    ok;
                                {ok, Pid} ->
                                  Behaviour:close(Pid),
                                  esockd_udp_router_db:delete_out(Sid)
                          end
                  end, ok, Monitors),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn :: term() | {down, term()},
                  State :: term(),
                  Extra :: term()) -> {ok, NewState :: term()} |
          {error, Reason :: term()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called for changing the form and appearance
%% of gen_server status when it is returned from sys:get_status/1,2
%% or when it appears in termination error logs.
%% @end
%%--------------------------------------------------------------------
-spec format_status(Opt :: normal | terminate,
                    Status :: list()) -> Status :: term().
format_status(_Opt, Status) ->
    Status.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
-spec proc_name(pool_id()) -> atom().
proc_name(Id) ->
    list_to_atom(lists:concat([?POOL, "_", Id])).

-spec call(sourceid(), term()) -> ok.
call(Sid, Req) ->
    MPid = gproc_pool:pick_worker(?POOL, Sid),
    gen_server:call(MPid, Req).
