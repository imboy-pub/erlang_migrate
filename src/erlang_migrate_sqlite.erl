%% @doc SQLite 3+ driver for erlang_migrate.
%% Uses esqlite (https://github.com/mmzeeman/esqlite).
%%
%% Locking: SQLite has no advisory locks. We use OTP global:set_lock/3
%% to serialize migrations across processes on the same node.
-module(erlang_migrate_sqlite).
-behaviour(erlang_migrate_driver).
-export([ensure_table/2, current_version/2, lock/2, lock/3, unlock/2,
         set_version/4, is_dirty/2, exec_sql/2, drop_table/2]).

-define(LOCK_RETRY_MS, 100).

%% Create schema_migrations table if not exists.
ensure_table(Conn, Table) ->
    SQL = iolist_to_binary([
        "CREATE TABLE IF NOT EXISTS ", table_ref(Table), " (",
        "  version    INTEGER PRIMARY KEY,",
        "  dirty      INTEGER NOT NULL DEFAULT 0,",
        "  applied_at TEXT    NOT NULL DEFAULT (datetime('now'))",
        ")"
    ]),
    case esqlite3:exec(Conn, SQL) of
        ok  -> ok;
        Err -> {error, {ensure_table_failed, Err}}
    end.

%% Get current version and dirty flag.
current_version(Conn, Table) ->
    SQL = iolist_to_binary([
        "SELECT version, dirty FROM ", table_ref(Table),
        " ORDER BY version DESC LIMIT 1"
    ]),
    case esqlite3:q(Conn, SQL) of
        []                   -> {ok, undefined, false};
        [[VerInt, DirtyInt]] -> {ok, VerInt, DirtyInt =:= 1};
        Err                  -> {error, {query_failed, Err}}
    end.

%% Acquire OTP global lock with default 15-second timeout.
lock(_Conn, LockId) -> lock(_Conn, LockId, 15000).

%% Acquire OTP global lock with explicit timeout (milliseconds).
lock(_Conn, LockId, Timeout) when is_integer(Timeout), Timeout >= 0 ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    try_lock(LockId, Deadline).

try_lock(LockId, Deadline) ->
    %% ResourceId = {erlang_migrate_lock, LockId}; LockRequesterId = self()
    %% so different processes compete rather than reusing the same requester id.
    case global:set_lock({{erlang_migrate_lock, LockId}, self()}, [node()], 0) of
        true  -> ok;
        false ->
            Remaining = Deadline - erlang:monotonic_time(millisecond),
            if Remaining =< 0 ->
                {error, lock_timeout};
            true ->
                timer:sleep(min(?LOCK_RETRY_MS, Remaining)),
                try_lock(LockId, Deadline)
            end
    end.

%% Release OTP global lock.
unlock(_Conn, LockId) ->
    global:del_lock({{erlang_migrate_lock, LockId}, self()}, [node()]),
    ok.

%% Replace the single tracking row (golang-migrate semantics).
set_version(Conn, Table, undefined, _Dirty) ->
    SQL = iolist_to_binary(["DELETE FROM ", table_ref(Table)]),
    case esqlite3:exec(Conn, SQL) of
        ok  -> ok;
        Err -> {error, {set_version_failed, Err}}
    end;
set_version(Conn, Table, Version, Dirty) ->
    DirtyInt = case Dirty of true -> "1"; false -> "0" end,
    %% Delete rows for other versions, then atomically upsert the current one.
    Del = iolist_to_binary([
        "DELETE FROM ", table_ref(Table),
        " WHERE version != ", integer_to_binary(Version)
    ]),
    Upsert = iolist_to_binary([
        "INSERT OR REPLACE INTO ", table_ref(Table),
        " (version, dirty, applied_at) VALUES (",
        integer_to_binary(Version), ", ", DirtyInt, ", datetime('now'))"
    ]),
    case esqlite3:exec(Conn, Del) of
        ok  ->
            case esqlite3:exec(Conn, Upsert) of
                ok  -> ok;
                Err -> {error, {set_version_failed, Err}}
            end;
        Err -> {error, {set_version_failed, Err}}
    end.

%% Check if current state is dirty.
is_dirty(Conn, Table) ->
    case current_version(Conn, Table) of
        {ok, _, Dirty} -> {ok, Dirty};
        Err            -> Err
    end.

%% Execute arbitrary SQL (for migration content).
exec_sql(Conn, SQL) when is_binary(SQL) ->
    case esqlite3:exec(Conn, SQL) of
        ok  -> ok;
        Err -> {error, {sql_exec_failed, Err}}
    end.

%% Drop schema_migrations table.
drop_table(Conn, Table) ->
    SQL = iolist_to_binary(["DROP TABLE IF EXISTS ", table_ref(Table)]),
    case esqlite3:exec(Conn, SQL) of
        ok  -> ok;
        Err -> {error, {drop_failed, Err}}
    end.

%%% Internal

table_ref(Table) when is_binary(Table) -> validate_table_name(Table);
table_ref(Table) when is_list(Table)   -> validate_table_name(list_to_binary(Table)).

%% Raises error/1 (not {error,_}) — invalid table name is a programmer error, not a runtime condition.
validate_table_name(Name) ->
    case re:run(Name, "^[a-zA-Z_][a-zA-Z0-9_]*$", [{capture, none}]) of
        match   -> Name;
        nomatch -> error({invalid_table_name, Name})
    end.
