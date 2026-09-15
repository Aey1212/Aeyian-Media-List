#!/usr/bin/env bash
# Runs every db/tests/*.sql against a throwaway PostgreSQL 16 container.
# Each test file NNNN_*.sql gets a fresh database with migrations 0001..NNNN applied,
# so every layer is tested against the schema as it stood when that layer landed.
#
#   db/test.sh                  uses podman
#   CONTAINER=docker db/test.sh uses docker
set -euo pipefail
cd "$(dirname "$0")"

cli="${CONTAINER:-podman}"
image="docker.io/library/postgres:16-alpine"
name="aml-test-$$"

"$cli" run -d --rm --name "$name" -e POSTGRES_HOST_AUTH_METHOD=trust "$image" >/dev/null
trap '"$cli" stop "$name" >/dev/null 2>&1 || true' EXIT

pg() { "$cli" exec -i "$name" psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres "$@"; }

# The image's init server listens on the socket only; TCP answers once the real server is up.
ready=0
for _ in $(seq 600); do
  if "$cli" exec "$name" pg_isready -q -h 127.0.0.1 -U postgres >/dev/null 2>&1; then ready=1; break; fi
done
[ "$ready" -eq 1 ] || { echo "postgres did not become ready" >&2; exit 1; }

pass=0; fail=0; status=0
for t in tests/*.sql; do
  echo "== $(basename "$t")"
  pg -d postgres -c 'DROP DATABASE IF EXISTS aml_test' -c 'CREATE DATABASE aml_test' >/dev/null
  n=$(basename "$t" | cut -d_ -f1)
  applied=()
  for m in migrations/*.sql; do
    [[ "$(basename "$m" | cut -d_ -f1)" > "$n" ]] && continue
    pg -d aml_test < "$m" >/dev/null || { echo "migration $(basename "$m") failed" >&2; exit 1; }
    applied+=("$(basename "$m" | cut -d_ -f1)")
  done
  echo "   migrations: ${applied[*]}"
  if ! out=$(pg -d aml_test -At < "$t" 2>&1); then status=1; fi
  printf '%s\n' "$out"
  p=$(grep -c '^PASS' <<<"$out" || true); f=$(grep -c '^FAIL' <<<"$out" || true)
  pass=$((pass + p)); fail=$((fail + f))
done

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ] && [ "$status" -eq 0 ]
