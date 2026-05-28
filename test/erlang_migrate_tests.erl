%% Unit tests for erlang_migrate core logic.
%% Uses meck to mock erlang_migrate_pg and erlang_migrate_source — no real DB required.
-module(erlang_migrate_tests).
-include_lib("eunit/include/eunit.hrl").

%%% ── Fixtures ────────────────────────────────────────────────────────────────

config() ->
    #{conn => test_conn, dir => "/fake/dir"}.

migrations_3() ->
    [
        #{version => 1, title => <<"init">>,
          up_file => "/fake/1_init.up.sql",  down_file => "/fake/1_init.down.sql"},
        #{version => 2, title => <<"users">>,
          up_file => "/fake/2_users.up.sql", down_file => "/fake/2_users.down.sql"},
        #{version => 3, title => <<"index">>,
          up_file => "/fake/3_index.up.sql", down_file => "/fake/3_index.down.sql"}
    ].

%% Mock pg layer. CurrentVersion = integer() | undefined. IsDirty = boolean().
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
    setup_pg(undefined, false),
    setup_source(migrations_3()),
    ok = erlang_migrate:up(config()),
    %% 3 migrations x (dirty=true + dirty=false) = 6 set_version calls
    6 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    teardown().

up_from_existing_version_test() ->
    setup_pg(1, false),
    setup_source(migrations_3()),
    ok = erlang_migrate:up(config()),
    %% only versions 2 and 3 applied
    4 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    teardown().

up_no_pending_test() ->
    setup_pg(3, false),
    setup_source(migrations_3()),
    ok = erlang_migrate:up(config()),
    0 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    teardown().

%%% ── up/2 ─────────────────────────────────────────────────────────────────

up_n_steps_test() ->
    setup_pg(undefined, false),
    setup_source(migrations_3()),
    ok = erlang_migrate:up(config(), 2),
    %% only versions 1 and 2 applied
    4 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    teardown().

up_one_step_test() ->
    setup_pg(2, false),
    setup_source(migrations_3()),
    ok = erlang_migrate:up(config(), 1),
    2 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    teardown().

%%% ── down/1 ───────────────────────────────────────────────────────────────

down_all_test() ->
    setup_pg(3, false),
    setup_source(migrations_3()),
    ok = erlang_migrate:down(config()),
    %% 3 rollbacks x dirty=true; DELETE uses exec_sql (not set_version)
    3 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    %% 3 migration SQL + 3 DELETE SQL
    6 = meck:num_calls(erlang_migrate_pg, exec_sql, '_'),
    teardown().

down_from_undefined_is_noop_test() ->
    setup_pg(undefined, false),
    setup_source(migrations_3()),
    ok = erlang_migrate:down(config()),
    0 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    teardown().

%%% ── down/2 ───────────────────────────────────────────────────────────────

down_n_steps_test() ->
    setup_pg(3, false),
    setup_source(migrations_3()),
    ok = erlang_migrate:down(config(), 2),
    %% only versions 3 and 2 rolled back
    2 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    teardown().

down_one_step_test() ->
    setup_pg(2, false),
    setup_source(migrations_3()),
    ok = erlang_migrate:down(config(), 1),
    1 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    teardown().

%%% ── goto/2 ───────────────────────────────────────────────────────────────

goto_up_test() ->
    setup_pg(1, false),
    setup_source(migrations_3()),
    ok = erlang_migrate:goto(config(), 3),
    %% apply versions 2 and 3
    4 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    teardown().

goto_down_test() ->
    setup_pg(3, false),
    setup_source(migrations_3()),
    ok = erlang_migrate:goto(config(), 1),
    %% roll back versions 3 and 2 (dirty=true each)
    2 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    teardown().

goto_same_version_is_noop_test() ->
    setup_pg(2, false),
    setup_source(migrations_3()),
    ok = erlang_migrate:goto(config(), 2),
    0 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    teardown().

goto_from_nil_test() ->
    setup_pg(undefined, false),
    setup_source(migrations_3()),
    ok = erlang_migrate:goto(config(), 2),
    %% apply versions 1 and 2
    4 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    teardown().

%%% ── version/1 ────────────────────────────────────────────────────────────

version_returns_version_and_dirty_test() ->
    setup_pg(5, true),
    {ok, 5, true} = erlang_migrate:version(config()),
    teardown().

version_returns_undefined_when_empty_test() ->
    setup_pg(undefined, false),
    {ok, undefined, false} = erlang_migrate:version(config()),
    teardown().

version_dirty_false_test() ->
    setup_pg(3, false),
    {ok, 3, false} = erlang_migrate:version(config()),
    teardown().

%%% ── force/2 ──────────────────────────────────────────────────────────────

