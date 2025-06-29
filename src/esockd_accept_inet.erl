%%--------------------------------------------------------------------
%% Copyright (c) 2025 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(esockd_accept_inet).

-export([
    init/2,
    async_accept/2,
    async_accept_result/3,
    post_accept/2,
    fast_close/1
]).

-export([
    mk_tune_socket_fun/1,
    tune_socket/2
]).

-type ctx() :: {module(), tune_socket_fun()}.
-type socket() :: inet:socket().
-type async_ref() :: reference().

-type tune_socket_fun() ::
    {fun((socket(), Opts) -> {ok, socket()} | {error, any()}), Opts}.

%%

-spec init(socket(), _Opts) -> ctx().
init(LSock, TuneFun) ->
    {ok, SockMod} = inet_db:lookup_socket(LSock),
    {SockMod, TuneFun}.

-spec async_accept(socket(), ctx()) ->
    {async, async_ref()} | {error, atom()}.
async_accept(LSock, _Ctx) ->
    case prim_inet:async_accept(LSock, -1) of
        {ok, Ref} ->
            {async, Ref};
        {error, Reason} ->
            {error, Reason}
    end.

-spec async_accept_result(Message, async_ref(), ctx()) ->
    {ok, socket()} | {error, atom()} | Message.
async_accept_result({inet_async, _LSock, Ref, {ok, Sock}}, Ref, _Ctx) ->
    {ok, Sock};
async_accept_result({inet_async, _LSock, Ref, {error, Reason}}, Ref, _Ctx) ->
    {error, Reason};
async_accept_result(Info, _Ref, _Ctx) ->
    Info.

-spec post_accept(socket(), ctx()) -> {ok, socket()} | {error, atom()}.
post_accept(Sock, {SockMod, TuneFun}) ->
    %% make it look like gen_tcp:accept
    inet_db:register_socket(Sock, SockMod),
    eval_tune_socket_fun(TuneFun, Sock).

eval_tune_socket_fun({Fun, Opts}, Sock) ->
    Fun(Sock, Opts).

-spec mk_tune_socket_fun([esockd:option()]) -> tune_socket_fun().
mk_tune_socket_fun(Opts) ->
    TuneOpts = [{Name, Val} || {Name, Val} <- Opts,
                               Name =:= tune_buffer orelse
                               Name =:= tune_fun],
    {fun ?MODULE:tune_socket/2, TuneOpts}.

tune_socket(Sock, []) ->
    {ok, Sock};
tune_socket(Sock, [{tune_buffer, true}|More]) ->
    case esockd_transport:getopts(Sock, [sndbuf, recbuf, buffer]) of
        {ok, BufSizes} ->
            BufSz = lists:max([Sz || {_Opt, Sz} <- BufSizes]),
            case esockd_transport:setopts(Sock, [{buffer, BufSz}]) of
                ok ->
                    tune_socket(Sock, More);
                Error ->
                    Error
            end;
        Error ->
            Error
    end;
tune_socket(Sock, [{tune_fun, {M, F, A}} | More]) ->
    case apply(M, F, A) of
        ok ->
            tune_socket(Sock, More);
        Error ->
            Error
    end.

-spec fast_close(socket()) -> ok.
fast_close(Sock) ->
    try
        %% NOTE
        %% Port-close leads to a TCP reset which cuts out TCP graceful close overheads.
        _ = port_close(Sock),
        receive {'EXIT', Sock, _} -> ok after 1 -> ok end
    catch
        error:_ -> ok
    end.
