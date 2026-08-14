#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written. When the
# harness also publishes a durable session id, the record additionally carries
# it as "pid=<n> harness=<name> session=<id>", because a pid alone stops
# identifying the session the moment its process tree is replaced (see
# bin/fm-session-lock-lib.sh and docs/turnend-guard.md). Without a session id
# the bare-integer legacy record is written and behavior is unchanged.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder, liveness, and session id when present;
#                             always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# Describe the record currently parsed into FM_LOCK_*, for operator-facing
# output only. Never a decision input.
lock_holder_desc() {
  case "$FM_LOCK_FORM" in
    typed) printf 'pid %s %s session %s' "$FM_LOCK_PID" "$FM_LOCK_HARNESS" "$FM_LOCK_SESSION" ;;
    legacy) printf 'pid %s' "$FM_LOCK_PID" ;;
    *) printf 'an unrecognized record' ;;
  esac
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  cat "$LOCK" >/dev/null 2>&1 || {
    echo "lock: unreadable"
    exit 0
  }
  fm_session_lock_read "$STATE" || true
  if [ "$FM_LOCK_FORM" = malformed ]; then
    echo "lock: unreadable (record is neither a pid nor a typed session record)"
    exit 0
  fi
  if fm_harness_pid_alive "$FM_LOCK_PID"; then
    echo "lock: held by live harness $(lock_holder_desc)"
  else
    echo "lock: stale ($(lock_holder_desc) dead or not a harness)"
  fi
  exit 0
fi

me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
me_harness=$(fm_harness_ancestry_name "$me") || me_harness=''
me_session=$(fm_harness_session_id "$me_harness") || me_session=''
if [ -n "$me_session" ]; then
  record="pid=$me harness=$me_harness session=$me_session"
else
  record=$me
fi
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$CLAIM_LOCK"
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  cat "$LOCK" >/dev/null 2>&1 || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  # A record this session already owns is refreshed, not contested. Otherwise
  # only a live harness pid means a genuinely competing session: a dead pid, a
  # non-harness pid, and an unrecognized record are all stale, exactly as
  # before, whichever record form carried them.
  if ! fm_session_lock_owned_by_self "$STATE" \
    && [ -n "$FM_LOCK_PID" ] && [ "$FM_LOCK_PID" != "$me" ] \
    && fm_harness_pid_alive "$FM_LOCK_PID"; then
    echo "error: another live firstmate session holds the lock ($(lock_holder_desc)); operate read-only until resolved" >&2
    exit 1
  fi
fi
if ! { printf '%s\n' "$record" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$record" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
if [ -n "$me_session" ]; then
  echo "lock acquired: harness pid $me ($me_harness session $me_session)"
else
  echo "lock acquired: harness pid $me"
fi
