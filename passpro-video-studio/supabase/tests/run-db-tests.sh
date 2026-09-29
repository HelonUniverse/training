#!/usr/bin/env bash
# Creates a THROWAWAY local Postgres cluster, applies the PassPro stub
# baseline, every migration (twice from scratch, to prove recreatability),
# the seeds (twice, to prove idempotency) and the SQL assertions.
# It never connects to Supabase.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
WORK="$(mktemp -d)"
PORT="${VS_TEST_PGPORT:-54329}"
RUN_AS=()
if [ "$(id -u)" = "0" ]; then
  chown -R postgres "$WORK"
  RUN_AS=(runuser -u postgres --)
fi

cleanup() {
  "${RUN_AS[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

"${RUN_AS[@]}" "$PGBIN/initdb" -D "$WORK/data" -A trust -U postgres >/dev/null
"${RUN_AS[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" -o "-p $PORT -k $WORK -c listen_addresses=''" -l "$WORK/log" start >/dev/null

PSQL=(psql -h "$WORK" -p "$PORT" -U postgres -v ON_ERROR_STOP=1 -q -X)

build_db() {
  local db="$1"
  "${PSQL[@]}" -d postgres -c "drop database if exists $db" -c "create database $db"
  "${PSQL[@]}" -d "$db" -f "$HERE/00_stub_passpro_baseline.sql"
  for f in "$ROOT"/supabase/migrations/*.sql; do
    "${PSQL[@]}" -d "$db" -f "$f"
  done
  for f in "$ROOT"/supabase/seed/*.sql; do
    "${PSQL[@]}" -d "$db" -f "$f"
    "${PSQL[@]}" -d "$db" -f "$f"   # seeds must be idempotent
  done
}

echo "▸ build #1 (fresh)";   build_db vs_test
echo "▸ build #2 (recreate from migrations)"; build_db vs_test
echo "▸ assertions"
"${PSQL[@]}" -d vs_test -o /dev/null -f "$HERE/10_assertions.sql"
echo "✔ database tests passed"
