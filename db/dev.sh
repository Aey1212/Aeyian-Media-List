#!/usr/bin/env bash
# Local development database for AML: PostgreSQL 16 in a container, data kept in
# a named volume between runs, reachable on 127.0.0.1 only.
#
#   db/dev.sh up            start it (creating it the first time) and apply pending migrations
#   db/dev.sh down          stop it; the data is kept
#   db/dev.sh status        show whether it runs and which migrations are applied
#   db/dev.sh psql          open psql on the dev database
#   db/dev.sh seed          load the files in db/seed/ that are not loaded yet (.sql, or .py run with the repo's .venv)
#   db/dev.sh reset --yes   delete the dev database and its data
#
#   CONTAINER=docker db/dev.sh up    use docker instead of podman
#   AML_DEV_PORT=55433 db/dev.sh up  use another local port (default 55432)
#
# Local use only: the database trusts every connection that reaches it, and it
# only listens on 127.0.0.1.
set -euo pipefail
cd "$(dirname "$0")"

cli="${CONTAINER:-podman}"
image="docker.io/library/postgres:16-alpine"
name="aml-dev"
volume="aml-dev-pgdata"
port="${AML_DEV_PORT:-55432}"

pg() { "$cli" exec -i "$name" psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U aml -d aml "$@"; }
exists() { "$cli" inspect "$name" >/dev/null 2>&1; }
running() { [ "$("$cli" inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = "true" ]; }

wait_ready() {
  # The image's first-start init server listens on the socket only; TCP answers
  # once the real server is up.
  for _ in $(seq 600); do
    if "$cli" exec "$name" pg_isready -q -h 127.0.0.1 -U aml >/dev/null 2>&1; then return 0; fi
  done
  echo "postgres did not become ready" >&2
  return 1
}

up() {
  if ! exists; then
    "$cli" run -d --name "$name" \
      -e POSTGRES_USER=aml -e POSTGRES_DB=aml -e POSTGRES_HOST_AUTH_METHOD=trust \
      -p "127.0.0.1:${port}:5432" \
      -v "${volume}:/var/lib/postgresql/data" \
      "$image" >/dev/null
  elif ! running; then
    "$cli" start "$name" >/dev/null
  fi
  wait_ready

  pg -c "SET client_min_messages = warning;
         CREATE TABLE IF NOT EXISTS public.aml_migration (
           name       text PRIMARY KEY,
           applied_at timestamptz NOT NULL DEFAULT now()
         )" >/dev/null

  local m n applied=0
  for m in migrations/*.sql; do
    n="$(basename "$m")"
    if [ "$(pg -At -c "SELECT count(*) FROM public.aml_migration WHERE name = '${n}'")" = "0" ]; then
      pg < "$m" >/dev/null
      pg -c "INSERT INTO public.aml_migration (name) VALUES ('${n}')" >/dev/null
      echo "applied ${n}"
      applied=$((applied + 1))
    fi
  done
  [ "$applied" -eq 0 ] && echo "no pending migrations"
  echo "dev database up: postgresql://aml@127.0.0.1:${port}/aml"
}

down() {
  if running; then "$cli" stop "$name" >/dev/null; fi
  echo "dev database stopped (data kept)"
}

status() {
  if ! exists; then echo "dev database: not created"; return 0; fi
  if ! running; then echo "dev database: stopped"; return 0; fi
  echo "dev database: running on 127.0.0.1:${port}"
  pg -At -c "SELECT name || '  ' || to_char(applied_at, 'YYYY/MM/DD HH24:MI') FROM public.aml_migration ORDER BY name"
}

seed() {
  if ! running; then echo "dev database is not running: db/dev.sh up" >&2; return 1; fi
  pg -c "SET client_min_messages = warning;
         CREATE TABLE IF NOT EXISTS public.aml_seed (
           name       text PRIMARY KEY,
           applied_at timestamptz NOT NULL DEFAULT now()
         )" >/dev/null

  local s n loaded=0
  for s in seed/*; do   # in file name order, whatever the type
    case "$s" in *.sql|*.py) ;; *) continue ;; esac
    n="$(basename "$s")"
    [ "$(pg -At -c "SELECT count(*) FROM public.aml_seed WHERE name = '${n}'")" = "0" ] || continue
    case "$s" in
      *.sql) pg < "$s" >/dev/null ;;
      # Python seeds write files as well as rows (pictures into the media folder).
      *.py)
        if [ ! -x ../.venv/bin/python ]; then echo "no .venv in the repo: run uv sync first" >&2; return 1; fi
        (cd .. && PYTHONPATH=. AML_DATABASE_URL="postgresql://aml@127.0.0.1:${port}/aml" .venv/bin/python "db/$s") ;;
    esac
    pg -c "INSERT INTO public.aml_seed (name) VALUES ('${n}')" >/dev/null
    echo "seeded ${n}"
    loaded=$((loaded + 1))
  done
  [ "$loaded" -eq 0 ] && echo "no seed files left to load"
  return 0
}

reset() {
  if [ "${1:-}" != "--yes" ]; then
    echo "This deletes the dev database and all its data. Run: db/dev.sh reset --yes" >&2
    return 1
  fi
  if exists; then "$cli" rm -f "$name" >/dev/null; fi
  "$cli" volume rm -f "$volume" >/dev/null 2>&1 || true
  echo "dev database deleted"
}

case "${1:-}" in
  up)     up ;;
  down)   down ;;
  status) status ;;
  psql)   "$cli" exec -it "$name" psql -X -h 127.0.0.1 -U aml -d aml ;;
  seed)   seed ;;
  reset)  shift; reset "$@" ;;
  *)      sed -n '2,16p' "$(basename "$0")" | sed 's/^# \{0,1\}//'; exit 1 ;;   # already cd'd into db/
esac
