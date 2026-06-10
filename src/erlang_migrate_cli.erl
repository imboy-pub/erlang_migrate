%% @doc Minimal CLI for erlang_migrate. Build with: rebar3 escriptize
%% Output: _build/default/bin/erlang_migrate_cli
%%
%% Only `new' (file generation) is provided — applying migrations stays
%% in-app via erlang_migrate:up/1, preserving the zero-dependency design
%% (a full CLI would have to bundle every database driver).
-module(erlang_migrate_cli).
-export([main/1]).

-define(DEFAULT_DIR, "priv/migrations").

main(["new", Title]) ->
    main(["new", Title, ?DEFAULT_DIR]);
main(["new", Title, Dir]) ->
    io:setopts(standard_io, [{encoding, unicode}]),
    case erlang_migrate:create(Dir, Title) of
        {ok, Up, Down} ->
            io:format("created ~ts~ncreated ~ts~n", [Up, Down]);
        {error, Reason} ->
            io:format(standard_error, "error: ~p~n", [Reason]),
            erlang:halt(1)
    end;
main(_) ->
    io:format(standard_error,
              "usage: erlang_migrate_cli new <title> [dir]~n"
              "       creates {utc_timestamp}_<title>.up.sql and .down.sql"
              " (default dir: " ?DEFAULT_DIR ")~n", []),
    erlang:halt(2).
