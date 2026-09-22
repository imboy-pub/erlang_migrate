%% Real-database integration tests for the SQLite driver (esqlite).
%% No mocks: every assertion below runs against a real SQLite file.
-module(erlang_migrate_sqlite_integration_it).
-include_lib("eunit/include/eunit.hrl").

-define(TABLE, <<"em_it_schema_migrations">>).
-define(HIST, <<"em_it_schema_migrations_history">>).

%%% ── fixture ────────────────────────────────────────────────────────────────

-record(fx, {conn, dir, db}).

%% n migrations; migration i creates table em_it_t<i> (up) / drops it (down).
migrations(N) ->
    fun(Dir) ->
        lists:foreach(fun(I) ->
            B = integer_to_list(I),
            file:write_file(filename:join(Dir, B ++ "_step" ++ B ++ ".up.sql"),
                unicode:characters_to_binary(
                    "CREATE TABLE em_it_t" ++ B ++ " (id integer PRIMARY KEY);\n"
                    "INSERT INTO em_it_t" ++ B ++ " VALUES (1);")),
            file:write_file(filename:join(Dir, B ++ "_step" ++ B ++ ".down.sql"),
                unicode:characters_to_binary("DROP TABLE em_it_t" ++ B ++ ";"))
        end, lists:seq(1, N))
    end.

setup_fx(N) -> setup_fx(N, fun(_) -> ok end).

