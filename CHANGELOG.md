# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
