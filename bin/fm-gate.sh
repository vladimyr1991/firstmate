#!/usr/bin/env bash
# Serialize FULL test-gate runs across every task worktree on this MACHINE, with
# no firstmate in the loop: a worker takes the queue itself and releases it itself.
# One machine sustains one full gate run; two at once starve each other for
# memory, and on 2026-09-08 such a pair cost an hour when the system killed one
# of them halfway through its browser half.
# The hold therefore lives OUTSIDE any home, in this user's own state root at
# ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/fm-gate-lock, so a firstmate
# home and every secondmate home on the same machine contend for one single hold;
# a per-home hold only ever serialized a home against itself while the hazard it
# guards is per-machine. That root is equally machine-wide across homes - it
# names one directory per user, not one per home - while a fixed name in a
# world-writable directory is a wedge nothing can clear: anything foreign
# pre-created there makes every worker on the machine refuse without ever running
# a gate, indefinitely, until a human removes it. fm-procevent-lib.sh already
# keeps its machine-wide claim root there for the same reason.
# NAMED LIMITATION of that choice, not a defect: the hold is per UNIX USER. Two
# different users running fleets on one machine each resolve their own hold and
# cannot see each other's, so that machine can carry two full runs at once -
# the hazard this queue exists to prevent, arriving from the one direction a
# per-user path cannot reach. Each user's own fleet is still serialized whole.
# The remedy is explicit: point both fleets at ONE hold both users can write, by
# setting FM_GATE_LOCK_DIR to the same absolute path in both.
# CORRECTNESS does not depend on FM_HOME. The hold path, the recorded holder
# identity and the recorded owner worktree are all resolved without it: the owner
# worktree comes from this home's metadata when it is there and otherwise from
# the git working tree the acquiring process sits in, which is the task worktree
# by construction of the mandated one-liner. This matters because a crewmate pane
# inherits no FM_HOME at all, so anything that needed one would be blank in
# exactly the panes this contract is written for. That fallback is GUARDED: only
# a git worktree root is accepted, and never the user's home directory nor an
# ancestor of it. The recorded worktree is the string the argv probe greps for,
# so recording a home would turn that deliberately narrow probe into the
# machine-wide "is any check work running anywhere" question this design refuses
# below, and one unrelated pytest under the home would keep a dead holder's hold
# alive until the ceiling - the wedge direction with no recovery.
# When neither source yields a path the hold records `(unknown)` rather than an
# empty value, and the argv check-work signal below is then simply unavailable
# for that hold: its liveness rests on the recorded holder process alone.
# The RESOURCE probe that backs issuance is the one thing FM_HOME still selects,
# and it deliberately
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
#   message that overstates what is live. That cost clears by itself only while
#   the neighbouring process actually ends, which is not something this script
#   can promise: an orphaned runner that hangs - a browser half waiting on a dead
#   dev server - would otherwise refuse every other task in this home forever,
#   with each worker's whole turn parked inside `acquire --wait`. So the wait on
#   a RESOURCE refusal is bounded by FM_GATE_RESOURCE_WAIT_SECONDS (default 3600)
#   and then GIVEN UP loudly, naming the task whose run is live. Giving up is not
#   granting: the queue is never handed over on that path, because that would put
#   the second full run on the machine. The worker re-reads state and escalates,
#   which is what the end of any wait obliges it to do.
#   What it does count is CHECK WORK (pytest, playwright, make, vitest, jest),
#   never "any process in the worktree", never a bare `node`, and never a process
#   whose argv carries this script's own name. A worker WAITING for the queue
#   keeps wait shells alive, so counting any process made waiters look busy to
#   each other and would have deadlocked the whole fleet after the first release.
#   A bare `node` matched the vite dev server of the browser inspection this queue
#   explicitly does NOT cover, so one idle dev server would have pinned the queue
#   for the whole fleet with no staleness path out of it, since a HOLD ages out
#   into a grant and a resource refusal never does - it is only ever given up. And the mandated worker one-liner carries
#   `acquire ... --wait && <the gate command>` in a single argv, so a harness that
#   shells out via `bash -c` leaves the worktree path and the runner name in a
#   MERELY WAITING shell: counting that text would have put two waiters in a
#   permanent two-way stall, each reading the other's unrun command as a live run.
#   A process holding this script's invocation is a waiter or a wrapper by
#   contract and never the run itself, so it is skipped before the runner match.
#   A hold is abandoned when it is older than FM_GATE_STALE_SECONDS (default 1500,
#   25 minutes) and NEITHER holder-liveness signal answers. The two signals are
#   ORed, and the OR is the point: each one is blind exactly where the other sees.
#     - The recorded HOLDER PROCESS: the parent of this script, the shell running
#       the mandated one-liner, whose pid and start time are written into the hold
#       at acquire time. This exists because argv cannot answer the question at
#       all - the only process whose argv carries the task worktree is the wrapper
#       shell, which must be skipped for being a waiter, while the real runner
#       carries no path (`make test`, a system `pytest tests/`, a bare
#       `bash tests/foo.test.sh`), and a genuinely running suite lost its hold at
#       25 minutes because of it. The start time is compared as well as the pid so
#       a recycled pid cannot masquerade as the holder; an unreadable start time
#       counts as ALIVE, because uncertainty must never break a hold.
#     - The argv CHECK-WORK probe against the hold's own recorded worktree. This
#       exists because the recorded process can die while the run does not: a
#       harness tool-call timeout kills the wrapper and the suite it started keeps
#       going as an orphan re-parented to init, and breaking that hold puts a
#       second full run on the machine - the same hazard from the other side.
#       Asked only about one hold's recorded worktree, it cannot deadlock waiters
#       the way a fleet-wide "is anybody busy" question once did. It is NOT a
#       guarantee and it is blind in exactly the shapes listed above: an orphan
#       whose argv carries no worktree path - `make test`, a system
#       `pytest tests/`, a bare `bash tests/foo.test.sh` - is invisible to it, so
#       such a hold falls back to the ordinary age rule and is broken at the
#       stale age. That is the behaviour that predates this signal rather than a
#       regression, and the ceiling bounds it either way. Widening the probe past
#       the hold's own recorded worktree is deliberately not the answer: a
#       machine-wide "is any check work running anywhere" question lets unrelated
#       work in an unrelated checkout hold this whole fleet shut.
#   A hold written by an older copy of this script records no process; the probe
#   alone then answers, exactly as it used to.
#   FM_GATE_MAX_HOLD_SECONDS (default 7200) is the absolute ceiling: past it the
#   hold is broken however alive it looks, loudly, on stderr. Without it a
#   recorded parent that outlives its run - a harness reusing one shell across
#   tool calls, or a caller whose `bash -c` exec-optimises the wrapper away so
#   $PPID names the session - would wedge every home on the machine forever with
#   no escape but a manual delete. The 25-minute rule is unchanged for the
#   ordinary case.
#   NOT compatible across paths: a home still running an older PRIVATE copy of
#   this script holds $FM_HOME/state/.gate-lock, which this machine-wide hold does
#   not touch, so the two do NOT serialize against each other and a private copy
#   must be retired or repointed at this script. Reading a legacy hold that
#   records no process is a different and still-supported compatibility.
#   Only ONE contender breaks at a time, behind <hold>.breaking, and the break is
#   a COMPARE AND SWAP: the hold's identity is captured before the liveness
#   decision and re-verified immediately before the removal, still inside the
#   mutex, against the SAME age threshold that justified the break rather than
#   against the stale age unconditionally - re-checking the stale age silently
#   disabled the ceiling whenever it was configured below it, and printed a
#   changed-hold refusal that named the wrong reason. Without the swap itself, a
#   holder releasing during the decision and a new contender acquiring meant the
#   breaker deleted a hold milliseconds old and took
#   the queue - two full runs, with the first holder's own release then refused
#   because the hold recorded the second, and the queue reading free while its run
#   continued. The mutex alone is necessary and not sufficient.
#   A fixed name in a shared directory can be pre-created by another user, so a
#   hold that is a symlink, is not a directory, or is not owned by this uid is
#   refused outright: it is never broken, never removed, and never followed.
# Environment: FM_GATE_LOCK_DIR overrides the machine-wide hold path (default
#   ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/fm-gate-lock, which is one
#   hold per unix user - set it to a shared writable path in every fleet when
#   two different users run fleets on one machine; it must be ABSOLUTE, because a
#   relative one gives every worktree a hold of its own and is refused);
#   FM_HOME
#   selects the home whose state/ the home-scoped issuance probe scans and
#   nothing else; FM_STATE_OVERRIDE overrides that state directory;
#   FM_GATE_STALE_SECONDS sets the abandoned-hold age; FM_GATE_MAX_HOLD_SECONDS
#   sets the absolute ceiling; FM_GATE_POLL_SECONDS (default 30) sets the --wait
#   poll; FM_GATE_RESOURCE_WAIT_SECONDS (default 3600) bounds how long --wait
#   sits on a RESOURCE refusal before giving up, generous enough that an ordinary
#   full run in a neighbouring worktree never trips it. A non-numeric age, a
#   non-numeric or zero ceiling, a non-numeric or zero resource wait, and a
#   non-numeric or zero poll each fall back to their default, LOUDLY on stderr,
#   rather than
#   silently disabling the rule they govern: a zero ceiling breaks every hold
#   instantly however alive its holder is, granting the queue twice, and a poll
#   of zero - or one that every `sleep` refuses - turns --wait into a hot spin
#   that re-runs the whole probe as fast as the machine allows, on the worker
#   whose entire turn is blocked inside that one command. A stale age of zero is
#   legal and is what the suite drives: that rule still asks both liveness
#   signals, so it hurries an abandoned hold rather than breaking a live one.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# Resolved without ever dereferencing an unset variable: with none of the three
# set, the path stays empty and each subcommand refuses by name rather than the
# whole script aborting on `set -u` before it can dispatch anything.
LOCK=
if [ -n "${FM_GATE_LOCK_DIR:-}" ]; then
  LOCK=$FM_GATE_LOCK_DIR
