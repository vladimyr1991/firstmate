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
#        fm-gate.sh run <id> [--wait] [--status <file>] -- <command...>
#                                          take the queue, run <command> as a child with a
#                                          heartbeat, release, and exit with <command>'s status;
#                                          1 when the queue was not granted (<command> never ran),
#                                          2 on a usage error
#        fm-gate.sh park <id> --reason <text> [--for <seconds>]
#                                          hold the queue deliberately with nothing running
#        fm-gate.sh release <id>            release your own hold; another task's hold is refused
#        fm-gate.sh status [--line] [--journal [N]]
#                                          print the holder, its liveness and the waiters;
#                                          --line joins that on one line, --journal tails the journal
#        fm-gate.sh limits                  print the thresholds in force, by variable name
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
#   a RESOURCE refusal is bounded by FM_GATE_RESOURCE_WAIT_SECONDS and then GIVEN
#   UP loudly, naming the task whose run is live. Giving up is not
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
#   into a grant and a resource refusal never does - it is only ever given up. And
#   the mandated worker one-liner carries `run ... -- <the gate command>` in a
#   single argv, so a harness that shells out via `bash -c` leaves the worktree
#   path and the runner name in a MERELY WAITING shell: counting that text would
#   have put two waiters in a permanent two-way stall, each reading the other's
#   unrun command as a live run. A process holding this script's invocation is a
#   waiter or a wrapper by contract and never the run itself, so it is skipped
#   before the runner match.
#
# THRESHOLDS - this header is the single owner of what each one means; `limits`
# prints the values in force and every message that names a threshold names it
# as `<value>s (<VARIABLE>)`.
#   FM_GATE_STALE_SECONDS (default 1500): the abandonment threshold. A hold
#     younger than this is never judged at all. Past it, a hold is abandoned only
#     when the holder proves nothing alive, in this order and stopping at the
#     first answer:
#       (a) a HEARTBEAT younger than this threshold - the holder's own proof,
#           written by `run` (below) - means alive, and nothing further is asked;
#       (b) a PARK (below) whose deadline has not passed means alive;
#       (c) otherwise the two INFERRED signals are ORed, and the OR is the point:
#           each one is blind exactly where the other sees.
#           - The recorded HOLDER PROCESS: for `acquire` the parent of this
#             script, the shell running the mandated one-liner; for `run` the
#             wrapper itself. Its pid and start time are written into the hold at
#             issue time, because argv cannot answer the question at all - the
#             only process whose argv carries the task worktree is the wrapper
#             shell, which must be skipped for being a waiter, while the real
#             runner carries no path (`make test`, a system `pytest tests/`, a
#             bare `bash tests/foo.test.sh`), and a genuinely running suite lost
#             its hold at the abandonment threshold because of it. The start time
#             is compared as well as the pid so a recycled pid cannot masquerade
#             as the holder; an unreadable start time counts as ALIVE, because
#             uncertainty must never break a hold.
#           - The argv CHECK-WORK probe against the hold's own recorded worktree.
#             The recorded process can die while the run does not: a harness
#             tool-call timeout kills the wrapper and the suite it started keeps
#             going as an orphan re-parented to init, and breaking that hold puts
#             a second full run on the machine. Asked only about one hold's
#             recorded worktree it cannot deadlock waiters the way a fleet-wide
#             "is anybody busy" question once did. It is NOT a guarantee and is
#             blind in the shapes listed above; such a hold falls back to the
#             ordinary age rule. Widening the probe past the hold's own recorded
#             worktree is deliberately not the answer: a machine-wide "is any
#             check work running anywhere" question lets unrelated work in an
#             unrelated checkout hold this whole fleet shut.
#     A hold written by an older copy of this script records no process; the
#     probe alone then answers, exactly as it used to.
#   FM_GATE_MAX_HOLD_SECONDS (default 7200): the ceiling on the INFERRED signals
#     only. Past it a hold WITHOUT a live heartbeat and not parked is broken
#     however alive those inferred signals look, loudly, on stderr, naming what
#     was seen. Without it a recorded parent that outlives its run - a harness
#     reusing one shell across tool calls, or a caller whose `bash -c`
#     exec-optimises the wrapper away so $PPID names the session - would wedge
#     every home on the machine forever with no escape but a manual delete. A
#     hold with a LIVE heartbeat is never broken by the ceiling, at any age: the
#     heartbeat is proof the holder itself supplies, and on 2026-09-17 a full run
#     measured at 134 minutes was broken at two hours while genuinely live. A
#     waiter that sees such a hold past the ceiling journals `over-ceiling-alive`
#     once per hold, and the holder's own `run` appends one `working:` line to
#     its status file when it crosses the ceiling, so an unusually long run is
#     visible without being interrupted.
#   FM_GATE_RESOURCE_WAIT_SECONDS (default 3600): how long --wait sits on a
#     RESOURCE refusal before giving up, generous enough that an ordinary full run
#     in a neighbouring worktree never trips it.
#   FM_GATE_POLL_SECONDS (default 30): the --wait poll.
#   FM_GATE_HEARTBEAT_SECONDS (default 60): how often `run` touches the
#     heartbeat while its command is alive and the hold is still its own.
#   FM_GATE_PARK_SECONDS (default 3600): the default deadline of a park.
#   A non-numeric value, and a zero for any threshold but the stale age, falls
#   back to its default LOUDLY on stderr rather than silently disabling the rule
#   it governs: a zero ceiling breaks every heartbeat-less hold instantly,
#   granting the queue twice, and a poll of zero - or one that every `sleep`
#   refuses - turns --wait into a hot spin that re-runs the whole probe as fast
#   as the machine allows, on the worker whose entire turn is blocked inside
#   that one command. A stale age of zero is legal and is what the suite drives:
#   that rule still asks the liveness signals, so it hurries an abandoned hold
#   rather than breaking a live one.
#
#   `run` is the mandated shape for a worker: it queues, takes the hold, appends
#   exactly `working: queue taken, gate running` to the --status file, starts the
#   command as a CHILD (not exec, so the wrapper stays the recorded holder
#   process and the leader of its own PROCESS GROUP), keeps the heartbeat,
#   forwards SIGTERM and SIGINT to that whole group (INT is forwarded as TERM,
#   because a background child of a non-interactive shell ignores INT; the
#   group, because a `bash -c` child dies on TERM at once and would leave the
#   suite it started running as an orphan), waits, releases unless the hold was
#   parked meanwhile, and exits with the command's own status. Release on any
#   exit status is therefore a property of the wrapper and no longer a
#   discipline asked of the worker. The command's stdin is /dev/null: a job in
#   its own group is never handed the terminal, so a command that read its
#   terminal would stop silently with a fresh heartbeat; it reads EOF instead,
#   and a run's command never reads its terminal. Two exceptions keep "release
#   on every exit" from meaning "release over a live run": after a SIGNALLED
#   exit the wrapper gives the group a bounded grace to shut down (runners
#   handle TERM gracefully and are still winding down when the `bash -c` that
#   started them has already died), polling the group and the check-work probe
#   against the hold's worktree, and releases once the tree has drained; only
#   when the run is still seen at the end of the grace does it PARK the hold
#   (`run-orphaned-after-signal`, for the default park deadline), say so on
#   stderr, and leave the worker to stop the orphan and release. And a `run`
#   for an id whose earlier run is still alive (fresh heartbeat, recorded
#   process alive) is refused as `your own run <pid> is still live` rather than
#   displacing it - the re-take is allowed only from a holder that is provably
#   gone, and it ends any park that holder left (journaled `unparked`): the
#   park described the previous holder's state, not this run's. A signal that
#   lands after the grant and before the command started releases the hold
#   (`signal-before-run`).
#   If the hold is taken from under a live run - which only the ceiling on an
#   inferred signal or a hand delete can do - the heartbeat notices the token
#   change, stops, says so on stderr, journals `run-lost-hold`, and the run is
#   neither killed nor its successor's hold touched.
#   `park` is the deliberate "hold the queue, run nothing" state that was missing
#   on 2026-09-16: a hold with nothing running was broken as abandoned after the
#   stale age while its owner was triaging a broken run. A park carries a reason
#   and a deadline; until the deadline it is judged neither abandoned nor over
#   the ceiling; past it the hold is judged like one without a heartbeat, and
#   the break names `park-expired`. `release` ends it.
#
#   ORDER OF ARRIVAL. Every --wait (acquire or run) files a TICKET in
#   <hold>.queue/ named <since>.<pid>.<id>, and a freed hold goes to the waiter
#   whose live ticket is the oldest (by arrival second, then by pid), while the
#   others sleep another poll. Before this, a freed hold went to whichever
#   waiter's poll happened to land first, and one waiter was passed twice in
#   four hours. A call WITHOUT --wait while live tickets exist is refused with
#   the count and the oldest waiter, so nobody skips the queue by not waiting; a
#   ticket whose pid is dead, or whose recorded start time no longer matches, is
#   removed by any waiter, so a killed waiter blocks nobody. Named risk: the
#   oldest waiter that is alive but no longer polling (stopped by a signal)
#   holds the queue idle until it dies or is removed; `status` shows exactly
#   that shape as `free` with a waiter list.
#
#   JOURNAL. <hold>.journal receives one line per event - taken, released,
#   parked, unparked, broken, over-ceiling-alive, run-lost-hold - as
#   `<iso8601Z> <event> id=<id> k=v ...`. It is never read for an issuance
#   decision; it exists for people and for `status --journal`. A BREAK also
#   appends `blocked [key=gate-hold-broken]: ...` to the displaced holder's own
#   status file (recorded at issue time as owner_status: the --status file of
#   `run`, or $FM_HOME/state/<id>.status when it exists for `acquire`), because
#   that line is what wakes firstmate; a break that reached nobody was found by
#   hand-matching pids against logs.
#
#   NOT compatible across paths: a home still running an older PRIVATE copy of
#   this script holds $FM_HOME/state/.gate-lock, which this machine-wide hold does
#   not touch, so the two do NOT serialize against each other and a private copy
#   must be retired or repointed at this script. Reading a hold from an older
#   copy - no process, no heartbeat, no `taken` - is a different and still
#   supported compatibility: it is judged by the inferred signals and the ceiling.
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
#   The marker is approached only when the heartbeat and the park have NOT
#   answered "alive": a waiter beside a live run costs one or two `stat` calls
#   per poll and never creates the marker, where before every waiter re-created
#   it every poll and read each other's `rmdir` as a foreign marker.
#   A fixed name in a shared directory can be pre-created by another user, so a
#   hold, marker, ticket directory or journal that is a symlink, is not the
#   expected kind of entry, or is not owned by this uid is refused outright and
#   the refusal names what was found: it is never broken, never removed, and
#   never followed. An owner that merely could not be READ - three tries, 50 ms
#   apart - is not foreign: the round is skipped and the next poll retries,
#   because a marker removed between the existence test and the ownership read
#   was once reported as another user's, and two workers went looking for a user
#   who did not exist.
# Environment: FM_GATE_LOCK_DIR overrides the machine-wide hold path (default
#   ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/fm-gate-lock, which is one
#   hold per unix user - set it to a shared writable path in every fleet when
#   two different users run fleets on one machine; it must be ABSOLUTE, because a
#   relative one gives every worktree a hold of its own and is refused); the
#   ticket directory, journal and break marker are its siblings <hold>.queue,
#   <hold>.journal and <hold>.breaking for every spelling of the path. FM_HOME
#   selects the home whose state/ the home-scoped issuance probe scans and
#   nothing else; FM_STATE_OVERRIDE overrides that state directory. The
#   FM_GATE_*_SECONDS thresholds are owned above.
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
# symlink, because a symlinked hold must still reach the foreign check as the
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
# Canonicalising the rest is what keeps the break marker, the ticket directory
# and the journal SIBLINGS of the hold for every spelling: a trailing slash, a
# trailing `.` or `..`, or doubled separators once left the marker INSIDE the
# hold, where `mkdir` refreshed the hold's own mtime, every age read back as 0,
# and both the abandonment rule and the ceiling were silently and permanently
# disabled.
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

