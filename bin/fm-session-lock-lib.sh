#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness session holds this home's session
# lock, and is the current process inside that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake;
# bin/fm-turnend-guard.sh uses it to recognize a session that cannot legally
# repair supervision at all.
# This file is sourced by scripts and has no side effects on source.
#
# Two record forms are accepted (see docs/turnend-guard.md for the contract):
# a bare integer pid (legacy), and the typed single line
# "pid=<n> harness=<name> session=<id>" written whenever a durable harness
# session id is resolvable. The typed form exists because process ancestry is
# not durable: backgrounding a Claude session replaces its process tree, so the
# recorded pid stops being an ancestor while remaining alive, and an
# ancestry-only test then reports "another live session owns this home" forever.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# Print the canonical harness name contained in text $1, or return 1. Longer
# names come first in FM_HARNESS_NAMES, so "pi-signed" is never reported as
# "pi".
fm_harness_canonical_name() {  # <text>
  local text=$1 name
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "$text" in
      *"$name"*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk and
# FM_HARNESS_MATCH_NAME for the callers that record which harness matched.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
FM_HARNESS_IS_CLAUDE=0
FM_HARNESS_MATCH_NAME=''
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  FM_HARNESS_MATCH_NAME=''
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    FM_HARNESS_MATCH_NAME=$(fm_harness_canonical_name "$base" || printf '')
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    FM_HARNESS_MATCH_NAME=$name
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        FM_HARNESS_MATCH_NAME=$(fm_harness_canonical_name "$args" || printf '')
        return 0
      fi
      ;;
  esac
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True when pid $1 is a member of this process's contiguous harness ancestry, at
# any depth. Membership, not equality with the outermost pid, is the honest test
# of whether this process descends from the recorded pid: the lock owner sits at
# an unknown depth in a contiguous Claude run, and a record naming a session
# parented by a harness-named daemon names an inner pid that can never equal the
# outermost one.
fm_harness_ancestry_has_pid() {  # <pid>
  local want=$1 pids pid
  [ -n "$want" ] || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$want" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}

# Print the canonical harness name of live pid $1, or return 1. Used by the
# acquisition path to label the record it is about to write, so the name always
# comes from the same match that resolved the pid.
fm_harness_ancestry_name() {  # <pid>
  local pid=$1 comm args
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args" || return 1
  [ -n "$FM_HARNESS_MATCH_NAME" ] || return 1
  printf '%s\n' "$FM_HARNESS_MATCH_NAME"
}

# Print this process's durable session id for harness $1, or return 1 when the
# harness has none. Optional $2 is a hook payload's own session id, used only
# when the environment does not carry one.
#
# Claude Code is the only verified harness that publishes a session id, in
# CLAUDE_CODE_SESSION_ID for tool and hook shells and as "session_id" in its
# Stop payload. Every other harness resolves no id, so its homes keep writing
# and reading the legacy pid record unchanged.
fm_harness_session_id() {  # <harness-name> [<payload-session-id>]
  local harness=$1 id=${2:-}
  case "$harness" in
    claude) : ;;
    *) return 1 ;;
  esac
  [ -z "${CLAUDE_CODE_SESSION_ID:-}" ] || id=$CLAUDE_CODE_SESSION_ID
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s\n' "$id"
}

# Read state dir $1's lock record into FM_LOCK_FORM, FM_LOCK_PID,
# FM_LOCK_HARNESS, and FM_LOCK_SESSION. Returns 0 only for a record that parsed.
#
# FM_LOCK_FORM is one of:
#   absent     no lock file
#   legacy     a bare integer pid
#   typed      pid=<n> harness=<name> session=<id>
#   malformed  anything else, including an unreadable file
# An unrecognized record fails closed: it parses as malformed with no pid, so no
# caller can mistake it for ownership.
FM_LOCK_FORM=''
FM_LOCK_PID=''
FM_LOCK_HARNESS=''
FM_LOCK_SESSION=''
fm_session_lock_read() {  # <state-dir>
  local state=$1 record f1 f2 f3 f4 pid harness session
  FM_LOCK_FORM=absent
  FM_LOCK_PID=''
  FM_LOCK_HARNESS=''
  FM_LOCK_SESSION=''
  [ -f "$state/.lock" ] || return 1
  record=$(cat "$state/.lock" 2>/dev/null) || { FM_LOCK_FORM=malformed; return 1; }
  case "$record" in
    ''|*$'\n'*) FM_LOCK_FORM=malformed; return 1 ;;
    *[!0-9]*) : ;;
    *) FM_LOCK_FORM=legacy; FM_LOCK_PID=$record; return 0 ;;
  esac
  IFS=' ' read -r f1 f2 f3 f4 <<EOF
$record
EOF
  pid=${f1#pid=}
  harness=${f2#harness=}
  session=${f3#session=}
  if [ -n "$f4" ] || [ "$f1" = "$pid" ] || [ "$f2" = "$harness" ] || [ "$f3" = "$session" ]; then
    FM_LOCK_FORM=malformed
    return 1
  fi
  case "$pid" in ''|*[!0-9]*) FM_LOCK_FORM=malformed; return 1 ;; esac
  case "$harness" in ''|*[!a-z-]*) FM_LOCK_FORM=malformed; return 1 ;; esac
  case "$session" in ''|*[!A-Za-z0-9._-]*) FM_LOCK_FORM=malformed; return 1 ;; esac
  FM_LOCK_FORM=typed
  FM_LOCK_PID=$pid
  FM_LOCK_HARNESS=$harness
  FM_LOCK_SESSION=$session
  return 0
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# True when state dir $1's session lock belongs to THIS session. Optional $2 is
# a hook payload's own session id, used only when the environment carries none.
# Leaves the parsed record in FM_LOCK_*, so a caller that needs to describe or
# classify a lock it does not own reads it from there instead of re-parsing.
#
# A typed record is decided by session id alone whenever this process can
# resolve one: that identity outlives the process tree, and it is also the only
# test that separates two sessions sharing one pooled background host process,
# whose pid is a genuine ancestor of both.
#
# A legacy record - and a typed record read by a process with no session id -
# falls back to membership in the contiguous harness ancestry, exactly as
# before. Membership is the honest test of that question, because the lock owner
# sits at an unknown depth in a contiguous Claude run: the outermost pid when
# the hook fires inside the session's own nested worker chain, an inner pid when
# a harness-named daemon parents the session. A missing lock, a malformed lock,
# a session id that does not match, a lock held by a harness outside this
# ancestry, or an ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {  # <state-dir> [<payload-session-id>]
  local state=$1 fallback=${2:-} self_session
  fm_session_lock_read "$state" || return 1
  if [ "$FM_LOCK_FORM" = typed ]; then
    if self_session=$(fm_harness_session_id "$FM_LOCK_HARNESS" "$fallback"); then
      [ "$self_session" = "$FM_LOCK_SESSION" ] && return 0
      return 1
    fi
  fi
  fm_harness_ancestry_has_pid "$FM_LOCK_PID"
}
