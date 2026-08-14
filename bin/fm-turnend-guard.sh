#!/usr/bin/env bash
# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode and pi adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive. Grok delegates native
# blocking when its running Stop payload advertises that capability, with one
# bounded resume fallback for payloads from pre-native processes.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# secondmate home (treehouse-leased or git-cloned), and any crewmate/scout task
# worktree spawned to work on firstmate itself (the recursive "firstmate
# improving itself" case). A secondmate home runs its OWN primary firstmate
# session, so it must be guarded like the main primary; only child crew/scout
# worktrees are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked secondmate home - and
# stay a silent, fast no-op inside child task worktrees.
#
# Loop-guard, codex/Grok (default) mode: never block twice in the same turn.
# Codex uses stop_hook_active and Grok uses stopHookActive; typed camel-case
# takes precedence when both spellings are present. A true value means the
# current stop attempt already follows a block, so this guard always allows it.
# Passive harness adapters provide their own one-follow-up guard before calling
# this script.
# That bounds those harnesses to at most one forced continuation per turn -
# never a wedged, un-endable session - while still nagging again on a later turn
# if the problem persists.
#
# Loop-guard, --claude mode (Stop-owned auto-arm cooperation): Claude Code
# marks EVERY stop after ANY stop-hook-driven continuation stop_hook_active=true,
# including turns started by the asyncRewake auto-arm, so the one-shot allow
# would re-open the exact blind window this guard exists to close
# (docs/turnend-guard.md records the 2026-07-21 incident). In --claude mode this
# guard ignores stop_hook_active and instead cooperates with the Stop-owned
# auto-arm (bin/fm-claude-stop-autoarm.sh), which fires on the same Stop event:
#   1. a live identity-matched watcher with a fresh beacon allows immediately;
#   2. otherwise wait briefly (FM_CLAUDE_AUTOARM_SYNC_WAIT_MS, default 800ms)
#      for the auto-arm to claim this home (state/.claude-autoarm.lock owner
#      alive) or to record a fresh actionable exit-2 outcome
#      (state/.claude-autoarm-epoch) for this event epoch - either proof allows
#      without consuming a continuation, so one event epoch yields exactly one recovery turn;
#      the first fresh exhausted-failure epoch preserves the bounded progression,
#      while later fresh failed epochs consume it instead of resetting it;
#   3. only when neither materializes is the auto-arm genuinely absent: re-block
#      with the repair banner, bounded to FM_CLAUDE_TURNEND_BLOCK_BUDGET
#      (default 3) consecutive blocks per session - safely below Claude Code's
#      hard 8-consecutive-block override - then allow one loud attended
#      fail-open.
#
# Independence from the auto-arm's own files, --claude mode: every terminal
# outcome above must be reachable from evidence THIS script can observe. A guard
# whose only escape depends on a file the auto-arm writes cannot survive the
# auto-arm going silent, which is the one failure it exists to survive: any
# cause that silences that hook otherwise produces an unbounded, unsatisfiable
# block. So the blocked-stop count advances on every blocking turn end rather
# than only when the auto-arm's epoch changes, and the bounded fail-open also
# accepts "no live auto-arm owner and no fresh epoch" as proof that no recovery
# is under way. A session that does not hold the home lock is a separate case
# entirely: it is forbidden from arming or repairing supervision at all
# (AGENTS.md section 3), so blocking it can never be satisfied and it is allowed
# to end its turn with one loud notice instead.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
CLAUDE_MODE=0
SYNC_WAIT_MS=${FM_CLAUDE_AUTOARM_SYNC_WAIT_MS:-800}
EPOCH_FRESH=${FM_CLAUDE_AUTOARM_EPOCH_FRESH:-15}
BLOCK_BUDGET=${FM_CLAUDE_TURNEND_BLOCK_BUDGET:-3}
case "$SYNC_WAIT_MS" in ''|*[!0-9]*) SYNC_WAIT_MS=800 ;; esac
case "$EPOCH_FRESH" in ''|*[!0-9]*|0) EPOCH_FRESH=15 ;; esac
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac

