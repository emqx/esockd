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

-module(esockd_udp_router).

-behaviour(gen_server).

%% API
-export([start_link/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/2]).

-export_type([sourceid/0, router_module/0, router_options/0]).

-define(NOW, erlang:system_time(second)).
-define(SSL_TRANSPORT, esockd_transport).
-define(ERROR_MSG(Format, Args),
        error_logger:error_msg("[~s]: " ++ Format, [?MODULE | Args])).
-define(DEF_HEARTBEAT, 60).

%%--------------------------------------------------------------------
%%  Definitions
%%--------------------------------------------------------------------
-record(state,
        {behaviour :: router_module(),
         source :: socket(),
         attachs :: #{sourceid => pos_integer()} %% last source's connection active time
        }).

-type state() :: #state{}.

-type router_module() :: atom().
-type socket_packet() :: binary().
-type app_packet() :: term().
-type socket() :: inet:socket() | ssl:sslsocket().

-type router_packet() :: {datagram, sourceinfo(), socket_packet()}
                       | {ssl, socket(), socket_packet()}
                       | {incoming, app_packet()}.

-type transport() :: {udp, pid(), socket()} | ?SSL_TRANSPORT.
-type sourceinfo() :: {inet:ip_address(), inet:port_number()}.
-type peer() :: socket() | sourceinfo().
-type sourceid() :: peer()
                  | integer()
                  | string()
                  | binary().

%% Routing information search results
-type routing_find_result() :: sourceid() %% send raw socket packet
                             | {sourceid(), app_packet()} %% send decoded packet
                             | invalid.

-type timespan() :: non_neg_integer(). %% second, 0 = infinity
-type router_options() :: #{behaviour := router_module(),
                            heartbeat => timespan()}.

%%--------------------------------------------------------------------
%%- Callbacks
%%--------------------------------------------------------------------
%% Create new connection
-callback create(transport(), peer()) -> {ok, pid()}.

%% Find routing information
-callback find(transport(), peer(), socket(), socket_packet()) ->
    routing_find_result().

%% Dispacth message
-callback dispatch(router_packet()) -> ok.

%% Close Connection
-callback close(pid()) -> ok.

%%--------------------------------------------------------------------
%%- API
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
-spec start_link(socket(), router_options()) -> {ok, Pid :: pid()} |
          {error, Error :: {already_started, pid()}} |
          {error, Error :: term()} |
          ignore.
start_link(Socket, Opts) ->
    gen_server:start_link(?MODULE, [Socket, Opts], []).

