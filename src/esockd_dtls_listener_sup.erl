%%%===================================================================
%%% Copyright (c) 2013-2018 EMQ Inc. All rights reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%===================================================================

-module(esockd_dtls_listener_sup).

-import(esockd_util, [merge_opts/2]).

-export([start_link/4]).

-export([init/1]).

start_link(Proto, Port, Opts, MFA) ->
    case ssl:listen(Port, dtls_options(Opts)) of
        {ok, LSock} ->
            io:format("~s opened on dtls ~w~n", [Proto, Port]),
            {ok, Sup} = supervisor:start_link(?MODULE, []),
            {ok, AcceptorSup} = start_acceptor_sup(Sup, Opts, MFA),
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

dtls_options(Opts) ->
    UdpOpts = merge_opts([{reuseaddr, true}], proplists:get_value(udp_options, Opts, [])),
    [{protocol, dtls} | merge_opts(UdpOpts, proplists:get_value(ssl_options, Opts, []))].

start_acceptor_sup(Sup, Opts, MFA) ->
    Spec = #{id       => acceptor_sup,
             start    => {esockd_dtls_acceptor_sup, start_link, [Opts, MFA]},
             restart  => transient,
             shutdown => brutal_kill,
             type     => supervisor,
             modules  => [esockd_acceptor_sup]},
    supervisor:start_child(Sup, Spec).

init([]) ->
    {ok, {{rest_for_one, 10, 3600}, []}}.

