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

-module(esockd_udp_router_db).

%% API
-export([ insert/2, insert_in/2, delete_in/3
        , delete_out/1, lookup/1, start/0]).

-record(in, { source :: pid()      %% the router pid
            , sid :: sourceid()}).

-record(out, { sid :: sourceid()
             , destination :: pid()  %% the connection pid
             , count :: non_neg_integer()}). %% Reference Counter

-define(TAB, esockd_udp_router_db).
-define(MINIMUM_VAL, -2147483647).

-type sourceid() :: esockd_udp_router:sourceid().
-type router_module() :: esockd_udp_router:router_mdoule().

%%--------------------------------------------------------------------
%%- API
%%--------------------------------------------------------------------
start() ->
    ets:new(?TAB, [ set, public, named_table
                  , {keypos, #out.sid}
                  , {write_concurrency, true}
                  , {read_concurrency, true}]).

-spec insert(sourceid(), pid()) -> boolean().
insert(Sid, Destination) ->
    ets:insert_new(?TAB, #out{sid = Sid,
                              destination = Destination,
                              count = 1}).

-spec insert_in(pid(), sourceid()) -> integer().
insert_in(Source, Sid) ->
    ets:insert(?TAB, #in{source = Source, sid = Sid}), %% junk ?
    ets:update_counter(?TAB, Sid, {#out.count, 1}, 1).

-spec delete_in(router_module(), pid(), sourceid()) -> ok.
delete_in(Behaviour, Source, Sid) ->
    ets:delete(?TAB, Source), %% XXX maybe shodule this ?
    RC = ets:update_counter(?TAB, Sid, {#out.count, -1, 0, ?MINIMUM_VAL}, 0),
    if RC < 0 ->
            Pid = ets:lookup_element(?TAB, Sid, #out.sid),
            Behaviour:close(Pid),
            ets:delete(?TAB, Sid),
            ok;
       true ->
            ok
    end.

-spec delete_out(sourceid()) -> ok.
delete_out(Sid) ->
    ets:delete(?TAB, Sid),
    ok.

-spec lookup(sourceid()) -> {ok, pid()} | undefined.
lookup(Sid) ->
    case ets:lookup(?TAB, Sid) of
        [#out{destination = Pid}] ->
            {ok, Pid};
        _ ->
            undefined
    end.

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%%- Internal functions
%%--------------------------------------------------------------------
