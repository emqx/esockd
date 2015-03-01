%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2014-2015, Feng Lee <feng@emqtt.io>
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
%%% eSockd server.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_server).

-author("feng@emqtt.io").

-behaviour(gen_server).

-define(SERVER, ?MODULE).

%% Start esockd server
-export([start_link/0]).

%% API
-export([listeners/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {}).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% Start esockd manager.
%%
%% @end
%%------------------------------------------------------------------------------
-spec start_link() -> {ok, Pid :: pid()} | ignore | {error, any()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%------------------------------------------------------------------------------
%% @doc
%% Get listeners.
%%
%% @end
%%------------------------------------------------------------------------------
listeners() ->
    gen_server:call(?SERVER, listeners).

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @end
%%------------------------------------------------------------------------------
init([]) ->
    {ok, #state{}}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%------------------------------------------------------------------------------
handle_call(listeners, _From, State) ->
    %%TODO: get listeners...
    {reply, [], State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%------------------------------------------------------------------------------
handle_cast(_Request, State) ->
    {noreply, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @end
%%------------------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%------------------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @end
%%------------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

