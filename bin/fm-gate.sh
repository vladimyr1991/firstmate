#!/usr/bin/env bash
# Serialize FULL test-gate runs across every task worktree on this MACHINE, with
# no firstmate in the loop: a worker takes the queue itself and releases it itself.
# One machine sustains one full gate run; two at once starve each other for
# memory, and on 2026-09-08 such a pair cost an hour when the system killed one
# of them halfway through its browser half.
# The hold therefore lives OUTSIDE any home, at /tmp/fm-gate-lock, so a firstmate
# home and every secondmate home on the same machine contend for one single hold;
# a per-home hold only ever serialized a home against itself while the hazard it
# guards is per-machine. The RESOURCE probe that backs issuance deliberately
# stays HOME-SCOPED - it scans this home's state/*.meta and nothing else - because
# the hold is what serializes the fleet across homes, and that probe only has to
# catch a run that went around the hold inside this home; there is no machine-wide
# worktree registry and this script does not invent one.
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
#   at the permit. A permit-counting guard only ever meets the worker who
#   politely asked, and on 2026-09-08 a worker who released the hold and then ran
#   the browser half on a neighbouring lane broke nothing and still put a second
#   full run on the machine.
#   That probe is BEST EFFORT and is NOT a guarantee that no run is live. It can
#   only see a run whose argv carries the task worktree path, because it starts
#   from `pgrep -f <worktree>`: `make test` launched from inside the worktree has
#   argv exactly `make test`, and a system `pytest tests/` carries no path either,
#   so both are invisible to it and the queue is granted beside them. What
#   serializes the honest case is the machine-wide HOLD; this probe only catches a
#   full run that went around the hold and still names its worktree.
#   It also cannot tell a FULL run from the targeted run this queue explicitly
#   exempts, so `pytest tests/one_test.py` in a worktree refuses issuance with a
#   message that overstates what is live. That cost is bounded - the refusal
#   clears when the targeted test ends and --wait rides it out - so it spends
#   parallelism rather than pinning the queue, and no argv-based probe can
#   separate the two.
#   What it does count is CHECK WORK (pytest, playwright, make, vitest, jest),
#   never "any process in the worktree", never a bare `node`, and never a process
#   whose argv carries this script's own name. A worker WAITING for the queue
#   keeps wait shells alive, so counting any process made waiters look busy to
#   each other and would have deadlocked the whole fleet after the first release.
#   A bare `node` matched the vite dev server of the browser inspection this queue
#   explicitly does NOT cover, so one idle dev server would have pinned the queue
#   for the whole fleet with no staleness path out of it, since only HOLDS age out
#   and a resource refusal never does. And the mandated worker one-liner carries
#   `acquire ... --wait && <the gate command>` in a single argv, so a harness that
#   shells out via `bash -c` leaves the worktree path and the runner name in a
#   MERELY WAITING shell: counting that text would have put two waiters in a
#   permanent two-way stall, each reading the other's unrun command as a live run.
#   A process holding this script's invocation is a waiter or a wrapper by
#   contract and never the run itself, so it is skipped before the runner match.
#   A hold is abandoned when its recorded HOLDER PROCESS is gone AND the hold is
#   older than FM_GATE_STALE_SECONDS (default 1500, 25 minutes). That process is
#   the parent of this script - the shell running the mandated one-liner, which by
#   construction lives exactly as long as wait plus run plus release - and its pid
#   and start time are written into the hold at acquire time. Liveness is a
#   recorded FACT, never an inference from process command text: the one-liner
#   makes that inference impossible, because the only process whose argv carries
#   the task worktree is the wrapper shell (which must be skipped, being also a
#   waiter) while the real runner carries no path at all - `make test`, a system
#   `pytest tests/`, or a bare `bash tests/foo.test.sh` are all invisible to argv
#   matching, and a genuinely running suite lost its hold at 25 minutes because of
#   it. The start time is compared as well as the pid so a recycled pid cannot
#   masquerade as the holder; when the start time cannot be read the holder counts
#   as ALIVE, because uncertainty must never break a hold. A hold written by an
#   older copy of this script records no process and falls back to the argv probe,
#   so it is no worse off than before. The owner's worktree is recorded too, so
#   nothing here needs another home's metadata.
#   Only ONE contender breaks at a time, behind <hold>.breaking, and the break is
#   a COMPARE AND SWAP: the hold's identity is captured before the liveness
#   decision and re-verified immediately before the removal, still inside the
#   mutex. Without that, a holder releasing during the decision and a new
#   contender acquiring meant the breaker deleted a hold milliseconds old and took
#   the queue - two full runs, with the first holder's own release then refused
#   because the hold recorded the second, and the queue reading free while its run
#   continued. The mutex alone is necessary and not sufficient.
#   A fixed name in a shared directory can be pre-created by another user, so a
#   hold that is a symlink, is not a directory, or is not owned by this uid is
#   refused outright: it is never broken, never removed, and never followed.
# Environment: FM_GATE_LOCK_DIR overrides the machine-wide hold path (default
#   /tmp/fm-gate-lock); FM_HOME selects the home whose state/ the home-scoped
#   issuance probe scans; FM_STATE_OVERRIDE overrides that state directory;
#   FM_GATE_STALE_SECONDS sets the abandoned-hold age; FM_GATE_POLL_SECONDS
#   (default 30) sets the --wait poll.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="${FM_GATE_LOCK_DIR:-/tmp/fm-gate-lock}"
STALE="${FM_GATE_STALE_SECONDS:-1500}"
POLL="${FM_GATE_POLL_SECONDS:-30}"
BREAK_MUTEX="$LOCK.breaking"
GATE_SELF="$(basename "${BASH_SOURCE[0]}")"
GATE_SELF_INVOCATION="${GATE_SELF//./\\.}[\"']?[[:space:]]+(acquire|release|status)([[:space:]]|\$)"

