%% Unit tests for erlang_migrate core logic.
%% Uses meck to mock erlang_migrate_pg and erlang_migrate_source — no real DB required.
%% Uses plain _test functions with try/after to guarantee mock cleanup even on failure.
-module(erlang_migrate_tests).
-include_lib("eunit/include/eunit.hrl").

%%% ── Fixtures ────────────────────────────────────────────────────────────────

config() -> #{conn => test_conn, dir => "/fake/dir"}.

migrations_3() ->
    [
        #{version => 1, title => <<"init">>,
          up_file => "/fake/1_init.up.sql",  down_file => "/fake/1_init.down.sql"},
        #{version => 2, title => <<"users">>,
          up_file => "/fake/2_users.up.sql", down_file => "/fake/2_users.down.sql"},
        #{version => 3, title => <<"index">>,
          up_file => "/fake/3_index.up.sql", down_file => "/fake/3_index.down.sql"}
    ].

setup_pg(CurrentVersion, IsDirty) ->
    meck:new(erlang_migrate_pg, [no_link]),
    meck:expect(erlang_migrate_pg, ensure_table,    fun(_, _)       -> ok end),
    meck:expect(erlang_migrate_pg, lock,            fun(_, _, _)    -> ok end),
    meck:expect(erlang_migrate_pg, unlock,          fun(_, _)       -> ok end),
    meck:expect(erlang_migrate_pg, is_dirty,        fun(_, _)       -> {ok, IsDirty} end),
    meck:expect(erlang_migrate_pg, current_version, fun(_, _)       -> {ok, CurrentVersion, IsDirty} end),
    meck:expect(erlang_migrate_pg, set_version,     fun(_, _, _, _) -> ok end),
    meck:expect(erlang_migrate_pg, exec_sql,        fun(_, _)       -> ok end),
    meck:expect(erlang_migrate_pg, drop_table,      fun(_, _)       -> ok end).

setup_source(Migrations) ->
    meck:new(erlang_migrate_source, [no_link]),
    meck:expect(erlang_migrate_source, scan,     fun(_)    -> {ok, Migrations} end),
    meck:expect(erlang_migrate_source, read_sql, fun(_, _) -> {ok, <<"SELECT 1">>} end).

teardown() ->
    catch meck:unload(erlang_migrate_pg),
    catch meck:unload(erlang_migrate_source).

%%% ── up/1 ─────────────────────────────────────────────────────────────────

up_all_from_clean_test() ->
    setup_pg(undefined, false), setup_source(migrations_3()),
    try
        ok = erlang_migrate:up(config()),
        %% 3 migrations x (dirty=true + dirty=false) = 6 set_version calls
        ?assertEqual(6, meck:num_calls(erlang_migrate_pg, set_version, '_'))
    after teardown() end.

up_from_existing_version_test() ->
    setup_pg(1, false), setup_source(migrations_3()),
    try
        ok = erlang_migrate:up(config()),
        %% only versions 2 and 3 pending
        ?assertEqual(4, meck:num_calls(erlang_migrate_pg, set_version, '_'))
    after teardown() end.

up_no_pending_test() ->
    setup_pg(3, false), setup_source(migrations_3()),
    try
        ok = erlang_migrate:up(config()),
        ?assertEqual(0, meck:num_calls(erlang_migrate_pg, set_version, '_'))
    after teardown() end.

%%% ── up/2 ─────────────────────────────────────────────────────────────────

up_n_steps_test() ->
    setup_pg(undefined, false), setup_source(migrations_3()),
    try
        ok = erlang_migrate:up(config(), 2),
        ?assertEqual(4, meck:num_calls(erlang_migrate_pg, set_version, '_'))
    after teardown() end.

up_one_step_test() ->
    setup_pg(2, false), setup_source(migrations_3()),
    try
        ok = erlang_migrate:up(config(), 1),
        ?assertEqual(2, meck:num_calls(erlang_migrate_pg, set_version, '_'))
    after teardown() end.

%%% ── down/1 ───────────────────────────────────────────────────────────────

