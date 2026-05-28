%% @doc Behaviour definition for erlang_migrate database drivers.
%% Implement all callbacks to add support for a new database.
-module(erlang_migrate_driver).

%% Create or verify the schema_migrations tracking table.
-callback ensure_table(Conn :: term(), Table :: binary()) ->
    ok | {error, term()}.

%% Return {ok, Version, Dirty} for the highest applied version, or {ok, undefined, false}.
-callback current_version(Conn :: term(), Table :: binary()) ->
    {ok, integer() | undefined, boolean()} | {error, term()}.

%% Acquire an exclusive advisory lock. Timeout in milliseconds.
-callback lock(Conn :: term(), LockId :: integer(), TimeoutMs :: integer()) ->
    ok | {error, lock_timeout} | {error, term()}.

%% Release the advisory lock acquired by lock/3.
-callback unlock(Conn :: term(), LockId :: integer()) -> ok.

%% Replace the single tracking row (DELETE + INSERT).
%% Version = undefined means DELETE only (no migrations applied).
-callback set_version(Conn :: term(), Table :: binary(),
                      Version :: integer() | undefined, Dirty :: boolean()) ->
    ok | {error, term()}.

%% Return {ok, true|false} indicating whether the current version row is dirty.
-callback is_dirty(Conn :: term(), Table :: binary()) ->
    {ok, boolean()} | {error, term()}.

%% Execute arbitrary SQL (migration file content or internal housekeeping).
-callback exec_sql(Conn :: term(), SQL :: binary()) ->
    ok | {error, term()}.

%% Drop the schema_migrations tracking table.
-callback drop_table(Conn :: term(), Table :: binary()) ->
    ok | {error, term()}.