setup_fx(N, ExtraFiles) ->
    Dir = "/tmp/em_it_sqlite_" ++ integer_to_list(erlang:unique_integer([positive]))
          ++ "_" ++ integer_to_list(erlang:system_time(millisecond)),
    ok = file:make_dir(Dir),
    (migrations(N))(Dir),
    ok = ExtraFiles(Dir),
    Db = filename:join(Dir, "it.db"),
    {ok, Conn} = esqlite3:open(Db),
    Cfg = #{conn => Conn, dir => Dir, driver => erlang_migrate_sqlite,
            table => ?TABLE},
    {Cfg, #fx{conn = Conn, dir = Dir, db = Db}}.

cleanup_fx(#fx{conn = Conn, dir = Dir}) ->
    catch esqlite3:close(Conn),
    {ok, Files} = file:list_dir(Dir),
    [file:delete(filename:join(Dir, F)) || F <- Files],
    file:del_dir(Dir).

q(Fx, SQL) -> esqlite3:q(Fx#fx.conn, iolist_to_binary(SQL)).

sqlite_integration_test_() ->
    case os:getenv("EM_SQLITE_IT") of
        "1" ->
            [lifecycle_case(),
             multi_statement_file_case(),
             no_down_migration_errors_case(),
             dirty_state_lifecycle_case(),
             force_rejects_unknown_version_case(),
             dry_run_touches_nothing_case(),
             lock_contention_case(),
             concurrent_migration_case(),
             strict_records_and_detects_out_of_order_case(),
             strict_backfill_blind_marks_never_applied_case(),
             strict_bootstrap_fail_refuses_case(),
             connection_failure_mid_run_case()];
        _ -> []
    end.

%% NB: esqlite 0.8.1's esqlite3:q/2 returns rows in REVERSE order (its
%% fetchall1 accumulates with [Row|Acc] and never reverses). Sort before
%% comparing whenever order matters.
rows(Fx, SQL) -> lists:sort(q(Fx, SQL)).

table_exists(Fx, Name) when is_list(Name) ->
    table_exists(Fx, unicode:characters_to_binary(Name));
table_exists(Fx, Name) ->
    case q(Fx, ["SELECT name FROM sqlite_master WHERE type='table' AND name='",
                Name, "'"]) of
        [[Name]] -> true;
        _        -> false
    end.

%%% ── lifecycle ──────────────────────────────────────────────────────────────

lifecycle_case() ->
    {timeout, 30, fun() ->
        {Cfg, Fx} = setup_fx(3),
        try
            %% clean database
            ?assertEqual({ok, undefined, false}, erlang_migrate:version(Cfg)),
            %% up all
            ?assertEqual(ok, erlang_migrate:up(Cfg)),
            ?assertEqual({ok, 3, false}, erlang_migrate:version(Cfg)),
            ?assert(table_exists(Fx, "em_it_t3")),
            %% up is idempotent
            ?assertEqual(ok, erlang_migrate:up(Cfg)),
            %% down 1
            ?assertEqual(ok, erlang_migrate:down(Cfg, 1)),
            ?assertEqual({ok, 2, false}, erlang_migrate:version(Cfg)),
            ?assertNot(table_exists(Fx, "em_it_t3")),
            %% goto up
            ?assertEqual(ok, erlang_migrate:goto(Cfg, 3)),
            ?assertEqual({ok, 3, false}, erlang_migrate:version(Cfg)),
            %% goto down
            ?assertEqual(ok, erlang_migrate:goto(Cfg, 1)),
            ?assertEqual({ok, 1, false}, erlang_migrate:version(Cfg)),
            %% down all clears tracking
            ?assertEqual(ok, erlang_migrate:down(Cfg)),
            ?assertEqual({ok, undefined, false}, erlang_migrate:version(Cfg)),
            %% up N
            ?assertEqual(ok, erlang_migrate:up(Cfg, 2)),
            ?assertEqual({ok, 2, false}, erlang_migrate:version(Cfg))
        after cleanup_fx(Fx) end
    end}.

multi_statement_file_case() ->
    {timeout, 30, fun() ->
        {Cfg, Fx} = setup_fx(0, fun(Dir) ->
            file:write_file(filename:join(Dir, "1_multi.up.sql"),
                <<"CREATE TABLE em_it_a (id integer); CREATE TABLE em_it_b (id integer);">>),
            file:write_file(filename:join(Dir, "1_multi.down.sql"),
                <<"DROP TABLE em_it_b; DROP TABLE em_it_a;">>)
        end),
        try
            ?assertEqual(ok, erlang_migrate:up(Cfg)),
            ?assert(table_exists(Fx, "em_it_a")),
            ?assert(table_exists(Fx, "em_it_b"))
        after cleanup_fx(Fx) end
    end}.

no_down_migration_errors_case() ->
    {timeout, 30, fun() ->
        {Cfg, Fx} = setup_fx(0, fun(Dir) ->
            file:write_file(filename:join(Dir, "1_nodown.up.sql"), <<"SELECT 1;">>)
        end),
        try
            ?assertEqual(ok, erlang_migrate:up(Cfg)),
            ?assertEqual({error, {no_down_migration, 1}}, erlang_migrate:down(Cfg))
        after cleanup_fx(Fx) end
    end}.

%%% ── dirty state ────────────────────────────────────────────────────────────

dirty_state_lifecycle_case() ->
    {timeout, 30, fun() ->
        %% migration 2 has broken SQL
        {Cfg, Fx} = setup_fx(3, fun(Dir) ->
            file:write_file(filename:join(Dir, "2_step2.up.sql"),
                <<"CREATE TABLE definitely_bogus (;">>)
        end),
        try
            %% v1 applies, v2 fails mid-way
            ?assertMatch({error, _}, erlang_migrate:up(Cfg)),
            ?assertEqual({ok, 2, true}, erlang_migrate:version(Cfg)),
            %% dirty blocks everything
            ?assertMatch({error, {dirty_state, _}}, erlang_migrate:up(Cfg)),
            ?assertMatch({error, {dirty_state, _}}, erlang_migrate:down(Cfg, 1)),
            ?assertMatch({error, {dirty_state, _}}, erlang_migrate:goto(Cfg, 3)),
            %% force recovers (metadata only — no SQL executed)
            ?assertEqual(ok, erlang_migrate:force(Cfg, 1)),
            ?assertEqual({ok, 1, false}, erlang_migrate:version(Cfg)),
            %% fix the file, up again — v2 is re-applied (was never recorded clean)
            file:write_file(filename:join(Fx#fx.dir, "2_step2.up.sql"),
                <<"CREATE TABLE em_it_t2 (id integer);">>),
            ?assertEqual(ok, erlang_migrate:up(Cfg)),
            ?assertEqual({ok, 3, false}, erlang_migrate:version(Cfg))
        after cleanup_fx(Fx) end
    end}.

%%% ── force ──────────────────────────────────────────────────────────────────

force_rejects_unknown_version_case() ->
    {timeout, 30, fun() ->
        {Cfg, Fx} = setup_fx(2),
        try
            ?assertMatch({error, {unknown_version, 99, _}}, erlang_migrate:force(Cfg, 99))
        after cleanup_fx(Fx) end
    end}.

%%% ── dry_run ────────────────────────────────────────────────────────────────

dry_run_touches_nothing_case() ->
    {timeout, 30, fun() ->
        {Cfg, Fx} = setup_fx(2, fun(_) -> ok end),
        try
            ?assertEqual(ok, erlang_migrate:up(Cfg#{dry_run => true})),
            %% tracking table was created (ensure_table) but no version row,
            %% and no migration table exists
            ?assertEqual({ok, undefined, false}, erlang_migrate:version(Cfg)),
            ?assertNot(table_exists(Fx, "em_it_t1"))
        after cleanup_fx(Fx) end
    end}.

%%% ── locking ────────────────────────────────────────────────────────────────

lock_contention_case() ->
    {timeout, 30, fun() ->
        {Cfg, Fx} = setup_fx(1),
        try
            %% Hold the driver's global lock from another process.
            LockId = erlang:phash2(?TABLE, 1 bsl 30),
            Self = self(),
            Holder = spawn(fun() ->
                true = global:set_lock({{erlang_migrate_lock, LockId}, self()}, [node()], 0),
                Self ! held,
                receive release -> global:del_lock({{erlang_migrate_lock, LockId}, self()}, [node()]) end
            end),
            receive held -> ok after 5000 -> throw(holder_timeout) end,
            ?assertEqual({error, lock_timeout},
                         erlang_migrate:up(Cfg#{lock_timeout => 200})),
            Holder ! release,
            %% lock released -> migration proceeds
            ?assertEqual(ok, erlang_migrate:up(Cfg)),
            ?assertEqual({ok, 1, false}, erlang_migrate:version(Cfg))
        after cleanup_fx(Fx) end
    end}.

%% Two processes migrate the same DB concurrently: the VM-wide global lock
%% must serialise them — exactly one run applies, the other waits or fails
%% with lock_timeout, and the final state is clean.
concurrent_migration_case() ->
    {timeout, 60, fun() ->
        {Cfg, Fx} = setup_fx(3),
        try
            %% Pre-create the tracking table so the loser's ensure_table is
            %% a no-op while the winner holds a write transaction.
            {ok, undefined, false} = erlang_migrate:version(Cfg),
            %% Each runner gets its own connection — like two app instances
            %% on one node competing for the same database file.
            Parent = self(),
            Runner = fun(Tag) ->
                fun() ->
                    Parent ! {Tag, (try
                        {ok, Conn} = esqlite3:open(Fx#fx.db),
                        erlang_migrate:up(Cfg#{conn => Conn, lock_timeout => 5000})
                    catch C:E:St ->
                        {crashed, C, E, St}
                    end)}
                end
            end,
            spawn(Runner(a)),
            spawn(Runner(b)),
            RA = receive {a, R1} -> R1 after 30000 -> timeout end,
            RB = receive {b, R2} -> R2 after 30000 -> timeout end,
            %% Each CREATE TABLE ran exactly once (a second execution would
            %% error "table already exists" and surface as {error,_} here).
            ?assertEqual(ok, RA),
            ?assertEqual(ok, RB),
            ?assertEqual({ok, 3, false}, erlang_migrate:version(Cfg)),
            Rows = q(Fx, ["SELECT count(*) FROM ", ?TABLE]),
            ?assertEqual([[1]], Rows),
            lists:foreach(fun(I) ->
                ?assert(table_exists(Fx, "em_it_t" ++ integer_to_list(I)))
            end, lists:seq(1, 3))
        after cleanup_fx(Fx) end
    end}.

%%% ── strict mode ────────────────────────────────────────────────────────────

strict_records_and_detects_out_of_order_case() ->
    {timeout, 30, fun() ->
        {Cfg, Fx} = setup_fx(3),
        try
            SCfg = Cfg#{strict => true},
            ?assertEqual(ok, erlang_migrate:up(SCfg)),
            ?assertEqual([[1], [2], [3]], rows(Fx, ["SELECT version FROM ", ?HIST])),
            %% down removes history rows too
            ?assertEqual(ok, erlang_migrate:down(SCfg, 1)),
            ?assertEqual([[1], [2]], rows(Fx, ["SELECT version FROM ", ?HIST])),
            %% simulate a late-merged version that tracking says is applied
            %% (re-apply v3 without strict bookkeeping) but history never saw:
            ok = erlang_migrate:up(Cfg#{strict => false}, 1),
            esqlite3:exec(Fx#fx.conn, <<"DELETE FROM ", ?HIST/binary, " WHERE version = 3">>),
            ?assertEqual({error, {out_of_order, [3]}}, erlang_migrate:up(SCfg))
        after cleanup_fx(Fx) end
    end}.

%% THE audit scenario: legacy install at version 5 where 3 and 4 were merged
%% late and NEVER executed. Default backfill marks them applied forever;
%% strict_bootstrap => fail refuses the guess.
strict_backfill_blind_marks_never_applied_case() ->
    {timeout, 30, fun() ->
        {Cfg, Fx} = setup_fx(0, fun(Dir) ->
            lists:foreach(fun(I) ->
                B = integer_to_list(I),
                file:write_file(filename:join(Dir, B ++ "_step" ++ B ++ ".up.sql"),
                    unicode:characters_to_binary("CREATE TABLE em_it_t" ++ B ++ " (id integer);")),
                file:write_file(filename:join(Dir, B ++ "_step" ++ B ++ ".down.sql"),
                    unicode:characters_to_binary("DROP TABLE em_it_t" ++ B ++ ";"))
            end, lists:seq(1, 5))
        end),
        try
            %% legacy reality: only 1, 2 and 5 exist in the database
            esqlite3:exec(Fx#fx.conn,
                <<"CREATE TABLE em_it_t1 (id integer); CREATE TABLE em_it_t2 (id integer); CREATE TABLE em_it_t5 (id integer);">>),
            ok = erlang_migrate:force(Cfg, 5),
            %% default bootstrap: backfill assumes 1..5 all applied
            ok = erlang_migrate:up(Cfg#{strict => true}),
            ?assertEqual([[1], [2], [3], [4], [5]],
                         rows(Fx, ["SELECT version FROM ", ?HIST])),
            %% ...but 3 and 4 were NEVER executed — the blind mark is real:
            ?assertNot(table_exists(Fx, "em_it_t3")),
            ?assertNot(table_exists(Fx, "em_it_t4")),
            %% and they can never be applied through up/1 again
            ?assertEqual(ok, erlang_migrate:up(Cfg#{strict => true})),
            ?assertNot(table_exists(Fx, "em_it_t3"))
        after cleanup_fx(Fx) end
    end}.

strict_bootstrap_fail_refuses_case() ->
    {timeout, 30, fun() ->
        {Cfg, Fx} = setup_fx(3),
        try
            ok = erlang_migrate:force(Cfg, 3),   %% legacy install, no history
            ?assertEqual({error, {strict_bootstrap_needed, 3}},
                         erlang_migrate:up(Cfg#{strict => true, strict_bootstrap => fail})),
            %% nothing recorded, nothing executed
            ?assertEqual([], q(Fx, ["SELECT version FROM ", ?HIST])),
            %% explicit force rebuilds history deliberately
            ok = erlang_migrate:force(Cfg#{strict => true}, 3),
            ?assertEqual([[1], [2], [3]], rows(Fx, ["SELECT version FROM ", ?HIST]))
        after cleanup_fx(Fx) end
    end}.

%%% ── connection failure ─────────────────────────────────────────────────────

connection_failure_mid_run_case() ->
    {timeout, 30, fun() ->
        {Cfg, Fx} = setup_fx(2),
        try
            %% Close the connection from under the run: the failure must
            %% propagate (an {error,_} return or an exit) — never a false ok.
            esqlite3:close(Fx#fx.conn),
            Result = (catch erlang_migrate:up(Cfg)),
            ?assertNotEqual(ok, Result)
        after cleanup_fx(Fx) end
    end}.
