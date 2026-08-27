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
%% Migrations live in `dir' as pairs:
%%   {version}_{title}.up.sql
%%   {version}_{title}.down.sql   (optional — skipping makes down/2 fail)
%%
%% version must be a positive integer, e.g. 1, 100, 20240101120000.
%%
%% == GracefulStop ==
%% Send `erlang_migrate_abort' to the migration process to abort between
%% migrations:  MigPid ! erlang_migrate_abort
%%
%% == dry_run mode ==
%% Set `dry_run => true' in Config to log what would be applied without
%% touching the database. dry_run also bypasses strict-mode bookkeeping.
%%
%% == strict mode (out-of-order detection) ==
%% Set `strict => true' to record every applied migration in a
%% `Table_history' table (one row per version). up/1,2 then fails with
%% `{error, {out_of_order, Versions}}' if a file's version is at or below
%% current but was never applied — e.g. a timestamp-versioned migration merged
%% late from another branch, which would otherwise be silently skipped forever.
%% Recovery: re-timestamp the late file to a fresh version, or run force/2
%% to rebuild the history after applying it manually.
%% Requires a driver exporting applied_versions/2 (pg/mysql/sqlite all do).
-module(erlang_migrate).
-export([up/1, up/2, down/1, down/2, goto/2, version/1, force/2, drop/1,
         create/2]).

-define(DEFAULT_TABLE,              <<"schema_migrations">>).
-define(DEFAULT_LOCK_TIMEOUT,       15000).  %% milliseconds
-define(DEFAULT_SET_VERSION_RETRIES, 3).
-define(DEFAULT_SET_VERSION_RETRY_MS, 200).

%% Apply all pending migrations.
-spec up(Config :: map()) -> ok | {error, term()}.
up(Config) -> up(Config, all).

%% Apply up to N pending migrations (all = unlimited).
-spec up(Config :: map(), Steps :: pos_integer() | all) -> ok | {error, term()}.
up(Config, Steps) ->
    DryRun = dry_run(Config),
    with_lock(Config, fun(Conn, Table, Logger, Driver) ->
        case check_dirty(Driver, Conn, Table) of
            {error, _} = E -> E;
            ok ->
                {ok, Current, _} = Driver:current_version(Conn, Table),
                case erlang_migrate_source:scan(dir(Config)) of
                    {error, _} = E -> E;
                    {ok, All} ->
                        case strict_prepare(Config, Driver, Conn, Table, Current, All, enforce) of
                            {error, _} = E -> E;
                            ok ->
                                Pending = pending_up(All, Current, Steps),
                                apply_up(Driver, Conn, Table, Pending, Logger, DryRun, Config)
                        end
                end
        end
    end).

%% Roll back all applied migrations.
-spec down(Config :: map()) -> ok | {error, term()}.
down(Config) -> down(Config, all).

%% Roll back N migrations (all = unlimited).
-spec down(Config :: map(), Steps :: pos_integer() | all) -> ok | {error, term()}.
down(Config, Steps) when Steps =:= all orelse (is_integer(Steps) andalso Steps > 0) ->
    DryRun = dry_run(Config),
    with_lock(Config, fun(Conn, Table, Logger, Driver) ->
        case check_dirty(Driver, Conn, Table) of
            {error, _} = E -> E;
            ok ->
                {ok, Current, _} = Driver:current_version(Conn, Table),
                case Current of
                    undefined -> ok;
                    _ ->
                        case erlang_migrate_source:scan(dir(Config)) of
                            {error, _} = E -> E;
                            {ok, All} ->
                                case strict_prepare(Config, Driver, Conn, Table, Current, All, init) of
                                    {error, _} = E -> E;
                                    ok ->
                                        ToRollback = pending_down(All, Current, Steps),
                                        apply_down(base_version_for(All, ToRollback),
                                            Driver, Conn, Table, ToRollback, Logger, DryRun, Config)
                                end
                        end
                end
        end
    end).