for arg in "$@"; do
  case "$arg" in
    --claude) CLAUDE_MODE=1 ;;
    *) echo "usage: $(basename "$0") [--claude]" >&2; exit 2 ;;
  esac
done

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload")
  elif has("stopHookActive") then
    if ((.stopHookActive | type) == "boolean") then .stopHookActive else error("stopHookActive") end
  elif has("stop_hook_active") then
    if ((.stop_hook_active | type) == "boolean") then .stop_hook_active else error("stop_hook_active") end
  else false
  end
' 2>/dev/null) || exit 0
if [ "$CLAUDE_MODE" -eq 0 ] && [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# --- scope precisely to a PRIMARY checkout ----------------------------------
# A genuinely-marked secondmate home runs its OWN primary firstmate session, so
# force-INCLUDE it as a guarded primary whether treehouse leased it as a linked
# worktree (git-dir != git-common-dir) or it is a git-cloned plain checkout. This
# mirrors the cd-guard's intent that a secondmate's own session is a guarded
# primary. Only an UNMARKED checkout (or one with an invalid marker) falls
# through to the linked-worktree exemption: firstmate hands out crewmate/scout
# task worktrees as genuine linked `git worktree`s (bin/fm-spawn.sh aborts
# otherwise), whose git-dir lives under the parent repo's .git/worktrees/<name>
# and differs from the common (shared) git-dir, while a main, non-worktree
# checkout has the two equal. Child worktrees never carry the gitignored marker,
# so this exempts them while guarding every real secondmate home.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

BUDGET_FILE="$STATE/.turnend-claude-blocks"
BUDGET_LOCK="$STATE/.turnend-claude-blocks.lock"
OWNER_LOCK="$STATE/.claude-autoarm.lock"
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null || printf 'unknown')
PAYLOAD_SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // ""' 2>/dev/null || printf '')
LOCK_OWNERSHIP=owned
BUDGET_EVENT_COUNTED=0

# Classify this session's standing against the home lock into LOCK_OWNERSHIP:
#   owned    this session holds it
#   free     no lock record exists yet
#   stale    a record whose owner is dead or not a harness, so it is reclaimable
#   foreign  a live owner that is not this session, or an unrecognized record
# Only "foreign" means this session can never legally repair supervision: "free"
# and "stale" are both claimable by the auto-arm's own guarded recovery path, so
# they keep the ordinary blocking behavior.
lock_classify() {
  if fm_session_lock_owned_by_self "$STATE" "$PAYLOAD_SESSION_ID"; then
    LOCK_OWNERSHIP=owned
    return 0
  fi
  case "$FM_LOCK_FORM" in
    absent) LOCK_OWNERSHIP=free ;;
    malformed) LOCK_OWNERSHIP=foreign ;;
    *)
      if fm_harness_pid_alive "$FM_LOCK_PID"; then
        LOCK_OWNERSHIP=foreign
      else
        LOCK_OWNERSHIP=stale
      fi
      ;;
  esac
}

# Operator-facing description of the record parsed by lock_classify.
lock_owner_desc() {
  case "$FM_LOCK_FORM" in
    typed) printf '%s session %s, pid %s' "$FM_LOCK_HARNESS" "$FM_LOCK_SESSION" "$FM_LOCK_PID" ;;
    legacy) printf 'harness pid %s' "$FM_LOCK_PID" ;;
    *) printf 'an unrecognized lock record' ;;
  esac
}

budget_reset() {
  [ "$CLAUDE_MODE" -eq 1 ] || return 0
  fm_lock_try_acquire "$BUDGET_LOCK" || return 0
  rm -f "$BUDGET_FILE" 2>/dev/null || true
  fm_lock_release "$BUDGET_LOCK"
}

fm_supervision_status "$STATE" "$GRACE"
if [ "$FM_SUP_NEEDED" = false ]; then
  [ -e "$FAILURE_NOTICE" ] || budget_reset
  exit 0
fi
if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  [ "$CLAUDE_MODE" -eq 1 ] || exit 0
  fm_failure_episode_reset "$STATE" && exit 0
  exit 2
fi