force_sets_version_and_clears_dirty_test() ->
    setup_pg(undefined, true),
    ok = erlang_migrate:force(config(), 3),
    %% set_version called with Version=3, Dirty=false
    1 = meck:num_calls(erlang_migrate_pg, set_version, [test_conn, '_', 3, false]),
    teardown().

force_works_when_dirty_test() ->
    %% force bypasses the dirty check entirely (no with_lock)
    setup_pg(2, true),
    ok = erlang_migrate:force(config(), 2),
    1 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    0 = meck:num_calls(erlang_migrate_pg, lock, '_'),
    teardown().

%%% ── drop/1 ───────────────────────────────────────────────────────────────

drop_calls_drop_table_test() ->
    setup_pg(undefined, false),
    ok = erlang_migrate:drop(config()),
    1 = meck:num_calls(erlang_migrate_pg, drop_table, '_'),
    teardown().

%%% ── dirty state blocking ─────────────────────────────────────────────────

dirty_blocks_up_test() ->
    setup_pg(1, true),
    setup_source(migrations_3()),
    {error, {dirty_state, _}} = erlang_migrate:up(config()),
    0 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    teardown().

dirty_blocks_down_test() ->
    setup_pg(1, true),
    setup_source(migrations_3()),
    {error, {dirty_state, _}} = erlang_migrate:down(config(), 1),
    0 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    teardown().

dirty_blocks_goto_test() ->
    setup_pg(1, true),
    setup_source(migrations_3()),
    {error, {dirty_state, _}} = erlang_migrate:goto(config(), 3),
    0 = meck:num_calls(erlang_migrate_pg, set_version, '_'),
    teardown().

%%% ── lock timeout ─────────────────────────────────────────────────────────

lock_timeout_propagated_test() ->
    meck:new(erlang_migrate_pg, [no_link]),
    meck:expect(erlang_migrate_pg, ensure_table, fun(_, _)    -> ok end),
    meck:expect(erlang_migrate_pg, lock,         fun(_, _, _) -> {error, lock_timeout} end),
    setup_source(migrations_3()),
    {error, lock_timeout} = erlang_migrate:up(config()),
    %% unlock must NOT be called when lock was never acquired
    0 = meck:num_calls(erlang_migrate_pg, unlock, '_'),
    teardown().

lock_custom_timeout_passed_to_pg_test() ->
    meck:new(erlang_migrate_pg, [no_link]),
    meck:expect(erlang_migrate_pg, ensure_table,    fun(_, _)       -> ok end),
    meck:expect(erlang_migrate_pg, lock,            fun(_, _, _)    -> ok end),
    meck:expect(erlang_migrate_pg, unlock,          fun(_, _)       -> ok end),
    meck:expect(erlang_migrate_pg, is_dirty,        fun(_, _)       -> {ok, false} end),
    meck:expect(erlang_migrate_pg, current_version, fun(_, _)       -> {ok, undefined, false} end),
    meck:expect(erlang_migrate_pg, set_version,     fun(_, _, _, _) -> ok end),
    setup_source([]),
    Cfg = maps:put(lock_timeout, 5000, config()),
    ok = erlang_migrate:up(Cfg),
    %% verify the custom timeout value was forwarded to the pg layer
    1 = meck:num_calls(erlang_migrate_pg, lock, [test_conn, '_', 5000]),
    teardown().

%%% ── logger interface ─────────────────────────────────────────────────────

logger_called_during_up_test() ->
    setup_pg(undefined, false),
    setup_source(migrations_3()),
    Self = self(),
    Logger = fun(Level, Msg) -> Self ! {log, Level, Msg} end,
    Cfg = maps:put(logger, Logger, config()),
    ok = erlang_migrate:up(Cfg),
    Logs = collect_logs([]),
    %% acquire(1) + acquired(1) + applying×3 + applied×3 + released(1) = 9 minimum
    true = length(Logs) >= 9,
    true = lists:any(fun({L, _}) -> L =:= info end, Logs),
    teardown().

logger_called_on_lock_timeout_test() ->
    meck:new(erlang_migrate_pg, [no_link]),
    meck:expect(erlang_migrate_pg, ensure_table, fun(_, _)    -> ok end),
    meck:expect(erlang_migrate_pg, lock,         fun(_, _, _) -> {error, lock_timeout} end),
    setup_source([]),
    Self = self(),
    Logger = fun(Level, Msg) -> Self ! {log, Level, Msg} end,
    Cfg = maps:put(logger, Logger, config()),
    {error, lock_timeout} = erlang_migrate:up(Cfg),
    Logs = collect_logs([]),
    true = lists:any(fun({L, _}) -> L =:= error end, Logs),
    teardown().

collect_logs(Acc) ->
    receive
        {log, Level, Msg} -> collect_logs([{Level, Msg} | Acc])
    after 0 -> lists:reverse(Acc)
    end.
