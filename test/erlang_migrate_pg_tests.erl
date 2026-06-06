%% Unit tests for erlang_migrate_pg driver.
%% Mocks epgsql — no real database required.
-module(erlang_migrate_pg_tests).
-include_lib("eunit/include/eunit.hrl").

-define(TABLE, <<"schema_migrations">>).
-define(CONN,  test_conn).

%%% ── Helpers ─────────────────────────────────────────────────────────────────

setup_epgsql(CurrentVersion, IsDirty) ->
    meck:new(epgsql, [no_link, non_strict]),
    DirtyStr = case IsDirty of true -> <<"t">>; false -> <<"f">> end,
    Rows = case CurrentVersion of
        undefined -> [];
        V         -> [{integer_to_binary(V), DirtyStr}]
    end,
    meck:expect(epgsql, squery, fun(_, SQL) ->
        SQLBin = iolist_to_binary(SQL),
        case SQLBin of
            <<"BEGIN">>                        -> {ok, [], []};
            <<"COMMIT">>                       -> {ok, [], []};
            <<"ROLLBACK">>                     -> {ok, [], []};
            <<"CREATE TABLE",       _/binary>> -> {ok, [], []};
            <<"DROP TABLE",         _/binary>> -> {ok, 1};
            <<"DELETE FROM",        _/binary>> -> {ok, 1};
            <<"INSERT INTO",        _/binary>> -> {ok, 1};
            <<"SELECT version",     _/binary>> -> {ok, [version, dirty], Rows};
            <<"SELECT pg_try",      _/binary>> -> {ok, [lock], [{<<"t">>}]};
            <<"SELECT pg_advisory", _/binary>> -> {ok, [unlock], [{<<"t">>}]};
            _                                  -> {ok, [], []}
        end
    end).

teardown() ->
    catch meck:unload(epgsql).

%%% ── ensure_table ────────────────────────────────────────────────────────────

ensure_table_ok_test() ->
    setup_epgsql(undefined, false),
    try
        ok = erlang_migrate_pg:ensure_table(?CONN, ?TABLE),
        ?assertEqual(1, meck:num_calls(epgsql, squery, '_'))
    after teardown() end.

%%% ── current_version ─────────────────────────────────────────────────────────

current_version_empty_test() ->
    setup_epgsql(undefined, false),
    try
        ?assertEqual({ok, undefined, false},
                     erlang_migrate_pg:current_version(?CONN, ?TABLE))
    after teardown() end.

current_version_with_row_test() ->
    setup_epgsql(5, false),
    try
        ?assertEqual({ok, 5, false},
                     erlang_migrate_pg:current_version(?CONN, ?TABLE))
    after teardown() end.

current_version_dirty_test() ->
    setup_epgsql(3, true),
    try
        {ok, 3, true} = erlang_migrate_pg:current_version(?CONN, ?TABLE)
    after teardown() end.

%%% ── set_version transaction ─────────────────────────────────────────────────

set_version_wraps_in_transaction_test() ->
    setup_epgsql(undefined, false),
    try
        ok = erlang_migrate_pg:set_version(?CONN, ?TABLE, 5, false),
        %% BEGIN and COMMIT must be issued
        ?assert(meck:called(epgsql, squery, [?CONN, "BEGIN"])),
        ?assert(meck:called(epgsql, squery, [?CONN, "COMMIT"]))
    after teardown() end.

set_version_rollback_on_insert_failure_test() ->
    meck:new(epgsql, [no_link, non_strict]),
    meck:expect(epgsql, squery, fun(_, SQL) ->
        SQLBin = iolist_to_binary(SQL),
        case SQLBin of
            <<"BEGIN">>                       -> {ok, [], []};
            <<"ROLLBACK">>                    -> {ok, [], []};
            <<"DELETE FROM", _/binary>>       -> {ok, 1};
            <<"INSERT INTO", _/binary>>       -> {error, <<"simulated insert failure">>};
            _                                 -> {ok, [], []}
        end
    end),
    try
        {error, _} = erlang_migrate_pg:set_version(?CONN, ?TABLE, 5, false),
        ?assert(meck:called(epgsql, squery, [?CONN, "ROLLBACK"])),
        ?assertNot(meck:called(epgsql, squery, [?CONN, "COMMIT"]))
    after teardown() end.