elif [ -n "${XDG_STATE_HOME:-}" ]; then
  LOCK="$XDG_STATE_HOME/firstmate/fm-gate-lock"
elif [ -n "${HOME:-}" ]; then
  LOCK="$HOME/.local/state/firstmate/fm-gate-lock"
fi
# Canonical form of the ABSOLUTE path $1: repeated separators collapsed, `.`
# components dropped, `..` resolved against what precedes it. Empty output means
# the path names nothing below the root and so nothing this script can hold.
# Purely lexical by design - the hold's own leaf is never followed through a
# symlink, because a symlinked hold must still reach hold_is_foreign as the
# foreign entry it is. No arrays: expanding an empty one under `set -u` is fatal
# on the stock macOS bash this repo still supports.
canonical_path() {
  local rest=$1 part out=''
  while [ -n "$rest" ]; do
    part=${rest%%/*}
    if [ "$part" = "$rest" ]; then rest=; else rest=${rest#*/}; fi
    case "$part" in
      ''|.) ;;
      ..) out=${out%/*} ;;
      *) out="$out/$part" ;;
    esac
  done
  printf '%s\n' "$out"
}

# The hold path must be ABSOLUTE and must name one directory. A relative value
# resolves against each acquiring process's own working directory, and every
# worker runs the mandated one-liner from a different task worktree, so it turns
# the one machine-wide hold into a hold per worktree - the two-full-runs hazard
# this queue exists to prevent, arriving with nothing printed. There is no
# correct base to resolve it against, so it is refused rather than guessed at.
# Canonicalising the rest is what keeps the break marker a SIBLING of the hold
# for every spelling: a trailing slash, a trailing `.` or `..`, or doubled
# separators once left the marker INSIDE the hold, where `mkdir` refreshed the
# hold's own mtime, every age read back as 0, and both the 25-minute rule and the
# ceiling were silently and permanently disabled.
LOCK_RAW=$LOCK
LOCK_UNUSABLE=
LOCK_UNUSABLE_WHY=
if [ -n "$LOCK" ]; then
  case "$LOCK" in
    /*) LOCK=$(canonical_path "$LOCK") ;;
    *) LOCK= ;;
  esac
  if [ -z "$LOCK" ]; then
    LOCK_UNUSABLE=$LOCK_RAW
    case "$LOCK_RAW" in
      /*) LOCK_UNUSABLE_WHY="it names no directory below the filesystem root" ;;
      *) LOCK_UNUSABLE_WHY="it is not an absolute path, so every worker would resolve it against its own worktree and hold a queue of its own" ;;
    esac
  fi
fi
# A configured value that would disable the rule it governs falls back to the
# documented default AND says so, because the operator who mistyped it must learn
# it here rather than discover it as a rule that quietly stopped applying.
note_tunable_fallback() {
  echo "ignoring $1=$2: $3; using the default $4 instead" >&2
}

STALE="${FM_GATE_STALE_SECONDS:-1500}"
case "$STALE" in
  ''|*[!0-9]*)
    [ -z "${FM_GATE_STALE_SECONDS:-}" ] ||
      note_tunable_fallback FM_GATE_STALE_SECONDS "$FM_GATE_STALE_SECONDS" \
        "not a whole number of seconds" 1500
    STALE=1500
    ;;
esac
# A stale age of 0 stays legal: that rule is still gated by both liveness
# signals, so it hurries an abandoned hold rather than breaking a live one. The
# CEILING has no such gate - it breaks a hold however alive its holder is - so a
# zero there grants the queue twice on every acquire, which is the hazard this
# queue exists to prevent arriving through the rule added to bound it. Every
# all-zero spelling is rejected, which only a value test catches.
MAX_HOLD="${FM_GATE_MAX_HOLD_SECONDS:-7200}"
case "$MAX_HOLD" in
  ''|*[!0-9]*)
    [ -z "${FM_GATE_MAX_HOLD_SECONDS:-}" ] ||
      note_tunable_fallback FM_GATE_MAX_HOLD_SECONDS "$FM_GATE_MAX_HOLD_SECONDS" \
        "not a whole number of seconds" 7200
    MAX_HOLD=7200
    ;;
esac
if [ "$MAX_HOLD" -le 0 ]; then
  note_tunable_fallback FM_GATE_MAX_HOLD_SECONDS "$MAX_HOLD" \
    "a zero ceiling breaks every hold instantly, however alive its holder is" 7200
  MAX_HOLD=7200
fi
RESOURCE_WAIT="${FM_GATE_RESOURCE_WAIT_SECONDS:-3600}"
case "$RESOURCE_WAIT" in
  ''|*[!0-9]*)
    [ -z "${FM_GATE_RESOURCE_WAIT_SECONDS:-}" ] ||
      note_tunable_fallback FM_GATE_RESOURCE_WAIT_SECONDS "$FM_GATE_RESOURCE_WAIT_SECONDS" \
        "not a whole number of seconds" 3600
    RESOURCE_WAIT=3600
    ;;
esac
# Zero would give up on the first refusal, which is not a wait at all.
if [ "$RESOURCE_WAIT" -le 0 ]; then
  note_tunable_fallback FM_GATE_RESOURCE_WAIT_SECONDS "$RESOURCE_WAIT" \
    "a zero wait gives up before the neighbouring run has any chance to end" 3600
  RESOURCE_WAIT=3600
fi
POLL="${FM_GATE_POLL_SECONDS:-30}"
case "$POLL" in
  ''|*[!0-9]*)
    [ -z "${FM_GATE_POLL_SECONDS:-}" ] ||
      note_tunable_fallback FM_GATE_POLL_SECONDS "$FM_GATE_POLL_SECONDS" \
        "not a whole number of seconds" 30
    POLL=30
    ;;
esac
# `sleep 0` and `sleep 00` both succeed and spin, so the poll needs the same
# value test rather than a check against the literal string.
if [ "$POLL" -le 0 ]; then
  note_tunable_fallback FM_GATE_POLL_SECONDS "$POLL" \
    "a zero poll turns --wait into a hot spin" 30
  POLL=30
fi
# Derived from the canonical hold's own parent and name, so the marker is a
# sibling of the hold and never an entry inside it, for every spelling of the
# configured path.
BREAK_MUTEX=
[ -n "$LOCK" ] && BREAK_MUTEX="$(dirname "$LOCK")/$(basename "$LOCK").breaking"
# Deliberately NOT $STALE: a marker held for the length of one decision must not
# be aged out on the hold's 25-minute clock, and a suite that drives
# FM_GATE_STALE_SECONDS low must not start removing markers other contenders are
# actively holding, which silently reopens the double-grant window.
BREAK_MUTEX_MAX=120
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

# What a hold records when neither this home's metadata nor the acquiring
# process's directory named a worktree. Never blank: an empty recorded worktree
# read as "no worktree to ask about" and as "ask about everything" at once.
WORKTREE_UNKNOWN='(unknown)'

# The acquiring process's own worktree, when its directory plausibly is one: the
# root of the git working tree it sits in, never the user's home directory and
# never an ancestor of it. See the header for what a home recorded here would do
# to the argv probe.
cwd_worktree() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  top=$(cd "$top" 2>/dev/null && pwd -P) || return 1
  [ -n "$top" ] || return 1
  [ "$top" = "/" ] && return 1
  if [ -n "${HOME:-}" ]; then
    [ "$top" = "$HOME" ] && return 1
    case "$HOME" in "$top"/*) return 1 ;; esac
  fi
  printf '%s\n' "$top"
}

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

# True when something sits at $1 that this uid does not own: a symlink, a
# non-directory, or another user's directory. Both fixed names this script uses
# live in a shared directory, so both get this.
path_is_foreign() {
  local path=$1 uid me
  [ -e "$path" ] || [ -L "$path" ] || return 1
  [ -L "$path" ] && return 0
  [ -d "$path" ] || return 0
  uid=$(path_uid "$path")
  case "$uid" in ''|*[!0-9]*) return 0 ;; esac
  me=$(id -u)
  [ "$uid" = "$me" ] && return 1
  return 0
}

hold_is_foreign() { path_is_foreign "$LOCK"; }

refuse_foreign_hold() {
  # On stdout as well as stderr, for the same reason the busy refusals are.
  echo "QUEUE NOT AVAILABLE - the hold at $LOCK is not owned by this user; refusing to touch it"
  echo "hold at $LOCK is not owned by this user" >&2
}

# No hold path could be resolved at all, so there is nothing to hold, wait for or
# refuse ownership of. Named on both streams like every other refusal a worker
# reads, rather than as a `set -u` abort with a bash diagnostic.
refuse_unresolvable_hold() {
  echo "QUEUE NOT AVAILABLE - the hold path cannot be resolved: none of FM_GATE_LOCK_DIR, XDG_STATE_HOME or HOME is set in this environment"
  echo "cannot resolve the hold path: set FM_GATE_LOCK_DIR, XDG_STATE_HOME or HOME" >&2
}

# A configured path that canonicalises to nothing this script can name a hold at.
# Refused rather than used, because a marker derived from it would land inside
# the hold and disable both break rules without saying so.
refuse_unusable_hold_path() {
  echo "QUEUE NOT AVAILABLE - the configured hold path $LOCK_UNUSABLE cannot be used: $LOCK_UNUSABLE_WHY; set FM_GATE_LOCK_DIR to an absolute directory path every worker can reach"
  echo "unusable hold path $LOCK_UNUSABLE: $LOCK_UNUSABLE_WHY" >&2
}

require_hold_path() {
  [ -n "$LOCK" ] && return 0
  if [ -n "$LOCK_UNUSABLE" ]; then
    refuse_unusable_hold_path
  else
    refuse_unresolvable_hold
  fi
  exit 1
}

# A hold that cannot be created is not a hold someone else is holding, and the
# difference is the whole point: waiting out contention clears, waiting out an
# unwritable parent never does. Refused loudly, on both streams, --wait included.
refuse_unreachable_hold() {
  echo "QUEUE NOT AVAILABLE - the hold at $LOCK cannot be created; its parent $(dirname "$LOCK") is missing or not writable by this user, so no wait can clear it"
  echo "cannot create the hold at $LOCK: its parent is missing or not writable" >&2
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
  [ "$wt" = "$WORKTREE_UNKNOWN" ] && return 1
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

# Either signal votes the holder alive; only silence from both is abandonment.
# The OR is strictly fail-safe - it can never turn a live holder into a dead one -
# and the header says what each signal is blind to.
owner_running() {
  [ -n "$(owner)" ] || return 1
  owner_process_alive && return 0
  check_work_live "$(owner_worktree)"
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
# before the removal, against the same threshold that justified the break. See
# the header for the failures this closes.
break_if_abandoned() {
  local now age holder identity why threshold broke=1
  [ -d "$LOCK" ] || return 1
  hold_is_foreign && return 1
  now=$(date +%s)
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  # Cheap pre-filter, so contenders do not queue on the marker for a fresh hold.
  # The ceiling is checked here too, in case it is configured below the stale age.
  age=$(path_age "$now" "$LOCK")
  [ "$age" -ge "$STALE" ] || [ "$age" -ge "$MAX_HOLD" ] || return 1

  # The marker is a second fixed name in the same shared directory, so it carries
  # the hold's own protections. Left unguarded, one `mkdir` by another user
  # disabled the abandoned-hold rule for every home on the machine, permanently
  # and without printing anything.
  if path_is_foreign "$BREAK_MUTEX"; then
    echo "BREAK NOT POSSIBLE - the break marker at $BREAK_MUTEX is not owned by this user; the abandoned-hold rule stays disabled until it is removed by hand" >&2
    return 1
  fi
  # A breaker killed mid-decision must not wedge the rule for every later one.
  if [ -d "$BREAK_MUTEX" ] && [ "$(path_age "$now" "$BREAK_MUTEX")" -ge "$BREAK_MUTEX_MAX" ]; then
    rmdir "$BREAK_MUTEX" 2>/dev/null
  fi
  mkdir "$BREAK_MUTEX" 2>/dev/null || return 1

  now=$(date +%s)
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  age=$(path_age "$now" "$LOCK")
  identity=$(hold_identity)
  why=
  threshold=
  if [ -d "$LOCK" ] && ! hold_is_foreign; then
    if [ "$age" -ge "$MAX_HOLD" ]; then
      why="past the ${MAX_HOLD}s ceiling, broken however alive it looks"
      threshold=$MAX_HOLD
    elif [ "$age" -ge "$STALE" ] && ! owner_running; then
      why="holder process gone and no check work in its worktree"
      threshold=$STALE
    fi
  fi
  if [ -n "$why" ]; then
    holder=$(owner)
    now=$(date +%s)
    case "$now" in ''|*[!0-9]*) now=0 ;; esac
    # Age first, identity last, and the message after the removal: everything
    # between the final identity read and the `rm -rf` is a window in which the
    # judged holder can release and a fresh contender can take the path.
    if [ "$(path_age "$now" "$LOCK")" -ge "$threshold" ] && [ "$(hold_identity)" = "$identity" ]; then
      rm -rf "$LOCK"
      broke=0
      echo "breaking an abandoned hold (owner $holder, ${age}s old, $why)" >&2
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
    require_hold_path
    ID=${2:-}
    [ -n "$ID" ] || { echo "error: acquire needs a task id" >&2; exit 2; }
    WAIT=${3:-}
    [ -z "$WAIT" ] || [ "$WAIT" = "--wait" ] || { echo "error: unknown argument: $WAIT" >&2; exit 2; }
    if ! mkdir -p "$(dirname "$LOCK")" 2>/dev/null && [ ! -d "$(dirname "$LOCK")" ]; then
      refuse_unreachable_hold
      exit 1
    fi
    # Resolved once, before any hold exists: a crewmate pane carries no FM_HOME,
    # so the metadata lookup finds nothing there and the worker's own worktree is
    # the task worktree by construction of the mandated one-liner.
    OWNER_WT=$(worktree_of "$ID")
    [ -n "$OWNER_WT" ] || OWNER_WT=$(cwd_worktree)
    [ -n "$OWNER_WT" ] || OWNER_WT="$WORKTREE_UNKNOWN"
    OWNER_READS=0
    MISSING_READS=0
    RESOURCE_SINCE=
    RESOURCE_NAMED=
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
        printf '%s\n' "$OWNER_WT" > "$LOCK/owner_worktree"
        printf '%s\n' "$PPID" > "$LOCK/owner_pid"
        printf '%s\n' "$(process_start "$PPID")" > "$LOCK/owner_pid_start"
        printf '%s.%s.%s\n' "$$" "$(date +%s)" "${RANDOM:-0}" > "$LOCK/token"
        if OTHER=$(other_task_running "$ID"); then
          [ "$(owner)" = "$ID" ] && rm -rf "$LOCK"
          # Printed on stdout as well as stderr: a worker reading only stdout
          # took a refusal for a success on 2026-09-08. Under --wait it is
          # printed once per named task rather than once per poll, so a long
          # wait does not bury the turn it is blocking in repeated lines.
          if [ "$WAIT" != "--wait" ]; then
            echo "QUEUE NOT GRANTED - a full run is already live in $OTHER, although the hold was free"
            echo "a full run is live outside the hold, in $OTHER" >&2
            exit 1
          fi
          NOW=$(date +%s)
          case "$NOW" in ''|*[!0-9]*) NOW=0 ;; esac
          [ -n "$RESOURCE_SINCE" ] || RESOURCE_SINCE=$NOW
          if [ "$RESOURCE_NAMED" != "$OTHER" ]; then
            echo "QUEUE NOT GRANTED - a full run is already live in $OTHER, although the hold was free"
            echo "a full run is live outside the hold, in $OTHER" >&2
            RESOURCE_NAMED=$OTHER
          fi
          WAITED=$(( NOW - RESOURCE_SINCE ))
          if [ "$WAITED" -ge "$RESOURCE_WAIT" ]; then
            echo "QUEUE GIVEN UP - a full run in $OTHER stayed live for the whole ${RESOURCE_WAIT}s wait; the queue was never granted and this wait was abandoned rather than satisfied"
            echo "gave up after ${WAITED}s: a full run is still live in $OTHER" >&2
            exit 1
          fi
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
      # mkdir failed and nothing is at the path: contention cannot explain that,
      # and no amount of waiting makes an unwritable parent writable. A brief
      # budget covers a holder that released inside the same instant.
      if [ ! -d "$LOCK" ]; then
        if [ "$MISSING_READS" -lt 40 ]; then
          MISSING_READS=$(( MISSING_READS + 1 ))
          sleep 0.05
          continue
        fi
        refuse_unreachable_hold
        exit 1
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
    require_hold_path
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
    require_hold_path
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
