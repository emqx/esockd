%%--------------------------------------------------------------------
%% Copyright (c) 2019 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(esockd_dtls_listener_sup).

-behaviour(supervisor).

%% APIs
-export([ start_link/4
        , acceptor_sup/1
        ]).

%% get/set
-export([ get_options/1
        , get_acceptors/1
        , get_max_connections/1
        , get_current_connections/1
        , get_shutdown_count/1
        ]).

-export([ set_max_connections/2 ]).

-export([ get_access_rules/1
        , allow/2
        , deny/2
        ]).

%% supervisor callbacks
-export([init/1]).

-define(DTLS_OPTS, [{protocol, dtls}, {mode, binary}, {reuseaddr, true}]).

-define(ERROR_MSG(Format, Args),
        error_logger:error_msg("[~s]: " ++ Format, [?MODULE | Args])).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

-spec(start_link(atom(), {inet:ip_address(),inet:port_number()} | inet:port_number(),
                 [esockd:option()], mfa()) -> {ok, pid()} | {error, term()}).
start_link(Proto, {Host, Port}, Opts, MFA) ->
    start_link(Proto, Port, merge_addr(Host, Opts), MFA);
start_link(Proto, Port, Opts, MFA) ->
    case ssl:listen(Port, esockd:merge_opts(
                            ?DTLS_OPTS, proplists:get_value(dtls_options, Opts, []))) of
        {ok, LSock} ->
            %% error_logger:info_msg("~s opened on dtls ~w~n", [Proto, Port]),
            {ok, Sup} = supervisor:start_link(?MODULE, []),
            LimitFun = esockd_listener_sup:rate_limit_fun({dtls, Proto, Port}, Opts),
            {ok, AcceptorSup} = start_acceptor_sup(Sup, Opts, MFA, LimitFun),
            AcceptorNum = proplists:get_value(acceptors, Opts, 8),
            lists:foreach(fun(_) ->
                {ok, _Pid} = esockd_dtls_acceptor_sup:start_acceptor(AcceptorSup, LSock)
            end, lists:seq(1, AcceptorNum)),
            {ok, Sup};
        {error, Reason} ->
            error_logger:error_msg("DTLS failed to listen on ~p - ~p (~s)",
                                   [Port, Reason, inet:format_error(Reason)]),
            {error, Reason}
    end.

%% @private
start_acceptor_sup(Sup, Opts, MFA, LimitFun) ->
    Spec = #{id => acceptor_sup,
             start => {esockd_dtls_acceptor_sup, start_link, [Opts, MFA, LimitFun]},
             restart => transient,
             shutdown => infinity,
             type => supervisor,
             modules => [esockd_dtls_acceptor_sup]},
    supervisor:start_child(Sup, Spec).

%% @private
merge_addr(Addr, Opts) ->
    lists:keystore(ip, 1, Opts, {ip, Addr}).

%% @doc Get acceptor supervisor.
-spec(acceptor_sup(pid()) -> pid()).
acceptor_sup(Sup) ->
    child_pid(Sup, acceptor_sup).

%%--------------------------------------------------------------------
%% GET/SET APIs
%%--------------------------------------------------------------------

get_options(_LSup) ->
    ?ERROR_MSG("The ~p not supported ~p yet!!!", [?MODULE, ?FUNCTION_NAME]),
    [].

get_acceptors(LSup) ->
    esockd_dtls_acceptor_sup:count_acceptors(acceptor_sup(LSup)).

get_max_connections(_LSup) ->
    ?ERROR_MSG("The ~p not supported ~p yet!!!", [?MODULE, ?FUNCTION_NAME]),
    [].

get_current_connections(_LSup) ->
    ?ERROR_MSG("The ~p not supported ~p yet!!!", [?MODULE, ?FUNCTION_NAME]),
    0.

get_shutdown_count(_LSup) ->
    ?ERROR_MSG("The ~p not supported ~p yet!!!", [?MODULE, ?FUNCTION_NAME]),
    0.

set_max_connections(_LSup, MaxLimit) when is_integer(MaxLimit) ->
    ?ERROR_MSG("The ~p not supported ~p yet!!!", [?MODULE, ?FUNCTION_NAME]),
    ok.

get_access_rules(_LSup) ->
    ?ERROR_MSG("The ~p not supported ~p yet!!!", [?MODULE, ?FUNCTION_NAME]),
    [].

allow(_LSup, _CIDR) ->
    ?ERROR_MSG("The ~p not supported ~p yet!!!", [?MODULE, ?FUNCTION_NAME]),
    ok.

deny(_LSup, _CIDR) ->
    ?ERROR_MSG("The ~p not supported ~p yet!!!", [?MODULE, ?FUNCTION_NAME]),
    ok.

%%--------------------------------------------------------------------
%% Supervisor callbacks
%%--------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_all, 10, 3600}, []}}.

%%--------------------------------------------------------------------
%% Uitls
%%--------------------------------------------------------------------

child_pid(Sup, ChildId) ->
    hd([Pid || {Id, Pid, _, _}
               <- supervisor:which_children(Sup), Id =:= ChildId]).