# whole_seconds_or_default <VAR> <value> <default> <zero-reason>: prints the
# value when it is a whole number, and the default (loudly) otherwise; a
# zero-reason of `-` makes zero legal.
whole_seconds_or_default() {
  local var=$1 value=$2 default=$3 zero_reason=$4
  case "$value" in
    ''|*[!0-9]*)
      [ -z "$value" ] || note_tunable_fallback "$var" "$value" "not a whole number of seconds" "$default"
      printf '%s\n' "$default"
      return 0
      ;;
  esac
  if [ "$zero_reason" != - ] && [ "$value" -le 0 ]; then
    note_tunable_fallback "$var" "$value" "$zero_reason" "$default"
    printf '%s\n' "$default"
    return 0
  fi
  printf '%s\n' "$value"
}

# A stale age of 0 stays legal: that rule is still gated by the liveness
# signals, so it hurries an abandoned hold rather than breaking a live one. The
# CEILING has no such gate for a heartbeat-less hold, so a zero there grants the
# queue twice on every acquire, which is the hazard this queue exists to prevent
# arriving through the rule added to bound it. Every all-zero spelling is
# rejected, which only a value test catches; `sleep 0` and `sleep 00` both
# succeed and spin, so the poll needs the same value test.
STALE=$(whole_seconds_or_default FM_GATE_STALE_SECONDS "${FM_GATE_STALE_SECONDS:-}" 1500 -)
MAX_HOLD=$(whole_seconds_or_default FM_GATE_MAX_HOLD_SECONDS "${FM_GATE_MAX_HOLD_SECONDS:-}" 7200 \
  "a zero ceiling breaks every heartbeat-less hold instantly, however alive its holder is")
RESOURCE_WAIT=$(whole_seconds_or_default FM_GATE_RESOURCE_WAIT_SECONDS "${FM_GATE_RESOURCE_WAIT_SECONDS:-}" 3600 \
  "a zero wait gives up before the neighbouring run has any chance to end")
POLL=$(whole_seconds_or_default FM_GATE_POLL_SECONDS "${FM_GATE_POLL_SECONDS:-}" 30 \
  "a zero poll turns --wait into a hot spin")
HEARTBEAT=$(whole_seconds_or_default FM_GATE_HEARTBEAT_SECONDS "${FM_GATE_HEARTBEAT_SECONDS:-}" 60 \
  "a zero heartbeat interval turns the holder into a hot spin")
PARK_DEFAULT=$(whole_seconds_or_default FM_GATE_PARK_SECONDS "${FM_GATE_PARK_SECONDS:-}" 3600 \
  "a zero park deadline expires the park before it is taken")