# One line naming what the Stop-owned auto-arm is observably doing, so a block
# never reads as "the hook is broken" when the real answer is "this session does
# not hold the home lock" or "the epoch has been frozen for hours".
autoarm_participation_line() {
  local epoch_seq age
  if [ "$LOCK_OWNERSHIP" = foreign ]; then
    printf 'auto-arm: not participating (this session does not hold the home lock; owner %s)' "$(lock_owner_desc)"
    return 0
  fi
  if [ ! -e "$STATE/.claude-autoarm-epoch" ]; then
    printf 'auto-arm: no epoch recorded'
    return 0
  fi
  epoch_seq=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  case "$epoch_seq" in ''|*[!0-9]*) epoch_seq=unknown ;; esac
  age=$(fm_path_age "$STATE/.claude-autoarm-epoch")
  printf 'auto-arm: epoch %s is %ss old' "$epoch_seq" "$age"
}

block_stop() {
  local afk x_mode reason rule
  afk=0
  [ -e "$STATE/.afk" ] && afk=1
  x_mode=0
  [ -f "$CONFIG/x-mode.env" ] && x_mode=1
  reason=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
    || printf '%s\n' 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn')
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
    if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
      printf '●  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC"
    elif [ "$FM_SUP_SOURCES" -gt 0 ]; then
      printf '●  %s process-event source(s) registered, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_SOURCES" "$FM_SUP_BEACON_DESC"
    else
      printf '●  X-mode relay polling needs supervision, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_BEACON_DESC"
    fi
    if [ "$CLAUDE_MODE" -eq 1 ]; then
      printf '●  The Stop-owned auto-arm did not claim this home either, so recovery is NOT already under way.\n'
      printf '●  %s\n' "$(autoarm_participation_line)"
    fi
    printf '●  %s\n' "$reason"
    printf '●%s\n' "$rule"
  } >&2
  exit 2
}

if [ "$CLAUDE_MODE" -eq 0 ]; then
  block_stop
fi

# --- a session that does not hold the home lock is read-only -----------------
# It may not arm, drain, or repair supervision (AGENTS.md section 3), so a block
# demanding that repair can never be satisfied. Say who does hold the home once
# per session and allow the turn to end. Away mode is deliberately excluded: the
# daemon owns supervision there and both hooks keep their existing behavior.
#
# The one-per-session marker lives outside state/ on purpose: this path must
# leave the home byte-for-byte untouched, including the block budget, because
# the session taking it has no write authority over another session's home.
# An unwritable temp dir must not silently swallow the notice, so only a marker
# that is already there suppresses it.
nonowner_notice_is_new() {
  local key marker
  key=$(printf '%s|%s' "$STATE" "$SESSION_ID" | cksum | tr -cd '0-9')
  marker="${TMPDIR:-/tmp}/fm-turnend-nonowner-$key"
  [ ! -e "$marker" ] || return 1
  (set -C; : > "$marker") 2>/dev/null || true
  return 0
}

lock_classify
if [ "$LOCK_OWNERSHIP" = foreign ] && [ ! -e "$STATE/.afk" ]; then
  if nonowner_notice_is_new; then
    printf '{"systemMessage":"FIRSTMATE SUPERVISION IS NOT THIS SESSION'"'"'S TO REPAIR: the home lock is held by %s, so this session is read-only and must not arm, drain, or repair supervision. Its turn ends are no longer blocked. If that owner is gone, release the lock so this session can take the home over."}\n' \
      "$(lock_owner_desc)"
  fi
  exit 0
fi

