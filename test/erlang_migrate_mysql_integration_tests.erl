%% Real-database integration tests for the MySQL driver (mysql-otp).
%% No mocks: every assertion runs against a real MySQL server.
%%
%% Gated on environment variables (skipped silently when unset):
%%   EM_MYSQL_HOST (default 127.0.0.1), EM_MYSQL_PORT (default 3306),
%%   EM_MYSQL_USER, EM_MYSQL_PASSWORD, EM_MYSQL_DB (scratch database)
%%
%% The suite shares ONE scratch database; per-test isolation drops the
%% test-owned tables. Note the documented MySQL caveat: DDL implicitly
%% commits, so a multi-statement file failing midway is NOT fully rolled
%% back — the dirty-state test asserts the tracking semantics, not DDL
%% atomicity.
%%
%% Example:
%%   EM_MYSQL_USER=root EM_MYSQL_PASSWORD=root EM_MYSQL_DB=em_it rebar3 as test eunit
-module(erlang_migrate_mysql_integration_tests).
-include_lib("eunit/include/eunit.hrl").

-define(TABLE, <<"em_it_schema_migrations">>).
-define(HIST, <<"em_it_schema_migrations_history">>).

-record(g, {conn, dir}).

mysql_env(K, D) ->
    case os:getenv(K) of false -> D; V -> V end.

mysql_available() -> os:getenv("EM_MYSQL_USER") =/= false.

%%% ── one-time suite fixture ─────────────────────────────────────────────────

global_setup() ->
    {ok, Conn} = mysql:start_link([{host, mysql_env("EM_MYSQL_HOST", "127.0.0.1")},
                                   {port, list_to_integer(mysql_env("EM_MYSQL_PORT", "3306"))},
                                   {user, mysql_env("EM_MYSQL_USER", "root")},
                                   {password, mysql_env("EM_MYSQL_PASSWORD", "")},
                                   {database, mysql_env("EM_MYSQL_DB", "em_it")},
                                   {log_warnings, false}]),
    Dir = "/tmp/em_it_mysql_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = file:make_dir(Dir),
    #g{conn = Conn, dir = Dir}.

