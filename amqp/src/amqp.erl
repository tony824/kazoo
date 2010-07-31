-module(amqp).

-author('James Aimonetti <james@2600hz.com>').

-export([start/0, start_link/0, stop/0]).

ensure_started(App) ->
    case application:start(App) of
	ok ->
	    ok;
	{error, {already_started, App}} ->
	    ok
    end.

%% @spec start_link() -> {ok,Pid::pid()}
%% @doc Starts the app for inclusion in a supervisor tree
start_link() ->
    amqp_sup:start_link().

%% @spec start() -> ok
%% @doc Start the amqp server.
start() ->
    application:start(amqp).

%% @spec stop() -> ok
%% @doc Stop the amqp server.
stop() ->
    application:stop(amqp).
