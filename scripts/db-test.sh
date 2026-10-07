#!/usr/bin/env bash
# Docker olmadan veritabanı testleri: geçici bir PostgreSQL kümesi açar,
# Supabase taklit katmanını ve tüm migration'ları uygular, pgTAP testlerini ve
# eşzamanlılık testini koşar, sonunda kümeyi siler.
#
# Gerekenler: PostgreSQL 16 sunucu ikilileri, pgTAP (pg_prove), pg_cron, pgmq.
# Debian/Ubuntu: apt-get install postgresql-16 postgresql-16-pgtap postgresql-16-cron
# pgmq paketi yoksa betik saf SQL sürümünü kurmayı dener (bkz. install_pgmq).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS="$ROOT/backend/supabase/migrations"
TESTS="$ROOT/backend/supabase/tests/database"
PGMQ_VERSION="1.4.4"

PG_BIN="${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
if [[ -z "$PG_BIN" || ! -x "$PG_BIN/initdb" ]]; then
  echo "PostgreSQL sunucu ikilileri bulunamadı (PG_BIN ayarlayın)." >&2
  exit 1
fi

install_pgmq() {
  local ext_dir
  ext_dir="$("$PG_BIN/pg_config" --sharedir)/extension"
  [[ -f "$ext_dir/pgmq.control" ]] && return 0
  echo "pgmq $PGMQ_VERSION kuruluyor (saf SQL)..."
  local base="https://raw.githubusercontent.com/pgmq/pgmq/v$PGMQ_VERSION/pgmq-extension"
  curl -fsSL "$base/sql/pgmq.sql" -o "$ext_dir/pgmq--$PGMQ_VERSION.sql"
  curl -fsSL "$base/pgmq.control" | grep -v module_pathname > "$ext_dir/pgmq.control"
}
install_pgmq

# initdb root olarak çalışmaz; root isek postgres kullanıcısıyla çalıştır.
run_pg() {
  if [[ "$(id -u)" == "0" ]]; then
    runuser -u postgres -- "$@"
  else
    "$@"
  fi
}

WORK="$(mktemp -d)"
chmod 777 "$WORK"
PORT="${PGPORT_TEST:-54329}"
cleanup() {
  run_pg "$PG_BIN/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

run_pg "$PG_BIN/initdb" -D "$WORK/data" -U postgres --auth=trust >/dev/null
cat >> "$WORK/data/postgresql.conf" <<EOF
port = $PORT
listen_addresses = ''
unix_socket_directories = '$WORK'
shared_preload_libraries = 'pg_cron'
cron.database_name = 'postgres'
EOF
run_pg "$PG_BIN/pg_ctl" -D "$WORK/data" -l "$WORK/pg.log" -w start >/dev/null

export PGHOST="$WORK" PGPORT="$PORT" PGUSER=postgres PGDATABASE=postgres
PSQL=(psql -X -q -v ON_ERROR_STOP=1)

echo "== Supabase taklit katmanı"
"${PSQL[@]}" -f "$ROOT/scripts/sql/supabase_shim.sql"

echo "== Migration'lar"
for f in "$MIGRATIONS"/*.sql; do
  echo "   $(basename "$f")"
  "${PSQL[@]}" -f "$f" >/dev/null
done

echo "== pgTAP testleri"
"${PSQL[@]}" -c "create extension if not exists pgtap with schema extensions;"
PGOPTIONS="-c search_path=public,extensions" pg_prove --ext .sql -r "$TESTS"

echo "== Eşzamanlılık testi"
"$ROOT/scripts/concurrency-test.sh"

echo "Tüm veritabanı testleri geçti."
