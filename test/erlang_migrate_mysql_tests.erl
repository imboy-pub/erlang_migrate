%% Unit tests for erlang_migrate_mysql driver.
%% Mocks the mysql module — no real database required.
-module(erlang_migrate_mysql_tests).
-include_lib("eunit/include/eunit.hrl").

-define(TABLE, <<"schema_migrations">>).
-define(CONN,  test_conn).

%%% ── Helpers ─────────────────────────────────────────────────────────────────

setup_mysql(CurrentVersion, IsDirty) ->
    meck:new(mysql, [no_link, non_strict]),
    DirtyInt = case IsDirty of true -> 1; false -> 0 end,
    Rows = case CurrentVersion of
        undefined -> [];
        V         -> [[V, DirtyInt]]
    end,
    meck:expect(mysql, query,
        fun(_, SQL) when is_binary(SQL) ->
            case SQL of
                <<"CREATE TABLE",        _/binary>> -> ok;
                <<"DROP TABLE",          _/binary>> -> ok;
                <<"DELETE FROM",         _/binary>> -> ok;
                <<"SELECT version",      _/binary>> -> {ok, [version, dirty], Rows};
                <<"INSERT INTO",         _/binary>> -> ok;
                <<"SELECT GET_LOCK",     _/binary>> -> {ok, [result], [[1]]};
                <<"SELECT RELEASE_LOCK", _/binary>> -> {ok, [result], [[1]]};
                _                                   -> ok
            end
        end).

teardown() ->
    catch meck:unload(mysql).

%%% ── ensure_table ────────────────────────────────────────────────────────────

ensure_table_ok_test() ->
    setup_mysql(undefined, false),
    try
        ok = erlang_migrate_mysql:ensure_table(?CONN, ?TABLE),
        ?assertEqual(1, meck:num_calls(mysql, query, '_'))
    after teardown() end.

%%% ── current_version ─────────────────────────────────────────────────────────

current_version_empty_test() ->
    setup_mysql(undefined, false),
    try
        ?assertEqual({ok, undefined, false},
                     erlang_migrate_mysql:current_version(?CONN, ?TABLE))
    after teardown() end.

current_version_with_row_test() ->
    setup_mysql(5, false),
    try
        ?assertEqual({ok, 5, false},
                     erlang_migrate_mysql:current_version(?CONN, ?TABLE))
    after teardown() end.

current_version_dirty_test() ->
    setup_mysql(3, true),
    try
        {ok, 3, true} = erlang_migrate_mysql:current_version(?CONN, ?TABLE)
    after teardown() end.

%%% ── lock / unlock ───────────────────────────────────────────────────────────

lock_success_test() ->
    setup_mysql(undefined, false),
    try
        ok = erlang_migrate_mysql:lock(?CONN, 12345, 5000)
    after teardown() end.

lock_timeout_test() ->
    meck:new(mysql, [no_link, non_strict]),
    meck:expect(mysql, query, fun(_, _) -> {ok, [result], [[0]]} end),
    try
        ?assertEqual({error, lock_timeout},
                     erlang_migrate_mysql:lock(?CONN, 12345, 0))
    after teardown() end.

unlock_ok_test() ->
    setup_mysql(undefined, false),
    try
        ok = erlang_migrate_mysql:unlock(?CONN, 12345)
    after teardown() end.

%%% ── set_version ─────────────────────────────────────────────────────────────

set_version_ok_test() ->
    setup_mysql(undefined, false),
    try
        ok = erlang_migrate_mysql:set_version(?CONN, ?TABLE, 1, false),
        ok = erlang_migrate_mysql:set_version(?CONN, ?TABLE, 1, true),
        ok = erlang_migrate_mysql:set_version(?CONN, ?TABLE, undefined, false),
        %% 2x (DELETE+INSERT) + 1x DELETE-only = 5 mysql:query calls
        ?assertEqual(5, meck:num_calls(mysql, query, '_'))
    after teardown() end.

%%% ── is_dirty ────────────────────────────────────────────────────────────────

is_dirty_false_test() ->
    setup_mysql(2, false),
    try
        ?assertEqual({ok, false}, erlang_migrate_mysql:is_dirty(?CONN, ?TABLE))
    after teardown() end.

is_dirty_true_test() ->
    setup_mysql(2, true),
    try
        ?assertEqual({ok, true}, erlang_migrate_mysql:is_dirty(?CONN, ?TABLE))
    after teardown() end.

%%% ── exec_sql ────────────────────────────────────────────────────────────────

exec_sql_ok_test() ->
    setup_mysql(undefined, false),
    try
        ok = erlang_migrate_mysql:exec_sql(?CONN, <<"ALTER TABLE foo ADD COLUMN bar INT">>)
    after teardown() end.

%%% ── drop_table ──────────────────────────────────────────────────────────────

drop_table_ok_test() ->
    setup_mysql(undefined, false),
    try
        ok = erlang_migrate_mysql:drop_table(?CONN, ?TABLE),
        ?assertEqual(1, meck:num_calls(mysql, query, '_'))
    after teardown() end.