# --- --claude cooperative path -----------------------------------------------
# The Stop-owned auto-arm fires on the same Stop event. Give it a brief bounded
# window to prove it owns recovery for this event epoch before consuming one of
# Claude's bounded continuations.
#
# Pass "force" when accounting a turn end this guard is actually about to block.
# A blocking turn end always advances the count, even when the auto-arm epoch is
# unchanged: the epoch only tracks Stop events the auto-arm participated in, so
# a frozen epoch would otherwise pin the count at its first value and make the
# bounded progression unreachable for exactly as long as the auto-arm is silent.
# BUDGET_EVENT_COUNTED keeps that at one advance per Stop event, which is what
# the epoch-equality check was really protecting.
budget_account_current_epoch() {  # [force]
  local force=${1:-} current_epoch outcome old_session old_count old_epoch tmp initialized advanced
  fm_lock_try_acquire "$BUDGET_LOCK" || return 1
  current_epoch=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  outcome=$(sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  initialized=0
  advanced=0
  COUNT=0
  if [ -f "$BUDGET_FILE" ]; then
    old_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
    old_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
    old_epoch=$(sed -n '3s/^epoch=//p' "$BUDGET_FILE" 2>/dev/null || true)
    case "$old_count" in
      ''|*[!0-9]*) old_count=0 ;;
    esac
    if [ "$old_session" = "$SESSION_ID" ]; then
      COUNT=$old_count
      if [ "$BUDGET_EVENT_COUNTED" -eq 0 ] \
        && { [ "$force" = force ] || [ -z "$current_epoch" ] || [ "$old_epoch" != "$current_epoch" ]; }; then
        COUNT=$((COUNT + 1))
        advanced=1
      fi
    fi
  fi
  if [ ! -f "$BUDGET_FILE" ] || [ "${old_session:-}" != "$SESSION_ID" ]; then
    case "$outcome" in
      failed|failed-suppressed)
        if [ -e "$FAILURE_NOTICE" ]; then
          initialized=1
          COUNT=0
          advanced=0
        else
          COUNT=1
          advanced=1
        fi
        ;;
      *) COUNT=1; advanced=1 ;;
    esac
  fi
  tmp="$BUDGET_FILE.tmp.$$"
  if ! printf 'session=%s\ncount=%s\nepoch=%s\n' "$SESSION_ID" "$COUNT" "$current_epoch" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$BUDGET_FILE" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$BUDGET_LOCK"
    return 1
  fi
  rm -f "$tmp" 2>/dev/null || true
  BUDGET_INITIALIZED_FAILURE=$initialized
  [ "$advanced" -eq 0 ] || BUDGET_EVENT_COUNTED=1
  fm_lock_release "$BUDGET_LOCK"
  return 0
}

autoarm_owns_recovery() {
  local pid role outcome age
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && return 0
  pid=$(cat "$OWNER_LOCK/pid" 2>/dev/null || true)
  role=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  if fm_pid_alive "$pid" && [ "$role" = autoarm ]; then
    [ ! -e "$FAILURE_NOTICE" ] || budget_account_current_epoch || true
    return 0
  fi
  outcome=$(sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  case "$outcome" in
    rewake)
      age=$(fm_path_age "$STATE/.claude-autoarm-epoch")
      if [ "$age" -lt "$EPOCH_FRESH" ]; then
        [ ! -e "$FAILURE_NOTICE" ] || budget_account_current_epoch || true
        return 0
      fi
      ;;
    failed)
      age=$(fm_path_age "$STATE/.claude-autoarm-epoch")
      if [ "$age" -lt "$EPOCH_FRESH" ] && [ -e "$FAILURE_NOTICE" ] \
        && budget_account_current_epoch; then
        [ "$BUDGET_INITIALIZED_FAILURE" -eq 1 ] && return 0
      fi
      ;;
    failed-suppressed)
      age=$(fm_path_age "$STATE/.claude-autoarm-epoch")
      if [ "$age" -lt "$EPOCH_FRESH" ] && [ -e "$FAILURE_NOTICE" ] \
        && budget_account_current_epoch; then
        :
      fi
      ;;
  esac
  return 1
}

