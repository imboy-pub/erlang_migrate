%% Tests for erlang_migrate:create/2 — timestamped migration file generation.
-module(erlang_migrate_create_tests).
-include_lib("eunit/include/eunit.hrl").

create_pair_test() ->
    Dir = mk_tmp_dir(),
    {ok, Up, Down} = erlang_migrate:create(Dir, "add_users"),
    true = filelib:is_regular(Up),
    true = filelib:is_regular(Down),
    {match, _} = re:run(filename:basename(Up), "^[0-9]{14}_add_users\\.up\\.sql$"),
    {match, _} = re:run(filename:basename(Down), "^[0-9]{14}_add_users\\.down\\.sql$"),
    %% Round-trip: the generated pair must be scannable.
    {ok, [M]} = erlang_migrate_source:scan(Dir),
    <<"add_users">> = maps:get(title, M),
    true = maps:get(down_file, M) =/= undefined,
    clean_dir(Dir).

create_collision_bumps_version_test() ->
    Dir = mk_tmp_dir(),
    {ok, Up1, _} = erlang_migrate:create(Dir, "first"),
    {ok, Up2, _} = erlang_migrate:create(Dir, "second"),
    ?assert(version_of(Up2) > version_of(Up1)),
    {ok, Migrations} = erlang_migrate_source:scan(Dir),
    2 = length(Migrations),
    clean_dir(Dir).

create_utf8_title_test() ->
    Dir = mk_tmp_dir(),
    {ok, Up, _} = erlang_migrate:create(Dir, "用户表"),
    true = filelib:is_regular(Up),
    {ok, [M]} = erlang_migrate_source:scan(Dir),
    <<"用户表"/utf8>> = maps:get(title, M),
    clean_dir(Dir).

create_rejects_bad_title_test() ->
    {error, {invalid_title, _}} = erlang_migrate:create("/tmp", ""),
    {error, {invalid_title, _}} = erlang_migrate:create("/tmp", "a/b"),
    {error, {invalid_title, _}} = erlang_migrate:create("/tmp", "a\\b").

%%% Helpers

version_of(Path) ->
    [VerStr | _] = string:split(filename:basename(Path), "_"),
    list_to_integer(VerStr).

mk_tmp_dir() ->
    Dir = "/tmp/erlang_migrate_create_test_"
        ++ integer_to_list(erlang:unique_integer([positive])),
    ok = file:make_dir(Dir),
    Dir.

clean_dir(Dir) ->
    {ok, Files} = file:list_dir(Dir),
    [file:delete(filename:join(Dir, F)) || F <- Files],
    file:del_dir(Dir).