%% Migrate to a specific version (auto up or down).
-spec goto(Config :: map(), Version :: integer()) -> ok | {error, term()}.
goto(Config, Version) ->
    DryRun = dry_run(Config),
    with_lock(Config, fun(Conn, Table, Logger, Driver) ->
        case check_dirty(Driver, Conn, Table) of
            {error, _} = E -> E;
            ok ->
                {ok, Current, _} = Driver:current_version(Conn, Table),
                case erlang_migrate_source:scan(dir(Config)) of
                    {error, _} = E -> E;
                    {ok, All} ->
                        case strict_prepare(Config, Driver, Conn, Table, Current, All, init) of
                            {error, _} = SE -> SE;
                            ok ->
                                CurV = case Current of undefined -> 0; V -> V end,
                                %% Fix #15: use dropwhile/takewhile for O(range) traversal
                                %% instead of full-list comprehension with two maps:get per element.
                                if
                                    Version > CurV ->
                                        Pending = lists:takewhile(
                                            fun(M) -> maps:get(version, M) =< Version end,
                                            lists:dropwhile(fun(M) -> maps:get(version, M) =< CurV end, All)),
                                        apply_up(Driver, Conn, Table, Pending, Logger, DryRun, Config);
                                    Version < CurV ->
                                        Range = lists:takewhile(
                                            fun(M) -> maps:get(version, M) =< CurV end,
                                            lists:dropwhile(fun(M) -> maps:get(version, M) =< Version end, All)),
                                        apply_down(base_version_for(All, lists:reverse(Range)),
                                            Driver, Conn, Table, lists:reverse(Range), Logger, DryRun, Config);
                                    true ->
                                        ok
                                end
                        end
                end
        end
    end).

%% Return current schema version and dirty flag.
-spec version(Config :: map()) -> {ok, integer() | undefined, boolean()} | {error, term()}.
version(Config) ->
    Conn   = conn(Config),
    Table  = table(Config),
    Driver = driver(Config),
    case Driver:ensure_table(Conn, Table) of
        {error, _} = E -> E;
        ok ->
            case Driver:current_version(Conn, Table) of
                {ok, Ver, Dirty} -> {ok, Ver, Dirty};
                Err              -> Err
            end
    end.

%% Force set version (clears dirty flag — use after manual recovery).
%% Fix #6: validate Version exists in source files when 'dir' is configured.
%% Pass Version=undefined to clear the tracking table (reset to no migrations applied).
-spec force(Config :: map(), Version :: integer() | undefined) -> ok | {error, term()}.
force(Config, Version) ->
    Conn   = conn(Config),
    Table  = table(Config),
    Driver = driver(Config),
    case Driver:ensure_table(Conn, Table) of
        {error, _} = E -> E;
        ok ->
            case validate_force_version(Config, Version) of
                {error, _} = E -> E;
                ok ->
                    case Driver:set_version(Conn, Table, Version, false) of
                        ok -> strict_rebuild(Config, Driver, Conn, Table, Version);
                        {error, _} = E -> E
                    end
            end
    end.

validate_force_version(_Config, undefined) -> ok;
validate_force_version(Config, Version) when is_integer(Version) ->
    case maps:find(dir, Config) of
        error ->
            ok;  %% no dir configured — skip validation (backward-compatible)
        {ok, Dir} ->
            case erlang_migrate_source:scan(Dir) of
                {error, _} = E -> E;
                {ok, All} ->
                    Known = [maps:get(version, M) || M <- All],
                    case lists:member(Version, Known) of
                        true  -> ok;
                        false -> {error, {unknown_version, Version, Known}}
                    end
            end
    end.

%% Drop schema_migrations table (destructive — use in tests only).
-spec drop(Config :: map()) -> ok | {error, term()}.
drop(Config) ->
    Conn   = conn(Config),
    Table  = table(Config),
    Driver = driver(Config),
    case strict(Config) of
        false -> Driver:drop_table(Conn, Table);
        true ->
            case Driver:exec_sql(Conn, iolist_to_binary(
                     ["DROP TABLE IF EXISTS ", hist_table(Table)])) of
                ok             -> Driver:drop_table(Conn, Table);
                {error, _} = E -> E
            end
    end.

%% Generate a timestamped migration pair: {YYYYMMDDHHMMSS}_{Title}.up.sql/.down.sql.
%% Version is the current UTC time, so concurrent developers on different
%% machines get non-overlapping versions by construction. On a same-second
%% collision the version is bumped +1 until free.
-spec create(Dir :: file:filename(), Title :: iodata()) ->
    {ok, file:filename(), file:filename()} | {error, term()}.