terminal_fail_open() {
  local pid role old_session old_count
  [ "$COUNT" -gt "$BLOCK_BUDGET" ] || return 1
  terminal_evidence_ok || return 1
  [ ! -e "$FAILURE_ALARM" ] || return 1
  if ! fm_lock_try_acquire "$OWNER_LOCK"; then
    pid=$(cat "$OWNER_LOCK/pid" 2>/dev/null || true)
    role=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
    if fm_pid_alive "$pid" && [ "$role" = autoarm ]; then
      return 2
    fi
    return 1
  fi
  if ! fm_lock_set_role "$OWNER_LOCK" terminal-check; then
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  if ! fm_lock_try_acquire "$BUDGET_LOCK"; then
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  old_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
  old_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
  case "$old_count" in
    ''|*[!0-9]*) old_count=0 ;;
  esac
  role=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  if [ "$role" != terminal-check ] || [ "$old_session" != "$SESSION_ID" ] \
    || [ "$old_count" -le "$BLOCK_BUDGET" ] || ! terminal_evidence_ok \
    || [ -e "$FAILURE_ALARM" ]; then
    fm_lock_release "$BUDGET_LOCK"
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    if ! fm_failure_episode_reset "$STATE" held; then
      fm_lock_release "$BUDGET_LOCK"
      fm_lock_release "$OWNER_LOCK"
      return 1
    fi
    fm_lock_release "$BUDGET_LOCK"
    fm_lock_release "$OWNER_LOCK"
    return 2
  fi
  if ! (set -C; : > "$FAILURE_ALARM") 2>/dev/null; then
    fm_lock_release "$BUDGET_LOCK"
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  fm_lock_release "$BUDGET_LOCK"
  fm_lock_release "$OWNER_LOCK"
  return 0
}

failure_episode_verified() {
  local outcome
  [ ! -e "$STATE/.afk" ] || return 1
  [ -e "$FAILURE_NOTICE" ] || return 1
  outcome=$(sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  case "$outcome" in
    failed|failed-suppressed) return 0 ;;
    *) return 1 ;;
  esac
}

# The auto-arm is provably not recovering this home, from evidence this script
# owns rather than evidence the auto-arm must write: no live owner holds its
# lock, and its epoch ledger is absent or has not moved inside the freshness
# window. This is what makes the bounded terminal outcome reachable when the
# hook has gone silent instead of failing - a silent hook writes neither the
# failure notice nor a new epoch, so failure_episode_verified alone can never
# become true again.
autoarm_provably_absent() {
  local pid role age
  [ ! -e "$STATE/.afk" ] || return 1
  pid=$(cat "$OWNER_LOCK/pid" 2>/dev/null || true)
  role=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  if fm_pid_alive "$pid" && [ "$role" = autoarm ]; then
    return 1
  fi
  if [ -e "$STATE/.claude-autoarm-epoch" ]; then
    age=$(fm_path_age "$STATE/.claude-autoarm-epoch")
    [ "$age" -ge "$EPOCH_FRESH" ] || return 1
  fi
  return 0
}

# Either proof reaches the bounded loud allow: an auto-arm that reported its own
# exhausted failure, or an auto-arm that is observably not participating at all.
terminal_evidence_ok() {
  failure_episode_verified && return 0
  autoarm_provably_absent
}

i=0
while [ "$i" -lt $((SYNC_WAIT_MS / 100)) ]; do
  if autoarm_owns_recovery; then
    if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
      fm_failure_episode_reset "$STATE" || exit 2
    fi
    exit 0
  fi
  sleep 0.1
  i=$((i + 1))
done
if autoarm_owns_recovery; then
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    fm_failure_episode_reset "$STATE" || exit 2
  fi
  exit 0
fi

# The auto-arm genuinely failed to establish: consume the bounded re-block
# budget before considering the verified one-time attended fail-open.
budget_account_current_epoch force || block_stop
terminal_fail_open
terminal_status=$?
if [ "$terminal_status" -eq 0 ]; then
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
    NEED_DESC="$FM_SUP_IN_FLIGHT task(s) in flight"
  elif [ "$FM_SUP_SOURCES" -gt 0 ]; then
    NEED_DESC="$FM_SUP_SOURCES process-event source(s) registered"
  else
    NEED_DESC="X-mode relay polling active"
  fi
  printf '{"systemMessage":"FIRSTMATE SUPERVISION IS GENUINELY DOWN: %s, %s, no watcher or automatic continuation exists, and the block budget is exhausted. Keep this session attended and diagnose the automatic Stop-hook and watcher startup before relying on unattended supervision."}\n' \
    "$NEED_DESC" "$(autoarm_participation_line)"
  exit 0
fi
[ "$terminal_status" -eq 2 ] && exit 0
block_stop
