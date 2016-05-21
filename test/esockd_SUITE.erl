%%--------------------------------------------------------------------
%% Copyright (c) 2016 Feng Lee <feng@emqtt.io>.
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

-module(esockd_SUITE).

-include_lib("eunit/include/eunit.hrl").

%% Common Test
-compile(export_all).

all() ->
    [{group, api}].

groups() ->
    [{api, [sequence], [t_open_close]}].

init_per_suite(Config) ->
    application:start(lager),
    application:start(gen_logger),
    esockd:start(),
    Config.

end_per_suite(_Config) ->
    application:stop(esockd).

t_open_close(_) ->
    MFA = {echo_server, start_link, []},
    {ok, _LSup} = esockd:open(echo, {"127.0.0.1", 5000}, [binary, {packet, raw}], MFA),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", 5000, []),
    ok = gen_tcp:send(Sock, <<"Hello">>),
    esockd:close(echo, {"127.0.0.1", 5000}).
 