# fm_lock_path_mtime owns the platform test. A `stat -f %m || stat -c %Y` chain
# looks portable and is not: GNU `stat -f` means --file-system and SUCCEEDS, so
# the fallback never runs on Linux and the age reads as a filesystem block.
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

owner() { cat "$LOCK/owner" 2>/dev/null; }

# The holder's worktree as recorded in the hold itself, so the staleness proof
# works across homes. See the header.
owner_worktree() { cat "$LOCK/owner_worktree" 2>/dev/null; }

owner_pid() { cat "$LOCK/owner_pid" 2>/dev/null; }
owner_pid_start() { cat "$LOCK/owner_pid_start" 2>/dev/null; }
hold_token() { cat "$LOCK/token" 2>/dev/null; }

# Absolute start time of $1 on one line, or empty when it cannot be read.
process_start() {
  ps -p "$1" -o lstart= 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

# What this hold IS, for the compare-and-swap in break_if_abandoned. The token
# this script writes is exact; a hold from an older copy has none, so owner plus
# mtime stands in - enough to tell a stale hold from one taken after it.
hold_identity() {
  local token
  token=$(hold_token)
  if [ -n "$token" ]; then
    printf 'token:%s\n' "$token"
  else
    printf 'owner:%s:%s\n' "$(owner)" "$(fm_lock_path_mtime "$LOCK")"
  fi
}

path_uid() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %u "$1" 2>/dev/null
  else
    stat -c %u "$1" 2>/dev/null
  fi
}

# True when something sits at the hold path that this uid does not own: a
# symlink, a non-directory, or another user's directory.
hold_is_foreign() {
  local uid me
  [ -e "$LOCK" ] || [ -L "$LOCK" ] || return 1
  [ -L "$LOCK" ] && return 0
  [ -d "$LOCK" ] || return 0
  uid=$(path_uid "$LOCK")
  case "$uid" in ''|*[!0-9]*) return 0 ;; esac
  me=$(id -u)
  [ "$uid" = "$me" ] && return 1
  return 0
}

refuse_foreign_hold() {
  # On stdout as well as stderr, for the same reason the busy refusals are.
  echo "QUEUE NOT AVAILABLE - the hold at $LOCK is not owned by this user; refusing to touch it"
  echo "hold at $LOCK is not owned by this user" >&2
}

worktree_of() {
  sed -n 's/^worktree=//p' "$STATE/$1.meta" 2>/dev/null | head -n 1
}

# True when a FULL gate run is live in worktree $1. See the header on why this
# looks for check work rather than for any process, why a bare `node` is not check
# work, why a process carrying this script's own name is a waiter and never a run,
# and what this probe cannot see at all.
check_work_live() {
  local wt=$1 pid cmd
  [ -n "$wt" ] || return 1
  pgrep -f "$wt" 2>/dev/null | while read -r pid; do
    cmd=$(ps -p "$pid" -o command= 2>/dev/null)
    [ -n "$cmd" ] || continue
    [[ $cmd =~ $GATE_SELF_INVOCATION ]] && continue
    printf '%s\n' "$cmd"
  done | grep -qE '[p]ytest|[p]laywright|[m]ake |[v]itest|[j]est'
}

# The recorded holder process, checked as a fact. See the header for why an argv
# probe cannot answer this and what the start-time comparison is for.
owner_process_alive() {
  local pid recorded current
  pid=$(owner_pid)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  recorded=$(owner_pid_start)
  [ -n "$recorded" ] || return 0
  current=$(process_start "$pid")
  [ -n "$current" ] || return 0
  [ "$current" = "$recorded" ]
}

owner_running() {
  [ -n "$(owner)" ] || return 1
  case "$(owner_pid)" in
    ''|*[!0-9]*) check_work_live "$(owner_worktree)" ;;
    *) owner_process_alive ;;
  esac
}

# Print the id of another task with a live full run, if any. Home-scoped by
# design; see the header.
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

