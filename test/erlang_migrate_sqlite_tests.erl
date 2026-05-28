%% Unit tests for erlang_migrate_sqlite driver.
%% Mocks esqlite3 — no real database file required.
-module(erlang_migrate_sqlite_tests).
-include_lib("eunit/include/eunit.hrl").

-define(TABLE, <<"schema_migrations">>).
-define(CONN,  test_conn).

%%% ── Helpers ─────────────────────────────────────────────────────────────────

setup_sqlite(CurrentVersion, IsDirty) ->
    meck:new(esqlite3, [no_link, non_strict]),
    DirtyInt = case IsDirty of true -> 1; false -> 0 end,
    Rows = case CurrentVersion of
        undefined -> [];
        V         -> [{V, DirtyInt}]
    end,
    meck:expect(esqlite3, exec, fun(_, _) -> ok end),
    meck:expect(esqlite3, q,    fun(_, _) -> Rows end).

teardown() ->
    catch meck:unload(esqlite3).

%%% ── ensure_table ────────────────────────────────────────────────────────────

ensure_table_ok_test() ->
    setup_sqlite(undefined, false),
    try
        ok = erlang_migrate_sqlite:ensure_table(?CONN, ?TABLE),
        ?assertEqual(1, meck:num_calls(esqlite3, exec, '_'))
    after teardown() end.

%%% ── current_version ─────────────────────────────────────────────────────────

current_version_empty_test() ->
    setup_sqlite(undefined, false),
    try
        ?assertEqual({ok, undefined, false},
                     erlang_migrate_sqlite:current_version(?CONN, ?TABLE))
    after teardown() end.

current_version_with_row_test() ->
    setup_sqlite(7, false),
    try
        ?assertEqual({ok, 7, false},
                     erlang_migrate_sqlite:current_version(?CONN, ?TABLE))
    after teardown() end.

current_version_dirty_test() ->
    setup_sqlite(4, true),
    try
        {ok, 4, true} = erlang_migrate_sqlite:current_version(?CONN, ?TABLE)
    after teardown() end.

%%% ── lock / unlock ───────────────────────────────────────────────────────────

lock_success_test() ->
    setup_sqlite(undefined, false),
    try
        ok = erlang_migrate_sqlite:lock(?CONN, 99999, 5000),
        ok = erlang_migrate_sqlite:unlock(?CONN, 99999)
    after teardown() end.

lock_timeout_test() ->
    setup_sqlite(undefined, false),
    Self = self(),
    %% Hold the lock from a different process — different self() = different LockRequesterId.
    Holder = spawn(fun() ->
        true = global:set_lock({{erlang_migrate_lock, 77778}, self()}, [node()], 0),
        Self ! lock_held,
        receive release ->
            global:del_lock({{erlang_migrate_lock, 77778}, self()}, [node()])
        end
    end),
    receive lock_held -> ok end,
    try
        ?assertEqual({error, lock_timeout},
                     erlang_migrate_sqlite:lock(?CONN, 77778, 0))
    after
        Holder ! release,
        teardown()
    end.

unlock_ok_test() ->
    setup_sqlite(undefined, false),
    try
        ok = erlang_migrate_sqlite:lock(?CONN, 55555, 5000),
        ok = erlang_migrate_sqlite:unlock(?CONN, 55555)
    after teardown() end.

%%% ── set_version ─────────────────────────────────────────────────────────────

set_version_ok_test() ->
    setup_sqlite(undefined, false),
    try
        ok = erlang_migrate_sqlite:set_version(?CONN, ?TABLE, 1, false),
        ok = erlang_migrate_sqlite:set_version(?CONN, ?TABLE, 1, true),
        ?assertEqual(2, meck:num_calls(esqlite3, exec, '_'))
    after teardown() end.

%%% ── is_dirty ────────────────────────────────────────────────────────────────

is_dirty_false_test() ->
    setup_sqlite(3, false),
    try
        ?assertEqual({ok, false}, erlang_migrate_sqlite:is_dirty(?CONN, ?TABLE))
    after teardown() end.

is_dirty_true_test() ->
    setup_sqlite(3, true),
    try
        ?assertEqual({ok, true}, erlang_migrate_sqlite:is_dirty(?CONN, ?TABLE))
    after teardown() end.

%%% ── exec_sql ────────────────────────────────────────────────────────────────

exec_sql_ok_test() ->
    setup_sqlite(undefined, false),
    try
        ok = erlang_migrate_sqlite:exec_sql(?CONN, <<"CREATE INDEX idx ON foo (bar)">>)
    after teardown() end.

%%% ── drop_table ──────────────────────────────────────────────────────────────

drop_table_ok_test() ->
    setup_sqlite(undefined, false),
    try
        ok = erlang_migrate_sqlite:drop_table(?CONN, ?TABLE),
        ?assertEqual(1, meck:num_calls(esqlite3, exec, '_'))
    after teardown() end.
