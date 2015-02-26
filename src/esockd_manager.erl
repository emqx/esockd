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
%%% eSockd manager.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_manager).

-author("feng@emqtt.io").

-behaviour(gen_server).

-define(SERVER, ?MODULE).

%% Start esockd manager
-export([start_link/0]).

%% API
-export([opened/0, getopts/1, getopts/2, setopts/2, getstats/1, getstats/2]).

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
-spec start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%------------------------------------------------------------------------------
%% @doc
%% Get opened listeners.
%%
%% @end
%%------------------------------------------------------------------------------
opened() ->
    gen_server:call(?SERVER, get_opened).

%%------------------------------------------------------------------------------
%% @doc
%% Get all options of opened port.
%%
%% @end
%%------------------------------------------------------------------------------
getopts({Protocol, Port}) ->
    gen_server:call(?SERVER, {getopts, {Protocol, Port}}).

%%------------------------------------------------------------------------------
%% @doc
%% Get specific options of opened port.
%%
%% @end
%%------------------------------------------------------------------------------
getopts({Protocol, Port}, Opts) ->
    gen_server:call(?SERVER, {getopts, {Protocol, Port}, Opts}).

%%------------------------------------------------------------------------------
%% @doc
%% Set options of opened port.
%%
%% @end
%%------------------------------------------------------------------------------
setopts({Protocol, Port}, Options) ->
    gen_server:call(?SERVER, {setopts, {Protocol, Port}, Options}).

%%------------------------------------------------------------------------------
%% @doc
%% Get all stats of opened port.
%%
%% @end
%%------------------------------------------------------------------------------
getstats({Protol, Port}) ->
    gen_server:call(?SERVER, {getstats, {Protol, Port}}).

%%------------------------------------------------------------------------------
%% @doc
%% Get specific stats of opened port.
%%
%% @end
%%------------------------------------------------------------------------------
getstats({Protol, Port}, Options) ->
    gen_server:call(?SERVER, {getstats, {Protol, Port}, Options}).


%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%------------------------------------------------------------------------------
-spec init(Args) ->
    {ok, State} | {ok, State, timeout() | hibernate} |
    {stop, Reason} | ignore when
    Args    :: term(),
    State   :: #state{},
    Reason  :: any().
init([]) ->
    {ok, #state{}}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%------------------------------------------------------------------------------
-spec handle_call(Request, From, State) ->
    {reply, Reply, NewState} |
    {reply, Reply, NewState, timeout() | hibernate} |
    {noreply, NewState} |
    {noreply, NewState, timeout() | hibernate} |
    {stop, Reason, Reply, NewState} |
    {stop, Reason, NewState} when
    Request     :: term(),
    From        :: {pid, Tag :: term()},
    State       :: #state{},
    NewState    :: #state{},
    Reply       :: term(),
    Reason      :: term().


handle_call(get_opened, _From, State) ->
    %%TODO: get opened ports...
    {reply, [], State};


handle_call({getopts, {Protocol, Port}}, _From, State) ->
    %%TODO: options
    {reply, [], State};


handle_call({getopts, {Protocol, Port}, Opts}, _From, State) ->
    %%TODO:
    {reply, [], State};


handle_call({setopts, {Protocol, Port}, Options}, _From, State) ->
    %%TODO:
    {reply, ok, State};

handle_call({getstats, {Protol, Port}}, _From, State) ->
    %%TODO:
    {reply, [], State};

handle_call({getstats, {Protol, Port}, Options}, _From, State) ->
    %%TODO:
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
-spec handle_cast(Request, State) ->
    {noreply, NewState} |
    {noreply, NewState, timeout() | hibernate} |
    {stop, Reason, NewState} when
    Request   :: term(),
    State     :: #state{},
    NewState  :: #state{},
    Reason    :: term().
handle_cast(_Request, State) ->
    {noreply, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(Info, State) ->
    {noreply, NewState} |
    {noreply, NewState, timeout() | hibernate} |
    {stop, Reason, NewState} when
    Info     :: timeout() | term(),
    State    :: #state{},
    NewState :: #state{},
    Reason   :: term().
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
%% @spec terminate(Reason, State) -> void()
%% @end
%%------------------------------------------------------------------------------
-spec terminate(Reason, State) -> any() when
    Reason  :: normal | shutdown | {shutdown, term()} | term(),
    State :: #state{}.
terminate(_Reason, _State) ->
    ok.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%------------------------------------------------------------------------------
-spec code_change(OldVsn, State, Extra) -> {ok, NewState} | {error, Reason} when
    OldVsn   :: term() | {down, term()},
    State    :: #state{},
    Extra    :: term(),
    NewState :: #state{},
    Reason   :: term().
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================
