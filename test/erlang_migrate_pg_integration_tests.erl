%% Real-database integration tests for the PostgreSQL driver (epgsql).
%% No mocks: every assertion runs against a real PostgreSQL server.
%%
%% Gated on environment variables (skipped silently when unset):
%%   EM_PG_HOST (default localhost), EM_PG_PORT (default 5432),
%%   EM_PG_USER, EM_PG_PASSWORD, EM_PG_DB (bootstrap database, default postgres)
%%
%% The whole suite shares ONE scratch database (created/dropped once) —
%% per-test isolation is achieved by dropping the test-owned tables. This
%% avoids hammering the server with CREATE/DROP DATABASE cycles (which on
%% TimescaleDB instances also churn background workers).
%%
%% Example:
%%   EM_PG_USER=postgres EM_PG_PASSWORD=postgres EM_PG_DB=postgres rebar3 as test eunit
-module(erlang_migrate_pg_integration_tests).
-include_lib("eunit/include/eunit.hrl").

-define(TABLE, <<"em_it_schema_migrations">>).
-define(HIST, <<"em_it_schema_migrations_history">>).

-record(g, {conn, bootstrap, dbname, dir}).

pg_env(K, D) ->
    case os:getenv(K) of false -> D; V -> V end.

pg_available() -> os:getenv("EM_PG_USER") =/= false.

conn_opts(Db) ->
    #{host     => pg_env("EM_PG_HOST", "localhost"),
      port     => list_to_integer(pg_env("EM_PG_PORT", "5432")),
      username => list_to_binary(pg_env("EM_PG_USER", "postgres")),
      password => list_to_binary(pg_env("EM_PG_PASSWORD", "postgres")),
      database => list_to_binary(Db)}.

%%% ── one-time suite fixture ─────────────────────────────────────────────────

global_setup() ->
    Bootstrap = pg_env("EM_PG_DB", "postgres"),
    {ok, Bc} = epgsql:connect(conn_opts(Bootstrap)),
    DbName = "em_it_shared",
    {ok, _, _} = epgsql:squery(Bc, "DROP DATABASE IF EXISTS " ++ DbName),
    {ok, [], []} = epgsql:squery(Bc, "CREATE DATABASE " ++ DbName),
    {ok, Conn} = epgsql:connect(conn_opts(DbName)),
    Dir = "/tmp/em_it_pg_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = file:make_dir(Dir),
    #g{conn = Conn, bootstrap = Bc, dbname = DbName, dir = Dir}.

