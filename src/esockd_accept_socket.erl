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

-module(esockd_accept_socket).

-export([
    init/2,
    async_accept/1,
    async_accept_result/3,
    post_accept/2,
    sockname/1,
    fast_close/1
]).

-export([
    mk_tune_socket_fun/1,
    tune_socket/2
]).

-type socket() :: socket:socket().
-type async_ref() :: socket:select_info().

-type tune_socket_fun() ::
    {fun((socket(), Opts) -> {ok, socket()} | {error, any()}), Opts}.

-record(ctx, {
    lsock :: socket(),
    tune_fun :: tune_socket_fun()
}).

-type ctx() :: #ctx{}.

-define(DEFAULT_SOCK_OPTIONS, [{nodelay, true}]).

%%

-spec init(socket(), _Opts) -> ctx().
init(LSock, TuneFun) ->
    #ctx{
        lsock = LSock,
        tune_fun = TuneFun
    }.

-spec async_accept(ctx()) ->
    {ok, socket()} | {async, async_ref()} | {error, atom()}.
async_accept(#ctx{lsock = LSock}) ->
    case socket:accept(LSock, nowait) of
        {ok, Sock} ->
            {ok, Sock};
        {error, Reason} ->
            {error, Reason};
        {select, {_Info, _Tag, Handle}} ->
            {async, Handle}
    end.

-spec async_accept_result(Info, async_ref(), _Opts) ->
    {ok, socket()} | {error, atom()} | {async, async_ref()} | Info.
async_accept_result({'$socket', LSock, select, Handle}, Handle, _Opts) ->
    case socket:accept(LSock, Handle) of
        {ok, Sock} ->
            {ok, Sock};
        {error, Reason} ->
            {error, Reason};
        {select, {_Info, _Tag, NHandle}} ->
            {async, NHandle}
    end;
async_accept_result({'$socket', _LSock, abort, {Handle, Reason}}, Handle, _Opts) ->
    {error, Reason};
async_accept_result(Info, _Handle, _Opts) ->
    Info.

-spec post_accept(socket(), ctx()) -> {ok, esockd_socket, socket()} | {error, atom()}.
post_accept(Sock, #ctx{tune_fun = TuneFun}) ->
    eval_tune_socket_fun(Sock, TuneFun).

return_socket(Sock) ->
    {ok, esockd_socket, Sock}.

eval_tune_socket_fun(Sock, {Fun, Opts}) ->
    Fun(Sock, Opts).

-spec mk_tune_socket_fun([esockd:option()]) -> tune_socket_fun().
mk_tune_socket_fun(Opts) ->
    TcpOpts = proplists:get_value(tcp_options, Opts, []),
    SockOpts = lists:flatten([sock_opt(O) || O <- merge_sock_defaults(TcpOpts)]),
    TuneOpts = [{Name, Val} || {Name, Val} <- Opts,
                               Name =:= tune_buffer orelse
                               Name =:= tune_fun],
    {fun ?MODULE:tune_socket/2, [{setopts, SockOpts} | TuneOpts]}.

tune_socket(Sock, [{setopts, SockOpts} | Rest]) ->
    case esockd_socket:setopts(Sock, SockOpts) of
        ok ->
            tune_socket(Sock, Rest);
        Error ->
            Error
    end;
tune_socket(Sock, [{tune_buffer, true} | Rest]) ->
    try
        BufRecv = ensure(socket:getopt(Sock, {socket, rcvbuf})),
        Buffer = ensure(socket:getopt(Sock, {otp, rcvbuf})),
        Max = max(Buffer, BufRecv),
        ok = ensure(socket:setopt(Sock, {otp, rcvbuf}, Max)),
        tune_socket(Sock, Rest)
    catch
        Error -> Error
    end;
tune_socket(Sock, [{tune_fun, {M, F, A}} | Rest]) ->
    %% NOTE: Socket is not part of the argument list, backward compatibility.
    case apply(M, F, A) of
        ok ->
            tune_socket(Sock, Rest);
        Error ->
            Error
    end;
tune_socket(Sock, _) ->
    return_socket(Sock).

ensure(ok) -> ok;
ensure({ok, Result}) -> Result;
ensure(Error) -> throw(Error).

merge_sock_defaults(Opts) ->
    esockd:merge_opts(?DEFAULT_SOCK_OPTIONS, Opts).

sock_opt(binary) ->
    %% Meaningless.
    [];
sock_opt({nodelay, Flag}) ->
    {{tcp, nodelay}, Flag};
sock_opt({linger, {Flag, N}}) ->
    {{socket, linger}, #{onoff => Flag, linger => N}};
sock_opt({recbuf, Size}) ->
    {{socket, rcvbuf}, Size};
sock_opt({sndbuf, Size}) ->
    {{socket, sndbuf}, Size};
sock_opt({buffer, Size}) ->
    {{otp, rcvbuf}, Size};
sock_opt({reuseaddr, _}) ->
    %% Listener option.
    [];
sock_opt({backlog, _}) ->
    %% Listener option.
    [];
sock_opt(_Opt) ->
    %% TODO: Ignored, need to notify user.
    [].

-spec sockname(ctx()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, inet:posix() | closed}.
sockname(#ctx{lsock = LSock}) ->
    esockd_socket:sockname(LSock).

-spec fast_close(socket()) -> ok.
fast_close(Sock) ->
    esockd_socket:fast_close(Sock).
