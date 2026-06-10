-module(erlang_migrate_source_tests).
-include_lib("eunit/include/eunit.hrl").

scan_empty_dir_test() ->
    Dir = mk_tmp_dir(),
    {ok, []} = erlang_migrate_source:scan(Dir),
    clean_dir(Dir).

scan_nonexistent_dir_test() ->
    {error, {dir_not_found, _, _}} = erlang_migrate_source:scan("/nonexistent/path/xyz").

scan_sorted_test() ->
    Dir = mk_tmp_dir(),
    write_file(Dir, "3_third.up.sql", "SELECT 3"),
    write_file(Dir, "1_first.up.sql", "SELECT 1"),
    write_file(Dir, "2_second.up.sql", "SELECT 2"),
    {ok, Migrations} = erlang_migrate_source:scan(Dir),
    [1, 2, 3] = [maps:get(version, M) || M <- Migrations],
    clean_dir(Dir).

scan_finds_down_file_test() ->
    Dir = mk_tmp_dir(),
    write_file(Dir, "1_init.up.sql", "CREATE TABLE t (id int)"),
    write_file(Dir, "1_init.down.sql", "DROP TABLE t"),
    {ok, [M]} = erlang_migrate_source:scan(Dir),
    true = is_list(maps:get(down_file, M)),
    clean_dir(Dir).

scan_no_down_file_test() ->
    Dir = mk_tmp_dir(),
    write_file(Dir, "1_init.up.sql", "CREATE TABLE t (id int)"),
    {ok, [M]} = erlang_migrate_source:scan(Dir),
    undefined = maps:get(down_file, M),
    clean_dir(Dir).

duplicate_versions_test() ->
    Dir = mk_tmp_dir(),
    write_file(Dir, "1_first.up.sql", "SELECT 1"),
    write_file(Dir, "1_second.up.sql", "SELECT 2"),
    {error, duplicate_versions} = erlang_migrate_source:scan(Dir),
    clean_dir(Dir).

parse_title_test() ->
    Dir = mk_tmp_dir(),
    write_file(Dir, "00000001_create_users.up.sql", "SELECT 1"),
    {ok, [M]} = erlang_migrate_source:scan(Dir),
    1 = maps:get(version, M),
    <<"create_users">> = maps:get(title, M),
    clean_dir(Dir).

utf8_title_test() ->
    Dir = mk_tmp_dir(),
    Name = unicode:characters_to_list("20240101120000_用户表.up.sql"),
    write_file(Dir, Name, "SELECT 1"),
    {ok, [M]} = erlang_migrate_source:scan(Dir),
    20240101120000 = maps:get(version, M),
    <<"用户表"/utf8>> = maps:get(title, M),
    clean_dir(Dir).

%%% Helpers
mk_tmp_dir() ->
    Dir = "/tmp/erlang_migrate_test_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = file:make_dir(Dir),
    Dir.

write_file(Dir, Name, Content) ->
    ok = file:write_file(filename:join(Dir, Name), Content).

clean_dir(Dir) ->
    {ok, Files} = file:list_dir(Dir),
    [file:delete(filename:join(Dir, F)) || F <- Files],
    file:del_dir(Dir).