create(Dir, Title0) ->
    case normalize_title(Title0) of
        {error, _} = E -> E;
        {ok, Title} ->
            case filelib:ensure_dir(filename:join(Dir, "any")) of
                {error, R} -> {error, {mkdir_failed, R}};
                ok ->
                    Version  = free_version(Dir, utc_version()),
                    Base     = integer_to_list(Version) ++ "_" ++ Title,
                    UpPath   = filename:join(Dir, Base ++ ".up.sql"),
                    DownPath = filename:join(Dir, Base ++ ".down.sql"),
                    case file:write_file(UpPath, sql_template(Base, "up")) of
                        {error, R} -> {error, {write_failed, UpPath, R}};
                        ok ->
                            case file:write_file(DownPath, sql_template(Base, "down")) of
                                {error, R} -> {error, {write_failed, DownPath, R}};
                                ok -> {ok, UpPath, DownPath}
                            end
                    end
            end
    end.

%%% Internal helpers

normalize_title(Title0) ->
    Title = unicode:characters_to_list(Title0),
    IsBad = fun(C) -> C =:= $/ orelse C =:= $\\ orelse C =:= 0 end,
    case is_list(Title) andalso Title =/= [] andalso not lists:any(IsBad, Title) of
        true  -> {ok, Title};
        false -> {error, {invalid_title, Title0}}
    end.

utc_version() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    (((Y * 100 + Mo) * 100 + D) * 100 + H) * 10000 + Mi * 100 + S.

%% Bump +1 until no existing file claims the version. A bumped value may not
%% be a real clock time (e.g. second 60) — only uniqueness and ordering matter.
free_version(Dir, V) ->
    case filelib:wildcard(filename:join(Dir, integer_to_list(V) ++ "_*.sql")) of
        [] -> V;
        _  -> free_version(Dir, V + 1)
    end.

sql_template(Base, Direction) ->
    unicode:characters_to_binary(
        ["-- ", Base, " (", Direction, ")\n",
         "-- Add ", Direction, " migration SQL here.\n"]).

