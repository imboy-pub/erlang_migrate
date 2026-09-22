#!/bin/sh
# Run the full erlang_migrate integration suite against disposable
# PostgreSQL + MySQL containers (SQLite runs inside the suite already).
#
#   sh test/integration/run.sh
#
# Requires: docker, rebar3. Exits non-zero if any test fails.
set -e
cd "$(dirname "$0")/../.."   # repo root

echo "==> starting disposable postgres/mysql containers"
docker compose -f test/integration/docker-compose.yml up -d --wait

cleanup() {
  docker compose -f test/integration/docker-compose.yml down -v
}
trap cleanup EXIT

echo "==> running integration suites"
EM_PG_HOST=localhost EM_PG_PORT=5433 EM_PG_USER=em EM_PG_PASSWORD=em EM_PG_DB=em_bootstrap \
EM_MYSQL_HOST=127.0.0.1 EM_MYSQL_PORT=3307 EM_MYSQL_USER=root EM_MYSQL_PASSWORD=em EM_MYSQL_DB=em_it \
rebar3 as test eunit
EM_SQLITE_IT=1 rebar3 as test eunit --module=erlang_migrate_sqlite_integration_it

echo "==> integration suites passed"
