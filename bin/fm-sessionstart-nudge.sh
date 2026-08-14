#!/usr/bin/env bash
# Print the one-line session-start instruction only for a genuine firstmate
# primary whose current harness session has not already acquired the home lock.
# Every silence and error path exits 0 because Claude SessionStart exit 2 blocks
# session initialization.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# For the lock record contract: a legacy record deliberately keeps this file's
# own minimal ancestry walk rather than the harness-aware ownership predicate,
# while a typed record is answered the way its own contract defines identity.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# True when the lock records an acquisition made by THIS harness session, which
# is the one question that decides silence.
#
# A typed record answers it by session id whenever this process resolves one of
# its own for that record's harness: the id is what identifies the session, and
# a new session can meet the previous session's still-live recorded pid in an
# unchanged process tree. A legacy record, and a typed record read by a process
# that resolves no session id, keep the minimal ancestry walk unchanged. In
# every form the recorded pid must still be live and above pid 1.
lock_is_this_session() {
  local lock_pid pid=$$ self_session _
  fm_session_lock_read "$STATE" || return 1
  lock_pid=$FM_LOCK_PID
  case "$lock_pid" in
    ''|*[!0-9]*|1) return 1 ;;
  esac
  kill -0 "$lock_pid" 2>/dev/null || return 1
  if [ "$FM_LOCK_FORM" = typed ] && self_session=$(fm_harness_session_id "$FM_LOCK_HARNESS"); then
    [ "$self_session" = "$FM_LOCK_SESSION" ] || return 1
    return 0
  fi
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$lock_pid" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

lock_is_this_session && exit 0
nudge=
fm_operational_input_encode session-start \
  "Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions." \
  nudge || exit 0
printf '%s\n' "$nudge"
exit 0
