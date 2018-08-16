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

-module(esockd_gen).

-author("Feng Lee <feng@emqtt.io>").

-export([send_fun/1, async_send_fun/1]).

-spec(send_fun(esockd_connection:connection()) -> fun()).
send_fun(Connection) ->
     fun(Data) -> Connection:send(Data) end.

-spec(async_send_fun(esockd_connection:connection()) -> fun()).
async_send_fun(Connection) ->
    fun(Data) ->
        try Connection:async_send(Data) of
            true -> ok
        catch
            error:Error -> exit({shutdown, Error})
        end
    end.

