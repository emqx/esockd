%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2012-2015, Feng Lee <feng@emqtt.io>
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
%%% esockd main api.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(esockd).

-author("feng@emqtt.io").

%% Start Application.
-export([start/0]).

%% Core API
-export([open/4, close/2]).

%% Management API
-export([opened/0, getopts/1, getopts/2, setopts/2, getstats/1, getstats/2]).

%% utility functions...
-export([ulimit/0]).

-type mfargs() :: {module(), atom(), [term()]}.

-type callback() :: mfargs() | atom() | function().

-type option() :: 
		{acceptor_pool, pos_integer()} |
		{max_connections, pos_integer()} | 
        {ssl, [ssl:ssloption()]} |
        gen_tcp:listen_option().

-export_type([callback/0, option/0]).

%%------------------------------------------------------------------------------
%% @doc
%% Start esockd application.
%%
%% @end
%%------------------------------------------------------------------------------
-spec start() -> ok.
start() ->
    application:start(esockd).

%%------------------------------------------------------------------------------
%% @doc
%% Open a listener on Port.
%%
%% @end
%%------------------------------------------------------------------------------
-spec open(Protocol, Port, Options, Callback) -> {ok, pid()} | {error, any()} when
    Protocol     :: atom(),
    Port         :: inet:port_number(),
    Options		 :: [option()], 
    Callback     :: callback().
open(Protocol, Port, Options, Callback)  ->
	esockd_sup:start_listener(Protocol, Port, Options, Callback).

%%------------------------------------------------------------------------------
%% @doc
%% Close the listener.
%%
%% @end
%%------------------------------------------------------------------------------
-spec close(Protocol, Port) -> ok when 
    Protocol    :: atom(),
    Port        :: inet:port_number().
close(Protocol, Port) when is_atom(Protocol) and is_integer(Port) ->
	esockd_sup:stop_listener(Protocol, Port).

%%------------------------------------------------------------------------------
%% @doc
%% Get opened listeners.
%%
%% @end
%%------------------------------------------------------------------------------
opened() ->
    esockd_manager:opened().

%%------------------------------------------------------------------------------
%% @doc
%% Get all options of opened port.
%%
%% @end
%%------------------------------------------------------------------------------
getopts({Protocol, Port}) ->
    esockd_manager:getopts({Protocol, Port}).

%%------------------------------------------------------------------------------
%% @doc
%% Get specific options of opened port.
%%
%% @end
%%------------------------------------------------------------------------------
getopts({Protocol, Port}, Options) ->
    esockd_manager:getopts({Protocol, Port}, Options).

%%------------------------------------------------------------------------------
%% @doc
%% Set options of opened port.
%%
%% @end
%%------------------------------------------------------------------------------
setopts({Protocol, Port}, Options) ->
    esockd_manager:setopts({Protocol, Port}, Options).

%%------------------------------------------------------------------------------
%% @doc
%% Get all stats of opened port.
%%
%% @end
%%------------------------------------------------------------------------------
getstats({Protol, Port}) ->
    esockd_manager:getstats({Protol, Port}).

%%------------------------------------------------------------------------------
%% @doc
%% Get specific stats of opened port.
%%
%% @end
%%------------------------------------------------------------------------------
getstats({Protol, Port}, Options) ->
    esockd_manager:getstats({Protol, Port}, Options).

%%------------------------------------------------------------------------------
%% @doc
%% System `ulimit -n`
%% 
%%------------------------------------------------------------------------------
-spec ulimit() -> pos_integer().
ulimit() ->
    proplists:get_value(max_fds, erlang:system_info(check_io)).


