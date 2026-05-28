%% @doc erlang_migrate — database migration library modeled after golang-migrate/v4.
%%
%% == Quick Start ==
%% ```
%% Config = #{
%%     conn  => Conn,           % epgsql connection pid
%%     dir   => "priv/migrations",
%%     table => <<"schema_migrations">>,  % optional
%%     lock_id => 7369284       % optional, auto-derived from table name
%% },
%% ok = erlang_migrate:up(Config).
%% '''
%%
%% == File naming ==
%% Migrations live in `dir` as pairs:
%%   {version}_{title}.up.sql
%%   {version}_{title}.down.sql   (optional — skipping makes down/2 fail)
%%
%% version must be a positive integer, e.g. 1, 100, 20240101120000.
-module(erlang_migrate).
-export([up/1, up/2, down/1, down/2, goto/2, version/1, force/2, drop/1]).

-define(DEFAULT_TABLE,        <<"schema_migrations">>).
-define(DEFAULT_LOCK_TIMEOUT, 15000).  %% milliseconds, matches golang-migrate default

%% Apply all pending migrations.
-spec up(Config :: map()) -> ok | {error, term()}.
up(Config) -> up(Config, all).

%% Apply up to N pending migrations (all = unlimited).
-spec up(Config :: map(), Steps :: pos_integer() | all) -> ok | {error, term()}.
up(Config, Steps) ->
    with_lock(Config, fun(Conn, Table, Logger) ->
        case check_dirty(Conn, Table) of
            {error, _} = E -> E;
            ok ->
                {ok, Current, _} = erlang_migrate_pg:current_version(Conn, Table),
                case erlang_migrate_source:scan(dir(Config)) of
                    {error, _} = E -> E;
                    {ok, All} ->
                        Pending = pending_up(All, Current, Steps),
                        apply_up(Conn, Table, Pending, Logger)
                end
        end
    end).

%% Roll back all applied migrations.
-spec down(Config :: map()) -> ok | {error, term()}.
down(Config) -> down(Config, all).

%% Roll back N migrations (all = unlimited).
-spec down(Config :: map(), Steps :: pos_integer() | all) -> ok | {error, term()}.
down(Config, Steps) when Steps =:= all orelse (is_integer(Steps) andalso Steps > 0) ->
    with_lock(Config, fun(Conn, Table, Logger) ->
        case check_dirty(Conn, Table) of
            {error, _} = E -> E;
            ok ->
                {ok, Current, _} = erlang_migrate_pg:current_version(Conn, Table),
                case Current of
                    undefined -> ok;
                    _ ->
                        case erlang_migrate_source:scan(dir(Config)) of
                            {error, _} = E -> E;
                            {ok, All} ->
                                ToRollback = pending_down(All, Current, Steps),
                                apply_down(Conn, Table, ToRollback, Logger)
                        end
                end
        end
    end).

%% Migrate to a specific version (auto up or down — equivalent to golang-migrate Migrate(v)).
-spec goto(Config :: map(), Version :: integer()) -> ok | {error, term()}.
goto(Config, Version) ->
    with_lock(Config, fun(Conn, Table, Logger) ->
        case check_dirty(Conn, Table) of
            {error, _} = E -> E;
            ok ->
                {ok, Current, _} = erlang_migrate_pg:current_version(Conn, Table),
                case erlang_migrate_source:scan(dir(Config)) of
                    {error, _} = E -> E;
                    {ok, All} ->
                        CurV = case Current of undefined -> 0; V -> V end,
                        if
                            Version > CurV ->
                                Pending = [M || M <- All,
                                               maps:get(version, M) > CurV,
                                               maps:get(version, M) =< Version],
                                apply_up(Conn, Table, Pending, Logger);
                            Version < CurV ->
                                ToRollback = [M || M <- All,
                                                   maps:get(version, M) =< CurV,
                                                   maps:get(version, M) > Version],
                                apply_down(Conn, Table, lists:reverse(ToRollback), Logger);
                            true ->
                                ok
                        end
                end
        end
    end).

%% Return current schema version and dirty flag.
-spec version(Config :: map()) -> {ok, integer() | undefined, boolean()} | {error, term()}.
version(Config) ->
    Conn  = conn(Config),
    Table = table(Config),
    ok = erlang_migrate_pg:ensure_table(Conn, Table),
    case erlang_migrate_pg:current_version(Conn, Table) of
        {ok, Ver, Dirty} -> {ok, Ver, Dirty};
        Err              -> Err
    end.

%% Force set version (clears dirty flag — use after manual recovery).
-spec force(Config :: map(), Version :: integer()) -> ok | {error, term()}.
force(Config, Version) ->
    Conn  = conn(Config),
    Table = table(Config),
    ok = erlang_migrate_pg:ensure_table(Conn, Table),
    erlang_migrate_pg:set_version(Conn, Table, Version, false).

%% Drop schema_migrations table (destructive — use in tests only).
-spec drop(Config :: map()) -> ok | {error, term()}.
drop(Config) ->
    Conn  = conn(Config),
    Table = table(Config),
    erlang_migrate_pg:drop_table(Conn, Table).

%%% Internal helpers

with_lock(Config, Fun) ->
    Conn    = conn(Config),
    Table   = table(Config),
    LockId  = lock_id(Config, Table),
    Timeout = lock_timeout(Config),
    Logger  = logger(Config),
    ok = erlang_migrate_pg:ensure_table(Conn, Table),
    log(Logger, info, fmt("acquiring lock ~b (timeout ~bms)", [LockId, Timeout])),
    case erlang_migrate_pg:lock(Conn, LockId, Timeout) of
        {error, lock_timeout} ->
            log(Logger, error, fmt("lock timeout after ~bms", [Timeout])),
            {error, lock_timeout};
        {error, _} = E ->
            log(Logger, error, <<"lock acquisition failed">>),
            E;
        ok ->
            log(Logger, info, <<"lock acquired">>),
            try Fun(Conn, Table, Logger)
            after
                erlang_migrate_pg:unlock(Conn, LockId),
                log(Logger, info, <<"lock released">>)
            end
    end.

check_dirty(Conn, Table) ->
    case erlang_migrate_pg:is_dirty(Conn, Table) of
        {ok, true}  -> {error, {dirty_state, "Run force/2 to recover"}};
        {ok, false} -> ok;
        Err         -> Err
    end.

pending_up(All, undefined, all) -> All;
pending_up(All, undefined, N)   -> lists:sublist(All, N);
pending_up(All, Current, all)   -> [M || M <- All, maps:get(version, M) > Current];
pending_up(All, Current, N)     -> lists:sublist([M || M <- All, maps:get(version, M) > Current], N).

pending_down(All, Current, all) ->
    lists:reverse([M || M <- All, maps:get(version, M) =< Current]);
pending_down(All, Current, N) ->
    lists:sublist(lists:reverse([M || M <- All, maps:get(version, M) =< Current]), N).

apply_up(_Conn, _Table, [], _Logger) -> ok;
apply_up(Conn, Table, [M | Rest], Logger) ->
    Version = maps:get(version, M),
    Title   = maps:get(title, M),
    UpFile  = maps:get(up_file, M),
    log(Logger, info, fmt("applying up ~b ~s", [Version, Title])),
    case erlang_migrate_source:read_sql(UpFile, up) of
        {error, _} = E -> E;
        {ok, SQL} ->
            ok = erlang_migrate_pg:set_version(Conn, Table, Version, true),
            case erlang_migrate_pg:exec_sql(Conn, SQL) of
                {error, _} = E ->
                    log(Logger, error, fmt("failed up ~b — dirty state set", [Version])),
                    E;
                ok ->
                    ok = erlang_migrate_pg:set_version(Conn, Table, Version, false),
                    log(Logger, info, fmt("applied up ~b", [Version])),
                    apply_up(Conn, Table, Rest, Logger)
            end
    end.

apply_down(_Conn, _Table, [], _Logger) -> ok;
apply_down(Conn, Table, [M | Rest], Logger) ->
    Version  = maps:get(version, M),
    Title    = maps:get(title, M),
    DownFile = maps:get(down_file, M),
    case DownFile of
        undefined ->
            {error, {no_down_migration, Version}};
        _ ->
            log(Logger, info, fmt("applying down ~b ~s", [Version, Title])),
            case erlang_migrate_source:read_sql(DownFile, down) of
                {error, _} = E -> E;
                {ok, SQL} ->
                    ok = erlang_migrate_pg:set_version(Conn, Table, Version, true),
                    case erlang_migrate_pg:exec_sql(Conn, SQL) of
                        {error, _} = E ->
                            log(Logger, error, fmt("failed down ~b — dirty state set", [Version])),
                            E;
                        ok ->
                            DelSQL = iolist_to_binary([
                                "DELETE FROM ", Table,
                                " WHERE version = ", integer_to_binary(Version)
                            ]),
                            ok = erlang_migrate_pg:exec_sql(Conn, DelSQL),
                            log(Logger, info, fmt("applied down ~b", [Version])),
                            apply_down(Conn, Table, Rest, Logger)
                    end
            end
    end.

conn(#{conn := C})   -> C.
table(#{table := T}) -> T;
table(_)             -> ?DEFAULT_TABLE.
dir(#{dir := D})     -> D.

lock_id(#{lock_id := Id}, _) -> Id;
lock_id(_, Table)            -> erlang:phash2(Table, 16#7FFFFFFFFFFFFFFF).

lock_timeout(#{lock_timeout := T}) when is_integer(T), T >= 0 -> T;
lock_timeout(_)                                                -> ?DEFAULT_LOCK_TIMEOUT.

logger(#{logger := F}) when is_function(F, 2) -> F;
logger(_)                                     -> undefined.

log(undefined, _Level, _Msg) -> ok;
log(Fun, Level, Msg)         -> Fun(Level, Msg).

fmt(Fmt, Args) -> iolist_to_binary(io_lib:format(Fmt, Args)).