# Age of $1 in seconds, or -1 when it cannot be read as a number.
path_age() {
  local now=$1 path=$2 m
  m=$(fm_lock_path_mtime "$path")
  case "$m" in ''|*[!0-9]*) printf '%s\n' -1; return 0 ;; esac
  printf '%s\n' "$(( now - m ))"
}

# Break the hold if it is provably abandoned. Only one contender decides at a
# time, behind $BREAK_MUTEX, and the decision is a compare-and-swap: the hold's
# identity is captured before the liveness check and re-verified immediately
# before the removal. See the header for both failures this closes.
break_if_abandoned() {
  local now age holder identity broke=1
  [ -d "$LOCK" ] || return 1
  hold_is_foreign && return 1
  now=$(date +%s)
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  # Cheap pre-filter, so contenders do not queue on the mutex for a fresh hold.
  age=$(path_age "$now" "$LOCK")
  [ "$age" -ge "$STALE" ] || return 1

  # A breaker killed mid-decision must not wedge the rule for every later one.
  if [ -d "$BREAK_MUTEX" ] && [ "$(path_age "$now" "$BREAK_MUTEX")" -ge "$STALE" ]; then
    rmdir "$BREAK_MUTEX" 2>/dev/null
  fi
  mkdir "$BREAK_MUTEX" 2>/dev/null || return 1

  now=$(date +%s)
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  age=$(path_age "$now" "$LOCK")
  identity=$(hold_identity)
  if [ -d "$LOCK" ] && ! hold_is_foreign && [ "$age" -ge "$STALE" ] && ! owner_running; then
    holder=$(owner)
    now=$(date +%s)
    case "$now" in ''|*[!0-9]*) now=0 ;; esac
    if [ "$(hold_identity)" = "$identity" ] && [ "$(path_age "$now" "$LOCK")" -ge "$STALE" ]; then
      echo "breaking an abandoned hold (owner $holder, ${age}s old, holder process gone)" >&2
      rm -rf "$LOCK"
      broke=0
    else
      echo "not breaking: the hold changed while it was being judged" >&2
    fi
  fi
  rmdir "$BREAK_MUTEX" 2>/dev/null
  return "$broke"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  acquire)
    ID=${2:-}
    [ -n "$ID" ] || { echo "error: acquire needs a task id" >&2; exit 2; }
    WAIT=${3:-}
    [ -z "$WAIT" ] || [ "$WAIT" = "--wait" ] || { echo "error: unknown argument: $WAIT" >&2; exit 2; }
    mkdir -p "$STATE" 2>/dev/null || true
    mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true
    OWNER_READS=0
    while :; do
      # Waiting cannot help a hold this user may not touch, so --wait refuses too.
      if hold_is_foreign; then
        refuse_foreign_hold
        exit 1
      fi
      if mkdir "$LOCK" 2>/dev/null; then
        # Owner first, probe second: the probe walks every meta with a pgrep and a
        # ps apiece, and a concurrent reader inside that window used to be told
        # "held by:" with no holder named.
        printf '%s\n' "$ID" > "$LOCK/owner"
        printf '%s\n' "$(worktree_of "$ID")" > "$LOCK/owner_worktree"
        printf '%s\n' "$PPID" > "$LOCK/owner_pid"
        printf '%s\n' "$(process_start "$PPID")" > "$LOCK/owner_pid_start"
        printf '%s.%s.%s\n' "$$" "$(date +%s)" "${RANDOM:-0}" > "$LOCK/token"
        if OTHER=$(other_task_running "$ID"); then
          [ "$(owner)" = "$ID" ] && rm -rf "$LOCK"
          # Printed on stdout as well as stderr: a worker reading only stdout
          # took a refusal for a success on 2026-09-08.
          echo "QUEUE NOT GRANTED - a full run is already live in $OTHER, although the hold was free"
          echo "a full run is live outside the hold, in $OTHER" >&2
          [ "$WAIT" = "--wait" ] || exit 1
          sleep "$POLL"
          continue
        fi
        HOLDER=$(owner)
        if [ "$HOLDER" != "$ID" ]; then
          echo "QUEUE NOT YOURS - held by: $HOLDER"
          echo "the hold changed owner to $HOLDER while it was being taken" >&2
          [ "$WAIT" = "--wait" ] || exit 1
          sleep "$POLL"
          continue
        fi
        echo "queue held by you: $ID"
        exit 0
      fi
      break_if_abandoned && continue
      HOLDER=$(owner)
      # A hold that is gone, or one caught between its mkdir and its owner file,
      # names no holder; retry briefly rather than report an empty one.
      if [ -z "$HOLDER" ] && [ "$OWNER_READS" -lt 40 ]; then
        OWNER_READS=$(( OWNER_READS + 1 ))
        sleep 0.05
        continue
      fi
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
    if hold_is_foreign; then
      refuse_foreign_hold
      exit 1
    fi
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
    if hold_is_foreign; then
      refuse_foreign_hold
      exit 1
    fi
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