%%--------------------------------------------------------------------
%%- gen_server callbacks
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
init([Socket, #{behaviour := Behaviour} = Opts]) ->
    parse_opts(Opts),
    {ok, #state{source = Socket,
                behaviour = Behaviour,
                attachs = #{}}}.

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
handle_info({udp, Socket, IP, Port, Data}, State) ->
    Transport = {udp, self(), Socket},
    Peer = {IP, Port},
    {noreply,
     handle_incoming(Transport, Peer, Socket, Data, State)};

handle_info({ssl, Socket, Data}, State) ->
    {noreply,
     handle_incoming(?SSL_TRANSPORT, Socket, Socket, Data, State)};

handle_info({heartbeat, Span}, #state{behaviour = Behaviour, attachs = Attachs} = State) ->
    heartbeat(Span),
    Now = ?NOW,
    Self = self(),
    Attachs2 = maps:fold(fun(Sid, LastActive, Acc) ->
                                 if Now - LastActive > Span ->
                                         esockd_udp_router_db:delete_in(Behaviour, Self, Sid),
                                         Acc;
                                    true ->
                                         Acc#{Sid => LastActive}
                                 end
                         end,
                         #{},
                         Attachs),
    State2 = State#state{attachs = Attachs2},
    case Attachs2 of
        #{} ->
            {stop, normal, State2};
        _ ->
            {noreply, State2}
    end;

handle_info({ssl_error, _Sock, Reason}, State) ->
    {stop, Reason, socket_exit(State)};

handle_info({ssl_closed, _Sock}, State) ->
    {stop, ssl_closed, socket_exit(State)};

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
terminate(_Reason, #state{behaviour = Behaviour,
                          attachs = Attachs}) ->
    Self = self(),
    _ = maps:fold(fun(Sid, _, _) ->
                          esockd_udp_router_db:delete_in(Behaviour, Self, Sid)
                  end,
                  ok,
                  Attachs),
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
%%- Internal functions
%%--------------------------------------------------------------------
-spec handle_incoming(transport(), peer(), socket(), socket_packet(), state()) -> state().
handle_incoming(Transport, Peer, Socket, Data, #state{behaviour = Behaviour} = State) ->
    case Behaviour:find(Transport, Peer, Socket, Data) of
        {ok, Sid} ->
            Tag = raw_packet_tag(Transport),
            dispatch(Transport, Peer, Behaviour, Sid, {Tag, Peer, Data}, State);
        {ok, Sid, AppPacket} ->
            dispatch(Transport, Peer, Behaviour, Sid, {incoming, AppPacket}, State);
        invalid ->
            State
    end.

-spec dispatch(transport(), peer(), router_module(), sourceid(), router_packet(), state()) -> state().
dispatch(Transport, Peer, Behaviour, Sid, Packet, State) ->
    {ok, Pid} =
        case esockd_udp_router_db:lookup(Sid) of
            {ok, Dest} ->
                safe_attach(Transport, Peer, Sid, Dest, State);
            undefined ->
                Result = esockd_udp_router_monitor:create(Transport, Peer, Sid, Behaviour),
                unsafe_attach(Sid, State),
                Result
        end,
    dispatch(Behaviour, Sid, Pid, Packet, State).

-spec dispatch(router_module(), sourceid(), pid(), router_packet(), state()) -> state().
dispatch(Behaviour, Sid, Pid, Packet, #state{attachs = Attachs} = State) ->
    Behaviour:dispatch(Pid, Packet),
    State#state{attachs = Attachs#{Sid => ?NOW}}.

-spec raw_packet_tag(transport()) -> datagram | ssl.
raw_packet_tag(?SSL_TRANSPORT) -> ssl;
raw_packet_tag(_) -> datagram.

-spec unsafe_attach(sourceid(), state()) -> state().
unsafe_attach(Sid, #state{attachs = Attachs}) ->
    case maps:is_key(Sid, Attachs) of
        false ->
            esockd_udp_router_db:insert_in(self(), Sid),
            ok;
        _ ->
            ok
    end.

-spec safe_attach(transport(), peer(), sourceid(), pid(), state()) -> {ok, pid(), state()}.
safe_attach(Transport, Peer, Sid, Dest, #state{behaviour = Behaviour,
                                               attachs = Attachs}) ->
    case maps:is_key(Sid, Attachs) of
        true ->
            {ok, Dest};
        false ->
            Result = esockd_udp_router_db:insert_in(self(), Sid),
            if Result > 0 ->
                    %% the connection are exists, but maybe not Dest
                    %%(some router close the old, and some create new, when this router doing attach)
                    case esockd_udp_router_db:lookup(Sid) of
                        {ok, RDest} ->
                            {ok, RDest};
                        undefined ->
                            esockd_udp_router_monitor:create(Transport, Peer, Sid, Behaviour)
                    end;
               true ->
                    %% when this router attach Sid's connection
                    %% ohter router closed this connection, so we need create new
                    %% or maybe we should just throw a exception?
                    esockd_udp_router_monitor:create(Transport, Peer, Sid, Behaviour)
            end
    end.

-spec socket_exit(state()) -> state().
socket_exit(#state{behaviour = Behaviour, attachs = Attachs} = State) ->
    _ = maps:fold(fun(Sid, _, _) ->
                          esockd_udp_router_db:delete_in(Behaviour, self(), Sid)
                  end,
                  ok,
                  Attachs),
    State#state{attachs = #{}}.

-spec heartbeat(timespan()) -> ok.
heartbeat(Span) ->
    erlang:send_after(self(), timer:seconds(Span), {?FUNCTION_NAME, Span}),
    ok.

parse_opts(Opts) ->
    lists:foreach(fun(Opt) ->
                          parse_opt(Opt, Opts)
                  end,
                  [heartbeat]).

parse_opt(heartbeat, #{heartbeat := Span}) ->
    if Span ->
            heartbeat(Span);
       true ->
            ok
    end;

parse_opt(heartbeat, _) ->
    heartbeat(?DEF_HEARTBEAT).
