#!/usr/bin/env bash
# Serialize FULL test-gate runs across this home's task worktrees, with no
# firstmate in the loop: a worker takes the queue itself and releases it itself.
# One machine sustains one full gate run; two at once starve each other for
# memory, and on 2026-09-08 such a pair cost an hour when the system killed one
# of them halfway through its browser half.
# The queue covers FULL runs and deliberately NOT visual inspections: measured
# on 2026-09-08, one full run plus one inspection held free memory flat at 4 GB
# across three samples with no swap growth. Widening it to inspections would
# halve parallelism against a hazard that was measured not to exist; widen it
# only on a new measurement.
# Usage: fm-gate.sh acquire <id> [--wait]   0 = the queue is yours, 1 = busy (prints the holder)
#        fm-gate.sh release <id>            release your own hold; another task's hold is refused
#        fm-gate.sh status                  print the current holder
#   acquire is atomic (mkdir), so two workers racing it cannot both win; a real
#   race of twenty contenders produced exactly one winner.
#   Before handing the queue out, acquire also looks at the RESOURCE and not only
#   at the permit: if a full run is already live in another task's worktree, the
#   queue is refused even though the hold is free. A permit-counting guard only
#   ever meets the worker who politely asked, and on 2026-09-08 a worker who
#   released the hold and then ran the browser half on a neighbouring lane broke
#   nothing and still put a second full run on the machine.
#   That live-run probe counts CHECK WORK (pytest, playwright, node, make,
#   vitest, jest), never "any process in the worktree": a worker WAITING for the
#   queue keeps two wait shells alive, so counting any process made waiters look
#   busy to each other and would have deadlocked the whole fleet after the first
#   release.
#   A hold whose owner has no live check work and is older than FM_GATE_STALE_SECONDS
#   (default 1500, 25 minutes) is treated as abandoned and broken.
# Environment: FM_HOME selects the home whose state/ holds the queue;
#   FM_STATE_OVERRIDE overrides that state directory; FM_GATE_STALE_SECONDS sets
#   the abandoned-hold age; FM_GATE_POLL_SECONDS (default 30) sets the --wait poll.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.gate-lock"
STALE="${FM_GATE_STALE_SECONDS:-1500}"
POLL="${FM_GATE_POLL_SECONDS:-30}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

owner() { cat "$LOCK/owner" 2>/dev/null; }

mtime_of() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

worktree_of() {
  sed -n 's/^worktree=//p' "$STATE/$1.meta" 2>/dev/null | head -n 1
}

# True when a FULL gate run is live in worktree $1. See the header on why this
# looks for check work rather than for any process.
check_work_live() {
  local wt=$1 pid
  [ -n "$wt" ] || return 1
  pgrep -f "$wt" 2>/dev/null | while read -r pid; do
    ps -p "$pid" -o command= 2>/dev/null
  done | grep -qE '[p]ytest|[p]laywright|[n]ode |[m]ake |[v]itest|[j]est'
}

owner_running() {
  local id
  id=$(owner)
  [ -n "$id" ] || return 1
  check_work_live "$(worktree_of "$id")"
}

# Print the id of another task with a live full run, if any.
other_task_running() {
  local meta id
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$id" = "$1" ] && continue
    grep -q '^kind=secondmate' "$meta" && continue
    if check_work_live "$(worktree_of "$id")"; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  return 1
}

break_if_abandoned() {
  [ -d "$LOCK" ] || return 1
  local now mtime age
  now=$(date +%s)
  mtime=$(mtime_of "$LOCK")
  [ -n "$mtime" ] || mtime=$now
  age=$(( now - mtime ))
  if [ "$age" -ge "$STALE" ] && ! owner_running; then
    echo "breaking an abandoned hold (owner $(owner), ${age}s old, no check work running)" >&2
    rm -rf "$LOCK"
    return 0
  fi
  return 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  acquire)
    ID=${2:-}
    [ -n "$ID" ] || { echo "error: acquire needs a task id" >&2; exit 2; }
    WAIT=${3:-}
    [ -z "$WAIT" ] || [ "$WAIT" = "--wait" ] || { echo "error: unknown argument: $WAIT" >&2; exit 2; }
    mkdir -p "$STATE" 2>/dev/null || true
    while :; do
      if mkdir "$LOCK" 2>/dev/null; then
        if OTHER=$(other_task_running "$ID"); then
          rmdir "$LOCK" 2>/dev/null
          # Printed on stdout as well as stderr: a worker reading only stdout
          # took a refusal for a success on 2026-09-08.
          echo "QUEUE NOT GRANTED - a full run is already live in $OTHER, although the hold was free"
          echo "a full run is live outside the hold, in $OTHER" >&2
          [ "$WAIT" = "--wait" ] || exit 1
          sleep "$POLL"
          continue
        fi
        printf '%s\n' "$ID" > "$LOCK/owner"
        echo "queue held by you: $ID"
        exit 0
      fi
      break_if_abandoned && continue
      HOLDER=$(owner)
      if [ "$HOLDER" = "$ID" ]; then
        echo "queue is already yours: $ID"
        exit 0
      fi
      if [ "$WAIT" != "--wait" ]; then
        echo "QUEUE NOT YOURS - held by: $HOLDER"
        echo "held by: $HOLDER" >&2
        exit 1
      fi
      sleep "$POLL"
    done
    ;;
  release)
    ID=${2:-}
    [ -n "$ID" ] || { echo "error: release needs a task id" >&2; exit 2; }
    if [ ! -d "$LOCK" ]; then
      echo "queue was already free"
      exit 0
    fi
    HOLDER=$(owner)
    if [ "$HOLDER" != "$ID" ]; then
      echo "not your queue (held by $HOLDER) - leaving it alone" >&2
      exit 1
    fi
    rm -rf "$LOCK"
    echo "queue released"
    exit 0
    ;;
  status)
    if [ -d "$LOCK" ]; then
      echo "held by: $(owner)"
    else
      echo "free"
    fi
    ;;
  *)
    echo "usage: fm-gate.sh acquire <id> [--wait] | release <id> | status" >&2
    exit 2
    ;;
esac