# Derived from the canonical hold's own parent and name, so each is a sibling of
# the hold and never an entry inside it, for every spelling of the configured
# path.
BREAK_MUTEX=
QUEUE_DIR=
JOURNAL=
if [ -n "$LOCK" ]; then
  BREAK_MUTEX="$(dirname "$LOCK")/$(basename "$LOCK").breaking"
  QUEUE_DIR="$(dirname "$LOCK")/$(basename "$LOCK").queue"
  JOURNAL="$(dirname "$LOCK")/$(basename "$LOCK").journal"
fi
# Deliberately NOT $STALE: a marker held for the length of one decision must not
# be aged out on the hold's abandonment clock, and a suite that drives
# FM_GATE_STALE_SECONDS low must not start removing markers other contenders are
# actively holding, which silently reopens the double-grant window.
BREAK_MUTEX_MAX=120
GATE_SELF="$(basename "${BASH_SOURCE[0]}")"
GATE_SELF_INVOCATION="${GATE_SELF//./\\.}[\"']?[[:space:]]+(acquire|release|status|run|park|limits)([[:space:]]|\$)"
ME_UID=$(id -u)

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

# Process-wide cleanup: the ticket this process filed and the heartbeat it
# started must not outlive it, whatever path ends it. A `run` ended by a signal
# after its hold was written but before its command started (RUN_STARTED still
# empty) releases that hold here, so the window between the grant and the
# traps run_command installs cannot leave a hold with nothing behind it.
MY_TICKET=
HB_PID=
RUN_ID=
RUN_STARTED=
WROTE_TOKEN=
# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup_on_exit() {
  [ -z "$HB_PID" ] || kill "$HB_PID" 2>/dev/null
  [ -z "$MY_TICKET" ] || rm -f "$MY_TICKET" 2>/dev/null
  if [ -n "$RUN_ID" ] && [ -z "$RUN_STARTED" ] && [ -n "$WROTE_TOKEN" ] \
    && [ "$(hold_token)" = "$WROTE_TOKEN" ]; then
    echo "run interrupted before its command started; releasing" >&2
    release_hold "$RUN_ID" signal-before-run
  fi
}
trap cleanup_on_exit EXIT

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
hold_taken() { cat "$LOCK/taken" 2>/dev/null; }
hold_owner_status() { cat "$LOCK/owner_status" 2>/dev/null; }

now_epoch() {
  local now
  now=$(date +%s)
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  printf '%s\n' "$now"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Absolute start time of $1 on one line, or empty when it cannot be read.
process_start() {
  ps -p "$1" -o lstart= 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

# process_alive_as_recorded <pid> <recorded-start>: the recorded process, checked
# as a fact. The start time is compared as well as the pid so a recycled pid
# cannot masquerade as the holder; an unreadable start time on either side counts
# as ALIVE, because uncertainty must never break a hold or drop a waiter.
process_alive_as_recorded() {
  local pid=$1 recorded=$2 current
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  [ -n "$recorded" ] || return 0
  current=$(process_start "$pid")
  [ -n "$current" ] || return 0
  [ "$current" = "$recorded" ]
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

# path_kind <path> [dir|file]: what sits at <path>, as one of
#   absent, directory-own, file-own, symlink, not-a-directory, not-a-file,
#   foreign-uid <uid>, unreadable-owner.
# Every fixed name this script uses lives in a shared directory, so every one of
# them gets this. The ownership read is retried three times 50 ms apart and the
# existence test is repeated each time: an entry removed between the test and
# the read is `absent`, not another user's, and one that stays unreadable is
# reported as exactly that.
path_kind() {
  local path=$1 want=${2:-dir} tries=0 uid
  while :; do
    if [ -L "$path" ]; then printf 'symlink\n'; return 0; fi
    if [ ! -e "$path" ]; then printf 'absent\n'; return 0; fi
    if [ "$want" = dir ]; then
      [ -d "$path" ] || { printf 'not-a-directory\n'; return 0; }
    else
      [ -f "$path" ] || { printf 'not-a-file\n'; return 0; }
    fi
    uid=$(path_uid "$path")
    case "$uid" in
      ''|*[!0-9]*)
        tries=$((tries + 1))
        if [ "$tries" -ge 3 ]; then printf 'unreadable-owner\n'; return 0; fi
        sleep 0.05
        continue
        ;;
    esac
    if [ "$uid" = "$ME_UID" ]; then
      if [ "$want" = dir ]; then printf 'directory-own\n'; else printf 'file-own\n'; fi
      return 0
    fi
    printf 'foreign-uid %s\n' "$uid"
    return 0
  done
}

# True for the kinds this user must never touch: another user's entry, or
# something that is not the expected kind of entry at all.
kind_is_foreign() {
  case "$1" in
    symlink|not-a-directory|not-a-file|"foreign-uid "*) return 0 ;;
  esac
  return 1
}

# describe_kind <path> <kind>: the finding, in words a reader can act on.
describe_kind() {
  local path=$1 kind=$2
  case "$kind" in
    symlink) printf '%s is a symbolic link\n' "$path" ;;
    not-a-directory) printf '%s is not a directory\n' "$path" ;;
    not-a-file) printf '%s is not a regular file\n' "$path" ;;
    "foreign-uid "*) printf '%s is owned by uid %s, not %s\n' "$path" "${kind#foreign-uid }" "$ME_UID" ;;
    unreadable-owner) printf 'the owner of %s could not be read\n' "$path" ;;
    *) printf '%s is %s\n' "$path" "$kind" ;;
  esac
}

HOLD_KIND=
# Classifies the hold once per call site into HOLD_KIND; true when it is foreign.
hold_is_foreign() {
  HOLD_KIND=$(path_kind "$LOCK" dir)
  kind_is_foreign "$HOLD_KIND"
}

refuse_foreign_hold() {
  local finding
  finding=$(describe_kind "$LOCK" "$HOLD_KIND")
  # On stdout as well as stderr, for the same reason the busy refusals are.
  echo "QUEUE NOT AVAILABLE - the hold at $LOCK is not this user's to touch: $finding; refusing to touch it"
  echo "hold at $LOCK refused: $finding" >&2
}

# The hold exists but its owner could not be read even after retries. Not
# foreign, not free: the round is skipped and the next poll retries.
refuse_unreadable_hold() {
  echo "QUEUE NOT AVAILABLE - could not read the owner of the hold at $LOCK; retrying next poll"
  echo "could not read the owner of $LOCK; retrying next poll" >&2
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
  process_alive_as_recorded "$(owner_pid)" "$(owner_pid_start)"
}

# Either inferred signal votes the holder alive; only silence from both is
# abandonment. The OR is strictly fail-safe - it can never turn a live holder
# into a dead one - and the header says what each signal is blind to.
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

# Age of the hold: from its recorded issue time when this script wrote one,
# because files created inside the hold later (heartbeat, park) refresh the
# directory's own mtime; a hold from an older copy records none, and its mtime
# stands in exactly as before.
hold_age() {
  local now=$1 taken
  taken=$(hold_taken)
  case "$taken" in
    ''|*[!0-9]*) path_age "$now" "$LOCK" ;;
    *) printf '%s\n' "$(( now - taken ))" ;;
  esac
}

# Age of the holder's heartbeat, or -1 when the hold has none.
heartbeat_age() {
  [ -e "$LOCK/heartbeat" ] || { printf '%s\n' -1; return 0; }
  path_age "$1" "$LOCK/heartbeat"
}

