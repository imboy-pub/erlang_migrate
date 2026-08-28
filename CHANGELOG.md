# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.2] - 2026-08-28

### Fixed

- `down(Config, N)` and `goto(Config, Version)` now retain the correct target
  version after a partial rollback. Previously, rolling back exactly the selected
  range could clear migration tracking and cause a later `up/1` to replay the
  full history.

## [0.3.1] - 2026-06-10

### Fixed

- edoc: module header used raw `=<` and `<table>` which the edoc XML parser rejects, breaking `rebar3 edoc` / hex doc generation.

## [0.3.0] - 2026-06-10

### Added

- **Strict mode** (`strict => true`): records every applied migration in a `<table>_history` table and fails `up/1,2` with `{error, {out_of_order, Versions}}` when a file version `=<` current was never applied — closes the silent-skip gap of timestamp versioning with multiple developers. First run backfills history; `force/2` rebuilds it; `drop/1` drops it; `dry_run` bypasses it.
- New optional driver callback `applied_versions/2`; implemented in the PG, MySQL and SQLite drivers.
- `create/2`: generate a `{utc_timestamp}_{title}.up/.down.sql` pair (UTC `YYYYMMDDHHMMSS` version, +1 bump on same-second collision, UTF-8 titles supported).
- CLI escript `erlang_migrate_cli` (`rebar3 escriptize`): `new <title> [dir]` — file generation only, keeping the zero-dependency design.

### Fixed

- UTF-8: `erlang_migrate_source` crashed (`badarg`) on non-Latin1 migration titles (`list_to_binary` → `unicode:characters_to_binary`); core log lines used `~s` instead of `~ts`, mojibaking UTF-8 titles.

## [0.2.3] - 2026-06-06

### Fixed

- `set_version` (all drivers): wrap DELETE+UPSERT in a single transaction to prevent partial state on process crash (#1)
- `run_one_up`/`run_one_down`: retry `set_version(false)` on transient failure after `exec_sql` succeeds — configurable via `set_version_retries` and `set_version_retry_ms` (#2)
- `exec_sql` (MySQL, SQLite): wrap in `BEGIN`/`COMMIT`/`ROLLBACK` — was unprotected, PG already had it (#5)
- `force/2`: validate that the requested version exists in source files when `dir` is configured; rejects phantom versions like `999999` (#6)
- Table name regex: allow schema-qualified names (`public.schema_migrations`) in all three drivers (#11)

### Added

- **GracefulStop**: send `erlang_migrate_abort` to the migration process to abort between migrations (`MigPid ! erlang_migrate_abort`) (#3)
- **dry_run mode**: set `dry_run => true` in Config to log what would be applied without touching the database (#14)
- **Structured logging**: logger callback now supports `fun(Level, Meta, Msg)` (3-arity) in addition to the existing `fun(Level, Msg)` — `Meta` is a map carrying `version`, `title`, `dry_run`, etc. (#16)
- Log "applied up N" / "applied down N" on success for each migration (#16)
- `goto/2`: use `dropwhile`/`takewhile` for O(range) traversal instead of full-list comprehension (#15)

### Tests

- 95 EUnit tests (was 57), 0 failures; 38 new tests covering all fixes above

## [0.2.2] - 2026-05-28

### Fixed

- `exec_sql` (PG): replace broken SAVEPOINT approach with `BEGIN`/`COMMIT`/`ROLLBACK`
- `set_version` (all drivers): replace non-atomic DELETE+INSERT with upsert (PG: `ON CONFLICT DO UPDATE`, MySQL: `REPLACE INTO`, SQLite: `INSERT OR REPLACE`)
- `apply_up`/`apply_down`/`version`/`force`: replace `ok = Driver:...` badmatch patterns with `case` expressions for proper `{error, _}` propagation
- Table name injection: add `validate_table_name/1` whitelist (`^[a-zA-Z_][a-zA-Z0-9_]*$`) in all three drivers
- `driver/1`: validate driver module is loaded via `code:which/1` before use
- Remove dead code: `clear_dirty/2` export and function body removed from `erlang_migrate_pg`
- Fix `current_version/2` edoc: correct return type to `{ok, Version, Dirty}`
- README: fix PostgreSQL minimum version (`18+` → `10+`), sync install example versions to `0.2.2`, fix epgsql version to `4.8.0`, correct Migration history table description

### Refactored

- Extract `run_one_up/6` and `run_one_down/7` to reduce `apply_up`/`apply_down` nesting from 5 to 1 level

## [0.2.1] - 2026-05-28

### Fixed

- Fix edoc module header: use backtick+single-quote syntax (dir') instead of double backtick to resolve doc chunk generation error

## [0.2.0] - 2026-05-28

### Added

- Multi-database support via `driver` config key (defaults to `erlang_migrate_pg`)
- `erlang_migrate_mysql` — MySQL 8+ driver using `mysql-otp`, `GET_LOCK` advisory lock
- `erlang_migrate_sqlite` — SQLite 3+ driver using `esqlite`, OTP `global:set_lock`
- `erlang_migrate_driver` behaviour — implement all 8 callbacks to add a new database
- `down/1` — roll back all applied migrations
- `goto/2` — jump to any version (auto up or down)
- `version/1` now returns `{ok, Version, Dirty}` (was `{ok, Version}`)
- `lock_timeout` config key — advisory lock wait timeout in ms (default 15 000)
- `logger` config key — optional `fun(Level, Msg) -> ok` callback
- 33 EUnit tests for core logic + 24 tests for MySQL/SQLite drivers (57 total)

### Changed

- **Single-row tracking table** — aligned with golang-migrate: `set_version` is now
  `DELETE + INSERT` so the table always holds at most one row; `force/2` is correct
  with no stale dirty rows
- Zero hard dependencies — `epgsql`, `mysql`, `esqlite` are all opt-in; add only
  the driver you use to your own `rebar.config`
- `table` config key — customise the tracking table name without touching
  `erlang_migrate` source

### Fixed

- `force/2` stale-dirty-row bug (multi-row model left dirty rows that `force` could
  not clear; single-row model eliminates the issue)
- `erlang:phash2` range — was `16#7FFFFFFFFFFFFFFF` (too large); now `1 bsl 30`

## [0.1.0] - 2026-05-28

### Added

- Initial release
- Plain SQL migration files (`.up.sql` / `.down.sql` pairs)
- Sequential integer versioning (`000001_title.up.sql`)
- Migration state stored in `schema_migrations` table in the target PostgreSQL database
- PostgreSQL advisory lock — safe for concurrent multi-node Erlang clusters
- Dirty state machine — blocks further runs after partial failure
- `force/2` to recover from dirty state
- `up/1`, `up/2` — apply all or N pending migrations
- `down/2` — roll back N applied migrations
- `version/1` — query current version
- `drop/1` — drop the `schema_migrations` table
- Minimal dependencies: only `epgsql`
- 7 EUnit tests for file scanner (`erlang_migrate_source`)