down_all_test() ->
    setup_pg(3, false), setup_source(migrations_3()),
    try
        ok = erlang_migrate:down(config()),
        %% 3 rollbacks x dirty=true; DELETE via exec_sql removes the row
        ?assertEqual(3, meck:num_calls(erlang_migrate_pg, set_version, '_')),
        %% 3 migration SQL + 3 DELETE SQL
        ?assertEqual(6, meck:num_calls(erlang_migrate_pg, exec_sql, '_'))
    after teardown() end.

down_from_undefined_is_noop_test() ->
    setup_pg(undefined, false), setup_source(migrations_3()),
    try
        ok = erlang_migrate:down(config()),
        ?assertEqual(0, meck:num_calls(erlang_migrate_pg, set_version, '_'))
    after teardown() end.

%%% ── down/2 ───────────────────────────────────────────────────────────────

down_n_steps_test() ->
    setup_pg(3, false), setup_source(migrations_3()),
    try
        ok = erlang_migrate:down(config(), 2),
        ?assertEqual(2, meck:num_calls(erlang_migrate_pg, set_version, '_'))
    after teardown() end.

down_one_step_test() ->
    setup_pg(2, false), setup_source(migrations_3()),
    try
        ok = erlang_migrate:down(config(), 1),
        ?assertEqual(1, meck:num_calls(erlang_migrate_pg, set_version, '_'))
    after teardown() end.

%%% ── goto/2 ───────────────────────────────────────────────────────────────

goto_up_test() ->
    setup_pg(1, false), setup_source(migrations_3()),
    try
        ok = erlang_migrate:goto(config(), 3),
        ?assertEqual(4, meck:num_calls(erlang_migrate_pg, set_version, '_'))
    after teardown() end.

goto_down_test() ->
    setup_pg(3, false), setup_source(migrations_3()),
    try
        ok = erlang_migrate:goto(config(), 1),
        %% roll back versions 3 and 2 (dirty=true each)
        ?assertEqual(2, meck:num_calls(erlang_migrate_pg, set_version, '_'))
    after teardown() end.

goto_same_version_is_noop_test() ->
    setup_pg(2, false), setup_source(migrations_3()),
    try
        ok = erlang_migrate:goto(config(), 2),
        ?assertEqual(0, meck:num_calls(erlang_migrate_pg, set_version, '_'))
    after teardown() end.

goto_from_nil_test() ->
    setup_pg(undefined, false), setup_source(migrations_3()),
    try
        ok = erlang_migrate:goto(config(), 2),
        ?assertEqual(4, meck:num_calls(erlang_migrate_pg, set_version, '_'))
    after teardown() end.

%%% ── version/1 ────────────────────────────────────────────────────────────

version_with_dirty_true_test() ->
    setup_pg(5, true),
    try ?assertEqual({ok, 5, true}, erlang_migrate:version(config()))
    after teardown() end.

version_empty_table_test() ->
    setup_pg(undefined, false),
    try ?assertEqual({ok, undefined, false}, erlang_migrate:version(config()))
    after teardown() end.

version_dirty_false_test() ->
    setup_pg(3, false),
    try ?assertEqual({ok, 3, false}, erlang_migrate:version(config()))
    after teardown() end.

%%% ── force/2 ──────────────────────────────────────────────────────────────

force_sets_version_clears_dirty_test() ->
    setup_pg(undefined, true),
    try
        ok = erlang_migrate:force(config(), 3),
        ?assertEqual(1, meck:num_calls(erlang_migrate_pg, set_version,
                                       [test_conn, '_', 3, false]))
    after teardown() end.

force_bypasses_dirty_check_test() ->
    setup_pg(2, true),
    try
        ok = erlang_migrate:force(config(), 2),
        ?assertEqual(1, meck:num_calls(erlang_migrate_pg, set_version, '_')),
        ?assertEqual(0, meck:num_calls(erlang_migrate_pg, lock, '_'))
    after teardown() end.

%%% ── drop/1 ───────────────────────────────────────────────────────────────

drop_calls_drop_table_test() ->
    setup_pg(undefined, false),
    try
        ok = erlang_migrate:drop(config()),
        ?assertEqual(1, meck:num_calls(erlang_migrate_pg, drop_table, '_'))
    after teardown() end.

