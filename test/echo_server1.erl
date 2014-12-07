-module(echo_server1).

-behaviour(gen_server).

-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1, go/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {sock}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Sock) ->
    gen_server:start_link(?MODULE, [Sock], []).

%%NOTICE: callbed by acceptor to tell socked is ready...
go(Pid, Sock) ->
	gen_server:call(Pid, {go, Sock}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([Sock]) ->
    {ok, #state{sock = Sock}}.

handle_call({go, Sock}, _From, State) ->
	inet:setopts(Sock, [{active, once}]),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({tcp, Sock, Data}, State=#state{sock=Sock}) ->
	echo(Sock, Data),
	inet:setopts(Sock, [{active, once}]),
    {noreply, State};

handle_info({tcp_closed, Sock}, State=#state{sock=Sock}) ->
	io:format("~p tcp_closed~n", [Sock]),
	{stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
echo(Sock, Data) ->
	{ok, Name} = inet:peername(Sock),
	io:format("~p: ~s~n", [Name, Data]),
	gen_tcp:send(Sock, Data).

