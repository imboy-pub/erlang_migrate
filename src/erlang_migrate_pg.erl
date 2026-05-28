%% @doc PostgreSQL driver for erlang_migrate.
%% Manages schema_migrations table and advisory locks.
-module(erlang_migrate_pg).
-behaviour(erlang_migrate_driver).
-export([ensure_table/2, current_version/2, lock/2, lock/3, unlock/2,
         set_version/4, clear_dirty/2, is_dirty/2, drop_table/2,
         exec_sql/2]).

-define(LOCK_RETRY_MS, 100).

-define(DEFAULT_TABLE, <<"schema_migrations">>).

%% Create schema_migrations table if not exists.
ensure_table(Conn, Table) ->
    SQL = iolist_to_binary([
        "CREATE TABLE IF NOT EXISTS ", table_ref(Table), " (",
        "  version    BIGINT PRIMARY KEY,",
        "  dirty      BOOLEAN NOT NULL DEFAULT false,",
        "  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()",
        ")"
    ]),
    case epgsql:squery(Conn, SQL) of
        {ok, _, _} -> ok;
        {ok, _}    -> ok;
        [{ok, _}]  -> ok;
        Err        -> {error, {ensure_table_failed, Err}}
    end.

%% Get current version. Returns {ok, Version} | {ok, undefined} | {error, term()}
current_version(Conn, Table) ->
    SQL = iolist_to_binary([
        "SELECT version, dirty FROM ", table_ref(Table),
        " ORDER BY version DESC LIMIT 1"
    ]),
    case epgsql:squery(Conn, SQL) of
        {ok, _, []}              -> {ok, undefined, false};
        {ok, _, [{VerBin, DirtyBin}]} ->
            Ver = binary_to_integer(VerBin),
            Dirty = DirtyBin =:= <<"t">> orelse DirtyBin =:= true,
            {ok, Ver, Dirty};
        Err -> {error, {query_failed, Err}}
    end.

%% Acquire advisory lock with default 15-second timeout.
lock(Conn, LockId) -> lock(Conn, LockId, 15000).

%% Acquire advisory lock with explicit timeout (milliseconds).
%% Uses pg_try_advisory_lock + retry loop — matches golang-migrate LockTimeout behaviour.
lock(Conn, LockId, Timeout) when is_integer(Timeout), Timeout >= 0 ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    try_lock(Conn, LockId, Deadline).

try_lock(Conn, LockId, Deadline) ->
    SQL = io_lib:format("SELECT pg_try_advisory_lock(~b)", [LockId]),
    case epgsql:squery(Conn, lists:flatten(SQL)) of
        {ok, _, [{<<"t">>}]} ->
            ok;
        {ok, _, [{<<"f">>}]} ->
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

%% Release PostgreSQL advisory lock.
unlock(Conn, LockId) ->
    SQL = io_lib:format("SELECT pg_advisory_unlock(~b)", [LockId]),
    epgsql:squery(Conn, lists:flatten(SQL)),
    ok.

%% Replace the single tracking row (golang-migrate semantics: always one row).
%% Version = undefined means DELETE only — table empty = no migrations applied.
set_version(Conn, Table, undefined, _Dirty) ->
    SQL = iolist_to_binary(["DELETE FROM ", table_ref(Table)]),
    case epgsql:squery(Conn, SQL) of
        {ok, _} -> ok;
        Err     -> {error, {set_version_failed, Err}}
    end;
set_version(Conn, Table, Version, Dirty) ->
    DirtyStr = case Dirty of true -> "true"; false -> "false" end,
    Del = iolist_to_binary(["DELETE FROM ", table_ref(Table)]),
    Ins = iolist_to_binary([
        "INSERT INTO ", table_ref(Table),
        " (version, dirty, applied_at) VALUES (",
        integer_to_binary(Version), ", ", DirtyStr, ", now())"
    ]),
    case epgsql:squery(Conn, Del) of
        {ok, _} ->
            case epgsql:squery(Conn, Ins) of
                {ok, _}    -> ok;
                {ok, _, _} -> ok;
                Err        -> {error, {set_version_failed, Err}}
            end;
        Err -> {error, {set_version_failed, Err}}
    end.

%% Clear dirty flag for current version.
clear_dirty(Conn, Table) ->
    SQL = iolist_to_binary([
        "UPDATE ", table_ref(Table),
        " SET dirty = false WHERE version = (",
        "  SELECT version FROM ", table_ref(Table),
        "  ORDER BY version DESC LIMIT 1)"
    ]),
    case epgsql:squery(Conn, SQL) of
        {ok, _}    -> ok;
        {ok, _, _} -> ok;
        Err        -> {error, {clear_dirty_failed, Err}}
    end.

%% Check if current state is dirty.
is_dirty(Conn, Table) ->
    case current_version(Conn, Table) of
        {ok, _, Dirty} -> {ok, Dirty};
        Err            -> Err
    end.

%% Drop schema_migrations table.
drop_table(Conn, Table) ->
    SQL = iolist_to_binary(["DROP TABLE IF EXISTS ", table_ref(Table)]),
    case epgsql:squery(Conn, SQL) of
        {ok, _, _} -> ok;
        {ok, _}    -> ok;
        Err        -> {error, {drop_failed, Err}}
    end.

%% Execute arbitrary SQL (for migration content).
exec_sql(Conn, SQL) when is_binary(SQL) ->
    case epgsql:squery(Conn, binary_to_list(SQL)) of
        Results when is_list(Results) ->
            Errors = [E || {error, _} = E <- Results],
            case Errors of
                []        -> ok;
                [Err | _] -> {error, {sql_exec_failed, Err}}
            end;
        {ok, _, _} -> ok;
        {ok, _}    -> ok;
        {error, E} -> {error, {sql_exec_failed, E}}
    end.

%%% Internal

table_ref(Table) when is_binary(Table) -> Table;
table_ref(Table) when is_list(Table)   -> list_to_binary(Table).
