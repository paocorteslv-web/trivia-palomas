#!/usr/bin/env bash
# Crea un Postgres temporal desde cero, carga supabase_stub.sql + schema.sql (dos veces: debe ser re-ejecutable) y corre los tests.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
PGBIN=${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}
[ -x "$PGBIN/initdb" ] || { echo "No hay Postgres local (initdb). Instalá postgresql o definí PGBIN."; exit 2; }
TMP=$(mktemp -d); PORT=${PORT:-54329}
RUNAS=(); [ "$(id -u)" = 0 ] && { chown -R postgres "$TMP"; RUNAS=(su postgres -s /bin/bash -c); }
pgdo(){ if [ ${#RUNAS[@]} -gt 0 ]; then "${RUNAS[@]}" "$*"; else bash -c "$*"; fi; }
cleanup(){ pgdo "$PGBIN/pg_ctl -D $TMP/data -m immediate stop" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT
pgdo "$PGBIN/initdb -D $TMP/data -A trust -U postgres --locale=C.UTF-8 -E UTF8" >/dev/null
pgdo "$PGBIN/pg_ctl -D $TMP/data -o '-p $PORT -k $TMP -c listen_addresses=' -l $TMP/log -w start" >/dev/null
PSQL=(psql -h "$TMP" -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1)
"${PSQL[@]}" -c "create database carrito" >/dev/null
DB=("${PSQL[@]}" -d carrito)
"${DB[@]}" -f "$HERE/supabase_stub.sql" >/dev/null
PGOPTIONS="-c client_min_messages=warning" "${DB[@]}" -f "$ROOT/schema.sql" >/dev/null && echo "✔ schema.sql inicializa una base vacía"
PGOPTIONS="-c client_min_messages=warning" "${DB[@]}" -f "$ROOT/schema.sql" >/dev/null && echo "✔ schema.sql se puede volver a ejecutar"
"${DB[@]}" -o /dev/null -f "$HERE/test_schema.sql" 2>&1 | sed 's/^psql:[^ ]* NOTICE:  /  /;s/^NOTICE:  /  /'
# G) concurrencia real: dos sesiones abren la caja del mismo día a la vez; solo una puede
"${DB[@]}" -c "delete from records where kind in('aperturas','cierres') and date=mza_today()-3" >/dev/null
OPEN="begin; set role authenticated; select t.login('admin@x');
 insert into records(kind,id,date,data) values('aperturas',(mza_today()-3)::text,mza_today()-3,'{\"open\":1}'); select pg_sleep(1); commit;"
for i in 1 2; do ( if "${DB[@]}" -c "$OPEN" >"$TMP/a$i" 2>&1; then echo 0; else echo 1; fi >"$TMP/s$i" ) & done; wait
N=$("${DB[@]}" -At -c "select count(*) from records where kind='aperturas' and date=mza_today()-3")
if [ "$N" = 1 ] && [ "$(cat "$TMP/s1")$(cat "$TMP/s2")" != 00 ] && grep -q "duplicate key" "$TMP/a1" "$TMP/a2"; then
  echo "  ✔ G aperturas simultáneas (2 sesiones): solo una queda"
else echo "✘ G concurrencia: $N aperturas"; cat "$TMP/a1" "$TMP/a2"; exit 1; fi