# A heartbeat younger than the abandonment threshold is the holder's own proof.
heartbeat_fresh() {
  local hb
  hb=$(heartbeat_age "$1")
  [ "$hb" -ge 0 ] && [ "$hb" -lt "$STALE" ]
}

# The words the break message and journal use for the heartbeat evidence.
heartbeat_words() {
  local hb
  hb=$(heartbeat_age "$1")
  if [ "$hb" -lt 0 ]; then printf 'none\n'; else printf 'silent %ss\n' "$hb"; fi
}

PARK_REASON=
PARK_UNTIL=
# True when the hold is parked; leaves the reason and deadline in PARK_REASON
# and PARK_UNTIL.
read_park() {
  PARK_REASON=
  PARK_UNTIL=
  [ -f "$LOCK/parked" ] || return 1
  PARK_REASON=$(sed -n 's/^reason=//p' "$LOCK/parked" 2>/dev/null | head -n 1)
  PARK_UNTIL=$(sed -n 's/^until=//p' "$LOCK/parked" 2>/dev/null | head -n 1)
  case "$PARK_UNTIL" in ''|*[!0-9]*) PARK_UNTIL=0 ;; esac
  return 0
}

# Journal values carry no spaces, so a line stays one line of k=v fields.
journal_value() { printf '%s' "$1" | tr ' \t\n' '___'; }

JOURNAL_WARNED=
# journal <event> <id> [k=v ...]: one line, appended, best effort. A journal
# that is not this user's regular file is left alone and said so once per call.
journal() {
  local event=$1 id=$2 kind line
  shift 2
  [ -n "$JOURNAL" ] || return 0
  kind=$(path_kind "$JOURNAL" file)
  case "$kind" in
    absent|file-own) ;;
    *)
      if [ -z "$JOURNAL_WARNED" ]; then
        echo "not writing the queue journal: $(describe_kind "$JOURNAL" "$kind")" >&2
        JOURNAL_WARNED=1
      fi
      return 0
      ;;
  esac
  line="$(now_iso) $event id=$(journal_value "$id")"
  while [ "$#" -gt 0 ]; do
    line="$line ${1%%=*}=$(journal_value "${1#*=}")"
    shift
  done
  printf '%s\n' "$line" >> "$JOURNAL" 2>/dev/null || true
}

# --- tickets: order of arrival ----------------------------------------------

refuse_foreign_queue_dir() {
  local finding
  finding=$(describe_kind "$QUEUE_DIR" "$1")
  echo "QUEUE NOT AVAILABLE - the queue directory $QUEUE_DIR is not this user's to touch: $finding; refusing to touch it"
  echo "queue directory refused: $finding" >&2
}

refuse_unreachable_queue_dir() {
  echo "QUEUE NOT AVAILABLE - the queue directory $QUEUE_DIR cannot be created; its parent is missing or not writable by this user, so no wait can clear it"
  echo "cannot create the queue directory $QUEUE_DIR: its parent is missing or not writable" >&2
}

# Fields of ticket <file>, as the process that filed it recorded them.
ticket_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }

# file_ticket <id>: record this process's place in the queue. Written whole to a
# temporary name and moved into place, so no reader sees a half ticket. Refuses
# on both streams when the directory is not this user's, or cannot be created.
file_ticket() {
  local id=$1 kind since tmp
  kind=$(path_kind "$QUEUE_DIR" dir)
  case "$kind" in
    absent)
      if ! mkdir -p "$QUEUE_DIR" 2>/dev/null && [ ! -d "$QUEUE_DIR" ]; then
        refuse_unreachable_queue_dir
        return 1
      fi
      ;;
    directory-own) ;;
    unreadable-owner)
      echo "QUEUE NOT AVAILABLE - could not read the owner of the queue directory $QUEUE_DIR"
      echo "could not read the owner of $QUEUE_DIR" >&2
      return 1
      ;;
    *)
      refuse_foreign_queue_dir "$kind"
      return 1
      ;;
  esac
  since=$(now_epoch)
  MY_TICKET="$QUEUE_DIR/$since.$$.$id"
  tmp="$QUEUE_DIR/.$since.$$.$id.tmp"
  if ! printf 'id=%s\npid=%s\npid_start=%s\nsince=%s\n' "$id" "$$" "$(process_start "$$")" "$since" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$MY_TICKET" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    MY_TICKET=
    refuse_unreachable_queue_dir
    return 1
  fi
  return 0
}

