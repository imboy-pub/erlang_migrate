%% @doc MySQL 8+ driver for erlang_migrate.
%% Uses mysql-otp (https://github.com/mysql-otp/mysql-otp).
-module(erlang_migrate_mysql).
-behaviour(erlang_migrate_driver).
-export([ensure_table/2, current_version/2, lock/2, lock/3, unlock/2,
         set_version/4, is_dirty/2, exec_sql/2, drop_table/2]).

-define(LOCK_RETRY_MS, 100).

%% Create schema_migrations table if not exists.
ensure_table(Conn, Table) ->
    SQL = iolist_to_binary([
        "CREATE TABLE IF NOT EXISTS ", table_ref(Table), " (",
        "  version    BIGINT PRIMARY KEY,",
        "  dirty      TINYINT(1) NOT NULL DEFAULT 0,",
        "  applied_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)",
        ")"
    ]),
    case mysql:query(Conn, SQL) of
        ok  -> ok;
        Err -> {error, {ensure_table_failed, Err}}
    end.

%% Get current version and dirty flag.
current_version(Conn, Table) ->
    SQL = iolist_to_binary([
        "SELECT version, dirty FROM ", table_ref(Table),
        " ORDER BY version DESC LIMIT 1"
    ]),
    case mysql:query(Conn, SQL) of
        {ok, _Cols, []}               -> {ok, undefined, false};
        {ok, _Cols, [[VerInt, Dirty]]} ->
            {ok, VerInt, Dirty =:= 1 orelse Dirty =:= true};
        Err -> {error, {query_failed, Err}}
    end.

%% Acquire MySQL named lock with default 15-second timeout.
lock(Conn, LockId) -> lock(Conn, LockId, 15000).

%% Acquire MySQL named lock with explicit timeout (milliseconds).
%% MySQL GET_LOCK takes seconds; we use a retry loop for sub-second precision.
lock(Conn, LockId, Timeout) when is_integer(Timeout), Timeout >= 0 ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    try_lock(Conn, LockId, Deadline).

try_lock(Conn, LockId, Deadline) ->
    Name = lock_name(LockId),
    SQL  = iolist_to_binary(["SELECT GET_LOCK('", Name, "', 0)"]),
    case mysql:query(Conn, SQL) of
        {ok, _, [[1]]} ->
            ok;
        {ok, _, [[0]]} ->
            Remaining = Deadline - erlang:monotonic_time(millisecond),
            if Remaining =< 0 ->
                {error, lock_timeout};
            true ->
                timer:sleep(min(?LOCK_RETRY_MS, Remaining)),
                try_lock(Conn, LockId, Deadline)
            end;
        Err ->
            {error, {lock_failed, Err}}
    end.

%% Release MySQL named lock.
unlock(Conn, LockId) ->
    Name = lock_name(LockId),
    SQL  = iolist_to_binary(["SELECT RELEASE_LOCK('", Name, "')"]),
    mysql:query(Conn, SQL),
    ok.

%% Replace the single tracking row (golang-migrate semantics).
set_version(Conn, Table, undefined, _Dirty) ->
    SQL = iolist_to_binary(["DELETE FROM ", table_ref(Table)]),
    case mysql:query(Conn, SQL) of
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
        "REPLACE INTO ", table_ref(Table),
        " (version, dirty, applied_at) VALUES (",
        integer_to_binary(Version), ", ", DirtyInt, ", NOW(6))"
    ]),
    case mysql:query(Conn, Del) of
        ok  ->
            case mysql:query(Conn, Upsert) of
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
    case mysql:query(Conn, SQL) of
        ok  -> ok;
        Err -> {error, {sql_exec_failed, Err}}
    end.

%% Drop schema_migrations table.
drop_table(Conn, Table) ->
    SQL = iolist_to_binary(["DROP TABLE IF EXISTS ", table_ref(Table)]),
    case mysql:query(Conn, SQL) of
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

lock_name(LockId) ->
    iolist_to_binary(["erlang_migrate_", integer_to_list(LockId)]).