with_lock(Config, Fun) ->
    Conn    = conn(Config),
    Table   = table(Config),
    LockId  = lock_id(Config, Table),
    Timeout = lock_timeout(Config),
    Logger  = logger(Config),
    Driver  = driver(Config),
    case Driver:ensure_table(Conn, Table) of
        {error, _} = E -> E;
        ok ->
            log(Logger, info, #{}, fmt("acquiring lock ~b (timeout ~bms)", [LockId, Timeout])),
            case Driver:lock(Conn, LockId, Timeout) of
                {error, lock_timeout} ->
                    log(Logger, error, #{}, fmt("lock timeout after ~bms", [Timeout])),
                    {error, lock_timeout};
                {error, _} = E ->
                    log(Logger, error, #{}, <<"lock acquisition failed">>),
                    E;
                ok ->
                    log(Logger, info, #{}, <<"lock acquired">>),
                    try Fun(Conn, Table, Logger, Driver)
                    after
                        Driver:unlock(Conn, LockId),
                        log(Logger, info, #{}, <<"lock released">>)
                    end
            end
    end.

check_dirty(Driver, Conn, Table) ->
    case Driver:is_dirty(Conn, Table) of
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

%% Fix #3 (GracefulStop): check own mailbox for an abort signal between migrations.
check_abort() ->
    receive
        erlang_migrate_abort -> {error, aborted}
    after 0 -> ok
    end.

apply_up(_Driver, _Conn, _Table, [], _Logger, _DryRun, _Config) -> ok;
apply_up(Driver, Conn, Table, [M | Rest], Logger, DryRun, Config) ->
    %% Fix #3: honour abort signal sent from another process
    case check_abort() of
        {error, aborted} -> {error, aborted};
        ok ->
            Version = maps:get(version, M),
            log(Logger, info, #{version => Version, title => maps:get(title, M)},
                fmt("applying up ~b ~ts", [Version, maps:get(title, M)])),
            case run_one_up(Driver, Conn, Table, Version, maps:get(up_file, M),
                            Logger, DryRun, Config) of
                ok ->
                    log(Logger, info, #{version => Version}, fmt("applied up ~b", [Version])),
                    apply_up(Driver, Conn, Table, Rest, Logger, DryRun, Config);
                {error, _} = E -> E
            end
    end.

run_one_up(Driver, Conn, Table, Version, UpFile, Logger, DryRun, Config) ->
    case erlang_migrate_source:read_sql(UpFile, up) of
        {error, _} = E -> E;
        {ok, SQL} ->
            %% Fix #12: dry_run skips exec_sql and set_version entirely
            if DryRun ->
                log(Logger, info, #{version => Version, dry_run => true},
                    fmt("[dry-run] would apply up ~b", [Version])),
                ok;
            true ->
                case Driver:set_version(Conn, Table, Version, true) of
                    {error, _} = E -> E;
                    ok ->
                        case Driver:exec_sql(Conn, SQL) of
                            {error, _} = E ->
                                log(Logger, error, #{version => Version},
                                    fmt("failed up ~b — dirty state set", [Version])),
                                E;
                            ok ->
                                %% Fix #2: retry set_version(false) on transient failures
                                case set_version_with_retry(Driver, Conn, Table, Version, false,
                                                            set_version_retries(Config),
                                                            set_version_retry_ms(Config),
                                                            Logger) of
                                    ok -> strict_record_up(Config, Driver, Conn, Table, Version);
                                    {error, _} = E -> E
                                end
                        end
                end
            end
    end.

%% partial-down-tracking：ToRollback 之外、紧邻其前的已应用迁移版本。
%% 此前 PrevVersion 从 Rest 内部推导——down(N) 滚完 N 份后 Rest 耗尽即 undefined，
%% driver 按约定清空整条升级历史，后续 up() 从第一版重放。
%% 正确语义：停在 ToRollback 之前的最近已应用版本；仅真回滚到空库才清空。
base_version_for(_All, []) ->
    undefined;
base_version_for(All, ToRollback) ->
    Lowest = lists:min([maps:get(version, M) || M <- ToRollback]),
    Below  = [maps:get(version, M) || M <- All, maps:get(version, M) < Lowest],
    case Below of
        []     -> undefined;
        Vers   -> lists:max(Vers)
    end.

apply_down(BaseVersion, Driver, Conn, Table, [], _Logger, _DryRun, _Config) -> ok;
%% BaseVersion：ToRollback 之外、紧邻其前的已应用迁移版本。
%% 修复（partial-down-tracking）：此前 PrevVersion 从 Rest 内部推导，
%% down(N) 滚完 N 份后 Rest 耗尽 → undefined → 清空整条升级历史，
%% 后续 up() 便从 00000001 重放。正确语义是停在 BaseVersion；
%% 仅当真的回滚到空库（BaseVersion=undefined）才清空跟踪表。
apply_down(BaseVersion, Driver, Conn, Table, [M | Rest], Logger, DryRun, Config) ->
    case check_abort() of
        {error, aborted} -> {error, aborted};
        ok ->
            Version  = maps:get(version, M),
            DownFile = maps:get(down_file, M),
            case DownFile of
                undefined -> {error, {no_down_migration, Version}};
                _ ->
                    log(Logger, info, #{version => Version, title => maps:get(title, M)},
                        fmt("applying down ~b ~ts", [Version, maps:get(title, M)])),
                    PrevVersion = case Rest of
                        []         -> BaseVersion;
                        [Next | _] -> maps:get(version, Next)
                    end,
                    case run_one_down(Driver, Conn, Table, Version, PrevVersion, DownFile,
                                     Logger, DryRun, Config) of
                        ok ->
                            log(Logger, info, #{version => Version}, fmt("applied down ~b", [Version])),
                            apply_down(BaseVersion, Driver, Conn, Table, Rest, Logger, DryRun, Config);
                        {error, _} = E -> E
                    end
            end
    end.

run_one_down(Driver, Conn, Table, Version, PrevVersion, DownFile, Logger, DryRun, Config) ->
    case erlang_migrate_source:read_sql(DownFile, down) of
        {error, _} = E -> E;
        {ok, SQL} ->
            if DryRun ->
                log(Logger, info, #{version => Version, dry_run => true},
                    fmt("[dry-run] would apply down ~b", [Version])),
                ok;
            true ->
                case Driver:set_version(Conn, Table, Version, true) of
                    {error, _} = E -> E;
                    ok ->
                        case Driver:exec_sql(Conn, SQL) of
                            {error, _} = E ->
                                log(Logger, error, #{version => Version},
                                    fmt("failed down ~b — dirty state set", [Version])),
                                E;
                            ok ->
                                case set_version_with_retry(Driver, Conn, Table, PrevVersion, false,
                                                            set_version_retries(Config),
                                                            set_version_retry_ms(Config),
                                                            Logger) of
                                    ok -> strict_record_down(Config, Driver, Conn, Table, Version);
                                    {error, _} = E -> E
                                end
                        end
                end
            end
    end.

%% Fix #2: retry set_version on transient failure, e.g. network flash after exec_sql succeeds.
set_version_with_retry(Driver, Conn, Table, Version, Dirty, 0, _RetryMs, _Logger) ->
    case Driver:set_version(Conn, Table, Version, Dirty) of
        ok           -> ok;
        {error, _} = E -> E
    end;
set_version_with_retry(Driver, Conn, Table, Version, Dirty, Retries, RetryMs, Logger) ->
    case Driver:set_version(Conn, Table, Version, Dirty) of
        ok -> ok;
        {error, _} ->
            log(Logger, warning, #{version => Version, retries_left => Retries},
                fmt("set_version retry (~b left) for ~b", [Retries, if Version =:= undefined -> 0; true -> Version end])),
            timer:sleep(RetryMs),
            set_version_with_retry(Driver, Conn, Table, Version, Dirty, Retries - 1, RetryMs, Logger)
    end.

conn(#{conn := C})   -> C.
table(#{table := T}) -> T;
table(_)             -> ?DEFAULT_TABLE.
dir(#{dir := D})     -> D.

dry_run(#{dry_run := true}) -> true;
dry_run(_)                  -> false.

set_version_retries(#{set_version_retries := N}) when is_integer(N), N >= 0 -> N;
set_version_retries(_) -> ?DEFAULT_SET_VERSION_RETRIES.

set_version_retry_ms(#{set_version_retry_ms := MS}) when is_integer(MS), MS >= 0 -> MS;
set_version_retry_ms(_) -> ?DEFAULT_SET_VERSION_RETRY_MS.

lock_id(#{lock_id := Id}, _) -> Id;
lock_id(_, Table)            -> erlang:phash2(Table, 1 bsl 30).

lock_timeout(#{lock_timeout := T}) when is_integer(T), T >= 0 -> T;
lock_timeout(_)                                                -> ?DEFAULT_LOCK_TIMEOUT.

logger(#{logger := F}) when is_function(F, 2) -> F;
logger(#{logger := F}) when is_function(F, 3) -> F;
logger(_)                                     -> undefined.

%% Fix #16: support both fun(Level, Msg) and fun(Level, Meta, Msg) loggers.
%% Meta is a map carrying structured context (version, title, dry_run, etc.).
log(undefined, _Level, _Meta, _Msg) -> ok;
log(Fun, Level, _Meta, Msg) when is_function(Fun, 2) -> Fun(Level, Msg);
log(Fun, Level, Meta, Msg)  when is_function(Fun, 3) -> Fun(Level, Meta, Msg).

%% Raises error/1 for bad driver config — these are programmer errors caught at startup.
driver(#{driver := D}) when is_atom(D) ->
    case code:which(D) of
        non_existing -> error({unknown_driver, D});
        _            -> D
    end;
driver(#{driver := D}) -> error({invalid_driver, D});
driver(_)              -> erlang_migrate_pg.

fmt(Fmt, Args) -> unicode:characters_to_binary(io_lib:format(Fmt, Args)).

%%% Strict mode (out-of-order detection)
%%
%% With strict => true, every applied migration is also recorded in
%% "<table>_history" (one row per version). strict_prepare/7 in `enforce'
%% mode (up only) fails when a file version =< current is absent from that
%% history; `init' mode (down/goto) just ensures and backfills the table.

strict(#{strict := true}) -> true;
strict(_)                 -> false.

strict_prepare(Config, Driver, Conn, Table, Current, All, Mode) ->
    case strict(Config) andalso not dry_run(Config) of
        false -> ok;
        true ->
            case erlang:function_exported(Driver, applied_versions, 2) of
                false -> {error, {strict_not_supported, Driver}};
                true  -> strict_prepare2(Driver, Conn, Table, Current, All, Mode)
            end
    end.

strict_prepare2(Driver, Conn, Table, Current, All, Mode) ->
    Hist = hist_table(Table),
    case ensure_history(Driver, Conn, Hist) of
        {error, _} = E -> E;
        ok ->
            case Driver:applied_versions(Conn, Hist) of
                {error, _} = E -> E;
                {ok, []} when Current =/= undefined ->
                    %% First strict run on an existing install: assume every
                    %% version =< current was applied and backfill the history.
                    Versions = [maps:get(version, M) || M <- All,
                                maps:get(version, M) =< Current],
                    insert_history(Driver, Conn, Hist, Versions);
                {ok, Applied} ->
                    case Mode of
                        init    -> ok;
                        enforce -> check_out_of_order(Applied, Current, All)
                    end
            end
    end.

ensure_history(Driver, Conn, Hist) ->
    %% Portable across PG / MySQL / SQLite.
    Driver:exec_sql(Conn, iolist_to_binary([
        "CREATE TABLE IF NOT EXISTS ", Hist, " (",
        "  version    BIGINT PRIMARY KEY,",
        "  applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP",
        ")"
    ])).

insert_history(_Driver, _Conn, _Hist, []) -> ok;
insert_history(Driver, Conn, Hist, Versions) ->
    Values = lists:join(",", [["(", integer_to_binary(V), ")"] || V <- Versions]),
    Driver:exec_sql(Conn, iolist_to_binary(
        ["INSERT INTO ", Hist, " (version) VALUES ", Values])).

check_out_of_order(_Applied, undefined, _All) -> ok;
check_out_of_order(Applied, Current, All) ->
    Missing = [V || M <- All,
                    V <- [maps:get(version, M)],
                    V =< Current,
                    not lists:member(V, Applied)],
    case Missing of
        [] -> ok;
        _  -> {error, {out_of_order, Missing}}
    end.

%% A history write failing after the migration itself succeeded surfaces as an
%% error; recovery is force/2, which rebuilds the history from source files.
strict_record_up(Config, Driver, Conn, Table, Version) ->
    case strict(Config) of
        false -> ok;
        true  -> insert_history(Driver, Conn, hist_table(Table), [Version])
    end.

strict_record_down(Config, Driver, Conn, Table, Version) ->
    case strict(Config) of
        false -> ok;
        true ->
            Driver:exec_sql(Conn, iolist_to_binary(
                ["DELETE FROM ", hist_table(Table),
                 " WHERE version = ", integer_to_binary(Version)]))
    end.

%% force/2 rebuilds the history to "all file versions =< Version".
strict_rebuild(Config, Driver, Conn, Table, Version) ->
    case strict(Config) andalso maps:is_key(dir, Config) of
        false -> ok;
        true ->
            Hist = hist_table(Table),
            case ensure_history(Driver, Conn, Hist) of
                {error, _} = E -> E;
                ok ->
                    case Driver:exec_sql(Conn, iolist_to_binary(["DELETE FROM ", Hist])) of
                        {error, _} = E -> E;
                        ok when Version =:= undefined -> ok;
                        ok ->
                            case erlang_migrate_source:scan(dir(Config)) of
                                {error, _} = E -> E;
                                {ok, All} ->
                                    Versions = [maps:get(version, M) || M <- All,
                                                maps:get(version, M) =< Version],
                                    insert_history(Driver, Conn, Hist, Versions)
                            end
                    end
            end
    end.

hist_table(Table) ->
    Bin = case Table of
        B when is_binary(B) -> B;
        L when is_list(L)   -> unicode:characters_to_binary(L)
    end,
    Hist = <<Bin/binary, "_history">>,
    case re:run(Hist, "^[a-zA-Z_][a-zA-Z0-9_]*(\\.[a-zA-Z_][a-zA-Z0-9_]*)?$",
                [{capture, none}]) of
        match   -> Hist;
        nomatch -> error({invalid_table_name, Hist})
    end.