%%% ── dirty state blocking ─────────────────────────────────────────────────

dirty_blocks_up_test() ->
    setup_pg(1, true), setup_source(migrations_3()),
    try
        ?assertMatch({error, {dirty_state, _}}, erlang_migrate:up(config())),
        ?assertEqual(0, meck:num_calls(erlang_migrate_pg, set_version, '_'))
    after teardown() end.

dirty_blocks_down_test() ->
    setup_pg(1, true), setup_source(migrations_3()),
    try
        ?assertMatch({error, {dirty_state, _}}, erlang_migrate:down(config(), 1)),
        ?assertEqual(0, meck:num_calls(erlang_migrate_pg, set_version, '_'))
    after teardown() end.

dirty_blocks_goto_test() ->
    setup_pg(1, true), setup_source(migrations_3()),
    try
        ?assertMatch({error, {dirty_state, _}}, erlang_migrate:goto(config(), 3)),
        ?assertEqual(0, meck:num_calls(erlang_migrate_pg, set_version, '_'))
    after teardown() end.

%%% ── lock timeout ─────────────────────────────────────────────────────────

lock_timeout_propagated_test() ->
    meck:new(erlang_migrate_pg, [no_link]),
    meck:expect(erlang_migrate_pg, ensure_table, fun(_, _)    -> ok end),
    meck:expect(erlang_migrate_pg, lock,         fun(_, _, _) -> {error, lock_timeout} end),
    setup_source(migrations_3()),
    try
        ?assertEqual({error, lock_timeout}, erlang_migrate:up(config())),
        ?assertEqual(0, meck:num_calls(erlang_migrate_pg, unlock, '_'))
    after teardown() end.

lock_custom_timeout_passed_to_pg_test() ->
    meck:new(erlang_migrate_pg, [no_link]),
    meck:expect(erlang_migrate_pg, ensure_table,    fun(_, _)       -> ok end),
    meck:expect(erlang_migrate_pg, lock,            fun(_, _, _)    -> ok end),
    meck:expect(erlang_migrate_pg, unlock,          fun(_, _)       -> ok end),
    meck:expect(erlang_migrate_pg, is_dirty,        fun(_, _)       -> {ok, false} end),
    meck:expect(erlang_migrate_pg, current_version, fun(_, _)       -> {ok, undefined, false} end),
    meck:expect(erlang_migrate_pg, set_version,     fun(_, _, _, _) -> ok end),
    setup_source([]),
    try
        ok = erlang_migrate:up(maps:put(lock_timeout, 5000, config())),
        ?assertEqual(1, meck:num_calls(erlang_migrate_pg, lock, [test_conn, '_', 5000]))
    after teardown() end.

%%% ── logger interface ─────────────────────────────────────────────────────

logger_called_during_up_test() ->
    setup_pg(undefined, false), setup_source(migrations_3()),
    try
        Self = self(),
        Logger = fun(Level, Msg) -> Self ! {log, Level, Msg} end,
        ok = erlang_migrate:up(maps:put(logger, Logger, config())),
        Logs = collect_logs([]),
        %% acquire(1) + acquired(1) + (applying+applied)x3 + released(1) = 9 min
        ?assert(length(Logs) >= 9),
        ?assert(lists:any(fun({L, _}) -> L =:= info end, Logs))
    after teardown() end.

logger_error_on_lock_timeout_test() ->
    meck:new(erlang_migrate_pg, [no_link]),
    meck:expect(erlang_migrate_pg, ensure_table, fun(_, _)    -> ok end),
    meck:expect(erlang_migrate_pg, lock,         fun(_, _, _) -> {error, lock_timeout} end),
    setup_source([]),
    try
        Self = self(),
        Logger = fun(Level, Msg) -> Self ! {log, Level, Msg} end,
        {error, lock_timeout} = erlang_migrate:up(maps:put(logger, Logger, config())),
        Logs = collect_logs([]),
        ?assert(lists:any(fun({L, _}) -> L =:= error end, Logs))
    after teardown() end.

collect_logs(Acc) ->
    receive
        {log, Level, Msg} -> collect_logs([{Level, Msg} | Acc])
    after 0 -> lists:reverse(Acc)
    end.