# live_tickets: prints the live tickets oldest first as `<since> <pid> <id> <name>`
# (name is the file's own name under <hold>.queue), removing every ticket whose
# process is gone on the way. The order is the recorded arrival second, then
# pid as a number - two tickets filed in the same second have a deterministic
# order.
live_tickets() {
  local f name since pid start id
  [ -d "$QUEUE_DIR" ] || return 0
  for f in "$QUEUE_DIR"/*; do
    [ -L "$f" ] && continue
    [ -f "$f" ] || continue
    name=$(basename "$f")
    case "$name" in .*) continue ;; esac
    pid=$(ticket_field "$f" pid)
    [ -n "$pid" ] || { pid=${name#*.}; pid=${pid%%.*}; }
    since=$(ticket_field "$f" since)
    case "$since" in ''|*[!0-9]*) since=${name%%.*} ;; esac
    id=$(ticket_field "$f" id)
    [ -n "$id" ] || id=${name#*.*.}
    start=$(ticket_field "$f" pid_start)
    if ! process_alive_as_recorded "$pid" "$start"; then
      rm -f "$f" 2>/dev/null
      continue
    fi
    printf '%s %s %s %s\n' "$since" "$pid" "$id" "$name"
  done | sort -k1,1n -k2,2n
}

# queue_turn <id> <--wait|''>: 0 when this caller may take a free hold now.
# With --wait, only when its own ticket is the oldest live one; without, only
# when no live ticket exists at all, in which case the refusal is printed on
# both streams and 1 returned. 2 means the queue directory is not usable.
queue_turn() {
  local id=$1 wait=$2 kind tickets count oldest_since oldest_pid oldest_id oldest_name now
  kind=$(path_kind "$QUEUE_DIR" dir)
  case "$kind" in
    absent) return 0 ;;
    directory-own) ;;
    unreadable-owner)
      echo "could not read the owner of $QUEUE_DIR; retrying next poll" >&2
      return 1
      ;;
    *)
      refuse_foreign_queue_dir "$kind"
      return 2
      ;;
  esac
  tickets=$(live_tickets)
  if [ "$wait" = "--wait" ] && [ ! -f "$MY_TICKET" ]; then
    # This waiter's own ticket is gone (removed by hand, or the directory was
    # recreated): file a fresh one rather than wait forever behind nothing.
    MY_TICKET=
    file_ticket "$id" || return 2
    return 1
  fi
  [ -n "$tickets" ] || return 0
  # shellcheck disable=SC2034  # the pid is positional; only the name is compared
  read -r oldest_since oldest_pid oldest_id oldest_name <<EOF
$(printf '%s\n' "$tickets" | head -n 1)
EOF
  if [ "$wait" = "--wait" ]; then
    [ "$oldest_name" = "$(basename "$MY_TICKET")" ]
    return $?
  fi
  count=$(printf '%s\n' "$tickets" | wc -l | tr -d ' ')
  now=$(now_epoch)
  echo "QUEUE NOT YOURS - free, but $count waiting ahead of you (oldest $oldest_id, waiting $(( now - oldest_since ))s); use --wait to queue"
  echo "free, but $count waiting ahead of you (oldest $oldest_id); use --wait to queue" >&2
  return 1
}

# --- breaking a provably abandoned hold ---------------------------------------

# Append the break trace to the displaced holder's own status file, when the
# hold recorded one and it is this user's regular file.
trace_break_to_holder() {
  local breaker=$1 age=$2 why=$3 target kind
  target=$(hold_owner_status)
  [ -n "$target" ] || return 0
  kind=$(path_kind "$target" file)
  case "$kind" in
    file-own)
      printf 'blocked [key=gate-hold-broken]: the test-gate hold was broken by %s after %ss (%s); if a run is still live it is unprotected now - stop it or re-take the queue\n' \
        "$breaker" "$age" "$why" >> "$target" 2>/dev/null || true
      ;;
    *)
      echo "not writing the broken-hold line: $(describe_kind "$target" "$kind")" >&2
      ;;
  esac
}

# A live run older than the ceiling is noted once per hold, keyed by its token.
note_over_ceiling_alive() {
  local token
  token=$(hold_token)
  [ -n "$token" ] || token="owner:$(owner)"
  if [ "$(path_kind "$JOURNAL" file)" = file-own ] \
    && grep -qF "over-ceiling-alive id=$(journal_value "$(owner)") token=$(journal_value "$token")" "$JOURNAL" 2>/dev/null; then
    return 0
  fi
  journal over-ceiling-alive "$(owner)" "token=$token" "age=$1" "ceiling=${MAX_HOLD}s"
}

# Break the hold if it is provably abandoned, on behalf of contender $1. Only
# one contender decides at a time, behind $BREAK_MUTEX, and the decision is a
# compare-and-swap: the hold's identity is captured before the liveness check
# and re-verified immediately before the removal, against the same threshold
# that justified the break. See the header for the failures this closes and for
# the order in which liveness is asked.
break_if_abandoned() {
  local breaker=$1 now age holder identity why threshold broke=1 park_note
  local proc work hb_words hb_journal kind
  [ -d "$LOCK" ] || return 1
  hold_is_foreign && return 1
  [ "$HOLD_KIND" = directory-own ] || return 1
  now=$(now_epoch)
  # Cheap pre-filter, so contenders do not queue on the marker for a fresh hold.
  # The ceiling is checked here too, in case it is configured below the stale age.
  age=$(hold_age "$now")
  [ "$age" -ge "$STALE" ] || [ "$age" -ge "$MAX_HOLD" ] || return 1
  # (a) The holder's own proof answers before anything is inferred or touched.
  if heartbeat_fresh "$now"; then
    [ "$age" -ge "$MAX_HOLD" ] && note_over_ceiling_alive "$age"
    return 1
  fi
  # (b) A park with a deadline still ahead is deliberate, not abandoned.
  park_note=
  if read_park; then
    [ "$PARK_UNTIL" -gt "$now" ] && return 1
    park_note="park-expired $(( now - PARK_UNTIL ))s ago, "
  fi

  # The marker is a second fixed name in the same shared directory, so it carries
  # the hold's own protections. Left unguarded, one `mkdir` by another user
  # disabled the abandoned-hold rule for every home on the machine, permanently
  # and without printing anything. An owner that merely could not be read is
  # not another user's: that round is skipped and the next poll asks again.
  kind=$(path_kind "$BREAK_MUTEX" dir)
  case "$kind" in
    absent|directory-own) ;;
    unreadable-owner)
      echo "could not read the owner of $BREAK_MUTEX; retrying next poll" >&2
      return 1
      ;;
    *)
      echo "BREAK NOT POSSIBLE - the break marker at $(describe_kind "$BREAK_MUTEX" "$kind"); the abandoned-hold rule stays disabled until it is removed by hand" >&2
      return 1
      ;;
  esac
  # A breaker killed mid-decision must not wedge the rule for every later one.
  if [ -d "$BREAK_MUTEX" ] && [ "$(path_age "$now" "$BREAK_MUTEX")" -ge "$BREAK_MUTEX_MAX" ]; then
    rmdir "$BREAK_MUTEX" 2>/dev/null
  fi
  mkdir "$BREAK_MUTEX" 2>/dev/null || return 1

  now=$(now_epoch)
  age=$(hold_age "$now")
  identity=$(hold_identity)
  why=
  threshold=
  proc=
  work=
  hb_words=$(heartbeat_words "$now")
  if [ -d "$LOCK" ] && ! hold_is_foreign && ! heartbeat_fresh "$now"; then
    if read_park && [ "$PARK_UNTIL" -gt "$now" ]; then
      why=
    elif [ "$age" -ge "$MAX_HOLD" ]; then
      # Past the ceiling the inferred signals are named, not consulted.
      if owner_process_alive; then proc=alive; else proc=gone; fi
      if check_work_live "$(owner_worktree)"; then work=seen; else work=none; fi
      why="${park_note}past the ${MAX_HOLD}s (FM_GATE_MAX_HOLD_SECONDS) ceiling with no live heartbeat; holder process $proc, check work $work, heartbeat $hb_words"
      threshold=$MAX_HOLD
    elif [ "$age" -ge "$STALE" ] && ! owner_running; then
      proc=gone
      work=none
      why="${park_note}holder process gone and no check work in its worktree past the ${STALE}s (FM_GATE_STALE_SECONDS) abandonment threshold, heartbeat $hb_words"
      threshold=$STALE
    fi
  fi
  if [ -n "$why" ]; then
    holder=$(owner)
    now=$(now_epoch)
    hb_journal=$(journal_value "$hb_words")
    # Age first, identity last, and the message after the removal: everything
    # between the final identity read and the `rm -rf` is a window in which the
    # judged holder can release and a fresh contender can take the path.
    if [ "$(hold_age "$now")" -ge "$threshold" ] && [ "$(hold_identity)" = "$identity" ]; then
      trace_break_to_holder "$breaker" "$age" "$why"
      journal broken "$holder" "breaker=$breaker" "holder_process=$proc" "check_work=$work" \
        "heartbeat=$hb_journal" "age=$age" "why=$why" "owner=$holder"
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

# --- taking the queue --------------------------------------------------------

# write_hold_files <id> <worktree> <holder-pid> <status-path>: the hold's
# records, in a fixed order, owner first. Owner first, probe second: the probe
# walks every meta with a pgrep and a ps apiece, and a concurrent reader inside
# that window used to be told "held by:" with no holder named.
write_hold_files() {
  local id=$1 wt=$2 pid=$3 status=$4
  printf '%s\n' "$id" > "$LOCK/owner"
  printf '%s\n' "$wt" > "$LOCK/owner_worktree"
  printf '%s\n' "$pid" > "$LOCK/owner_pid"
  printf '%s\n' "$(process_start "$pid")" > "$LOCK/owner_pid_start"
  printf '%s\n' "$(now_epoch)" > "$LOCK/taken"
  if [ -n "$status" ]; then
    printf '%s\n' "$status" > "$LOCK/owner_status"
  else
    rm -f "$LOCK/owner_status" 2>/dev/null
  fi
  WROTE_TOKEN="$$.$(now_epoch).${RANDOM:-0}"
  printf '%s\n' "$WROTE_TOKEN" > "$LOCK/token"
}

# The status file a plain acquire records for the break trace: this home's own
# state/<id>.status when it exists, else nothing.
acquire_status_path() {
  local candidate="$STATE/$1.status"
  [ -f "$candidate" ] && printf '%s\n' "$candidate"
  return 0
}

# take_queue <id> <--wait|''> <holder-pid> <status-path> <with-heartbeat 0|1>:
# the queue, by the rules in the header. Returns 0 with the hold this caller's
# (fresh, or already its own), 1 after printing a refusal on both streams.
take_queue() {
  local id=$1 wait=$2 holder_pid=$3 status=$4 heartbeat=$5
  local owner_wt owner_reads=0 missing_reads=0 resource_since='' resource_named=''
  local other holder now waited turn
  if ! mkdir -p "$(dirname "$LOCK")" 2>/dev/null && [ ! -d "$(dirname "$LOCK")" ]; then
    refuse_unreachable_hold
    return 1
  fi
  if [ "$wait" = "--wait" ]; then
    file_ticket "$id" || return 1
  fi
  # Resolved once, before any hold exists: a crewmate pane carries no FM_HOME,
  # so the metadata lookup finds nothing there and the worker's own worktree is
  # the task worktree by construction of the mandated one-liner.
  owner_wt=$(worktree_of "$id")
  [ -n "$owner_wt" ] || owner_wt=$(cwd_worktree)
  [ -n "$owner_wt" ] || owner_wt="$WORKTREE_UNKNOWN"
  while :; do
    # Waiting cannot help a hold this user may not touch, so --wait refuses too.
    if hold_is_foreign; then
      refuse_foreign_hold
      return 1
    fi
    if [ "$HOLD_KIND" = unreadable-owner ]; then
      refuse_unreadable_hold
      [ "$wait" = "--wait" ] || return 1
      sleep "$POLL"
      continue
    fi
    if [ ! -d "$LOCK" ]; then
      # A free hold goes to the oldest live ticket, and to a caller without a
      # ticket only when nobody holds one.
      queue_turn "$id" "$wait"; turn=$?
      if [ "$turn" -eq 2 ]; then
        return 1
      elif [ "$turn" -ne 0 ]; then
        [ "$wait" = "--wait" ] || return 1
        sleep "$POLL"
        continue
      fi
      if mkdir "$LOCK" 2>/dev/null; then
        write_hold_files "$id" "$owner_wt" "$holder_pid" "$status"
        if other=$(other_task_running "$id"); then
          [ "$(owner)" = "$id" ] && rm -rf "$LOCK"
          # Printed on stdout as well as stderr: a worker reading only stdout
          # took a refusal for a success on 2026-09-08. Under --wait it is
          # printed once per named task rather than once per poll, so a long
          # wait does not bury the turn it is blocking in repeated lines.
          if [ "$wait" != "--wait" ]; then
            echo "QUEUE NOT GRANTED - a full run is already live in $other, although the hold was free"
            echo "a full run is live outside the hold, in $other" >&2
            return 1
          fi
          now=$(now_epoch)
          [ -n "$resource_since" ] || resource_since=$now
          if [ "$resource_named" != "$other" ]; then
            echo "QUEUE NOT GRANTED - a full run is already live in $other, although the hold was free"
            echo "a full run is live outside the hold, in $other" >&2
            resource_named=$other
          fi
          waited=$(( now - resource_since ))
          if [ "$waited" -ge "$RESOURCE_WAIT" ]; then
            echo "QUEUE GIVEN UP - a full run in $other stayed live for the whole ${RESOURCE_WAIT}s (FM_GATE_RESOURCE_WAIT_SECONDS) wait; the queue was never granted and this wait was abandoned rather than satisfied"
            echo "gave up after ${waited}s: a full run is still live in $other" >&2
            return 1
          fi
          sleep "$POLL"
          continue
        fi
        holder=$(owner)
        if [ "$holder" != "$id" ]; then
          echo "QUEUE NOT YOURS - held by: $holder"
          echo "the hold changed owner to $holder while it was being taken" >&2
          [ "$wait" = "--wait" ] || return 1
          sleep "$POLL"
          continue
        fi
        [ "$heartbeat" -eq 1 ] && : > "$LOCK/heartbeat"
        if [ -n "$MY_TICKET" ]; then
          rm -f "$MY_TICKET" 2>/dev/null
          MY_TICKET=
        fi
        journal taken "$id" "pid=$holder_pid" "heartbeat=$heartbeat"
        echo "queue held by you: $id"
        return 0
      fi
      # mkdir failed and nothing is at the path: contention cannot explain that,
      # and no amount of waiting makes an unwritable parent writable. A brief
      # budget covers a holder that released inside the same instant.
      if [ ! -d "$LOCK" ]; then
        if [ "$missing_reads" -lt 40 ]; then
          missing_reads=$(( missing_reads + 1 ))
          sleep 0.05
          continue
        fi
        refuse_unreachable_hold
        return 1
      fi
    fi
    break_if_abandoned "$id" && continue
    holder=$(owner)
    # A hold that is gone, or one caught between its mkdir and its owner file,
    # names no holder; retry briefly rather than report an empty one.
    if [ -z "$holder" ] && [ "$owner_reads" -lt 40 ]; then
      owner_reads=$(( owner_reads + 1 ))
      sleep 0.05
      continue
    fi
    if [ "$holder" = "$id" ]; then
      if [ "$heartbeat" -eq 1 ]; then
        # A run re-takes its own hold only from a holder that is provably gone:
        # a dead recorded process or a silent heartbeat. Beside an earlier run
        # of this id that is still alive, re-taking would displace it - its
        # heartbeat would stop on the token change and its command keep running
        # unprotected beside the new one, two full runs of one task.
        now=$(now_epoch)
        if heartbeat_fresh "$now" && owner_process_alive && [ "$(owner_pid)" != "$holder_pid" ]; then
          echo "QUEUE NOT YOURS - your own run $(owner_pid) is still live"
          echo "your own run $(owner_pid) is still live; not re-taking the hold from under it" >&2
          return 1
        fi
        # Otherwise the run becomes its holder afresh: the recorded process,
        # token and status file are this run's, the heartbeat starts from now,
        # and a park the previous holder left ends here - it described that
        # holder's state, not this run's.
        if read_park; then
          journal unparked "$id" "reason=$PARK_REASON"
          rm -f "$LOCK/parked" 2>/dev/null
        fi
        write_hold_files "$id" "$owner_wt" "$holder_pid" "$status"
        : > "$LOCK/heartbeat"
        journal taken "$id" "pid=$holder_pid" "heartbeat=1" "retaken=1"
      fi
      if [ -n "$MY_TICKET" ]; then
        rm -f "$MY_TICKET" 2>/dev/null
        MY_TICKET=
      fi
      echo "queue is already yours: $id"
      return 0
    fi
    if [ "$wait" != "--wait" ]; then
      echo "QUEUE NOT YOURS - held by: $holder"
      echo "held by: $holder" >&2
      return 1
    fi
    sleep "$POLL"
  done
}

# release_hold <id> <reason>: the owner's own release, journaled.
release_hold() {
  local id=$1 reason=$2
  if read_park; then
    journal unparked "$id" "reason=$PARK_REASON"
  fi
  journal released "$id" "reason=$reason"
  rm -rf "$LOCK"
}

# park_hold <id> <reason> <seconds>: the park record inside an own hold, with
# its deadline, journaled. The reason carries no spaces (see journal_value).
park_hold() {
  local id=$1 reason=$2 secs=$3 deadline
  deadline=$(( $(now_epoch) + secs ))
  printf 'reason=%s\nuntil=%s\n' "$reason" "$deadline" > "$LOCK/parked"
  journal parked "$id" "reason=$reason" "for=${secs}s" "until=$deadline"
}

# --- run: hold the queue around a child command with a heartbeat ---------------

# start_heartbeat <id> <token> <status-path>: touches the heartbeat every
# FM_GATE_HEARTBEAT_SECONDS while the wrapper is alive and the hold's token is
# still this run's. A changed token means the hold was taken from under the run:
# the heartbeat says so, journals it, and stops without touching the successor's
# hold. Crossing the ceiling appends one status line, so an unusually long run
# is visible without being interrupted. Touching an existing file leaves the
# hold directory's own mtime alone.
start_heartbeat() {
  local id=$1 token=$2 status=$3 parent=$$
  (
    trap - EXIT
    sleeper=
    noted=
    trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM
    while kill -0 "$parent" 2>/dev/null; do
      current=$(hold_token)
      if [ "$current" != "$token" ]; then
        if [ -n "$current" ]; then
          echo "the hold was taken from under this run by $(owner)" >&2
          journal run-lost-hold "$id" "new_owner=$(owner)"
        else
          echo "the hold under this run is gone" >&2
          journal run-lost-hold "$id" "new_owner=none"
        fi
        exit 0
      fi
      touch "$LOCK/heartbeat" 2>/dev/null
      if [ -z "$noted" ] && [ -n "$status" ]; then
        now=$(now_epoch)
        if [ "$(hold_age "$now")" -ge "$MAX_HOLD" ]; then
          printf 'working: gate run has held the queue past FM_GATE_MAX_HOLD_SECONDS=%ss and is still alive\n' "$MAX_HOLD" >> "$status" 2>/dev/null || true
          noted=1
        fi
      fi
      sleep "$HEARTBEAT" &
      sleeper=$!
      wait "$sleeper"
    done
  ) &
  HB_PID=$!
}

stop_heartbeat() {
  [ -n "$HB_PID" ] || return 0
  kill "$HB_PID" 2>/dev/null
  wait "$HB_PID" 2>/dev/null
  HB_PID=
}

RUN_CHILD=
RUN_PGID=
RUN_SIGNALLED=
RUN_WAS_SIGNALLED=
# Seconds a signalled group gets to shut down before the wrapper decides
# whether its run is orphaned. Fixed like fm-test-run.sh's own kill grace, and
# not a threshold: it bounds a wait, it does not judge a hold.
RUN_SIGNAL_GRACE=5
# Invoked from the TERM and INT traps that run_command installs. The signal
# goes to the child's whole process group by its negative id: the child is a
# `bash -c` more often than not, and a TERM that reached only that shell left
# the suite it had started running as an orphan while the wrapper went on to
# release the hold over it.
# shellcheck disable=SC2329
forward_signal() {
  RUN_SIGNALLED=$1
  RUN_WAS_SIGNALLED=$1
  [ -n "$RUN_CHILD" ] && kill -"$1" -- "-$RUN_CHILD" 2>/dev/null
}

# run_command <cmd...>: the command as a child of this wrapper and the leader
# of its own process group (bash job control gives a background job its own
# group; the toggle is scoped to the launch), reading stdin from /dev/null,
# with TERM and INT forwarded to that group and the command's own exit status
# returned. The group id outlives this call in RUN_PGID.
run_command() {
  local rc
  trap 'forward_signal TERM' TERM
  trap 'forward_signal TERM' INT
  RUN_STARTED=1
  set -m
  "$@" </dev/null &
  RUN_CHILD=$!
  set +m
  RUN_PGID=$RUN_CHILD
  while :; do
    wait "$RUN_CHILD"; rc=$?
    [ -n "$RUN_SIGNALLED" ] || break
    RUN_SIGNALLED=
    kill -0 "$RUN_CHILD" 2>/dev/null || { wait "$RUN_CHILD" 2>/dev/null; rc=$?; break; }
  done
  trap - TERM INT
  RUN_CHILD=
  return "$rc"
}

# run_still_live_after_signal: true when, after the grace, the signalled run
# is still seen. The group and the check-work probe against the hold's own
# worktree are polled together; the tree has drained as soon as either the
# group is gone or the probe sees nothing, and the decision to park waits for
# the whole grace only while both still answer "alive".
run_still_live_after_signal() {
  local waited=0 wt
  wt=$(owner_worktree)
  while :; do
    kill -0 -- "-$RUN_PGID" 2>/dev/null || return 1
    check_work_live "$wt" || return 1
    [ "$waited" -lt $(( RUN_SIGNAL_GRACE * 2 )) ] || return 0
    waited=$(( waited + 1 ))
    sleep 0.5
  done
}

# --- status ----------------------------------------------------------------------

# status_lines: the holder, its liveness, and the waiters, one item per line.
status_lines() {
  local now age hb proc n tickets since pid id name
  now=$(now_epoch)
  if [ -d "$LOCK" ]; then
    echo "held by: $(owner)"
    age=$(hold_age "$now")
    hb=$(heartbeat_age "$now")
    if owner_process_alive; then proc=alive; else proc=gone; fi
    if read_park; then
      if [ "$PARK_UNTIL" -gt "$now" ]; then
        echo "taken ${age}s ago, parked: $PARK_REASON, expires in $(( PARK_UNTIL - now ))s, holder process $proc"
      else
        echo "taken ${age}s ago, parked: $PARK_REASON, EXPIRED $(( now - PARK_UNTIL ))s ago, holder process $proc"
      fi
    elif [ "$hb" -ge 0 ]; then
      if [ "$hb" -lt "$STALE" ]; then
        echo "taken ${age}s ago, heartbeat ${hb}s ago, running, holder process $proc"
      else
        echo "taken ${age}s ago, heartbeat ${hb}s ago, silent, holder process $proc"
      fi
    else
      echo "taken ${age}s ago, no heartbeat (plain acquire), holder process $proc"
    fi
  else
    echo "free"
  fi
  case "$(path_kind "$QUEUE_DIR" dir)" in
    absent|directory-own) ;;
    *)
      echo "waiting: unknown ($(describe_kind "$QUEUE_DIR" "$(path_kind "$QUEUE_DIR" dir)"))"
      return 0
      ;;
  esac
  tickets=$(live_tickets)
  if [ -z "$tickets" ]; then
    echo "waiting: 0"
    return 0
  fi
  echo "waiting: $(printf '%s\n' "$tickets" | wc -l | tr -d ' ')"
  n=0
  while read -r since pid id name; do
    [ -n "$since" ] || continue
    n=$(( n + 1 ))
    printf '  %s. %s  waiting %ss\n' "$n" "$id" "$(( now - since ))"
  done <<EOF
$tickets
EOF
}

# --- dispatch ---------------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  acquire)
    require_hold_path
    ID=${2:-}
    [ -n "$ID" ] || { echo "error: acquire needs a task id" >&2; exit 2; }
    WAIT=${3:-}
    [ -z "$WAIT" ] || [ "$WAIT" = "--wait" ] || { echo "error: unknown argument: $WAIT" >&2; exit 2; }
    take_queue "$ID" "$WAIT" "$PPID" "$(acquire_status_path "$ID")" 0
    exit $?
    ;;
  run)
    require_hold_path
    ID=${2:-}
    [ -n "$ID" ] || { echo "error: run needs a task id" >&2; exit 2; }
    shift 2
    WAIT=
    STATUS_FILE=
    SEEN_DASHDASH=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --wait) WAIT=--wait; shift ;;
        --status)
          [ -n "${2:-}" ] || { echo "error: --status needs a file path" >&2; exit 2; }
          STATUS_FILE=$2
          shift 2
          ;;
        --) SEEN_DASHDASH=1; shift; break ;;
        *) echo "error: unknown argument before --: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$SEEN_DASHDASH" ] || { echo "error: run needs -- followed by the command" >&2; exit 2; }
    [ "$#" -gt 0 ] || { echo "error: run needs a command after --" >&2; exit 2; }
    if [ -n "$STATUS_FILE" ]; then
      case "$STATUS_FILE" in
        /*) ;;
        *) STATUS_FILE="$PWD/$STATUS_FILE" ;;
      esac
    fi
    RUN_ID=$ID
    take_queue "$ID" "$WAIT" "$$" "$STATUS_FILE" 1 || exit 1
    if [ -n "$STATUS_FILE" ]; then
      printf 'working: queue taken, gate running\n' >> "$STATUS_FILE" 2>/dev/null \
        || echo "could not append the running line to $STATUS_FILE" >&2
    fi
    RUN_TOKEN=$(hold_token)
    start_heartbeat "$ID" "$RUN_TOKEN" "$STATUS_FILE"
    run_command "$@"
    RUN_RC=$?
    stop_heartbeat
    if [ "$(hold_token)" = "$RUN_TOKEN" ]; then
      if read_park; then
        echo "hold kept parked: $PARK_REASON" >&2
      elif [ -n "$RUN_WAS_SIGNALLED" ] && run_still_live_after_signal; then
        # The signal ended the child but not the run: past the grace, check
        # work still names this hold's worktree. Releasing now would grant the
        # queue over a live run, so the hold is parked instead, for the
        # default deadline, and the worker is told to stop the orphan or
        # release by hand.
        park_hold "$ID" run-orphaned-after-signal "$PARK_DEFAULT"
        echo "run interrupted but check work is still live in $(owner_worktree); not releasing - hold parked (run-orphaned-after-signal, ${PARK_DEFAULT}s (FM_GATE_PARK_SECONDS)); stop the orphaned run, then release $ID" >&2
      else
        if [ -n "$RUN_WAS_SIGNALLED" ]; then
          echo "run interrupted; releasing" >&2
          release_hold "$ID" signal
        else
          release_hold "$ID" "exit=$RUN_RC"
        fi
        echo "queue released" >&2
      fi
    else
      echo "not releasing: the hold under this run was taken by $(owner); leaving it alone" >&2
      journal run-lost-hold "$ID" "new_owner=$(owner)" "seen=at-exit"
    fi
    exit "$RUN_RC"
    ;;
  park)
    require_hold_path
    ID=${2:-}
    [ -n "$ID" ] || { echo "error: park needs a task id" >&2; exit 2; }
    shift 2
    REASON=
    FOR=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --reason)
          [ -n "${2:-}" ] || { echo "error: --reason needs a text" >&2; exit 2; }
          REASON=$2
          shift 2
          ;;
        --for)
          [ -n "${2:-}" ] || { echo "error: --for needs a number of seconds" >&2; exit 2; }
          FOR=$2
          shift 2
          ;;
        *) echo "error: unknown argument: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$REASON" ] || { echo "error: park needs --reason <text>" >&2; exit 2; }
    [ -n "$FOR" ] || FOR=$PARK_DEFAULT
    case "$FOR" in
      ''|*[!0-9]*) echo "error: --for must be a whole number of seconds" >&2; exit 2 ;;
    esac
    [ "$FOR" -gt 0 ] || { echo "error: --for must be a positive number of seconds" >&2; exit 2; }
    REASON=$(journal_value "$REASON")
    if hold_is_foreign; then
      refuse_foreign_hold
      exit 1
    fi
    if [ ! -d "$LOCK" ]; then
      # A park never skips the queue: it takes a free hold by the same rules as
      # a plain acquire, and its refusal is that acquire's own.
      TAKE_OUT=$(take_queue "$ID" "" "$PPID" "$(acquire_status_path "$ID")" 0) || {
        printf '%s\n' "$TAKE_OUT"
        exit 1
      }
    fi
    HOLDER=$(owner)
    if [ "$HOLDER" != "$ID" ]; then
      echo "QUEUE NOT YOURS - held by: $HOLDER"
      echo "held by: $HOLDER" >&2
      exit 1
    fi
    park_hold "$ID" "$REASON" "$FOR"
    echo "queue parked by you: $ID ($REASON, ${FOR}s)"
    exit 0
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
    release_hold "$ID" release
    echo "queue released"
    exit 0
    ;;
  status)
    require_hold_path
    shift
    LINE=
    SHOW_JOURNAL=
    JOURNAL_N=20
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --line) LINE=1; shift ;;
        --journal)
          SHOW_JOURNAL=1
          shift
          case "${1:-}" in
            ''|*[!0-9]*) ;;
            *) JOURNAL_N=$1; shift ;;
          esac
          ;;
        *) echo "error: unknown argument: $1" >&2; exit 2 ;;
      esac
    done
    if hold_is_foreign; then
      refuse_foreign_hold
      exit 1
    fi
    if [ -n "$SHOW_JOURNAL" ]; then
      # Read only this user's regular file: a journal that is anything else is
      # named and never followed, the same as when it is written.
      JOURNAL_KIND=$(path_kind "$JOURNAL" file)
      case "$JOURNAL_KIND" in
        file-own) tail -n "$JOURNAL_N" "$JOURNAL" ;;
        absent) echo "no journal yet at $JOURNAL" ;;
        *)
          echo "JOURNAL NOT AVAILABLE - not reading the queue journal: $(describe_kind "$JOURNAL" "$JOURNAL_KIND")"
          echo "not reading the queue journal: $(describe_kind "$JOURNAL" "$JOURNAL_KIND")" >&2
          exit 1
          ;;
      esac
      exit 0
    fi
    if [ -n "$LINE" ]; then
      status_lines | sed 's/^  *//' | paste -sd ';' - | sed 's/;/; /g'
    else
      status_lines
    fi
    exit 0
    ;;
  limits)
    printf 'FM_GATE_STALE_SECONDS=%s (abandoned after, when nothing proves the holder alive)\n' "$STALE"
    printf 'FM_GATE_MAX_HOLD_SECONDS=%s (ceiling on a hold without a live heartbeat)\n' "$MAX_HOLD"
    printf 'FM_GATE_RESOURCE_WAIT_SECONDS=%s (a --wait gives up on a resource refusal after)\n' "$RESOURCE_WAIT"
    printf 'FM_GATE_POLL_SECONDS=%s (the --wait poll)\n' "$POLL"
    printf 'FM_GATE_HEARTBEAT_SECONDS=%s (how often run touches its heartbeat)\n' "$HEARTBEAT"
    printf 'FM_GATE_PARK_SECONDS=%s (default park deadline)\n' "$PARK_DEFAULT"
    exit 0
    ;;
  *)
    echo "usage: fm-gate.sh acquire <id> [--wait] | run <id> [--wait] [--status <file>] -- <command...> | park <id> --reason <text> [--for <seconds>] | release <id> | status [--line] [--journal [N]] | limits" >&2
    exit 2
    ;;
esac
