%% @doc Migration file source — scans directory for *.up.sql / *.down.sql pairs.
%% File naming convention: {version}_{title}.up.sql
%% version must be a positive integer (e.g. 1, 2, 100, 20240101120000)
-module(erlang_migrate_source).
-export([scan/1, read_sql/2]).

-type migration() :: #{version := integer(), title := binary(),
                       up_file := file:filename(), down_file := file:filename() | undefined}.
-export_type([migration/0]).

%% Scan dir for migrations, return sorted ascending list.
-spec scan(Dir :: file:filename()) -> {ok, [migration()]} | {error, term()}.
scan(Dir) ->
    case file:list_dir(Dir) of
        {error, Reason} -> {error, {dir_not_found, Dir, Reason}};
        {ok, Files} ->
            UpFiles = [F || F <- Files, is_up_file(F)],
            Migrations = lists:filtermap(fun(F) -> parse_up(Dir, F) end, UpFiles),
            Sorted = lists:sort(fun(A, B) ->
                maps:get(version, A) =< maps:get(version, B)
            end, Migrations),
            check_duplicates(Sorted)
    end.

%% Read SQL content from file.
-spec read_sql(File :: file:filename(), Direction :: up | down) ->
    {ok, binary()} | {error, term()}.
read_sql(File, _Direction) ->
    case file:read_file(File) of
        {ok, Bin} -> {ok, Bin};
        {error, Reason} -> {error, {read_failed, File, Reason}}
    end.

%%% Internal

is_up_file(F) -> lists:suffix(".up.sql", F).

parse_up(Dir, UpFilename) ->
    Base = filename:rootname(filename:rootname(UpFilename)),  % strip .up.sql
    case parse_version_title(Base) of
        {error, _} -> false;
        {Version, Title} ->
            UpFile = filename:join(Dir, UpFilename),
            DownFilename = Base ++ ".down.sql",
            DownFile = filename:join(Dir, DownFilename),
            DownOrUndef = case filelib:is_regular(DownFile) of
                true  -> DownFile;
                false -> undefined
            end,
            {true, #{version => Version, title => Title,
                     up_file => UpFile, down_file => DownOrUndef}}
    end.

parse_version_title(Base) ->
    case string:split(Base, "_", leading) of
        [VerStr, Rest] ->
            case string:to_integer(VerStr) of
                {V, []} when V > 0 -> {V, unicode:characters_to_binary(Rest)};
                _ -> {error, bad_version}
            end;
        _ -> {error, bad_format}
    end.

check_duplicates([]) -> {ok, []};
check_duplicates(Sorted) ->
    Versions = [maps:get(version, M) || M <- Sorted],
    case length(Versions) =:= length(lists:usort(Versions)) of
        true  -> {ok, Sorted};
        false -> {error, duplicate_versions}
    end.
