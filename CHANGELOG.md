# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
