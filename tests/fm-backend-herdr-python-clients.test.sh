#!/usr/bin/env bash
# tests/fm-backend-herdr-python-clients.test.sh - runs the Herdr Python client
# unit tests (tests/fm-backend-herdr-*.test.py) against stub Unix socket servers,
# with no Herdr involved. bin/fm-test-run.sh discovers only tests/*.test.sh, so
# this script is the one place that makes those unittest files run in a lane.
# Skips cleanly when python3 is missing, as the clients themselves need it.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the Herdr socket clients)"; exit 0; }

status=0
ran=0
for test_file in "$ROOT"/tests/fm-backend-herdr-*.test.py; do
  [ -f "$test_file" ] || continue
  ran=$((ran + 1))
  if python3 "$test_file"; then
    printf 'ok - %s\n' "${test_file#"$ROOT"/}"
  else
    printf 'not ok - %s\n' "${test_file#"$ROOT"/}" >&2
    status=1
  fi
done
if [ "$ran" -eq 0 ]; then
  printf 'not ok - no tests/fm-backend-herdr-*.test.py files found\n' >&2
  exit 1
fi
exit "$status"