global_cleanup(#g{conn = Conn, bootstrap = Bc, dbname = DbName, dir = Dir}) ->
    catch epgsql:close(Conn),
    catch epgsql:squery(Bc,
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '"
        ++ DbName ++ "' AND pid <> pg_backend_pid()"),
    catch epgsql:squery(Bc, "DROP DATABASE IF EXISTS " ++ DbName),
    catch epgsql:close(Bc),
    {ok, Files} = file:list_dir(Dir),
    [file:delete(filename:join(Dir, F)) || F <- Files],
    file:del_dir(Dir).

q(G, SQL) ->
    {ok, _, Rows} = epgsql:squery(G#g.conn, iolist_to_binary(SQL)),
    Rows.

%% to_regclass returns one row with NULL when the table is absent.
table_present(G, Name) ->
    [{V}] = q(G, ["SELECT to_regclass('", Name, "')"]),
    V =/= null.

%% Drop every table this suite may create, so each test starts clean
%% without touching the database object itself.
reset_db(G) ->
    [catch epgsql:squery(G#g.conn, "DROP TABLE IF EXISTS " ++ T) ||
        T <- ["em_it_schema_migrations_history", "em_it_schema_migrations",
              "em_it_t1", "em_it_t2", "em_it_t3", "em_it_a", "em_it_b",
              "em_it_partial"]].

%%% ── per-test fixture ───────────────────────────────────────────────────────

write_std_migrations(Dir, N) ->
    lists:foreach(fun(I) ->
        B = integer_to_list(I),
        file:write_file(filename:join(Dir, B ++ "_step" ++ B ++ ".up.sql"),
            unicode:characters_to_binary(
                "CREATE TABLE em_it_t" ++ B ++ " (id bigint PRIMARY KEY);\n"
                "INSERT INTO em_it_t" ++ B ++ " VALUES (1);")),
        file:write_file(filename:join(Dir, B ++ "_step" ++ B ++ ".down.sql"),
            unicode:characters_to_binary("DROP TABLE em_it_t" ++ B ++ ";"))
    end, lists:seq(1, N)).

cfg(G, N) -> cfg(G, N, fun(_Dir) -> ok end).
cfg(G, N, Extra) ->
    reset_db(G),
    {ok, Files} = file:list_dir(G#g.dir),
    [file:delete(filename:join(G#g.dir, F)) || F <- Files],
    write_std_migrations(G#g.dir, N),
    ok = Extra(G#g.dir),
    #{conn => G#g.conn, dir => G#g.dir, driver => erlang_migrate_pg,
      table => ?TABLE}.

%%% ── suite ──────────────────────────────────────────────────────────────────

pg_test_() ->
    case pg_available() of
        false -> [];
        true  ->
            {setup, fun global_setup/0, fun global_cleanup/1,
             fun(G) ->
                 [{inorder,
                   {with, G, [fun lifecycle/1,
                              fun multi_statement_and_utf8/1,
                              fun no_down_migration_errors/1,
                              fun dirty_state_lifecycle/1,
                              fun force_validation/1,
                              fun dry_run_touches_nothing/1,
                              fun lock_contention_cross_connection/1,
                              fun concurrent_migration_cross_connection/1,
                              fun strict_mode/1,
                              fun strict_backfill_and_bootstrap_fail/1]}}]
             end}
    end.

lifecycle(G) ->
    Cfg = cfg(G, 3),
    ?assertEqual({ok, undefined, false}, erlang_migrate:version(Cfg)),
    ?assertEqual(ok, erlang_migrate:up(Cfg)),
    ?assertEqual({ok, 3, false}, erlang_migrate:version(Cfg)),
    [{<<"1">>}] = q(G, "SELECT id FROM em_it_t1"),
    ?assertEqual(ok, erlang_migrate:up(Cfg)),          %% idempotent
    ?assertEqual(ok, erlang_migrate:down(Cfg, 1)),
    ?assertEqual({ok, 2, false}, erlang_migrate:version(Cfg)),
    ?assertNot(table_present(G, "em_it_t3")),
    ?assertEqual(ok, erlang_migrate:goto(Cfg, 3)),
    ?assertEqual({ok, 3, false}, erlang_migrate:version(Cfg)),
    ?assertEqual(ok, erlang_migrate:goto(Cfg, 1)),
    ?assertEqual({ok, 1, false}, erlang_migrate:version(Cfg)),
    ?assertEqual(ok, erlang_migrate:down(Cfg)),
    ?assertEqual({ok, undefined, false}, erlang_migrate:version(Cfg)),
    ?assertEqual(ok, erlang_migrate:up(Cfg, 2)),
    ?assertEqual({ok, 2, false}, erlang_migrate:version(Cfg)).

multi_statement_and_utf8(G) ->
    Cfg = cfg(G, 0, fun(Dir) ->
        file:write_file(filename:join(Dir, "1_多语句.up.sql"),
            <<"CREATE TABLE em_it_a (id int); CREATE TABLE em_it_b (id int);">>),
        file:write_file(filename:join(Dir, "1_多语句.down.sql"),
            <<"DROP TABLE em_it_b; DROP TABLE em_it_a;">>)
    end),
    ?assertEqual(ok, erlang_migrate:up(Cfg)),
    [{<<"em_it_a">>}, {<<"em_it_b">>}] =
        lists:sort(q(G, "SELECT tablename FROM pg_tables WHERE tablename IN ('em_it_a','em_it_b')")),
    ?assertEqual(ok, erlang_migrate:down(Cfg)).

no_down_migration_errors(G) ->
    Cfg = cfg(G, 0, fun(Dir) ->
        file:write_file(filename:join(Dir, "1_nodown.up.sql"), <<"SELECT 1;">>)
    end),
    ?assertEqual(ok, erlang_migrate:up(Cfg)),
    ?assertEqual({error, {no_down_migration, 1}}, erlang_migrate:down(Cfg)).

dirty_state_lifecycle(G) ->
    %% migration 2 fails mid-file: first statement succeeds, second is
    %% broken — the whole file must roll back (PG DDL is transactional)
    %% and dirty stays.
    Cfg = cfg(G, 3, fun(Dir) ->
        file:write_file(filename:join(Dir, "2_step2.up.sql"),
            <<"CREATE TABLE em_it_partial (id int); CREATE TABLE broken(; ">>)
    end),
    ?assertMatch({error, _}, erlang_migrate:up(Cfg)),
    ?assertEqual({ok, 2, true}, erlang_migrate:version(Cfg)),
    ?assertNot(table_present(G, "em_it_partial")),     %% rolled back
    ?assertMatch({error, {dirty_state, _}}, erlang_migrate:up(Cfg)),
    ?assertMatch({error, {dirty_state, _}}, erlang_migrate:down(Cfg, 1)),
    ?assertMatch({error, {dirty_state, _}}, erlang_migrate:goto(Cfg, 3)),
    %% force recovers without executing SQL
    ?assertEqual(ok, erlang_migrate:force(Cfg, 1)),
    ?assertEqual({ok, 1, false}, erlang_migrate:version(Cfg)),
    ?assertNot(table_present(G, "em_it_t2")),
    %% fix the file and continue
    file:write_file(filename:join(G#g.dir, "2_step2.up.sql"),
        <<"CREATE TABLE em_it_t2 (id bigint PRIMARY KEY);">>),
    ?assertEqual(ok, erlang_migrate:up(Cfg)),
    ?assertEqual({ok, 3, false}, erlang_migrate:version(Cfg)).

force_validation(G) ->
    Cfg = cfg(G, 2),
    ?assertMatch({error, {unknown_version, 99, _}}, erlang_migrate:force(Cfg, 99)),
    ?assertEqual(ok, erlang_migrate:force(Cfg, 2)),
    ?assertEqual({ok, 2, false}, erlang_migrate:version(Cfg)).

dry_run_touches_nothing(G) ->
    Cfg = cfg(G, 2),
    ?assertEqual(ok, erlang_migrate:up(Cfg#{dry_run => true})),
    ?assertEqual({ok, undefined, false}, erlang_migrate:version(Cfg)),
    ?assertNot(table_present(G, "em_it_t1")).

%% True cross-session advisory lock: a SECOND epgsql connection holds
%% pg_advisory_lock — the migration run must time out, not proceed.
lock_contention_cross_connection(G) ->
    Cfg = cfg(G, 1),
    LockId = erlang:phash2(?TABLE, 1 bsl 30),
    {ok, Conn2} = epgsql:connect(conn_opts(G#g.dbname)),
    try
        {ok, _, _} = epgsql:squery(Conn2,
            lists:flatten(io_lib:format("SELECT pg_advisory_lock(~b)", [LockId]))),
        ?assertEqual({error, lock_timeout},
                     erlang_migrate:up(Cfg#{lock_timeout => 500})),
        %% nothing ran
        ?assertEqual({ok, undefined, false}, erlang_migrate:version(Cfg)),
        {ok, _, _} = epgsql:squery(Conn2,
            lists:flatten(io_lib:format("SELECT pg_advisory_unlock(~b)", [LockId]))),
        %% lock released -> migration proceeds
        ?assertEqual(ok, erlang_migrate:up(Cfg)),
        ?assertEqual({ok, 1, false}, erlang_migrate:version(Cfg))
    after
        epgsql:close(Conn2)
    end.

%% Two connections migrate concurrently: the advisory lock serialises them;
%% the loser fails fast with lock_timeout while the winner holds the lock
%% through a slow (pg_sleep) migration. Exactly-once by construction.
concurrent_migration_cross_connection(G) ->
    Cfg = cfg(G, 2, fun(Dir) ->
        %% make the winner's run slow enough to overlap the loser's attempt
        file:write_file(filename:join(Dir, "1_step1.up.sql"),
            <<"SELECT pg_sleep(2); CREATE TABLE em_it_t1 (id bigint PRIMARY KEY); INSERT INTO em_it_t1 VALUES (1);">>)
    end),
    {ok, Conn2} = epgsql:connect(conn_opts(G#g.dbname)),
    try
        Parent = self(),
        Winner = fun() ->
            Parent ! {a, erlang_migrate:up(Cfg#{lock_timeout => 10000})}
        end,
        Loser = fun() ->
            timer:sleep(300),   %% let the winner take the lock first
            Parent ! {b, erlang_migrate:up(#{conn => Conn2, dir => G#g.dir,
                                           driver => erlang_migrate_pg,
                                           table => ?TABLE, lock_timeout => 800})}
        end,
        spawn(Winner),
        spawn(Loser),
        RA = receive {a, R1} -> R1 after 30000 -> timeout_a end,
        RB = receive {b, R2} -> R2 after 30000 -> timeout_b end,
        ?assertEqual(ok, RA),
        ?assertEqual({error, lock_timeout}, RB),
        ?assertEqual({ok, 2, false}, erlang_migrate:version(Cfg)),
        [{<<"1">>}] = q(G, "SELECT id FROM em_it_t1")   %% applied exactly once
    after
        epgsql:close(Conn2)
    end.

strict_mode(G) ->
    Cfg = cfg(G, 3),
    SCfg = Cfg#{strict => true},
    ?assertEqual(ok, erlang_migrate:up(SCfg)),
    [{<<"1">>}, {<<"2">>}, {<<"3">>}] =
        q(G, ["SELECT version FROM ", ?HIST, " ORDER BY version"]),
    ?assertEqual(ok, erlang_migrate:down(SCfg, 1)),
    [{<<"1">>}, {<<"2">>}] = q(G, ["SELECT version FROM ", ?HIST, " ORDER BY version"]),
    %% re-apply v3 without strict bookkeeping: tracking says 3 but the
    %% history never saw it — strict up must refuse with out_of_order
    ok = erlang_migrate:up(Cfg, 1),
    ?assertEqual({error, {out_of_order, [3]}}, erlang_migrate:up(SCfg)).

strict_backfill_and_bootstrap_fail(G) ->
    Cfg = cfg(G, 3),
    %% legacy install at v3 without history
    ok = erlang_migrate:force(Cfg, 3),
    %% default bootstrap backfills 1..3
    ok = erlang_migrate:up(Cfg#{strict => true}),
    [{<<"1">>}, {<<"2">>}, {<<"3">>}] =
        q(G, ["SELECT version FROM ", ?HIST, " ORDER BY version"]),
    %% fail mode refuses the guess on a fresh legacy install
    reset_db(G),
    Cfg2 = cfg(G, 3),
    ok = erlang_migrate:force(Cfg2, 3),
    ?assertEqual({error, {strict_bootstrap_needed, 3}},
                 erlang_migrate:up(Cfg2#{strict => true,
                                         strict_bootstrap => fail})),
    [] = q(G, ["SELECT version FROM ", ?HIST]),
    %% explicit force rebuilds history deliberately
    ok = erlang_migrate:force(Cfg2#{strict => true}, 3),
    [{<<"1">>}, {<<"2">>}, {<<"3">>}] =
        q(G, ["SELECT version FROM ", ?HIST, " ORDER BY version"]).