global_cleanup(#g{conn = Conn, dir = Dir}) ->
    unlink(Conn),
    catch mysql:stop(Conn),
    {ok, Files} = file:list_dir(Dir),
    [file:delete(filename:join(Dir, F)) || F <- Files],
    file:del_dir(Dir).

q(G, SQL) ->
    {ok, _, Rows} = mysql:query(G#g.conn, iolist_to_binary(SQL)),
    Rows.

table_present(G, Name) ->
    Expected = unicode:characters_to_binary(Name),
    lists:any(fun([N]) -> N =:= Expected end,
              q(G, ["SHOW TABLES LIKE '", Name, "'"])).

reset_db(G) ->
    [catch mysql:query(G#g.conn, unicode:characters_to_binary(
        "DROP TABLE IF EXISTS " ++ T)) ||
        T <- ["em_it_schema_migrations_history", "em_it_schema_migrations",
              "em_it_t1", "em_it_t2", "em_it_t3", "em_it_a", "em_it_b",
              "em_it_partial"]].

%%% ── per-test fixture ───────────────────────────────────────────────────────

write_std_migrations(Dir, N) ->
    lists:foreach(fun(I) ->
        B = integer_to_list(I),
        file:write_file(filename:join(Dir, B ++ "_step" ++ B ++ ".up.sql"),
            unicode:characters_to_binary(
                "CREATE TABLE em_it_t" ++ B ++ " (id BIGINT PRIMARY KEY);\n"
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
    #{conn => G#g.conn, dir => G#g.dir, driver => erlang_migrate_mysql,
      table => ?TABLE}.

%%% ── suite ──────────────────────────────────────────────────────────────────

mysql_test_() ->
    case mysql_available() of
        false -> [];
        true  ->
            {setup, fun global_setup/0, fun global_cleanup/1,
             fun(G) ->
                 [{inorder,
                   {with, G, [fun lifecycle/1,
                              fun multi_statement_and_utf8/1,
                              fun no_down_migration_errors/1,
                              fun dirty_state_and_recovery/1,
                              fun lock_contention_cross_connection/1,
                              fun concurrent_migration_cross_connection/1,
                              fun strict_mode/1]}}]
             end}
    end.

lifecycle(G) ->
    Cfg = cfg(G, 3),
    ?assertEqual({ok, undefined, false}, erlang_migrate:version(Cfg)),
    ?assertEqual(ok, erlang_migrate:up(Cfg)),
    ?assertEqual({ok, 3, false}, erlang_migrate:version(Cfg)),
    [[1]] = q(G, "SELECT id FROM em_it_t1"),
    ?assertEqual(ok, erlang_migrate:up(Cfg)),
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
            <<"CREATE TABLE em_it_a (id INT); CREATE TABLE em_it_b (id INT);">>),
        file:write_file(filename:join(Dir, "1_多语句.down.sql"),
            <<"DROP TABLE em_it_b; DROP TABLE em_it_a;">>)
    end),
    %% mysql-otp enables CLIENT_MULTI_STATEMENTS by default
    ?assertEqual(ok, erlang_migrate:up(Cfg)),
    ?assert(table_present(G, "em_it_a")),
    ?assert(table_present(G, "em_it_b")),
    ?assertEqual(ok, erlang_migrate:down(Cfg)).

no_down_migration_errors(G) ->
    Cfg = cfg(G, 0, fun(Dir) ->
        file:write_file(filename:join(Dir, "1_nodown.up.sql"), <<"SELECT 1;">>)
    end),
    ?assertEqual(ok, erlang_migrate:up(Cfg)),
    ?assertEqual({error, {no_down_migration, 1}}, erlang_migrate:down(Cfg)).

%% Broken SQL fails the run, sets dirty, blocks further runs; force
%% recovers. NOTE: unlike PG, MySQL DDL commits implicitly, so tables
%% created before the failure inside the SAME file may remain — this test
%% uses a failing file that creates nothing first (single broken DDL).
dirty_state_and_recovery(G) ->
    Cfg = cfg(G, 3, fun(Dir) ->
        file:write_file(filename:join(Dir, "2_step2.up.sql"),
            <<"CREATE TABLE broken (; ">>)
    end),
    ?assertMatch({error, _}, erlang_migrate:up(Cfg)),
    ?assertEqual({ok, 2, true}, erlang_migrate:version(Cfg)),
    ?assertMatch({error, {dirty_state, _}}, erlang_migrate:up(Cfg)),
    ?assertMatch({error, {dirty_state, _}}, erlang_migrate:down(Cfg, 1)),
    ?assertMatch({error, {dirty_state, _}}, erlang_migrate:goto(Cfg, 3)),
    ?assertEqual(ok, erlang_migrate:force(Cfg, 1)),
    ?assertEqual({ok, 1, false}, erlang_migrate:version(Cfg)),
    ?assertNot(table_present(G, "em_it_t2")),
    file:write_file(filename:join(G#g.dir, "2_step2.up.sql"),
        <<"CREATE TABLE em_it_t2 (id BIGINT PRIMARY KEY);">>),
    ?assertEqual(ok, erlang_migrate:up(Cfg)),
    ?assertEqual({ok, 3, false}, erlang_migrate:version(Cfg)).

%% Cross-connection GET_LOCK: a second mysql connection holds the named
%% lock — the migration run must time out, not proceed.
lock_contention_cross_connection(G) ->
    Cfg = cfg(G, 1),
    LockId = erlang:phash2(?TABLE, 1 bsl 30),
    Name = <<"erlang_migrate_", (integer_to_binary(LockId))/binary>>,
    {ok, Conn2} = mysql:start_link([{host, mysql_env("EM_MYSQL_HOST", "127.0.0.1")},
                                    {port, list_to_integer(mysql_env("EM_MYSQL_PORT", "3306"))},
                                    {user, mysql_env("EM_MYSQL_USER", "root")},
                                    {password, mysql_env("EM_MYSQL_PASSWORD", "")},
                                    {database, mysql_env("EM_MYSQL_DB", "em_it")},
                                    {log_warnings, false}]),
    try
        {ok, _, [[1]]} = mysql:query(Conn2,
            ["SELECT GET_LOCK('", Name, "', 0)"]),
        ?assertEqual({error, lock_timeout},
                     erlang_migrate:up(Cfg#{lock_timeout => 500})),
        ?assertEqual({ok, undefined, false}, erlang_migrate:version(Cfg)),
        {ok, _, _} = mysql:query(Conn2,
            ["SELECT RELEASE_LOCK('", Name, "')"]),
        ?assertEqual(ok, erlang_migrate:up(Cfg)),
        ?assertEqual({ok, 1, false}, erlang_migrate:version(Cfg))
    after
        unlink(Conn2),
        catch mysql:stop(Conn2)
    end.

%% Two connections migrate concurrently: GET_LOCK serialises them; the
%% loser fails fast while the winner holds the lock through a slow
%% (SLEEP) migration. Exactly-once by construction.
concurrent_migration_cross_connection(G) ->
    Cfg = cfg(G, 2, fun(Dir) ->
        file:write_file(filename:join(Dir, "1_step1.up.sql"),
            <<"SELECT SLEEP(2); CREATE TABLE em_it_t1 (id BIGINT PRIMARY KEY); INSERT INTO em_it_t1 VALUES (1);">>)
    end),
    {ok, Conn2} = mysql:start_link([{host, mysql_env("EM_MYSQL_HOST", "127.0.0.1")},
                                    {port, list_to_integer(mysql_env("EM_MYSQL_PORT", "3306"))},
                                    {user, mysql_env("EM_MYSQL_USER", "root")},
                                    {password, mysql_env("EM_MYSQL_PASSWORD", "")},
                                    {database, mysql_env("EM_MYSQL_DB", "em_it")},
                                    {log_warnings, false}]),
    try
        Parent = self(),
        Winner = fun() ->
            Parent ! {a, erlang_migrate:up(Cfg#{lock_timeout => 10000})}
        end,
        Loser = fun() ->
            timer:sleep(300),
            Parent ! {b, erlang_migrate:up(#{conn => Conn2, dir => G#g.dir,
                                           driver => erlang_migrate_mysql,
                                           table => ?TABLE, lock_timeout => 800})}
        end,
        spawn(Winner),
        spawn(Loser),
        RA = receive {a, R1} -> R1 after 30000 -> timeout_a end,
        RB = receive {b, R2} -> R2 after 30000 -> timeout_b end,
        ?assertEqual(ok, RA),
        ?assertEqual({error, lock_timeout}, RB),
        ?assertEqual({ok, 2, false}, erlang_migrate:version(Cfg)),
        [[1]] = q(G, "SELECT id FROM em_it_t1")
    after
        unlink(Conn2),
        catch mysql:stop(Conn2)
    end.

strict_mode(G) ->
    Cfg = cfg(G, 3),
    SCfg = Cfg#{strict => true},
    ?assertEqual(ok, erlang_migrate:up(SCfg)),
    [[1], [2], [3]] = q(G, ["SELECT version FROM ", ?HIST, " ORDER BY version"]),
    ?assertEqual(ok, erlang_migrate:down(SCfg, 1)),
    [[1], [2]] = q(G, ["SELECT version FROM ", ?HIST, " ORDER BY version"]),
    %% re-apply v3 without strict bookkeeping: tracking says 3 but the
    %% history never saw it — strict up must refuse with out_of_order
    ok = erlang_migrate:up(Cfg, 1),
    ?assertEqual({error, {out_of_order, [3]}}, erlang_migrate:up(SCfg)).