set_version_no_commit_on_delete_failure_test() ->
    meck:new(epgsql, [no_link, non_strict]),
    meck:expect(epgsql, squery, fun(_, SQL) ->
        SQLBin = iolist_to_binary(SQL),
        case SQLBin of
            <<"BEGIN">>               -> {ok, [], []};
            <<"ROLLBACK">>            -> {ok, [], []};
            <<"DELETE FROM", _/binary>> -> {error, <<"simulated delete failure">>};
            _                         -> {ok, [], []}
        end
    end),
    try
        {error, _} = erlang_migrate_pg:set_version(?CONN, ?TABLE, 5, false),
        ?assert(meck:called(epgsql, squery, [?CONN, "ROLLBACK"])),
        ?assertNot(meck:called(epgsql, squery, [?CONN, "COMMIT"]))
    after teardown() end.

set_version_undefined_no_transaction_test() ->
    setup_epgsql(undefined, false),
    try
        %% Version=undefined is a single DELETE — no need for a transaction
        ok = erlang_migrate_pg:set_version(?CONN, ?TABLE, undefined, false),
        %% Only one squery call: the DELETE
        ?assertEqual(1, meck:num_calls(epgsql, squery, '_'))
    after teardown() end.

%%% ── exec_sql transaction ────────────────────────────────────────────────────

exec_sql_wraps_in_transaction_test() ->
    setup_epgsql(undefined, false),
    try
        ok = erlang_migrate_pg:exec_sql(?CONN, <<"ALTER TABLE foo ADD COLUMN bar INT">>),
        ?assert(meck:called(epgsql, squery, [?CONN, "BEGIN"])),
        ?assert(meck:called(epgsql, squery, [?CONN, "COMMIT"]))
    after teardown() end.

%%% ── validate_table_name (schema.table support) ──────────────────────────────

validate_table_name_simple_test() ->
    setup_epgsql(undefined, false),
    try
        ok = erlang_migrate_pg:ensure_table(?CONN, <<"schema_migrations">>),
        ok = erlang_migrate_pg:ensure_table(?CONN, <<"_private">>)
    after teardown() end.

validate_table_name_schema_qualified_test() ->
    setup_epgsql(undefined, false),
    try
        %% schema.table names should now be accepted
        ok = erlang_migrate_pg:ensure_table(?CONN, <<"public.schema_migrations">>)
    after teardown() end.

validate_table_name_rejects_invalid_test() ->
    ?assertError({invalid_table_name, _},
                 erlang_migrate_pg:ensure_table(fake_conn, <<"DROP TABLE users; --">>)).

%%% ── lock / unlock ───────────────────────────────────────────────────────────

lock_success_test() ->
    setup_epgsql(undefined, false),
    try
        ok = erlang_migrate_pg:lock(?CONN, 12345, 5000)
    after teardown() end.

lock_timeout_test() ->
    meck:new(epgsql, [no_link, non_strict]),
    meck:expect(epgsql, squery, fun(_, _) -> {ok, [lock], [{<<"f">>}]} end),
    try
        ?assertEqual({error, lock_timeout},
                     erlang_migrate_pg:lock(?CONN, 12345, 0))
    after teardown() end.

unlock_ok_test() ->
    setup_epgsql(undefined, false),
    try
        ok = erlang_migrate_pg:unlock(?CONN, 12345)
    after teardown() end.

%%% ── is_dirty ────────────────────────────────────────────────────────────────

is_dirty_false_test() ->
    setup_epgsql(2, false),
    try
        ?assertEqual({ok, false}, erlang_migrate_pg:is_dirty(?CONN, ?TABLE))
    after teardown() end.

is_dirty_true_test() ->
    setup_epgsql(2, true),
    try
        ?assertEqual({ok, true}, erlang_migrate_pg:is_dirty(?CONN, ?TABLE))
    after teardown() end.

%%% ── drop_table ──────────────────────────────────────────────────────────────

drop_table_ok_test() ->
    setup_epgsql(undefined, false),
    try
        ok = erlang_migrate_pg:drop_table(?CONN, ?TABLE),
        ?assertEqual(1, meck:num_calls(epgsql, squery, '_'))
    after teardown() end.
