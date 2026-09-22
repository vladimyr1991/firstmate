#!/usr/bin/env bash
# Behavior tests for bin/fm-gate.sh, the self-service full-test-gate queue.
#
# Three guarantees carry the fleet and are asserted directly here, because each
# one already failed once in production, or would have:
#   - Handing the queue out looks at the RESOURCE, not only at the permit. A
#     worker who released the hold and then ran the browser half on a
#     neighbouring lane broke no rule and still put a second full run on the
#     machine (2026-09-08).
#   - The live-run probe counts CHECK WORK and never "any process in the
#     worktree", and never a bare `node`. A worker WAITING for the queue keeps
#     wait shells alive, so counting any process made waiters look busy to each
#     other; and a `node` alternative counted the vite dev server of the browser
#     inspection this queue deliberately does NOT cover, which would have pinned
#     the queue for the whole fleet with no staleness path out.
#   - The hold is MACHINE-wide, not per-home: two homes on one machine contend
#     for one hold, and a hold whose owner runs in another home is not broken by
#     age, because the owner's worktree is recorded inside the hold rather than
#     looked up in the acquiring home's metadata.
#   - Reading command TEXT is not reading a running runner. The mandated worker
#     one-liner carries the worktree path, the acquire invocation and the gate
#     command in a single argv, so a merely waiting shell reads exactly like a
#     live run; counting it stalls two waiters against each other forever,
#     because resource refusals never age out.
#   - Breaking an abandoned hold is a claim only one contender can win. An
#     unsynchronised break granted the queue twice, which is the two-full-runs
#     hazard arriving through the rule meant to prevent it.
# Every test drives a hold path of its own through FM_GATE_LOCK_DIR; without that
# the suite would fight the real machine-wide hold of a live fleet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-gate)
FIXTURE_PIDS=()
# The hold path the gate helpers below drive; each test sets its own.
GATE_LOCK=

cleanup_fixtures() {
  local pid
  for pid in "${FIXTURE_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  fm_test_cleanup
}
trap cleanup_fixtures EXIT

# A fresh state dir with no tasks in it.
new_state() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# A fresh home with its own state/, for the cases that must prove two separate
# homes see one another rather than two separate state dirs.
new_home() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

# A hold path outside every state dir and every home, so the tests exercise the
# real machine-wide path shape without touching /tmp/fm-gate-lock.
new_lock() {
  local dir="$TMP_ROOT/$1-hold"
  mkdir -p "$(dirname "$dir")"
  # Spelled as the gate prints it: a TMPDIR with a trailing slash would
  # otherwise put a `//` into every path a message is compared against.
  printf '%s\n' "$dir" | sed 's#//*#/#g'
}

# Register a task's worktree the way fm-spawn records it.
register_task() {
  local state=$1 id=$2 worktree=$3
  mkdir -p "$worktree"
  fm_write_meta "$state/$id.meta" "window=fixture:$id" "worktree=$worktree" "project=fixture"
}

# Start a long-lived process whose command line carries <marker>, and wait until
# it is visible to pgrep so the assertion that follows is not a race.
start_fixture_process() {
  local marker=$1 pid tries=0
  # The trailing ':' keeps bash from exec-ing sleep in place, which would drop
  # the marker out of the process's command line partway through the test.
  bash -c 'sleep 60; :' "$marker" >/dev/null 2>&1 &
  pid=$!
  FIXTURE_PIDS+=("$pid")
  while [ "$tries" -lt 100 ]; do
    ps -p "$pid" -o command= 2>/dev/null | grep -qF -- "$marker" && { printf '%s\n' "$pid"; return 0; }
    tries=$((tries + 1))
    sleep 0.05
  done
  fail "fixture process never became visible with marker $marker"
}

# Backdate <path>'s mtime by <seconds>, so a hold can be genuinely stale while a
# hold created during the test is not. Driving staleness with
# FM_GATE_STALE_SECONDS=0 instead would make EVERY hold abandonable, including
# each contender's fresh one, which is a different situation entirely.
# A hold this script issued also records its issue time in `taken` (so that a
# heartbeat or a park written inside it later cannot refresh its age); a hold
# aged here has that record moved back by the same amount, so the two clocks
# agree exactly as they would for a hold that genuinely is that old. A hold
# built by hand without `taken` is aged by mtime alone, as an older copy of the
# script would have left it.
age_path() {
  local path=$1 seconds=$2 stamp
  if [ -f "$path/taken" ]; then
    printf '%s\n' "$(( $(date +%s) - seconds ))" > "$path/taken"
  fi
  if [ "$(uname)" = Darwin ]; then
    stamp=$(date -v-"${seconds}"S +%Y%m%d%H%M.%S)
  else
    stamp=$(date -d "@$(( $(date +%s) - seconds ))" +%Y%m%d%H%M.%S)
  fi
  touch -t "$stamp" "$path" || fail "could not backdate $path"
}

# Take the hold the way the brief's mandated one-liner does: a wrapper shell that
# runs `cd <worktree> && <gate> acquire <id>` and then STAYS ALIVE for the whole
# run. That wrapper is the holder's controlling process, and the runner it goes on
# to start carries no worktree path in its argv - `make test`, a system
# `pytest tests/`, a bare `bash tests/foo.test.sh` - which is exactly why holder
# liveness cannot be read off process command text. Echoes the wrapper's pid.
# $1 is 'state' or 'home', naming which of the two the gate should resolve.
start_holder_wrapper() {
  local kind=$1 root=$2 id=$3 wt=$4 runner=${5:-sleep 60} pid tries=0
  mkdir -p "$wt"
  if [ "$kind" = home ]; then
    FM_HOME="$root" FM_GATE_LOCK_DIR="$GATE_LOCK" \
      bash -c 'cd "$2" && "$1" acquire "$3" >/dev/null 2>&1 && exec $4' _ "$GATE" "$wt" "$id" "$runner" &
  else
    FM_STATE_OVERRIDE="$root" FM_GATE_LOCK_DIR="$GATE_LOCK" \
      bash -c 'cd "$2" && "$1" acquire "$3" >/dev/null 2>&1 && exec $4' _ "$GATE" "$wt" "$id" "$runner" &
  fi
  pid=$!
  FIXTURE_PIDS+=("$pid")
  while [ "$tries" -lt 300 ]; do
    case "$(FM_GATE_LOCK_DIR="$GATE_LOCK" "$GATE" status 2>/dev/null)" in
      *"held by: $id"*) printf '%s\n' "$pid"; return 0 ;;
    esac
    tries=$((tries + 1))
    sleep 0.05
  done
  fail "the holder wrapper never took the hold for $id"
}

gate() {
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_POLL_SECONDS=1 "$GATE" "$@"
}

# Same, but through a whole home rather than a state override, so "two homes"
# means what it says.
gate_home() {
  local home=$1
  shift
  FM_HOME="$home" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_POLL_SECONDS=1 "$GATE" "$@"
}

test_help_renders_the_header() {
  local out rc
  out=$("$GATE" --help 2>&1); rc=$?
  expect_code 0 "$rc" "fm-gate.sh --help must succeed"
  assert_contains "$out" "Usage: fm-gate.sh acquire <id> [--wait]" "--help must render the usage block"
  assert_contains "$out" "One machine sustains one full gate run" \
    "--help must state why the queue exists"
  assert_contains "$out" "covers FULL runs and deliberately NOT visual inspections" \
    "--help must state the measured boundary of what the queue covers"
  assert_contains "$out" "The hold therefore lives OUTSIDE any home" \
    "--help must state that the hold is machine-wide rather than per-home"
  assert_contains "$out" "stays HOME-SCOPED" \
    "--help must state that the issuance probe stays home-scoped"
  pass "fm-gate.sh: --help renders its header"
}

test_unknown_command_is_refused() {
  local state out rc
  state=$(new_state usage)
  GATE_LOCK=$(new_lock usage)
  out=$(gate "$state" frobnicate 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown subcommand must exit 2"
  assert_contains "$out" "usage: fm-gate.sh" "an unknown subcommand must print usage"
  out=$(gate "$state" acquire 2>&1); rc=$?
  expect_code 2 "$rc" "acquire without a task id must exit 2"
  pass "fm-gate.sh: unknown commands and a missing task id are refused"
}

test_one_holder_at_a_time() {
  local state out rc
  state=$(new_state single-holder)
  GATE_LOCK=$(new_lock single-holder)
  out=$(gate "$state" acquire task-a 2>&1); rc=$?
  expect_code 0 "$rc" "acquiring a free queue must succeed"
  assert_contains "$out" "queue held by you: task-a" "acquire must confirm the hold"
  out=$(gate "$state" status 2>&1)
  assert_contains "$out" "held by: task-a" "status must name the holder"

  # The refusal must reach stdout as well as stderr: a worker reading only
  # stdout took a refusal for a success on 2026-09-08.
  out=$(gate "$state" acquire task-b 2>/dev/null); rc=$?
  expect_code 1 "$rc" "a second task must be refused the queue"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-a" \
    "the refusal must be printed on stdout, not only on stderr"

  # Re-acquiring your own hold is idempotent, so a retry cannot deadlock a worker
  # against itself.
  out=$(gate "$state" acquire task-a 2>&1); rc=$?
  expect_code 0 "$rc" "the holder re-acquiring its own queue must succeed"
  assert_contains "$out" "queue is already yours: task-a" "a re-acquire must say the hold is already yours"
  pass "fm-gate.sh: exactly one task holds the queue and the refusal is visible"
}

# The atomicity claim in the header is demonstrated rather than asserted: many
# contenders released together against one free hold, one winner, everyone else
# refused.
test_a_real_race_produces_exactly_one_winner() {
  local state dir go n i pid rc out wins refusals ready
  state=$(new_state race)
  GATE_LOCK=$(new_lock race)
  dir="$TMP_ROOT/race-results"
  go="$TMP_ROOT/race-go"
  mkdir -p "$dir"
  n=20
  local pids=()
  for i in $(seq 1 "$n"); do
    (
      touch "$dir/$i.ready"
      # Every contender blocks on the same starting gun, so they contend rather
      # than queue up behind each other's process startup.
      while [ ! -e "$go" ]; do sleep 0.01; done
      gate "$state" acquire "task-$i" >"$dir/$i.out" 2>&1
      printf '%s\n' "$?" >"$dir/$i.rc"
    ) &
    pids+=("$!")
  done
  ready=0
  while [ "$ready" -lt 200 ]; do
    [ "$(find "$dir" -name '*.ready' | wc -l | tr -d ' ')" -eq "$n" ] && break
    ready=$((ready + 1))
    sleep 0.05
  done
  touch "$go"
  for pid in "${pids[@]}"; do wait "$pid"; done

  wins=0
  refusals=0
  for i in $(seq 1 "$n"); do
    [ -e "$dir/$i.rc" ] || fail "contender $i never recorded an outcome"
    rc=$(cat "$dir/$i.rc")
    out=$(cat "$dir/$i.out")
    if [ "$rc" = 0 ]; then
      wins=$((wins + 1))
      assert_contains "$out" "queue held by you: task-$i" \
        "contender $i succeeded without being told the queue is its own"
    else
      refusals=$((refusals + 1))
      assert_contains "$out" "QUEUE NOT YOURS" \
        "contender $i exited $rc without a visible refusal"
      # A refusal that names no holder is the shape a worker cannot act on; it
      # appeared whenever a reader caught the hold between its mkdir and its
      # owner file.
      case "$out" in
        *"QUEUE NOT YOURS - held by: task-"*) : ;;
        *) fail "contender $i was refused without a named holder: $out" ;;
      esac
    fi
  done
  [ "$wins" -eq 1 ] || fail "a race of $n contenders produced $wins winners, not exactly one"
  [ "$refusals" -eq $((n - 1)) ] || fail "a race of $n contenders produced $refusals refusals, not $((n - 1))"
  out=$(gate "$state" status 2>&1)
  assert_contains "$out" "held by: task-" "the single winner must be the recorded holder"
  pass "fm-gate.sh: a real race of $n contenders produces exactly one winner"
}

# Breaking an abandoned hold must be a claim only one contender can win. With an
# unsynchronised remove, two contenders could each observe the same stale hold,
# each remove it, and each take the queue - two full runs arriving through the
# very rule meant to prevent them, and a first holder whose own release is then
# refused because the hold records the second. This drives the window directly:
# every contender starts against one already-stale hold with a dead owner.
test_breaking_an_abandoned_hold_grants_it_to_exactly_one() {
  local state dir go n i pid rc out wins holder fakebin
  state=$(new_state stale-break-race)
  GATE_LOCK=$(new_lock stale-break-race)
  dir="$TMP_ROOT/stale-break-results"
  go="$TMP_ROOT/stale-break-go"
  mkdir -p "$dir"
  n=8
  # A hold whose owner has no live check work and whose mtime is an hour old: it
  # is abandoned under the default 25-minute rule, while any hold a contender
  # creates during this test is brand new and must NOT be breakable.
  mkdir -p "$GATE_LOCK"
  printf '%s\n' "task-dead" > "$GATE_LOCK/owner"
  printf '%s\n' "$TMP_ROOT/dead-wt" > "$GATE_LOCK/owner_worktree"
  age_path "$GATE_LOCK" 3600
  # The double-grant window is the gap between deciding a hold is abandoned and
  # actually breaking it. In production that gap is real - the liveness probe runs
  # a pgrep plus a ps per matched pid - but with an empty fixture worktree it is
  # sub-millisecond and the bug never shows. A slow pgrep on PATH reopens exactly
  # that gap deterministically, so every contender decides "abandoned" and only
  # then races to break it.
  fakebin=$(fm_fakebin "$TMP_ROOT/stale-break")
  cat > "$fakebin/pgrep" <<'SH'
#!/usr/bin/env bash
sleep 0.4
exit 1
SH
  chmod +x "$fakebin/pgrep"

  # STAGGERED, not released together: the double grant needs a contender that
  # decided "abandoned" against the OLD hold while an earlier contender has
  # already broken it and taken a fresh one. Contenders released at the same
  # instant all remove the hold before any of them re-creates it, and the bug
  # stays hidden. Spreading them across the probe window is the production shape.
  local pids=()
  for i in $(seq 1 "$n"); do
    (
      while [ ! -e "$go" ]; do sleep 0.01; done
      sleep "0.$(( i * 5 + 5 ))"
      PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
        FM_GATE_POLL_SECONDS=1 "$GATE" acquire "task-$i" >"$dir/$i.out" 2>"$dir/$i.err"
      printf '%s\n' "$?" >"$dir/$i.rc"
    ) &
    pids+=("$!")
  done
  touch "$go"
  for pid in "${pids[@]}"; do wait "$pid"; done

  wins=0
  for i in $(seq 1 "$n"); do
    [ -e "$dir/$i.rc" ] || fail "contender $i never recorded an outcome"
    rc=$(cat "$dir/$i.rc")
    out=$(cat "$dir/$i.out")
    if [ "$rc" = 0 ]; then
      wins=$((wins + 1))
      assert_contains "$out" "queue held by you: task-$i" \
        "contender $i succeeded without being told the queue is its own"
    else
      assert_contains "$out" "QUEUE NOT" "contender $i exited $rc without a visible refusal"
    fi
  done
  # Two contenders were each granted the broken hold before this was closed, and
  # the aftermath was worse than the double run: the first holder's own release
  # was refused because the hold recorded the second, so it left a hold it did not
  # own behind, and the queue read free while its run was still going.
  [ "$wins" -eq 1 ] || fail "breaking one abandoned hold granted the queue to $wins tasks, not exactly one"
  # The survivor must be the recorded holder, or its own release will be refused
  # and the queue will read free while its run is still going.
  holder=$(gate "$state" status 2>&1)
  assert_contains "$holder" "held by: task-" "the single winner must be the recorded holder"
  pass "fm-gate.sh: breaking an abandoned hold grants it to exactly one contender"
}

# The hold is machine-wide. Two homes on one machine must see one another, which
# a hold under $FM_HOME/state could never do.
test_two_homes_contend_for_one_hold() {
  local home_a home_b out rc
  home_a=$(new_home home-a)
  home_b=$(new_home home-b)
  GATE_LOCK=$(new_lock two-homes)

  out=$(gate_home "$home_a" acquire task-a 2>&1); rc=$?
  expect_code 0 "$rc" "the first home must be able to take a free hold"
  assert_contains "$out" "queue held by you: task-a" "the first home must be told the hold is its own"

  out=$(gate_home "$home_b" acquire task-b 2>/dev/null); rc=$?
  expect_code 1 "$rc" "a second home must be refused a hold the first home owns"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-a" \
    "the second home must be told which task in the other home holds the queue"

  out=$(gate_home "$home_b" status 2>&1)
  assert_contains "$out" "held by: task-a" "both homes must read the same hold"

  gate_home "$home_a" release task-a >/dev/null 2>&1
  out=$(gate_home "$home_b" acquire task-b 2>&1); rc=$?
  expect_code 0 "$rc" "the second home must get the hold once the first home releases"
  assert_contains "$out" "queue held by you: task-b" "the released hold must pass to the waiting home"
  pass "fm-gate.sh: two homes on one machine contend for a single hold"
}

test_release_is_owner_only() {
  local state out rc
  state=$(new_state release)
  GATE_LOCK=$(new_lock release)
  gate "$state" acquire task-a >/dev/null 2>&1

  out=$(gate "$state" release task-b 2>&1); rc=$?
  expect_code 1 "$rc" "releasing another task's hold must be refused"
  assert_contains "$out" "not your queue (held by task-a)" "the refusal must name the real holder"
  out=$(gate "$state" status 2>&1)
  assert_contains "$out" "held by: task-a" "a refused release must leave the hold intact"

  out=$(gate "$state" release task-a 2>&1); rc=$?
  expect_code 0 "$rc" "the holder must be able to release"
  out=$(gate "$state" status 2>&1)
  assert_contains "$out" "free" "the queue must be free after its holder releases"

  # Releasing a free queue is a no-op success, so a worker whose run died can
  # always end on a release without inventing a failure.
  out=$(gate "$state" release task-a 2>&1); rc=$?
  expect_code 0 "$rc" "releasing an already-free queue must succeed"
  assert_contains "$out" "queue was already free" "a redundant release must say so"
  pass "fm-gate.sh: only the holder releases, and a redundant release is harmless"
}

test_abandoned_hold_is_broken_but_a_live_run_is_not() {
  local state wt out rc
  state=$(new_state abandoned)
  GATE_LOCK=$(new_lock abandoned)
  wt="$TMP_ROOT/abandoned-wt"
  register_task "$state" task-a "$wt"
  # The holder's turn ended: the wrapper that took the hold has exited, so its
  # recorded controlling process is gone. That is what an abandoned hold IS.
  FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
    bash -c '"$1" acquire "$2" >/dev/null 2>&1' _ "$GATE" task-a

  # Past the stale age with the holder's process gone, the hold is abandoned.
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>/dev/null); rc=$?
  expect_code 0 "$rc" "an abandoned hold must be broken for the next task"
  assert_contains "$out" "queue held by you: task-b" "breaking an abandoned hold must hand the queue over"

  # Same age, but the holder's own process is genuinely alive: the hold stands.
  gate "$state" release task-b >/dev/null 2>&1
  start_holder_wrapper state "$state" task-a "$wt" >/dev/null
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>/dev/null); rc=$?
  expect_code 1 "$rc" "a hold whose owner is still running must not be broken by age alone"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-a" "the live owner must keep the queue"
  pass "fm-gate.sh: an abandoned hold is broken, a live owner's hold is not"
}

# The stale rule must read the same from any home. Resolving the holder through
# the ACQUIRING home's state/<id>.meta finds nothing for a holder that lives in
# another home, and would break a genuinely running suite's hold after 25
# minutes - the exact two-full-runs hazard the queue exists to prevent.
test_a_live_run_in_another_home_keeps_its_hold() {
  local home_a home_b wt out rc
  home_a=$(new_home stale-home-a)
  home_b=$(new_home stale-home-b)
  GATE_LOCK=$(new_lock cross-home-stale)
  wt="$TMP_ROOT/cross-home-wt"
  register_task "$home_a/state" task-a "$wt"
  start_holder_wrapper home "$home_a" task-a "$wt" >/dev/null

  # home-b knows nothing about task-a; only the hold itself records the holder.
  out=$(FM_HOME="$home_b" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>/dev/null); rc=$?
  expect_code 1 "$rc" "a hold whose owner runs in another home must not be broken by age"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-a" "the cross-home holder must keep the queue"
  out=$(gate_home "$home_b" status 2>&1)
  assert_contains "$out" "held by: task-a" "the hold must survive the other home's stale probe"
  pass "fm-gate.sh: a live run in another home keeps its hold across the stale rule"
}

# The reported shape, and the one the mandated one-liner always produces: the
# holder's only process carrying the worktree path is the wrapper shell, which the
# issuance probe must skip because it is also a waiter, while the runner it
# started carries no path and no runner name in its argv at all. Inferring holder
# liveness from command text therefore declared a genuinely running suite dead and
# broke its hold at 25 minutes - the exact two-full-runs hazard the queue exists
# to prevent. Liveness is now the recorded holder process, so no argv is consulted.
test_a_holder_whose_runner_is_invisible_to_argv_keeps_its_hold() {
  local state wt out rc
  state=$(new_state invisible-runner)
  GATE_LOCK=$(new_lock invisible-runner)
  wt="$TMP_ROOT/invisible-runner-wt"
  register_task "$state" task-a "$wt"
  start_holder_wrapper state "$state" task-a "$wt" >/dev/null

  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>/dev/null); rc=$?
  expect_code 1 "$rc" "a holder whose runner carries no worktree path must keep its hold"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-a" \
    "the running holder must still be named as the holder"
  out=$(gate "$state" status 2>&1)
  assert_contains "$out" "held by: task-a" "the stale rule must leave a running holder's hold alone"
  pass "fm-gate.sh: a holder whose runner is invisible to argv keeps its hold"
}

# The break must be a compare-and-swap, not a decision followed by a delete. The
# holder can release while the breaker is deciding, a new contender can take a
# brand-new hold at the same path, and the breaker then removes a hold that is
# milliseconds old and takes the queue - two full runs, and the first holder's own
# release refused because the hold records the second. The break mutex does not
# help: there is only ever one breaker here.
test_a_hold_taken_during_the_decision_is_not_broken() {
  local state fakebin live out rc breaker
  state=$(new_state break-cas)
  GATE_LOCK=$(new_lock break-cas)

  # A stale hold whose recorded holder process is alive but is NOT the recorded
  # one (the start times differ), so the breaker decides "abandoned" and proceeds.
  live=$(start_fixture_process "$TMP_ROOT/break-cas-idle" )
  mkdir -p "$GATE_LOCK"
  printf '%s\n' "task-dead" > "$GATE_LOCK/owner"
  printf '%s\n' "$TMP_ROOT/break-cas-wt" > "$GATE_LOCK/owner_worktree"
  printf '%s\n' "$live" > "$GATE_LOCK/owner_pid"
  printf '%s\n' "a start time this process never had" > "$GATE_LOCK/owner_pid_start"
  printf '%s\n' "token-of-the-stale-hold" > "$GATE_LOCK/token"
  age_path "$GATE_LOCK" 3600

  # Both liveness paths are slowed, so the window is open whether the holder is
  # judged by its recorded process (ps) or, for a hold from an older copy of the
  # script that records none, by the argv probe (pgrep).
  fakebin=$(fm_fakebin "$TMP_ROOT/break-cas")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
sleep 1
echo "Thu Jan  1 00:00:00 2026"
SH
  cat > "$fakebin/pgrep" <<'SH'
#!/usr/bin/env bash
sleep 1
exit 1
SH
  chmod +x "$fakebin/ps" "$fakebin/pgrep"

  ( PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
      "$GATE" acquire task-b >"$TMP_ROOT/break-cas.out" 2>"$TMP_ROOT/break-cas.err"
    printf '%s\n' "$?" >"$TMP_ROOT/break-cas.rc" ) &
  breaker=$!

  # Wait for the breaker to enter its decision rather than guessing at a delay:
  # it holds the break mutex for exactly that span.
  rc=0
  while [ "$rc" -lt 400 ]; do
    [ -d "$GATE_LOCK.breaking" ] && break
    rc=$((rc + 1))
    sleep 0.01
  done
  [ -d "$GATE_LOCK.breaking" ] || fail "the breaker never entered its decision"

  # The holder releases and a fresh contender takes the hold, both while the
  # breaker is still deciding about the hold that is now gone.
  gate "$state" release task-dead >/dev/null 2>&1
  out=$(gate "$state" acquire task-c 2>&1); rc=$?
  expect_code 0 "$rc" "the fresh contender must be able to take the released hold"
  assert_contains "$out" "queue held by you: task-c" "the fresh contender must hold the queue"
  wait "$breaker"

  rc=$(cat "$TMP_ROOT/break-cas.rc")
  out=$(cat "$TMP_ROOT/break-cas.out")
  expect_code 1 "$rc" "the breaker must not be granted a queue held by a hold it never judged"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-c" \
    "the breaker must be refused and must name the fresh holder"
  out=$(gate "$state" status 2>&1)
  assert_contains "$out" "held by: task-c" "the fresh holder's hold must survive the breaker"
  pass "fm-gate.sh: a hold taken while a break is being decided is not broken"
}

# Recording the holder process fixed the argv probe lying about a live holder; it
# must not become the ONLY signal. A harness tool-call timeout or interrupt kills
# the wrapper shell while the suite it started survives as an orphan re-parented
# to init - a run that is genuinely live - and breaking that hold puts a second
# full run on the machine, the same hazard from the other side.
test_an_orphaned_runner_keeps_the_holders_hold() {
  local state wt out rc
  state=$(new_state orphan-runner)
  GATE_LOCK=$(new_lock orphan-runner)
  wt="$TMP_ROOT/orphan-runner-wt"
  register_task "$state" task-a "$wt"
  # The wrapper takes the hold and then exits: the recorded holder process is gone.
  FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
    bash -c '"$1" acquire "$2" >/dev/null 2>&1' _ "$GATE" task-a
  # Its runner did not die with it, and still carries the recorded worktree.
  start_fixture_process "$wt/pytest-suite" >/dev/null
  age_path "$GATE_LOCK" 3600

  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>/dev/null); rc=$?
  expect_code 1 "$rc" "a hold whose runner outlived its wrapper must not be broken"
  # The hold surviving is the evidence; the refusal wording is secondary.
  assert_contains "$(gate "$state" status 2>&1)" "held by: task-a" \
    "the orphan's hold must survive the stale rule"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-a" "the orphaned run must keep the queue"
  pass "fm-gate.sh: an orphaned runner keeps its holder's hold"
}

# A crewmate pane inherits no FM_HOME, so the gate resolves some other home's
# state/ and finds no meta for the task holding the queue. Recording an EMPTY
# owner worktree there silently disabled the orphan signal for exactly the
# workers this contract is written for; the acquiring process's own directory is
# the task worktree by construction of the mandated one-liner, and it needs no
# environment at all.
test_a_hold_taken_without_its_home_records_the_working_directory() {
  local empty_home wt recorded out rc
  empty_home=$(new_home no-meta-home)
  GATE_LOCK=$(new_lock no-meta-home)
  # A real task worktree, because the fallback accepts only a git worktree root.
  wt="$TMP_ROOT/no-meta-wt"
  fm_git_worktree "$TMP_ROOT/no-meta-repo" "$wt" no-meta-branch
  wt=$(cd "$wt" && pwd -P)

  # The home knows nothing about task-a. The wrapper takes the hold from inside
  # the worktree and exits, exactly as a killed one-liner leaves it.
  ( cd "$wt" && FM_HOME="$empty_home" FM_GATE_LOCK_DIR="$GATE_LOCK" \
      "$GATE" acquire task-a >/dev/null 2>&1 ) \
    || fail "acquire must succeed in a home that has no meta for the task"
  recorded=$(cat "$GATE_LOCK/owner_worktree" 2>/dev/null)
  [ -n "$recorded" ] || fail "a hold must never record an empty owner worktree"
  [ "$recorded" = "$wt" ] \
    || fail "the hold must record the acquiring worker's own worktree, got '$recorded'"

  # The recorded value is load-bearing, not decoration: an orphaned runner in
  # that worktree keeps the hold, which a blank worktree could never do.
  start_fixture_process "$wt/pytest-suite" >/dev/null
  age_path "$GATE_LOCK" 3600
  out=$(FM_HOME="$empty_home" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>/dev/null); rc=$?
  expect_code 1 "$rc" "the orphan signal must still work for a hold taken without its home"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-a" \
    "the hold recorded without a home must still be defended by its worktree"
  pass "fm-gate.sh: a hold taken without its home records the acquiring worktree"
}

# The other side of that fallback. A directory the mandated one-liner never
# produces must not be recorded as the holder's worktree: the recorded string is
# what the argv probe greps for, so a home recorded there makes `pgrep -f $HOME`
# match nearly every process on the machine, one unrelated pytest beneath it
# votes a dead holder alive, and the hold survives every break until the two-hour
# ceiling - the machine-wide question this design refuses, reached through the
# fallback instead of through the probe.
test_an_acquire_from_the_home_directory_records_no_worktree() {
  local state fake_home recorded out rc
  state=$(new_state home-cwd)
  GATE_LOCK=$(new_lock home-cwd)
  # A git repo, so only the home rule itself can reject this directory.
  fake_home="$TMP_ROOT/home-cwd-home"
  fm_git_init_commit "$fake_home"
  fake_home=$(cd "$fake_home" && pwd -P)

  ( cd "$fake_home" && HOME="$fake_home" FM_STATE_OVERRIDE="$state" \
      FM_GATE_LOCK_DIR="$GATE_LOCK" "$GATE" acquire task-a >/dev/null 2>&1 ) \
    || fail "acquire must still succeed when the working directory is a home"
  recorded=$(cat "$GATE_LOCK/owner_worktree" 2>/dev/null)
  [ -n "$recorded" ] || fail "a hold must never record an empty owner worktree"
  [ "$recorded" != "$fake_home" ] \
    || fail "the hold must not record the user's home directory as a worktree"

  # The hold must therefore stay breakable: check work anywhere under that home
  # is not evidence that this dead holder is alive.
  start_fixture_process "$fake_home/pytest-suite" >/dev/null
  age_path "$GATE_LOCK" 3600
  out=$(HOME="$fake_home" FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
    FM_GATE_STALE_SECONDS=0 "$GATE" acquire task-b 2>/dev/null); rc=$?
  expect_code 0 "$rc" "a hold that recorded no worktree must stay breakable once its holder is gone"
  assert_contains "$out" "queue held by you: task-b" \
    "the abandoned hold must be handed to the next task rather than held to the ceiling"
  pass "fm-gate.sh: an acquire from the home directory records no worktree and stays breakable"
}

# The mirror image, and the direction with no recovery: $PPID can name something
# long-lived (a harness reusing one shell across tool calls), and a machine-wide
# hold that can never be broken wedges every home with no escape but a manual
# delete. For a hold WITHOUT a heartbeat - a plain acquire, whose only liveness
# is inferred from that pid - the ceiling is the bound on that inference: past
# it the hold goes however alive the inferred signals look, loudly, and the
# break names what it saw. This is the only executable proof that the ceiling
# still bounds a falsely-live pid; a hold whose holder proves itself alive with
# a heartbeat is covered by its own test below, not by inverting this one.
test_a_hold_without_a_heartbeat_past_the_ceiling_is_broken_and_names_its_evidence() {
  local state wt out err rc
  state=$(new_state hold-ceiling)
  GATE_LOCK=$(new_lock hold-ceiling)
  wt="$TMP_ROOT/hold-ceiling-wt"
  register_task "$state" task-a "$wt"
  start_holder_wrapper state "$state" task-a "$wt" >/dev/null

  # Well past the 25-minute rule but under the ceiling: the live holder keeps it.
  age_path "$GATE_LOCK" 3600
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
    "$GATE" acquire task-b 2>/dev/null); rc=$?
  expect_code 1 "$rc" "a live holder must keep its hold below the ceiling"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-a" "the live holder must still be named"

  # Past the ceiling, with the very same live holder, the hold goes.
  err="$TMP_ROOT/hold-ceiling.err"
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_MAX_HOLD_SECONDS=60 \
    "$GATE" acquire task-b 2>"$err"); rc=$?
  expect_code 0 "$rc" "a hold without a heartbeat past the ceiling must be broken however alive its inferred signals look"
  assert_contains "$out" "queue held by you: task-b" "the ceiling break must hand the queue over"
  # Never silent: the break names the owner it displaced and the age it reached.
  assert_contains "$(cat "$err")" "breaking an abandoned hold (owner task-a" \
    "a ceiling break must name the owner it displaced"
  assert_contains "$(cat "$err")" "ceiling" "a ceiling break must say the ceiling is why"
  # The break names the inferred signals it overrode and the threshold it
  # applied, by variable name and the value in force - not the default.
  assert_contains "$(cat "$err")" "holder process alive" \
    "a ceiling break must name the live holder process it overrode"
  assert_contains "$(cat "$err")" "heartbeat none" \
    "a ceiling break must say the hold carried no heartbeat"
  assert_contains "$(cat "$err")" "60s (FM_GATE_MAX_HOLD_SECONDS)" \
    "a ceiling break must name the ceiling in force by its variable"
  assert_not_contains "$(cat "$err")" "7200s (FM_GATE_MAX_HOLD_SECONDS)" \
    "a ceiling break must not name the default when another value is in force"
  pass "fm-gate.sh: a hold without a heartbeat past the ceiling is broken and names its evidence"
}

# The ceiling must fire on the threshold that justified the break. Re-checking
# the STALE age inside the compare-and-swap silently disabled the ceiling
# whenever an operator capped holds BELOW the stale age - the one case the
# pre-filter exists for - and refused with a changed-hold message naming a reason
# that was not what happened.
test_a_ceiling_below_the_stale_age_still_breaks_the_hold() {
  local state wt out err rc
  state=$(new_state sub-stale-ceiling)
  GATE_LOCK=$(new_lock sub-stale-ceiling)
  wt="$TMP_ROOT/sub-stale-ceiling-wt"
  register_task "$state" task-a "$wt"
  start_holder_wrapper state "$state" task-a "$wt" >/dev/null

  # Well under the 25-minute rule, and well over a ceiling capped beneath it.
  age_path "$GATE_LOCK" 900
  err="$TMP_ROOT/sub-stale-ceiling.err"
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
    FM_GATE_STALE_SECONDS=1500 FM_GATE_MAX_HOLD_SECONDS=600 \
    "$GATE" acquire task-b 2>"$err"); rc=$?
  expect_code 0 "$rc" "a ceiling set below the stale age must still break the hold"
  assert_contains "$out" "queue held by you: task-b" "the sub-stale ceiling break must hand the queue over"
  assert_contains "$(cat "$err")" "ceiling" "the break must name the ceiling as its reason"
  assert_not_contains "$(cat "$err")" "not breaking" \
    "a ceiling break must not refuse with a changed-hold reason that did not happen"
  pass "fm-gate.sh: a ceiling below the stale age still breaks the hold"
}

# The ceiling breaks a hold without a heartbeat however alive its holder is, so a
# zero there grants the queue twice on every acquire - two full runs on one
# machine, the hazard this queue exists to prevent, arriving through the rule
# added to bound it. Zero is
# also the spelling an operator reaches for to DISABLE a maximum-age knob, so it
# must fall back to the documented default and say so rather than be obeyed.
test_a_zero_ceiling_falls_back_rather_than_breaking_a_live_hold() {
  local state wt out err rc spelling
  state=$(new_state zero-ceiling)
  GATE_LOCK=$(new_lock zero-ceiling)
  wt="$TMP_ROOT/zero-ceiling-wt"
  register_task "$state" task-a "$wt"
  start_holder_wrapper state "$state" task-a "$wt" >/dev/null
  err="$TMP_ROOT/zero-ceiling.err"

  for spelling in 0 00 000 not-a-number; do
    out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
      FM_GATE_MAX_HOLD_SECONDS="$spelling" "$GATE" acquire task-b 2>"$err"); rc=$?
    expect_code 1 "$rc" "a ceiling of '$spelling' must not break a live holder's fresh hold"
    assert_contains "$out" "QUEUE NOT YOURS - held by: task-a" \
      "the live holder must keep the queue whatever the ceiling was set to"
    assert_contains "$(cat "$err")" "ignoring FM_GATE_MAX_HOLD_SECONDS=$spelling" \
      "an ignored ceiling must be named on stderr rather than silently dropped"
    assert_not_contains "$(cat "$err")" "breaking an abandoned hold" \
      "a rejected ceiling must never break a hold"
  done
  pass "fm-gate.sh: a zero ceiling falls back to the default rather than breaking a live hold"
}

# The worst failure shape this script has, and it arrives from operator
# configuration alone: with a trailing slash on the configured path the marker
# was built by concatenation and landed INSIDE the hold, so `mkdir` refreshed the
# hold's own mtime and every age read back as 0. Both the 25-minute rule and the
# ceiling were then permanently disabled - one machine-wide hold nothing could
# break, with every home queued behind it and nothing on stderr to say why.
test_a_trailing_slash_on_the_hold_path_still_breaks_an_abandoned_hold() {
  local state wt out err rc base
  state=$(new_state trailing-slash)
  base=$(new_lock trailing-slash)
  GATE_LOCK="$base"
  wt="$TMP_ROOT/trailing-slash-wt"
  register_task "$state" task-a "$wt"
  # A hold whose holder is gone, well past the stale age and the ceiling.
  mkdir -p "$GATE_LOCK"
  printf '%s\n' task-dead > "$GATE_LOCK/owner"
  printf '%s\n' "$wt" > "$GATE_LOCK/owner_worktree"
  printf '%s\n' token-of-the-stale-hold > "$GATE_LOCK/token"
  age_path "$GATE_LOCK" 90000

  err="$TMP_ROOT/trailing-slash.err"
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$base/" \
    "$GATE" acquire task-b 2>"$err"); rc=$?
  expect_code 0 "$rc" "a hold configured with a trailing slash must still be broken when abandoned"
  assert_contains "$out" "queue held by you: task-b" \
    "the break must hand the queue over however the hold path was spelled"
  assert_contains "$(cat "$err")" "breaking an abandoned hold" \
    "the break must still say what it did"
  [ ! -e "$GATE_LOCK/.breaking" ] \
    || fail "the break marker must never be created inside the hold directory"
  pass "fm-gate.sh: a trailing slash on the hold path still breaks an abandoned hold"
}

# Every other spelling that leaves the hold's own name unresolved is the same
# defect: a trailing `.` or `..` also put the marker inside the hold, so both
# break rules stayed silently disabled while a trailing-slash-only guard read as
# a fix. The hold is one directory; how the operator spelled it must not matter.
test_dot_terminated_hold_paths_still_break_an_abandoned_hold() {
  local state wt out err rc base spelling
  state=$(new_state dot-path)
  base=$(new_lock dot-path)
  GATE_LOCK="$base"
  wt="$TMP_ROOT/dot-path-wt"
  register_task "$state" task-a "$wt"
  err="$TMP_ROOT/dot-path.err"

  for spelling in "$base/." "$base/sub/.." "$base//" "$base/./"; do
    rm -rf "$GATE_LOCK" "$base.breaking"
    mkdir -p "$GATE_LOCK"
    printf '%s\n' task-dead > "$GATE_LOCK/owner"
    printf '%s\n' "$wt" > "$GATE_LOCK/owner_worktree"
    printf '%s\n' token-of-the-stale-hold > "$GATE_LOCK/token"
    age_path "$GATE_LOCK" 90000

    out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$spelling" \
      "$GATE" acquire task-b 2>"$err"); rc=$?
    expect_code 0 "$rc" "an abandoned hold spelled '$spelling' must still be broken"
    assert_contains "$out" "queue held by you: task-b" \
      "the break must hand the queue over for the hold spelled '$spelling'"
    assert_contains "$(cat "$err")" "breaking an abandoned hold" \
      "the break of '$spelling' must still say what it did"
    [ -z "$(find "$GATE_LOCK" -maxdepth 1 -name '*breaking*' 2>/dev/null)" ] \
      || fail "a marker was created inside the hold for the path spelled '$spelling'"
    gate "$state" release task-b >/dev/null 2>&1
  done
  pass "fm-gate.sh: dot- and dotdot-terminated hold paths still break an abandoned hold"
}

# The hold path is resolved from three environment variables, none of which is
# guaranteed. Dereferencing an unset HOME under `set -u` aborted the whole script
# before it dispatched anything - a bash diagnostic instead of one of this
# script's own refusals, on the one command a worker's whole turn is blocked in.
test_an_unresolvable_hold_path_refuses_by_name() {
  local out rc
  out=$(env -u HOME -u XDG_STATE_HOME -u FM_GATE_LOCK_DIR "$GATE" --help 2>&1); rc=$?
  expect_code 0 "$rc" "--help must work without any hold path in the environment"
  assert_contains "$out" "Usage: fm-gate.sh acquire <id> [--wait]" \
    "--help must still render the usage block"

  out=$(env -u HOME -u XDG_STATE_HOME -u FM_GATE_LOCK_DIR "$GATE" acquire task-a 2>&1); rc=$?
  expect_code 1 "$rc" "an acquire with no resolvable hold path must fail"
  assert_contains "$out" "QUEUE NOT AVAILABLE" \
    "the refusal must be visible on stdout, like every other refusal a worker reads"
  assert_contains "$out" "FM_GATE_LOCK_DIR" "the refusal must name what to set"
  assert_not_contains "$out" "unbound variable" \
    "the script must refuse by name rather than abort on an unset variable"
  out=$(env -u HOME -u XDG_STATE_HOME -u FM_GATE_LOCK_DIR "$GATE" status 2>&1); rc=$?
  expect_code 1 "$rc" "status with no resolvable hold path must fail too"
  assert_not_contains "$out" "unbound variable" "status must refuse by name as well"

  # A path that canonicalises to nothing holdable is refused for the same reason
  # rather than used: a marker derived from it lands inside the hold.
  out=$(FM_GATE_LOCK_DIR=/ "$GATE" acquire task-a 2>&1); rc=$?
  expect_code 1 "$rc" "a hold path that names no holdable directory must be refused"
  assert_contains "$out" "QUEUE NOT AVAILABLE" \
    "an unusable hold path must refuse visibly on stdout"
  assert_contains "$out" "names no directory below the filesystem root" \
    "the refusal must say what is wrong with the configured path"
  pass "fm-gate.sh: an unresolvable hold path refuses by name instead of aborting"
}

# The break marker is a second fixed name in the same shared directory as the
# hold. Unguarded, one `mkdir` by another user disabled the abandoned-hold rule
# for every home on the machine - permanently, and without printing anything.
test_a_foreign_break_marker_is_refused_visibly() {
  local state target out err rc
  state=$(new_state foreign-marker)
  GATE_LOCK=$(new_lock foreign-marker)
  target="$TMP_ROOT/foreign-marker-target"
  mkdir -p "$target"

  # An abandoned hold that the rule would otherwise break.
  mkdir -p "$GATE_LOCK"
  printf '%s\n' "task-dead" > "$GATE_LOCK/owner"
  printf '%s\n' "$TMP_ROOT/foreign-marker-wt" > "$GATE_LOCK/owner_worktree"
  printf '%s\n' "token-of-the-stale-hold" > "$GATE_LOCK/token"
  age_path "$GATE_LOCK" 3600
  ln -s "$target" "$GATE_LOCK.breaking"

  err="$TMP_ROOT/foreign-marker.err"
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>"$err"); rc=$?
  expect_code 1 "$rc" "a break blocked by a foreign marker must refuse rather than proceed"
  assert_contains "$(cat "$err")" "BREAK NOT POSSIBLE" \
    "a foreign break marker must produce a visible refusal, never silence"
  [ -L "$GATE_LOCK.breaking" ] || fail "a foreign break marker must never be removed"
  [ -d "$target" ] || fail "a foreign break marker must never be followed and emptied"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-dead" "the hold must be left intact"
  pass "fm-gate.sh: a foreign break marker is refused visibly and never removed"
}

# The marker's own recovery clock is independent of FM_GATE_STALE_SECONDS. Reusing
# the hold's clock meant a suite driving the stale age to 0 removed a marker
# another contender was actively holding, silently reopening the double-grant
# window the marker exists to close.
test_an_active_break_marker_survives_a_low_stale_age() {
  local state out rc
  state=$(new_state marker-clock)
  GATE_LOCK=$(new_lock marker-clock)

  mkdir -p "$GATE_LOCK"
  printf '%s\n' "task-dead" > "$GATE_LOCK/owner"
  printf '%s\n' "$TMP_ROOT/marker-clock-wt" > "$GATE_LOCK/owner_worktree"
  printf '%s\n' "token-of-the-stale-hold" > "$GATE_LOCK/token"
  age_path "$GATE_LOCK" 3600
  # A marker another contender is holding right now: brand new, ours, present.
  mkdir "$GATE_LOCK.breaking"

  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>/dev/null); rc=$?
  expect_code 1 "$rc" "a contender must not break while another holds the marker"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-dead" "the hold must be left to the active breaker"
  [ -d "$GATE_LOCK.breaking" ] || fail "an actively held break marker must not be removed"
  pass "fm-gate.sh: an active break marker survives a low stale age"
}

test_a_live_run_outside_the_hold_refuses_a_free_queue() {
  local state wt out rc
  state=$(new_state resource)
  GATE_LOCK=$(new_lock resource)
  wt="$TMP_ROOT/resource-wt"
  register_task "$state" task-a "$wt"
  register_task "$state" task-b "$TMP_ROOT/resource-wt-b"
  start_fixture_process "$wt/pytest-suite" >/dev/null

  out=$(gate "$state" status 2>&1)
  assert_contains "$out" "free" "the hold itself must be free for this case to mean anything"
  out=$(gate "$state" acquire task-b 2>/dev/null); rc=$?
  expect_code 1 "$rc" "a free hold must still be refused while another task's full run is live"
  assert_contains "$out" "QUEUE NOT GRANTED - a full run is already live in task-a" \
    "the refusal must name the task whose run is live"
  out=$(gate "$state" status 2>&1)
  assert_contains "$out" "free" "a refused acquire must not leave a hold behind"
  pass "fm-gate.sh: a full run outside the hold refuses the queue"
}

# The HOLD ages out into a grant; the RESOURCE refusal never can, because
# granting it would put the second full run on the machine. Left unbounded under
# the mandated --wait, a neighbouring run that hangs rather than ends - an
# orphaned browser half waiting on a dead dev server - parks every other worker
# in this home forever, inside the one command their whole turn is blocked in.
# That is the standing-forever failure this queue exists to remove, arriving
# through the queue. So the wait is bounded and then GIVEN UP, loudly, naming the
# task whose run is live, and it stays quiet in between rather than burying the
# blocked turn in one refusal per poll.
test_a_resource_refusal_is_given_up_rather_than_waited_out_forever() {
  local state wt outf errf rcf waiter tries=0 out refusals
  state=$(new_state resource-giveup)
  GATE_LOCK=$(new_lock resource-giveup)
  wt="$TMP_ROOT/resource-giveup-wt"
  register_task "$state" task-a "$wt"
  register_task "$state" task-b "$TMP_ROOT/resource-giveup-wt-b"
  # A neighbouring full run that never finishes within this test.
  start_fixture_process "$wt/pytest-suite" >/dev/null

  outf="$TMP_ROOT/resource-giveup.out"; errf="$TMP_ROOT/resource-giveup.err"
  rcf="$TMP_ROOT/resource-giveup.rc"
  ( FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_POLL_SECONDS=1 \
    FM_GATE_RESOURCE_WAIT_SECONDS=3 "$GATE" acquire task-b --wait \
    >"$outf" 2>"$errf"; printf '%s\n' "$?" > "$rcf" ) &
  waiter=$!
  FIXTURE_PIDS+=("$waiter")
  while kill -0 "$waiter" 2>/dev/null && [ "$tries" -lt 200 ]; do
    tries=$((tries + 1))
    sleep 0.1
  done
  if kill -0 "$waiter" 2>/dev/null; then
    kill "$waiter" 2>/dev/null
    fail "acquire --wait never gave up on a resource refusal that cannot clear"
  fi
  wait "$waiter" 2>/dev/null

  expect_code 1 "$(cat "$rcf")" "giving up on a resource refusal must exit non-zero"
  out=$(cat "$outf")
  assert_contains "$out" "QUEUE GIVEN UP" \
    "the give-up must be visible on stdout, like every other refusal a worker reads"
  assert_contains "$out" "task-a" "the give-up must name the task whose run is live"
  assert_contains "$out" "abandoned rather than satisfied" \
    "the give-up must say the wait ended without the queue"
  assert_not_contains "$out" "queue held by you" \
    "giving up must never grant the queue - that is the second full run"
  assert_contains "$(cat "$errf")" "gave up after" "the give-up must reach stderr too"
  assert_contains "$out" "3s (FM_GATE_RESOURCE_WAIT_SECONDS)" \
    "the give-up must name the wait it exhausted by its variable and the value in force"
  # Quiet while waiting: the refusal names the live task once, not once per poll.
  refusals=$(grep -c "QUEUE NOT GRANTED" "$outf" | tr -d " ")
  [ "$refusals" -le 1 ] \
    || fail "the resource refusal was re-printed $refusals times while waiting"
  assert_contains "$out" "QUEUE WAITING - test work is live in task-a" \
    "the wait must name the live task while it waits"
  refusals=$(grep -c "QUEUE WAITING" "$outf" | tr -d " ")
  [ "$refusals" -le 1 ] \
    || fail "the wait line was re-printed $refusals times while waiting"
  assert_contains "$(gate "$state" status 2>&1)" "free" \
    "a refused acquire must not leave a hold behind"
  pass "fm-gate.sh: a resource refusal is given up rather than waited out forever"
}

# A --wait resource refusal that CLEARS is a wait, not a refusal: on 2026-09-22
# a worker read "QUEUE NOT GRANTED" followed silently by "queue held by you" and
# its gate's output as "refused, then ran anyway". The wait must say it is one,
# the grant must say it waited, and the command must start only after the
# neighbour's run ended.
test_a_cleared_run_wait_says_it_waited_and_starts_only_after_the_neighbour() {
  local state wt pid outf errf rcf waiter tries=0 out journal
  state=$(new_state resource-clears)
  GATE_LOCK=$(new_lock resource-clears)
  wt="$TMP_ROOT/resource-clears-wt"
  register_task "$state" task-a "$wt"
  register_task "$state" task-b "$TMP_ROOT/resource-clears-wt-b"
  pid=$(start_fixture_process "$wt/pytest-suite")

  outf="$TMP_ROOT/resource-clears.out"; errf="$TMP_ROOT/resource-clears.err"
  rcf="$TMP_ROOT/resource-clears.rc"
  ( FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_POLL_SECONDS=1 \
    "$GATE" run task-b --wait -- \
    bash -c "kill -0 $pid 2>/dev/null && echo STARTED_WHILE_LIVE || echo STARTED_AFTER_END" \
    >"$outf" 2>"$errf"; printf '%s\n' "$?" > "$rcf" ) &
  waiter=$!
  FIXTURE_PIDS+=("$waiter")
  while ! grep -q "QUEUE WAITING" "$outf" 2>/dev/null && kill -0 "$waiter" 2>/dev/null \
    && [ "$tries" -lt 100 ]; do
    tries=$((tries + 1))
    sleep 0.1
  done
  kill "$pid" 2>/dev/null
  tries=0
  while kill -0 "$waiter" 2>/dev/null && [ "$tries" -lt 200 ]; do
    tries=$((tries + 1))
    sleep 0.1
  done
  if kill -0 "$waiter" 2>/dev/null; then
    kill "$waiter" 2>/dev/null
    fail "run --wait never took the queue after the neighbour's run ended"
  fi
  wait "$waiter" 2>/dev/null

  out=$(cat "$outf")
  assert_not_contains "$out" "QUEUE NOT GRANTED" \
    "a wait that is still going must not print the terminal refusal"
  assert_not_contains "$out" "STARTED_WHILE_LIVE" \
    "the command must never start while the neighbour's run is live"
  expect_code 0 "$(cat "$rcf")" "a cleared resource wait must end in the command's own success"
  printf '%s\n' "$out" | awk '
    /QUEUE WAITING - test work is live in task-a/ && s == 0 { s = 1 }
    /QUEUE GRANTED AFTER WAITING [0-9]+s - test work in task-a is no longer seen/ && s == 1 { s = 2 }
    /queue held by you: task-b/ && s == 2 { s = 3 }
    /STARTED_AFTER_END/ && s == 3 { s = 4 }
    END { exit (s == 4 ? 0 : 1) }' \
    || fail "stdout must say waiting, then granted after waiting, then held, then run; got: $out"
  assert_contains "$(cat "$errf")" "waiting: test work is live outside the hold, in task-a" \
    "the wait must reach stderr in its waiting form"
  journal=$(cat "$GATE_LOCK.journal")
  assert_contains "$journal" "resource-wait id=task-b live_in=task-a" \
    "the journal must record the resource wait"
  printf '%s\n' "$journal" | grep "taken id=task-b" | grep -q "waited=[0-9]*s waited_for=task-a" \
    || fail "the taken event must record how long it waited and for whom; journal: $journal"
  pass "fm-gate.sh: a cleared run --wait says it waited and starts only after the neighbour ended"
}

# Guard: without --wait a resource refusal of `run` never starts the command.
test_run_without_wait_never_starts_under_a_resource_refusal() {
  local state wt out rc
  state=$(new_state resource-run-nowait)
  GATE_LOCK=$(new_lock resource-run-nowait)
  wt="$TMP_ROOT/resource-run-nowait-wt"
  register_task "$state" task-a "$wt"
  register_task "$state" task-b "$TMP_ROOT/resource-run-nowait-wt-b"
  start_fixture_process "$wt/pytest-suite" >/dev/null

  out=$(gate "$state" run task-b -- touch "$TMP_ROOT/resource-run-nowait.trace" 2>/dev/null); rc=$?
  expect_code 1 "$rc" "run must exit 1 on a resource refusal"
  [ ! -e "$TMP_ROOT/resource-run-nowait.trace" ] || fail "run started its command despite the refusal"
  assert_contains "$out" "QUEUE NOT GRANTED - a full run is already live in task-a" \
    "the no-wait refusal keeps its terminal wording"
  assert_contains "$(gate "$state" status 2>&1)" "free" "a refused run must not leave a hold behind"
  pass "fm-gate.sh: run without --wait never starts its command under a resource refusal"
}

# Guard: a run --wait that gives up never starts the command.
test_run_wait_that_gives_up_never_starts() {
  local state wt out rc
  state=$(new_state resource-run-giveup)
  GATE_LOCK=$(new_lock resource-run-giveup)
  wt="$TMP_ROOT/resource-run-giveup-wt"
  register_task "$state" task-a "$wt"
  register_task "$state" task-b "$TMP_ROOT/resource-run-giveup-wt-b"
  start_fixture_process "$wt/pytest-suite" >/dev/null

  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_POLL_SECONDS=1 \
    FM_GATE_RESOURCE_WAIT_SECONDS=3 "$GATE" run task-b --wait -- \
    touch "$TMP_ROOT/resource-run-giveup.trace" 2>/dev/null); rc=$?
  expect_code 1 "$rc" "a given-up run --wait must exit 1"
  [ ! -e "$TMP_ROOT/resource-run-giveup.trace" ] || fail "run started its command after giving up"
  assert_contains "$out" "QUEUE GIVEN UP" "the give-up must be on stdout"
  assert_not_contains "$out" "queue held by you" "giving up must never grant the queue"
  assert_contains "$(gate "$state" status 2>&1)" "free" "a given-up run must not leave a hold behind"
  pass "fm-gate.sh: run --wait that gives up never starts its command"
}

# A grant that followed no resource wait says nothing about waiting.
test_a_grant_without_a_resource_wait_is_unchanged() {
  local state out
  state=$(new_state resource-none)
  GATE_LOCK=$(new_lock resource-none)
  register_task "$state" task-b "$TMP_ROOT/resource-none-wt-b"

  out=$(gate "$state" run task-b --wait -- true 2>/dev/null) \
    || fail "run --wait on a free queue must succeed"
  assert_contains "$out" "queue held by you: task-b" "a free queue is granted as before"
  assert_not_contains "$out" "QUEUE GRANTED AFTER WAITING" "no wait happened, so none is reported"
  if grep "taken id=task-b" "$GATE_LOCK.journal" | grep -q "waited="; then
    fail "a grant with no resource wait must not record one"
  fi
  pass "fm-gate.sh: a grant with no resource wait is unchanged"
}

# The header owns what each queue line means.
test_help_explains_the_resource_wait_lines() {
  local out line
  out=$("$GATE" --help 2>&1)
  for line in "QUEUE WAITING" "QUEUE GRANTED AFTER WAITING" "QUEUE NOT GRANTED" "QUEUE GIVEN UP" \
    "only after \`queue held by you\`"; do
    assert_contains "$out" "$line" "--help must explain $line"
  done
  pass "fm-gate.sh: --help explains the resource wait lines"
}

test_waiting_workers_do_not_block_each_other() {
  local state wt out rc
  state=$(new_state waiters)
  GATE_LOCK=$(new_lock waiters)
  wt="$TMP_ROOT/waiters-wt"
  register_task "$state" task-a "$wt"
  register_task "$state" task-b "$TMP_ROOT/waiters-wt-b"
  # A worker WAITING for the queue keeps shells alive in its worktree that are
  # not check work. Counting those would have deadlocked the fleet.
  start_fixture_process "$wt/waiting-for-the-queue" >/dev/null

  out=$(gate "$state" acquire task-b 2>&1); rc=$?
  expect_code 0 "$rc" "a waiting worker's shells must not read as a live full run"
  assert_contains "$out" "queue held by you: task-b" "the queue must still be grantable beside waiters"
  pass "fm-gate.sh: waiting workers are not mistaken for running ones"
}

# The mandated worker one-liner puts the worktree path, the acquire invocation and
# the project's gate command in ONE argv. A harness that shells out through
# `bash -c` therefore leaves a merely WAITING shell whose command line reads
# exactly like a live run. Counting that text put two waiters in a permanent
# two-way stall - each refused issuance by the other's unrun command, and a
# resource refusal never ages out - which is the fleet deadlock the 2026-09-09
# narrowing closed. A process carrying this script's own invocation is a waiter or
# a wrapper by contract and is never the run.
test_a_waiting_worker_holding_the_gate_command_does_not_block_issuance() {
  local state wt out rc gate_name
  state=$(new_state waiter-argv)
  GATE_LOCK=$(new_lock waiter-argv)
  wt="$TMP_ROOT/waiter-argv-wt"
  register_task "$state" task-a "$wt"
  register_task "$state" task-b "$TMP_ROOT/waiter-argv-wt-b"
  gate_name=$(basename "$GATE")
  # Exactly the reported shape: the whole one-liner in one argv, playwright named
  # but never exec'd because acquire has not returned.
  start_fixture_process "cd $wt && $GATE acquire task-a --wait && npx playwright test; $GATE release task-a" >/dev/null

  out=$(gate "$state" acquire task-b 2>&1); rc=$?
  expect_code 0 "$rc" "a worker still waiting inside the gate command must not read as a live full run"
  assert_contains "$out" "queue held by you: task-b" \
    "the queue must be grantable beside a worker whose argv only mentions a runner"
  [ -n "$gate_name" ] || fail "the gate script must have a resolvable name to exclude"
  gate "$state" release task-b >/dev/null 2>&1

  # The mandated shape today: the `run` wrapper carries the runner name in its
  # own argv from the moment it starts waiting, and it never reaches `make`.
  start_fixture_process "cd $wt && $GATE run task-a --wait --status $state/task-a.status -- make test" >/dev/null
  out=$(gate "$state" acquire task-b 2>&1); rc=$?
  expect_code 0 "$rc" "a waiting run wrapper naming a runner must not read as a live full run"
  assert_contains "$out" "queue held by you: task-b" \
    "the queue must be grantable beside a run wrapper that has not started its command"
  pass "fm-gate.sh: a waiting worker carrying the gate command does not block issuance"
}

# The browser inspection is explicitly NOT queued, so the dev server it runs must
# not be counted as a full run: a resource refusal has no staleness path, so one
# idle dev server would pin the queue for the whole fleet indefinitely.
test_a_dev_server_does_not_block_issuance() {
  local state wt out rc
  state=$(new_state devserver)
  GATE_LOCK=$(new_lock devserver)
  wt="$TMP_ROOT/devserver-wt"
  register_task "$state" task-a "$wt"
  register_task "$state" task-b "$TMP_ROOT/devserver-wt-b"
  start_fixture_process "node $wt/node_modules/.bin/vite" >/dev/null

  out=$(gate "$state" acquire task-b 2>&1); rc=$?
  expect_code 0 "$rc" "a dev server in another worktree must not read as a live full run"
  assert_contains "$out" "queue held by you: task-b" "the queue must be grantable beside a dev server"
  pass "fm-gate.sh: a dev server does not block issuance"
}

# The wait must stay a wait. A poll of zero, or one no `sleep` accepts, turns
# `acquire --wait` into an unbounded hot spin that re-runs the whole probe as
# fast as the machine allows - on the worker whose entire turn is blocked inside
# that one command. The stale age and the ceiling already fall back to their
# defaults on an unusable value; the poll must too.
test_an_unusable_poll_does_not_spin() {
  local state wt fakebin real_date counter waiter iters poll
  state=$(new_state poll-guard)
  GATE_LOCK=$(new_lock poll-guard)
  wt="$TMP_ROOT/poll-guard-wt"
  register_task "$state" task-a "$wt"
  register_task "$state" task-b "$TMP_ROOT/poll-guard-wt-b"
  real_date=$(command -v date) || fail "date must be resolvable for the poll counter"
  fakebin="$TMP_ROOT/poll-guard-bin"
  counter="$TMP_ROOT/poll-guard.count"
  mkdir -p "$fakebin"
  # Each iteration of the wait loop reads the clock exactly once, so counting
  # clock reads counts iterations without reaching into the implementation.
  cat > "$fakebin/date" <<EOF
#!/bin/sh
echo tick >> "$counter"
exec "$real_date" "\$@"
EOF
  chmod +x "$fakebin/date"

  for poll in not-a-number 0 00; do
    gate "$state" acquire task-a >/dev/null 2>&1 || fail "the holder must take the queue"
    : > "$counter"
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
      FM_GATE_POLL_SECONDS="$poll" "$GATE" acquire task-b --wait >/dev/null 2>&1 &
    waiter=$!
    FIXTURE_PIDS+=("$waiter")
    sleep 3
    kill "$waiter" 2>/dev/null
    wait "$waiter" 2>/dev/null
    iters=$(wc -l < "$counter" | tr -d " ")
    # One iteration and then a real 30s sleep is the whole point; a spin runs the
    # loop as many times as three seconds of forking allows.
    [ "$iters" -le 3 ] \
      || fail "a poll of '$poll' spun the wait: $iters loop iterations in 3s"
    gate "$state" release task-a >/dev/null 2>&1
  done
  pass "fm-gate.sh: an unusable poll falls back to the default instead of spinning"
}

# A hold that cannot be created is not a hold someone else is holding. Moving the
# default off world-writable /tmp made the parent reachable-or-not: it can be
# absent and uncreatable, root-owned, or on an unmounted XDG_STATE_HOME. Reported
# as contention it printed an empty holder - the shape a worker cannot act on -
# and under --wait it waited forever on a path that can never appear, inside the
# one command the worker's whole turn is blocked in.
test_an_unusable_hold_parent_is_refused_rather_than_waited_out() {
  local state parent out rc errf outf rcf waiter tries=0
  state=$(new_state unusable-parent)
  parent="$TMP_ROOT/unusable-parent"
  mkdir -p "$parent"
  GATE_LOCK="$parent/hold"
  if [ "$(id -u)" = 0 ]; then
    pass "fm-gate.sh: an unusable hold parent is refused rather than waited out (skipped as root)"
    return 0
  fi
  chmod 500 "$parent"

  out=$(gate "$state" acquire task-a 2>/dev/null); rc=$?
  expect_code 1 "$rc" "an acquire that cannot create the hold must fail"
  assert_contains "$out" "QUEUE NOT AVAILABLE" \
    "the refusal must be visible on stdout, like every other refusal a worker reads"
  assert_not_contains "$out" "QUEUE NOT YOURS - held by: " \
    "an uncreatable hold must never be reported as a hold with no holder"

  # --wait must refuse too: no wait can make an unwritable parent writable.
  outf="$TMP_ROOT/unusable-parent.out"; errf="$TMP_ROOT/unusable-parent.err"
  rcf="$TMP_ROOT/unusable-parent.rc"
  ( FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_POLL_SECONDS=1 \
    "$GATE" acquire task-a --wait >"$outf" 2>"$errf"; printf '%s\n' "$?" > "$rcf" ) &
  waiter=$!
  FIXTURE_PIDS+=("$waiter")
  while kill -0 "$waiter" 2>/dev/null && [ "$tries" -lt 150 ]; do
    tries=$((tries + 1))
    sleep 0.1
  done
  if kill -0 "$waiter" 2>/dev/null; then
    kill "$waiter" 2>/dev/null
    chmod 700 "$parent"
    fail "acquire --wait parked on a hold path that can never appear"
  fi
  wait "$waiter" 2>/dev/null
  expect_code 1 "$(cat "$rcf")" "acquire --wait must fail on an uncreatable hold"
  assert_contains "$(cat "$outf")" "QUEUE NOT AVAILABLE" \
    "the --wait refusal must reach stdout too"
  assert_contains "$(cat "$errf")" "not writable" \
    "the refusal must name why the hold cannot be created"
  chmod 700 "$parent"
  pass "fm-gate.sh: an unusable hold parent is refused rather than waited out"
}

# A relative hold path resolves against each acquiring process's own working
# directory, and every worker runs the mandated one-liner from a different task
# worktree - so one machine-wide hold silently becomes a hold per worktree and two
# full runs go at once, which is the hazard this queue exists to remove. There is
# no correct base to resolve it against, so it is refused rather than guessed at.
test_a_relative_hold_path_is_refused_rather_than_held_per_worktree() {
  local state dir out rc
  state=$(new_state relative-hold)
  mkdir -p "$TMP_ROOT/relative-a" "$TMP_ROOT/relative-b"
  for dir in "$TMP_ROOT/relative-a" "$TMP_ROOT/relative-b"; do
    out=$( cd "$dir" && FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR=fmhold \
      "$GATE" acquire task-x 2>&1 ); rc=$?
    expect_code 1 "$rc" "a relative hold path must be refused, never granted"
    assert_contains "$out" "QUEUE NOT AVAILABLE" \
      "the refusal must be visible on stdout, like every other refusal a worker reads"
    assert_contains "$out" "not an absolute path" \
      "the refusal must name why a relative hold path cannot serialize the fleet"
    [ ! -e "$dir/fmhold" ] \
      || fail "a relative hold path must not create a hold inside the worker's own directory"
  done
  pass "fm-gate.sh: a relative hold path is refused rather than held per worktree"
}

# The gate runs wherever a worker's pane runs, including the stock macOS bash this
# repo still supports, where expanding an empty array under `set -u` is fatal. A
# hold path whose `..` pops back to the root took exactly that route and refused a
# perfectly usable path with a raw bash diagnostic, so this drives the platform's
# own /bin/bash rather than the ambient one, which cannot see the class at all.
test_a_hold_path_resolved_through_dotdot_works_under_the_platform_bash() {
  local state shell spelled out err rc
  state=$(new_state platform-bash)
  GATE_LOCK=$(new_lock platform-bash)
  shell=/bin/bash
  [ -x "$shell" ] || shell=$(command -v bash)
  # Pops the leading component back to the root, then names the hold again.
  spelled="/tmp/..$GATE_LOCK"
  err="$TMP_ROOT/platform-bash.err"

  out=$(FM_GATE_LOCK_DIR="$spelled" "$shell" "$GATE" status 2>"$err"); rc=$?
  expect_code 0 "$rc" "status must succeed for a hold path resolved through .."
  assert_contains "$out" "free" "the hold must read as free rather than be refused"
  assert_not_contains "$(cat "$err")" "unbound variable" \
    "the platform's own bash must not abort inside the gate"

  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$spelled" "$shell" \
    "$GATE" acquire task-a 2>"$err"); rc=$?
  expect_code 0 "$rc" "acquire must succeed for a hold path resolved through .."
  assert_contains "$out" "queue held by you: task-a" "the queue must be granted"
  assert_not_contains "$(cat "$err")" "unbound variable" \
    "acquire must not abort inside the gate under the platform's own bash"
  [ -d "$GATE_LOCK" ] \
    || fail "the hold must be created at the canonical path, not at the spelled one"
  pass "fm-gate.sh: a hold path resolved through .. works under the platform's own bash"
}

# A fixed name in a shared directory can be pre-created by someone else. Such a
# hold is refused outright and never removed - least of all followed through a
# symlink into a directory this fleet does not own.
test_a_foreign_hold_is_refused_and_never_removed() {
  local state target out rc
  state=$(new_state foreign)
  GATE_LOCK=$(new_lock foreign)
  target="$TMP_ROOT/foreign-target"
  mkdir -p "$target"
  printf '%s\n' "someone-else" > "$target/owner"
  ln -s "$target" "$GATE_LOCK"

  out=$(gate "$state" acquire task-a 2>/dev/null); rc=$?
  expect_code 1 "$rc" "a hold this user does not own must be refused"
  assert_contains "$out" "QUEUE NOT AVAILABLE" "the refusal must be visible on stdout"
  [ -L "$GATE_LOCK" ] || fail "a foreign hold must not be removed by acquire"

  # Age must not turn it into something breakable either.
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-a 2>/dev/null); rc=$?
  expect_code 1 "$rc" "the stale rule must not break a hold this user does not own"
  [ -L "$GATE_LOCK" ] || fail "the stale rule must not remove a foreign hold"
  [ -e "$target/owner" ] || fail "the stale rule must not empty the directory a foreign hold points at"

  out=$(gate "$state" release task-a 2>/dev/null); rc=$?
  expect_code 1 "$rc" "release must refuse a hold this user does not own"
  [ -L "$GATE_LOCK" ] || fail "release must not remove a foreign hold"
  pass "fm-gate.sh: a foreign hold is refused and never removed"
}

test_secondmate_homes_are_not_counted_as_runs() {
  local state home out rc
  state=$(new_state secondmate)
  GATE_LOCK=$(new_lock secondmate)
  home="$TMP_ROOT/secondmate-home"
  mkdir -p "$home"
  fm_write_secondmate_meta "$state/mate-1.meta" "$home"
  register_task "$state" task-b "$TMP_ROOT/secondmate-task-wt"
  # A secondmate home is a firstmate, not a task worktree; its own crews are
  # accounted through their own metadata, and the machine-wide hold is what
  # serializes them against this home.
  start_fixture_process "$home/pytest-suite" >/dev/null

  out=$(gate "$state" acquire task-b 2>&1); rc=$?
  expect_code 0 "$rc" "a secondmate home must not hold the fleet's gate queue shut"
  assert_contains "$out" "queue held by you: task-b" "the queue must be granted beside a secondmate home"
  pass "fm-gate.sh: secondmate homes are excluded from the live-run probe"
}

# Take the hold the way the current mandated one-liner does: `run` with a
# status file, holding the command open. The wrapper is the recorded holder
# process and it keeps the heartbeat. Echoes the wrapper's pid.
start_run_holder() {
  local state=$1 id=$2 wt=$3 status=$4 runner=${5:-sleep 60} pid tries=0
  mkdir -p "$wt"
  FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
    bash -c 'cd "$2" && exec "$1" run "$3" --status "$4" -- $5' _ "$GATE" "$wt" "$id" "$status" "$runner" >/dev/null 2>&1 &
  pid=$!
  FIXTURE_PIDS+=("$pid")
  while [ "$tries" -lt 300 ]; do
    case "$(FM_GATE_LOCK_DIR="$GATE_LOCK" "$GATE" status 2>/dev/null)" in
      *"held by: $id"*) printf '%s\n' "$pid"; return 0 ;;
    esac
    tries=$((tries + 1))
    sleep 0.05
  done
  fail "the run holder never took the hold for $id"
}

# Start a `--wait` acquire directly (no wrapper subshell), so the pid returned
# is the gate process itself and killing it ends its wait and its ticket.
start_waiter() {
  local state=$1 id=$2 poll=$3 out=$4 pid tries=0
  FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_POLL_SECONDS="$poll" \
    "$GATE" acquire "$id" --wait >"$out" 2>"$out.err" &
  pid=$!
  FIXTURE_PIDS+=("$pid")
  while [ "$tries" -lt 200 ]; do
    case "$(FM_GATE_LOCK_DIR="$GATE_LOCK" "$GATE" status 2>/dev/null)" in
      *"$id  waiting"*) printf '%s\n' "$pid"; return 0 ;;
    esac
    tries=$((tries + 1))
    sleep 0.05
  done
  fail "the waiter $id never appeared in the queue"
}

# A stale hold built by hand, as an older copy of the script or a dead plain
# acquire leaves it: owner recorded, no process, no heartbeat.
write_dead_hold() {
  local owner=$1 wt=$2 age=$3
  mkdir -p "$GATE_LOCK"
  printf '%s\n' "$owner" > "$GATE_LOCK/owner"
  printf '%s\n' "$wt" > "$GATE_LOCK/owner_worktree"
  printf '%s\n' "token-of-the-stale-hold" > "$GATE_LOCK/token"
  age_path "$GATE_LOCK" "$age"
}

# On 2026-09-17 a full run measured at 134 minutes was broken at the two-hour
# ceiling while genuinely live, because the only liveness the hold carried was
# inferred and the ceiling exists to bound that inference. A holder that proves
# itself alive with its own heartbeat is not subject to it at any age; the
# waiter notes the long run once in the journal instead of interrupting it.
test_a_live_run_older_than_the_ceiling_keeps_its_hold() {
  local state wt statusf out err rc token journal
  state=$(new_state live-past-ceiling)
  GATE_LOCK=$(new_lock live-past-ceiling)
  wt="$TMP_ROOT/live-past-ceiling-wt"
  statusf="$TMP_ROOT/live-past-ceiling.status"
  register_task "$state" task-a "$wt"
  : > "$statusf"
  start_run_holder "$state" task-a "$wt" "$statusf" >/dev/null
  age_path "$GATE_LOCK" 8000
  token=$(cat "$GATE_LOCK/token")
  err="$TMP_ROOT/live-past-ceiling.err"
  journal="$GATE_LOCK.journal"

  out=$(gate "$state" acquire task-b 2>"$err"); rc=$?
  expect_code 1 "$rc" "a live run past the ceiling must keep its hold"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-a" "the live holder must still be named"
  assert_not_contains "$(cat "$err")" "breaking" \
    "a hold with a live heartbeat must never be broken, whatever its age"
  [ "$(cat "$GATE_LOCK/token" 2>/dev/null)" = "$token" ] \
    || fail "the live run's hold must be the same hold after the refused acquire"
  [ "$(grep -c 'over-ceiling-alive id=task-a' "$journal" 2>/dev/null | tr -d ' ')" = 1 ] \
    || fail "a live run past the ceiling must be noted exactly once in the journal: $(cat "$journal" 2>/dev/null)"
  out=$(gate "$state" acquire task-b 2>"$err"); rc=$?
  expect_code 1 "$rc" "a second acquire must be refused the same way"
  [ "$(grep -c 'over-ceiling-alive id=task-a' "$journal" 2>/dev/null | tr -d ' ')" = 1 ] \
    || fail "the over-ceiling note must not repeat on every poll"
  pass "fm-gate.sh: a live run older than the ceiling keeps its hold"
}

# Waiters beside a live run used to walk up to the break marker on every poll,
# because the pre-filter admitted them by age alone; each one created and
# removed the marker, read each other's rmdir as another user's marker, and the
# reported "foreign marker, present for three hours" was those waiters
# recreating it. A fresh heartbeat answers before any of that starts: no
# marker, no pgrep, nothing on stderr.
test_a_live_heartbeat_keeps_waiters_off_the_break_marker() {
  local state wt statusf fakebin calls waiter err ticks
  state=$(new_state hb-no-marker)
  GATE_LOCK=$(new_lock hb-no-marker)
  wt="$TMP_ROOT/hb-no-marker-wt"
  statusf="$TMP_ROOT/hb-no-marker.status"
  register_task "$state" task-a "$wt"
  : > "$statusf"
  start_run_holder "$state" task-a "$wt" "$statusf" >/dev/null
  age_path "$GATE_LOCK" 3600

  # The probe is slowed and logged, so a waiter that reaches it is both visible
  # and slow enough to be caught holding the marker.
  fakebin=$(fm_fakebin "$TMP_ROOT/hb-no-marker")
  calls="$TMP_ROOT/hb-no-marker.pgrep-calls"
  : > "$calls"
  cat > "$fakebin/pgrep" <<SH
#!/usr/bin/env bash
echo "pgrep \$*" >> "$calls"
sleep 0.4
exit 1
SH
  chmod +x "$fakebin/pgrep"
  # The fake proves it logs before its log is trusted to stay empty: the name
  # resolves to the fake, one call reaches the log, and the empty-log assertion
  # below would fail on exactly that.
  [ "$(PATH="$fakebin:$PATH" command -v pgrep)" = "$fakebin/pgrep" ] \
    || fail "pgrep must resolve to the fake on the test PATH"
  PATH="$fakebin:$PATH" pgrep -f probe-proof >/dev/null 2>&1 || true
  [ -s "$calls" ] || fail "the fake pgrep did not record a call it was given"
  : > "$calls"

  err="$TMP_ROOT/hb-no-marker.err"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
    FM_GATE_POLL_SECONDS=1 "$GATE" acquire task-b --wait >/dev/null 2>"$err" &
  waiter=$!
  FIXTURE_PIDS+=("$waiter")
  ticks=0
  while [ "$ticks" -lt 200 ]; do
    [ ! -e "$GATE_LOCK.breaking" ] \
      || { kill "$waiter" 2>/dev/null; fail "a waiter beside a live heartbeat created the break marker"; }
    ticks=$((ticks + 1))
    sleep 0.02
  done
  kill "$waiter" 2>/dev/null
  wait "$waiter" 2>/dev/null
  [ ! -s "$err" ] || fail "a waiter beside a live heartbeat wrote to stderr: $(cat "$err")"
  [ ! -s "$calls" ] || fail "a waiter beside a live heartbeat ran the probe: $(cat "$calls")"
  pass "fm-gate.sh: a live heartbeat keeps waiters off the break marker"
}

# A freed hold went to whichever waiter's poll landed first, and one waiter was
# passed twice in four hours. It goes to the oldest live ticket now, whatever
# the polling cadence: the slow, earlier waiter takes it and the fast, later
# one keeps waiting.
test_the_oldest_waiter_takes_the_hold_whatever_its_poll_cadence() {
  local state old new out
  state=$(new_state oldest-first)
  GATE_LOCK=$(new_lock oldest-first)
  gate "$state" acquire holder >/dev/null 2>&1 || fail "the holder must take the queue"
  old=$(start_waiter "$state" task-old 4 "$TMP_ROOT/oldest-first.old")
  sleep 1
  new=$(start_waiter "$state" task-new 1 "$TMP_ROOT/oldest-first.new")

  gate "$state" release holder >/dev/null 2>&1
  sleep 6
  out=$(gate "$state" status 2>&1)
  case "$out" in
    "held by: task-old"*) : ;;
    *) fail "the oldest waiter must take the freed hold, got: $out" ;;
  esac
  kill -0 "$new" 2>/dev/null || fail "the later waiter must still be waiting"
  assert_contains "$out" "waiting: 1" "the later waiter must still be listed"
  assert_contains "$out" "task-new" "the later waiter must be listed by name"
  wait "$old" 2>/dev/null
  assert_contains "$(cat "$TMP_ROOT/oldest-first.old")" "queue held by you: task-old" \
    "the oldest waiter must be told the queue is its own"
  pass "fm-gate.sh: the oldest waiter takes the hold whatever its poll cadence"
}

# The order of arrival is only an order if it cannot be skipped by not waiting:
# a free hold with a live waiter refuses a bare acquire and names the waiter. A
# ticket whose process is gone is nobody, so it never blocks the queue.
test_a_waiter_ahead_refuses_a_bare_acquire_and_a_dead_ticket_does_not() {
  local state waiter out rc dead ticket now
  state=$(new_state waiter-ahead)
  GATE_LOCK=$(new_lock waiter-ahead)
  gate "$state" acquire holder >/dev/null 2>&1 || fail "the holder must take the queue"
  waiter=$(start_waiter "$state" task-w 30 "$TMP_ROOT/waiter-ahead.w")
  gate "$state" release holder >/dev/null 2>&1

  out=$(gate "$state" acquire task-x 2>/dev/null); rc=$?
  expect_code 1 "$rc" "a bare acquire must be refused while a live waiter is ahead"
  assert_contains "$out" "QUEUE NOT YOURS - free, but 1 waiting ahead of you (oldest task-w" \
    "the refusal must be on stdout and name the waiter ahead"
  assert_contains "$out" "use --wait to queue" "the refusal must say how to queue"
  kill "$waiter" 2>/dev/null
  wait "$waiter" 2>/dev/null

  # A ticket whose recorded process has exited: the pid of a sleep that is gone.
  sleep 0 &
  dead=$!
  wait "$dead" 2>/dev/null
  now=$(date +%s)
  ticket="$GATE_LOCK.queue/$((now - 100)).$dead.task-dead"
  mkdir -p "$GATE_LOCK.queue"
  printf 'id=task-dead\npid=%s\npid_start=\nsince=%s\n' "$dead" "$((now - 100))" > "$ticket"
  out=$(gate "$state" acquire task-x 2>/dev/null); rc=$?
  expect_code 0 "$rc" "a dead ticket must not block the queue"
  assert_contains "$out" "queue held by you: task-x" "the queue must be granted past a dead ticket"
  [ ! -e "$ticket" ] || fail "a dead ticket must be removed by the contender that found it"
  pass "fm-gate.sh: a waiter ahead refuses a bare acquire and a dead ticket does not"
}

# Nobody could see who was waiting, or for how long: `status` named the holder
# and nothing else. It lists the waiters in queue order with their ages, and
# --line is the same on one line for a log marker.
test_status_lists_waiters_with_their_ages() {
  local state wt statusf out ticket
  state=$(new_state status-waiters)
  GATE_LOCK=$(new_lock status-waiters)
  wt="$TMP_ROOT/status-waiters-wt"
  statusf="$TMP_ROOT/status-waiters.status"
  register_task "$state" task-a "$wt"
  : > "$statusf"
  start_run_holder "$state" task-a "$wt" "$statusf" >/dev/null
  start_waiter "$state" task-b 30 "$TMP_ROOT/status-waiters.b" >/dev/null
  # task-b arrived a long time ago: its ticket records that arrival.
  ticket=$(find "$GATE_LOCK.queue" -name '*.task-b' | head -n 1)
  [ -n "$ticket" ] || fail "task-b must have a ticket"
  sed "s/^since=.*/since=$(( $(date +%s) - 4000 ))/" "$ticket" > "$ticket.new" && mv "$ticket.new" "$ticket"
  start_waiter "$state" task-c 30 "$TMP_ROOT/status-waiters.c" >/dev/null

  out=$(gate "$state" status 2>&1)
  case "$out" in
    "held by: task-a"*) : ;;
    *) fail "status must name the holder first: $out" ;;
  esac
  assert_contains "$out" "heartbeat" "status must show the holder's heartbeat"
  assert_contains "$out" "running" "status must say the holder is running"
  assert_contains "$out" "waiting: 2" "status must count the waiters"
  printf '%s\n' "$out" | grep -Eq '^  1\. task-b  waiting (40[0-9][0-9])s$' \
    || fail "the oldest waiter must be listed first with its age: $out"
  printf '%s\n' "$out" | grep -Eq '^  2\. task-c  waiting [0-9]s$' \
    || fail "the newest waiter must be listed last with its age: $out"
  out=$(gate "$state" status --line 2>&1)
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "status --line must print one line: $out"
  assert_contains "$out" "held by: task-a" "status --line must name the holder"
  assert_contains "$out" "waiting: 2" "status --line must count the waiters"
  pass "fm-gate.sh: status lists the waiters with their ages"
}

# Every refusal on the break marker said "not owned by this user", for a symlink,
# for a plain file, for another uid, and for an owner that simply could not be
# read - and two workers and firstmate went looking for a user who did not
# exist. The refusal names what it found, and this user's own directory is
# never called foreign.
test_a_marker_refusal_names_what_it_found() {
  local state wt target out err rc fakebin real_stat
  state=$(new_state marker-finding)
  GATE_LOCK=$(new_lock marker-finding)
  wt="$TMP_ROOT/marker-finding-wt"
  err="$TMP_ROOT/marker-finding.err"
  write_dead_hold task-dead "$wt" 3600

  # This user's own marker, held by another contender right now.
  mkdir "$GATE_LOCK.breaking"
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>"$err"); rc=$?
  expect_code 1 "$rc" "a contender must wait behind another contender's own marker"
  assert_not_contains "$(cat "$err")" "BREAK NOT POSSIBLE" \
    "this user's own marker must never be refused as foreign"
  assert_not_contains "$(cat "$err")" "not owned" "this user's own marker must never be called another user's"
  [ -d "$GATE_LOCK.breaking" ] || fail "an actively held marker must not be removed"
  rmdir "$GATE_LOCK.breaking"

  # A symbolic link.
  target="$TMP_ROOT/marker-finding-target"
  mkdir -p "$target"
  ln -s "$target" "$GATE_LOCK.breaking"
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>"$err"); rc=$?
  expect_code 1 "$rc" "a symlinked marker must block the break"
  assert_contains "$(cat "$err")" "BREAK NOT POSSIBLE - the break marker at $GATE_LOCK.breaking is a symbolic link" \
    "the refusal must say the marker is a symbolic link"
  [ -L "$GATE_LOCK.breaking" ] || fail "a symlinked marker must never be removed"
  [ -d "$target" ] || fail "a symlinked marker must never be followed and emptied"
  rm "$GATE_LOCK.breaking"

  # A plain file.
  : > "$GATE_LOCK.breaking"
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>"$err"); rc=$?
  expect_code 1 "$rc" "a marker that is a plain file must block the break"
  assert_contains "$(cat "$err")" "is not a directory" "the refusal must say the marker is not a directory"
  [ -f "$GATE_LOCK.breaking" ] || fail "a file at the marker path must never be removed"
  rm "$GATE_LOCK.breaking"

  # Another uid, as the ownership read reports it for this user's own directory.
  mkdir "$GATE_LOCK.breaking"
  real_stat=$(command -v stat) || fail "stat must be resolvable"
  fakebin=$(fm_fakebin "$TMP_ROOT/marker-finding")
  cat > "$fakebin/stat" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"%u "*"$GATE_LOCK.breaking") echo 0; exit 0 ;;
esac
exec "$real_stat" "\$@"
SH
  chmod +x "$fakebin/stat"
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
    FM_GATE_STALE_SECONDS=0 "$GATE" acquire task-b 2>"$err"); rc=$?
  expect_code 1 "$rc" "a marker owned by another uid must block the break"
  assert_contains "$(cat "$err")" "is owned by uid 0, not $(id -u)" \
    "the refusal must name the uid it found and the uid it expected"
  [ -d "$GATE_LOCK.breaking" ] || fail "a marker reported as another user's must never be removed"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-dead" "the hold must be left intact throughout"
  pass "fm-gate.sh: a marker refusal names what it found"
}

# A marker whose owner could not be read was reported as another user's, and
# that reading came from a race: the existence test saw a neighbour's marker
# and the ownership read landed after its rmdir. An unreadable owner is exactly
# that - unreadable - and the rule is not disabled by it: this round is skipped
# and the next poll asks again.
test_an_unreadable_marker_owner_is_retried_not_called_foreign() {
  local state wt fakebin real_stat counter out err rc outf errf rcf waiter tries=0
  state=$(new_state marker-unreadable)
  GATE_LOCK=$(new_lock marker-unreadable)
  wt="$TMP_ROOT/marker-unreadable-wt"
  err="$TMP_ROOT/marker-unreadable.err"
  write_dead_hold task-dead "$wt" 3600
  # A marker left behind by a breaker killed mid-decision, long past its own
  # recovery clock, so the break can proceed once the owner reads.
  mkdir "$GATE_LOCK.breaking"
  age_path "$GATE_LOCK.breaking" 200

  real_stat=$(command -v stat) || fail "stat must be resolvable"
  fakebin=$(fm_fakebin "$TMP_ROOT/marker-unreadable")
  counter="$TMP_ROOT/marker-unreadable.count"
  : > "$counter"
  cat > "$fakebin/stat" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"$GATE_LOCK.breaking")
    if [ "\$(wc -l < "$counter" | tr -d ' ')" -lt 3 ]; then
      echo fail >> "$counter"
      exit 1
    fi
    ;;
esac
exec "$real_stat" "\$@"
SH
  chmod +x "$fakebin/stat"

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
    FM_GATE_STALE_SECONDS=0 "$GATE" acquire task-b 2>"$err"); rc=$?
  expect_code 1 "$rc" "an unreadable marker owner must skip the round, not break"
  assert_contains "$(cat "$err")" "could not read the owner of $GATE_LOCK.breaking; retrying next poll" \
    "the skipped round must say the owner could not be read"
  assert_not_contains "$(cat "$err")" "not owned by this user" \
    "an unreadable owner must never be reported as another user's"
  assert_not_contains "$(cat "$err")" "removed by hand" \
    "an unreadable owner must not declare the rule disabled"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-dead" "the hold must be intact"
  [ "$(wc -l < "$counter" | tr -d ' ')" = 3 ] \
    || fail "the owner must have been read three times before it was called unreadable"

  # Once the owner reads, the very next poll breaks the abandoned hold.
  outf="$TMP_ROOT/marker-unreadable.out"; errf="$TMP_ROOT/marker-unreadable.wait.err"
  rcf="$TMP_ROOT/marker-unreadable.rc"
  ( PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
      FM_GATE_STALE_SECONDS=0 FM_GATE_POLL_SECONDS=1 "$GATE" acquire task-b --wait \
      >"$outf" 2>"$errf"; printf '%s\n' "$?" > "$rcf" ) &
  waiter=$!
  FIXTURE_PIDS+=("$waiter")
  while kill -0 "$waiter" 2>/dev/null && [ "$tries" -lt 50 ]; do
    tries=$((tries + 1))
    sleep 0.1
  done
  if kill -0 "$waiter" 2>/dev/null; then
    kill "$waiter" 2>/dev/null
    fail "the waiter did not break the abandoned hold within 5s once the marker owner read"
  fi
  wait "$waiter" 2>/dev/null
  expect_code 0 "$(cat "$rcf")" "the waiter must be granted the broken hold"
  assert_contains "$(cat "$outf")" "queue held by you: task-b" "the waiter must hold the queue"
  assert_contains "$(cat "$errf")" "breaking an abandoned hold (owner task-dead" \
    "the break must be announced once the owner read"
  pass "fm-gate.sh: an unreadable marker owner is retried, not called foreign"
}

# The ticket directory and the journal are two more fixed names in the same
# shared directory, and they get the hold's own protections: never followed
# through a symlink, never removed, and the refusal names the finding.
test_a_foreign_queue_directory_or_journal_is_refused_and_never_removed() {
  local state target out err rc
  state=$(new_state foreign-queue)
  GATE_LOCK=$(new_lock foreign-queue)
  err="$TMP_ROOT/foreign-queue.err"
  target="$TMP_ROOT/foreign-queue-target"
  mkdir -p "$target"
  : > "$target/someone-elses-ticket"
  ln -s "$target" "$GATE_LOCK.queue"

  out=$(gate "$state" acquire task-b --wait 2>"$err"); rc=$?
  expect_code 1 "$rc" "a --wait behind a foreign ticket directory must refuse rather than wait"
  assert_contains "$out" "QUEUE NOT AVAILABLE" "the refusal must be visible on stdout"
  assert_contains "$out" "is a symbolic link" "the refusal must name what it found"
  [ -L "$GATE_LOCK.queue" ] || fail "a foreign ticket directory must never be removed"
  [ -e "$target/someone-elses-ticket" ] || fail "a foreign ticket directory must never be followed and emptied"
  rm "$GATE_LOCK.queue"

  target="$TMP_ROOT/foreign-queue-journal-target"
  printf 'untouched\n' > "$target"
  ln -s "$target" "$GATE_LOCK.journal"
  out=$(gate "$state" acquire task-b 2>"$err"); rc=$?
  expect_code 0 "$rc" "a foreign journal must not block the queue"
  assert_contains "$out" "queue held by you: task-b" "the queue must still be granted"
  [ "$(cat "$target")" = untouched ] || fail "a symlinked journal must never be written through"
  [ -L "$GATE_LOCK.journal" ] || fail "a foreign journal must never be replaced"
  [ "$(grep -c journal "$err" | tr -d ' ')" = 1 ] \
    || fail "a foreign journal must be named exactly once on stderr: $(cat "$err")"
  assert_contains "$(cat "$err")" "is a symbolic link" "the journal refusal must name what it found"
  pass "fm-gate.sh: a foreign queue directory or journal is refused and never removed"
}

# "Hold the queue while I triage, run nothing" had no spelling: on 2026-09-16 a
# hold with nothing running was broken as abandoned while its owner was
# triaging the broken run. A park is that state, with a reason and a deadline;
# until the deadline it is neither abandoned nor over the ceiling, past it the
# hold is judged like any other, and a park never skips the waiters.
test_a_parked_hold_is_neither_abandoned_nor_over_the_ceiling_until_it_expires() {
  local state out err rc waiter
  state=$(new_state park)
  GATE_LOCK=$(new_lock park)
  err="$TMP_ROOT/park.err"

  # Parked from a shell that is gone, so no process of task-a exists.
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
    bash -c '"$1" park task-a --reason "triage after a broken run" --for 100' _ "$GATE" 2>&1); rc=$?
  expect_code 0 "$rc" "a free queue must be parkable"
  assert_contains "$out" "queue parked by you: task-a (triage_after_a_broken_run, 100s)" \
    "park must confirm the reason and the deadline"
  age_path "$GATE_LOCK" 8000

  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>"$err"); rc=$?
  expect_code 1 "$rc" "a parked hold must not be broken before its deadline, whatever its age"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-a" "the parked holder must keep the queue"
  assert_not_contains "$(cat "$err")" "breaking" "a parked hold must not be broken as abandoned or over the ceiling"
  out=$(gate "$state" status 2>&1)
  assert_contains "$out" "parked: triage_after_a_broken_run" "status must show the park and its reason"
  assert_contains "$out" "expires in" "status must show the remaining deadline"

  # Past its deadline the park is over and the hold is judged like any other.
  printf 'reason=triage_after_a_broken_run\nuntil=%s\n' "$(( $(date +%s) - 10 ))" > "$GATE_LOCK/parked"
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>"$err"); rc=$?
  expect_code 0 "$rc" "an expired park must be breakable like any abandoned hold"
  assert_contains "$out" "queue held by you: task-b" "the expired park must hand the queue over"
  assert_contains "$(cat "$err")" "breaking" "the expired park must be broken loudly"
  assert_contains "$(cat "$err")" "park-expired" "the break must name the expired park as its reason"
  gate "$state" release task-b >/dev/null 2>&1

  # A park never skips a waiter ahead of it.
  gate "$state" acquire holder >/dev/null 2>&1
  waiter=$(start_waiter "$state" task-w 30 "$TMP_ROOT/park.w")
  gate "$state" release holder >/dev/null 2>&1
  out=$(gate "$state" park task-c --reason x 2>&1); rc=$?
  expect_code 1 "$rc" "a park must be refused while a waiter is ahead"
  assert_contains "$out" "waiting ahead" "the refusal must name the waiter ahead"
  kill "$waiter" 2>/dev/null
  wait "$waiter" 2>/dev/null
  pass "fm-gate.sh: a parked hold is neither abandoned nor over the ceiling until it expires"
}

# `run` is the mandated one-liner's whole body: the running status line is
# written the instant the queue is granted, the command's own exit status is
# carried out, and the release happens on every exit status - which used to be
# a discipline asked of the worker, and is a property of the wrapper now. A
# refused queue runs nothing.
test_run_writes_the_running_line_releases_on_failure_and_carries_the_exit_status() {
  local state statusf out rc journal trace
  state=$(new_state run-wrapper)
  GATE_LOCK=$(new_lock run-wrapper)
  statusf="$TMP_ROOT/run-wrapper.status"
  journal="$GATE_LOCK.journal"
  printf 'paused: waiting for the test-gate queue\n' > "$statusf"

  out=$(gate "$state" run task-a --status "$statusf" -- bash -c 'exit 7' 2>/dev/null); rc=$?
  expect_code 7 "$rc" "run must exit with the command's own status"
  assert_contains "$out" "queue held by you: task-a" "run must confirm the hold before the command"
  [ "$(sed -n 2p "$statusf")" = "working: queue taken, gate running" ] \
    || fail "run must append exactly the running line as the second status line: $(cat "$statusf")"
  [ "$(wc -l < "$statusf" | tr -d ' ')" = 2 ] || fail "run must append exactly one status line"
  assert_contains "$(gate "$state" status 2>&1)" "free" "run must release the queue when the command fails"
  assert_contains "$(cat "$journal")" "taken id=task-a" "the journal must record the grant"
  assert_contains "$(cat "$journal")" "released id=task-a" "the journal must record the release"

  # Refused: nothing written, nothing run.
  gate "$state" acquire task-z >/dev/null 2>&1 || fail "another task must be able to take the queue"
  trace="$TMP_ROOT/run-wrapper.trace"
  out=$(gate "$state" run task-a --status "$statusf" -- touch "$trace" 2>/dev/null); rc=$?
  expect_code 1 "$rc" "run without --wait must exit 1 when the queue is busy"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-z" "the refusal must name the holder"
  [ "$(wc -l < "$statusf" | tr -d ' ')" = 2 ] || fail "a refused run must not touch the status file"
  [ ! -e "$trace" ] || fail "a refused run must never start its command"
  pass "fm-gate.sh: run writes the running line, releases on failure and carries the exit status"
}

# A break used to be visible only on the breaker's own stderr, so an incident
# was found by matching pids against logs by hand. The break leaves its trace
# where firstmate reads: a `blocked` line in the displaced holder's status
# file, which wakes firstmate, and a journal line with the evidence seen.
test_breaking_a_hold_leaves_a_trace_where_firstmate_reads() {
  local state wt statusf out err rc last journal target
  state=$(new_state break-trace)
  GATE_LOCK=$(new_lock break-trace)
  wt="$TMP_ROOT/break-trace-wt"
  err="$TMP_ROOT/break-trace.err"
  journal="$GATE_LOCK.journal"
  register_task "$state" task-dead "$wt"
  statusf="$state/task-dead.status"
  printf 'working: gate running\n' > "$statusf"
  # A plain acquire from a shell that is gone: the recorded process is dead.
  FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
    bash -c '"$1" acquire "$2" >/dev/null 2>&1' _ "$GATE" task-dead
  age_path "$GATE_LOCK" 3600

  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>"$err"); rc=$?
  expect_code 0 "$rc" "the abandoned hold must be broken"
  last=$(tail -n 1 "$statusf")
  case "$last" in
    "blocked [key=gate-hold-broken]: the test-gate hold was broken by task-b after 360"[0-9]"s ("*) : ;;
    *) fail "the displaced holder's status must end with the break trace, got: $last" ;;
  esac
  assert_contains "$last" "stop it or re-take the queue" "the trace must say what the holder should do"
  assert_contains "$(cat "$journal")" "broken id=task-dead breaker=task-b holder_process=gone check_work=none heartbeat=none" \
    "the journal must record the break with the evidence seen"
  gate "$state" release task-b >/dev/null 2>&1

  # A status path that is a symlink is not written through; the journal still is.
  target="$TMP_ROOT/break-trace-target"
  printf 'untouched\n' > "$target"
  ln -s "$target" "$TMP_ROOT/break-trace-link"
  mkdir -p "$GATE_LOCK"
  printf '%s\n' task-dead > "$GATE_LOCK/owner"
  printf '%s\n' "$wt" > "$GATE_LOCK/owner_worktree"
  printf '%s\n' "$TMP_ROOT/break-trace-link" > "$GATE_LOCK/owner_status"
  printf '%s\n' token-of-the-stale-hold > "$GATE_LOCK/token"
  age_path "$GATE_LOCK" 3600
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>"$err"); rc=$?
  expect_code 0 "$rc" "the second abandoned hold must be broken too"
  [ "$(cat "$target")" = untouched ] || fail "the break trace must never be written through a symlink"
  assert_contains "$(cat "$err")" "not writing the broken-hold line: $TMP_ROOT/break-trace-link is a symbolic link" \
    "the skipped trace must say why on stderr"
  [ "$(grep -c 'broken id=task-dead' "$journal" | tr -d ' ')" = 2 ] \
    || fail "the journal must record the second break as well"
  gate "$state" release task-b >/dev/null 2>&1

  # A recorded status file that is gone by the time of the break is said so,
  # not skipped in silence: that break reaches nobody, which is the incident
  # the trace exists for.
  mkdir -p "$GATE_LOCK"
  printf '%s\n' task-dead > "$GATE_LOCK/owner"
  printf '%s\n' "$wt" > "$GATE_LOCK/owner_worktree"
  printf '%s\n' "$TMP_ROOT/break-trace-removed.status" > "$GATE_LOCK/owner_status"
  printf '%s\n' token-of-the-stale-hold > "$GATE_LOCK/token"
  age_path "$GATE_LOCK" 3600
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>"$err"); rc=$?
  expect_code 0 "$rc" "the third abandoned hold must be broken too"
  assert_contains "$(cat "$err")" "not writing the broken-hold line: $TMP_ROOT/break-trace-removed.status is absent" \
    "a break whose recorded status file is gone must say so on stderr"
  [ ! -e "$TMP_ROOT/break-trace-removed.status" ] || fail "the break must not create a status file that was gone"
  [ "$(grep -c 'broken id=task-dead' "$journal" | tr -d ' ')" = 3 ] \
    || fail "the journal must record the third break as well"
  pass "fm-gate.sh: breaking a hold leaves a trace where firstmate reads"
}

# A TERM forwarded to the child alone reached only the `bash -c` the mandated
# one-liner wraps the gate command in; that shell died at once, the suite it
# had started ran on as an orphan, and the wrapper released the hold over it -
# the second full run, arriving through a harness tool-call timeout. The child
# now leads its own process group and the signal goes to the whole group; when
# check work still names the hold's worktree after a signalled exit, the hold
# is parked rather than released - but only after a grace: runners handle
# TERM gracefully and are still winding down when the shell that started them
# is already gone, and a probe taken that instant parked the machine-wide
# queue for an hour on every routine timeout.
test_a_signal_to_run_reaches_the_whole_group_and_parks_over_an_orphan() {
  local state wt statusf outf errf wrapper rc tries journal marker orphan graceful
  state=$(new_state run-signal)
  GATE_LOCK=$(new_lock run-signal)
  wt="$TMP_ROOT/run-signal-wt"
  statusf="$TMP_ROOT/run-signal.status"
  outf="$TMP_ROOT/run-signal.out"; errf="$TMP_ROOT/run-signal.err"
  journal="$GATE_LOCK.journal"
  register_task "$state" task-a "$wt"
  : > "$statusf"

  # The command is a shell that starts a grandchild and stays its parent, as
  # the mandated `bash -c 'cd ... && make test'` does; the grandchild's argv
  # carries the marker from the environment, and only the grandchild's.
  cat > "$TMP_ROOT/run-signal-parent.sh" <<'SH'
#!/usr/bin/env bash
bash -c 'sleep 60; :' "$RUN_SIGNAL_MARKER"
:
SH
  cat > "$TMP_ROOT/run-signal-orphan-parent.sh" <<'SH'
#!/usr/bin/env bash
bash -c 'trap "" TERM; sleep 60; :' "$RUN_SIGNAL_MARKER"
:
SH
  cat > "$TMP_ROOT/run-signal-graceful-parent.sh" <<'SH'
#!/usr/bin/env bash
bash -c 'trap "sleep 1.5; exit 0" TERM; sleep 60; :' "$RUN_SIGNAL_MARKER"
:
SH
  # A grandchild that carries no worktree path: it must die with the group.
  marker="run-signal-grandchild-$$"
  RUN_SIGNAL_MARKER="$marker" FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
    "$GATE" run task-a --status "$statusf" -- \
    bash "$TMP_ROOT/run-signal-parent.sh" >"$outf" 2>"$errf" &
  wrapper=$!
  FIXTURE_PIDS+=("$wrapper")
  tries=0
  while [ "$tries" -lt 200 ] && ! pgrep -f "$marker" >/dev/null 2>&1; do
    tries=$((tries + 1)); sleep 0.05
  done
  pgrep -f "$marker" >/dev/null 2>&1 || fail "the grandchild never started"
  kill -TERM "$wrapper"
  wait "$wrapper"; rc=$?
  expect_code 143 "$rc" "a signalled run must exit with the command's own signal status"
  tries=0
  while [ "$tries" -lt 40 ] && pgrep -f "$marker" >/dev/null 2>&1; do
    tries=$((tries + 1)); sleep 0.05
  done
  if pgrep -f "$marker" >/dev/null 2>&1; then
    pkill -KILL -f "$marker" 2>/dev/null
    fail "the forwarded signal must reach the whole process group, not only the direct child"
  fi
  assert_contains "$(gate "$state" status 2>&1)" "free" \
    "a signalled run whose tree is gone must release the hold"
  assert_contains "$(cat "$journal")" "released id=task-a reason=signal" \
    "the journal must record the release after the signal"

  # A grandchild that carries the recorded worktree and takes its time to shut
  # down on TERM, as vitest, playwright and jest do: it is dying, not
  # orphaned, and the hold must be released once it has drained.
  graceful="$wt/pytest-suite-graceful"
  RUN_SIGNAL_MARKER="$graceful" FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
    "$GATE" run task-a --status "$statusf" -- \
    bash "$TMP_ROOT/run-signal-graceful-parent.sh" >"$outf" 2>"$errf" &
  wrapper=$!
  FIXTURE_PIDS+=("$wrapper")
  tries=0
  while [ "$tries" -lt 200 ] && ! pgrep -f "$graceful" >/dev/null 2>&1; do
    tries=$((tries + 1)); sleep 0.05
  done
  pgrep -f "$graceful" >/dev/null 2>&1 || fail "the graceful grandchild never started"
  kill -TERM "$wrapper"
  wait "$wrapper"; rc=$?
  expect_code 143 "$rc" "the signalled run must carry the signal status out"
  pgrep -f "$graceful" >/dev/null 2>&1 && fail "the graceful grandchild must have finished shutting down before the wrapper decided"
  assert_contains "$(gate "$state" status 2>&1)" "free" \
    "a run whose tree drained within the grace must be released, not parked"
  assert_not_contains "$(cat "$journal")" "parked id=task-a" \
    "a run that was dying, not orphaned, must never be parked"
  [ "$(grep -c 'released id=task-a reason=signal' "$journal" | tr -d ' ')" = 2 ] \
    || fail "the journal must record the second release after the signal: $(cat "$journal")"

  # A grandchild that ignores TERM and carries the recorded worktree: an orphan
  # the wrapper must not release the queue over, even after the grace. A
  # second TERM lands inside that grace, as a re-signalling harness or a
  # second Ctrl-C would send it: the wrapper must still reach its verdict
  # rather than die with the hold neither parked nor released.
  orphan="$wt/pytest-suite"
  RUN_SIGNAL_MARKER="$orphan" FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
    "$GATE" run task-a --status "$statusf" -- \
    bash "$TMP_ROOT/run-signal-orphan-parent.sh" >"$outf" 2>"$errf" &
  wrapper=$!
  FIXTURE_PIDS+=("$wrapper")
  tries=0
  while [ "$tries" -lt 200 ] && ! pgrep -f "$orphan" >/dev/null 2>&1; do
    tries=$((tries + 1)); sleep 0.05
  done
  pgrep -f "$orphan" >/dev/null 2>&1 || fail "the orphan never started"
  kill -TERM "$wrapper"
  sleep 1
  kill -0 "$wrapper" 2>/dev/null || fail "the wrapper must still be deciding inside the grace when the second signal lands"
  kill -TERM "$wrapper"
  wait "$wrapper"; rc=$?
  expect_code 143 "$rc" "the signalled run must still carry the signal status out"
  pgrep -f "$orphan" >/dev/null 2>&1 || fail "the orphan fixture must survive the group signal for this proof"
  assert_contains "$(gate "$state" status 2>&1)" "held by: task-a" \
    "a signalled run with check work still live must keep the hold"
  assert_contains "$(gate "$state" status 2>&1)" "parked: run-orphaned-after-signal" \
    "the kept hold must be parked with the orphan reason"
  assert_contains "$(cat "$errf")" "not releasing" "the wrapper must say it is not releasing"
  assert_contains "$(cat "$errf")" "run-orphaned-after-signal" "stderr must name the park reason"
  assert_contains "$(cat "$errf")" "s (FM_GATE_PARK_SECONDS)" "stderr must name the park deadline by its variable"
  assert_contains "$(cat "$journal")" "parked id=task-a reason=run-orphaned-after-signal" \
    "the journal must record the park"
  [ "$(grep -c 'released id=task-a' "$journal" | tr -d ' ')" = 2 ] \
    || fail "the orphaned run's hold must not be released: $(cat "$journal")"
  pkill -KILL -f "$orphan" 2>/dev/null
  gate "$state" release task-a >/dev/null 2>&1
  pass "fm-gate.sh: a signal to run reaches the whole group and parks over an orphan"
}

# `run` for an id whose earlier run is still alive re-took the hold outright:
# the first wrapper's heartbeat saw the token change and stopped, its command
# kept running unprotected, and the second command started - two full runs of
# one task. The re-take is refused while the earlier holder proves itself
# alive, and allowed once it is provably gone.
test_a_run_does_not_displace_its_own_live_run() {
  local state wt statusf out rc token wrapper tries holder_pid trace journal
  state=$(new_state run-retake)
  GATE_LOCK=$(new_lock run-retake)
  wt="$TMP_ROOT/run-retake-wt"
  statusf="$TMP_ROOT/run-retake.status"
  trace="$TMP_ROOT/run-retake.trace"
  journal="$GATE_LOCK.journal"
  register_task "$state" task-a "$wt"
  : > "$statusf"
  FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_HEARTBEAT_SECONDS=1 \
    "$GATE" run task-a --status "$statusf" -- sleep 60 >/dev/null 2>&1 &
  wrapper=$!
  FIXTURE_PIDS+=("$wrapper")
  tries=0
  while [ "$tries" -lt 300 ]; do
    case "$(gate "$state" status 2>/dev/null)" in *"held by: task-a"*) break ;; esac
    tries=$((tries + 1)); sleep 0.05
  done
  token=$(cat "$GATE_LOCK/token")
  holder_pid=$(cat "$GATE_LOCK/owner_pid")
  [ "$holder_pid" = "$wrapper" ] || fail "the run wrapper must be the recorded holder process"

  out=$(gate "$state" run task-a --status "$statusf" -- touch "$trace" 2>"$TMP_ROOT/run-retake.err"); rc=$?
  expect_code 1 "$rc" "a run beside its own live run must be refused"
  assert_contains "$out" "QUEUE NOT YOURS - your own run $wrapper is still live" \
    "the refusal must name the live run's pid on stdout"
  assert_contains "$(cat "$TMP_ROOT/run-retake.err")" "your own run $wrapper is still live" \
    "the refusal must reach stderr"
  [ "$(cat "$GATE_LOCK/token")" = "$token" ] || fail "a refused re-take must not touch the hold"
  [ ! -e "$trace" ] || fail "a refused re-take must never start its command"
  sleep 1.5
  assert_not_contains "$(cat "$journal")" "run-lost-hold" "the live run must not have lost its hold"
  assert_not_contains "$(cat "$journal")" "retaken" "nothing must have been re-taken"

  # The earlier wrapper killed outright: its recorded process is gone, its
  # heartbeat still fresh. That holder is provably gone, so the re-take is
  # allowed.
  kill -KILL "$wrapper" 2>/dev/null
  wait "$wrapper" 2>/dev/null
  sleep 1.5
  assert_contains "$(gate "$state" status 2>&1)" "holder process gone" \
    "the killed wrapper must read as gone before the re-take"
  out=$(gate "$state" run task-a --status "$statusf" -- touch "$trace" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "a re-take from a holder that is provably gone must be allowed"
  [ -e "$trace" ] || fail "the allowed re-take must run its command"
  assert_contains "$(cat "$journal")" "retaken=1" "the journal must record the re-take"
  assert_contains "$(gate "$state" status 2>&1)" "free" "the re-taken run must release at the end"
  pass "fm-gate.sh: a run does not displace its own live run"
}

# A job in its own process group is never handed the terminal, so a gate
# command that read its terminal would stop on SIGTTIN with a fresh heartbeat
# and read as alive to every waiter forever. The command's stdin is /dev/null
# instead: it reads EOF, never the wrapper's own input.
test_a_run_command_reads_eof_not_the_wrappers_stdin() {
  local state out rc
  state=$(new_state run-stdin)
  GATE_LOCK=$(new_lock run-stdin)

  out=$(printf 'line-from-the-wrappers-stdin\n' | gate "$state" run task-a -- cat 2>/dev/null); rc=$?
  expect_code 0 "$rc" "a command reading EOF must end and carry its status out"
  assert_not_contains "$out" "line-from-the-wrappers-stdin" \
    "the command must not read the wrapper's stdin"
  assert_contains "$out" "queue held by you: task-a" "the run must still have been granted"
  assert_contains "$(gate "$state" status 2>&1)" "free" "the run must release at its end"
  pass "fm-gate.sh: a run's command reads EOF, not the wrapper's stdin"
}

# A signal between the grant and the traps run_command installs killed the
# wrapper with the hold written and nothing behind it, to be judged abandoned
# only after the stale age. The wrapper's exit path releases such a hold: its
# token is this process's own and its command never started.
test_a_signal_before_the_command_starts_releases_the_hold() {
  local state wt statusf trace outf errf fakebin calls wrapper rc tries journal
  state=$(new_state run-early-signal)
  GATE_LOCK=$(new_lock run-early-signal)
  wt="$TMP_ROOT/run-early-signal-wt"
  statusf="$TMP_ROOT/run-early-signal.status"
  trace="$TMP_ROOT/run-early-signal.trace"
  outf="$TMP_ROOT/run-early-signal.out"; errf="$TMP_ROOT/run-early-signal.err"
  journal="$GATE_LOCK.journal"
  register_task "$state" task-a "$wt"
  register_task "$state" task-n "$TMP_ROOT/run-early-signal-wt-n"
  : > "$statusf"

  # The resource probe runs after the hold is written and before the command
  # starts; a slow fake pgrep holds the wrapper inside that window.
  fakebin=$(fm_fakebin "$TMP_ROOT/run-early-signal")
  calls="$TMP_ROOT/run-early-signal.pgrep-calls"
  : > "$calls"
  cat > "$fakebin/pgrep" <<SH
#!/usr/bin/env bash
echo "pgrep \$*" >> "$calls"
sleep 3
exit 1
SH
  chmod +x "$fakebin/pgrep"
  # The test shell has run the real pgrep already and bash 3.2 remembers it;
  # the wrapper below is a fresh process and resolves the fake regardless.
  hash -r
  [ "$(PATH="$fakebin:$PATH" command -v pgrep)" = "$fakebin/pgrep" ] \
    || fail "pgrep must resolve to the fake on the test PATH"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" \
    "$GATE" run task-a --status "$statusf" -- touch "$trace" >"$outf" 2>"$errf" &
  wrapper=$!
  FIXTURE_PIDS+=("$wrapper")
  tries=0
  while [ "$tries" -lt 200 ] && [ ! -s "$calls" ]; do
    tries=$((tries + 1)); sleep 0.05
  done
  [ -s "$calls" ] || fail "the wrapper never reached the resource probe"
  assert_contains "$(gate "$state" status 2>&1)" "held by: task-a" \
    "the hold must already be written while the probe runs"
  kill -TERM "$wrapper"
  wait "$wrapper"; rc=$?
  [ "$rc" -ne 0 ] || fail "a wrapper killed before its command must not exit 0"
  [ ! -e "$trace" ] || fail "the command must never have started"
  assert_contains "$(gate "$state" status 2>&1)" "free" \
    "a hold whose run was killed before its command started must be released"
  assert_contains "$(cat "$journal")" "released id=task-a reason=signal-before-run" \
    "the journal must record the early release by its reason"
  assert_contains "$(cat "$errf")" "before its command started" "the wrapper must say why it released"
  pass "fm-gate.sh: a signal before the command starts releases the hold"
}

# `status --journal` read whatever sat at the journal's path, following a
# symlink another user could have planted there. It reads only this user's
# regular file and names anything else, as the writer already did.
test_status_journal_reads_only_this_users_regular_file() {
  local state out rc err target
  state=$(new_state journal-tail)
  GATE_LOCK=$(new_lock journal-tail)
  err="$TMP_ROOT/journal-tail.err"

  gate "$state" acquire task-a >/dev/null 2>&1 || fail "the queue must be free to take"
  gate "$state" release task-a >/dev/null 2>&1
  out=$(gate "$state" status --journal 1 2>"$err"); rc=$?
  expect_code 0 "$rc" "tailing an own journal must succeed"
  assert_contains "$out" "released id=task-a" "the tail must show the last event"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "the tail must honour its line count: $out"

  rm -f "$GATE_LOCK.journal"
  target="$TMP_ROOT/journal-tail-target"
  printf 'secret-line-of-another-user\n' > "$target"
  ln -s "$target" "$GATE_LOCK.journal"
  out=$(gate "$state" status --journal 2>"$err"); rc=$?
  expect_code 1 "$rc" "a symlinked journal must be refused"
  assert_not_contains "$out" "secret-line-of-another-user" "a symlinked journal must never be read through"
  assert_contains "$out" "$GATE_LOCK.journal is a symbolic link" "the refusal must name what it found"
  assert_contains "$(cat "$err")" "is a symbolic link" "the refusal must reach stderr"
  [ -L "$GATE_LOCK.journal" ] || fail "a foreign journal must never be removed"
  pass "fm-gate.sh: status --journal reads only this user's regular file"
}

# Three documents and three numbers for one threshold: the brief said "25
# minutes", messages said "7200s ceiling", the script read variables. One
# owner now: `limits` prints the values in force by variable name, and every
# message that names a threshold names it as <value>s (<VARIABLE>).
test_limits_and_messages_name_thresholds_by_variable() {
  local state wt out err rc
  state=$(new_state limits)
  GATE_LOCK=$(new_lock limits)
  err="$TMP_ROOT/limits.err"

  out=$("$GATE" limits 2>&1); rc=$?
  expect_code 0 "$rc" "limits must succeed"
  assert_contains "$out" "FM_GATE_STALE_SECONDS=1500" "limits must print the stale age in force"
  assert_contains "$out" "FM_GATE_MAX_HOLD_SECONDS=7200" "limits must print the ceiling in force"
  assert_contains "$out" "FM_GATE_RESOURCE_WAIT_SECONDS=3600" "limits must print the resource wait in force"
  assert_contains "$out" "FM_GATE_POLL_SECONDS=30" "limits must print the poll in force"
  assert_contains "$out" "FM_GATE_HEARTBEAT_SECONDS=60" "limits must print the heartbeat interval in force"
  assert_contains "$out" "FM_GATE_PARK_SECONDS=3600" "limits must print the park deadline in force"
  out=$(FM_GATE_STALE_SECONDS=7 "$GATE" limits 2>&1)
  assert_contains "$out" "FM_GATE_STALE_SECONDS=7" "limits must print the configured value, not the default"

  wt="$TMP_ROOT/limits-wt"
  write_dead_hold task-dead "$wt" 3600
  out=$(gate "$state" acquire task-b 2>"$err"); rc=$?
  expect_code 0 "$rc" "the abandoned hold must be broken under the default stale age"
  assert_contains "$(cat "$err")" "1500s (FM_GATE_STALE_SECONDS)" \
    "an abandonment break must name the stale age by its variable"
  pass "fm-gate.sh: limits and messages name thresholds by variable"
}

test_help_renders_the_header
test_unknown_command_is_refused
test_one_holder_at_a_time
test_a_real_race_produces_exactly_one_winner
test_breaking_an_abandoned_hold_grants_it_to_exactly_one
test_two_homes_contend_for_one_hold
test_release_is_owner_only
test_abandoned_hold_is_broken_but_a_live_run_is_not
test_a_live_run_in_another_home_keeps_its_hold
test_a_holder_whose_runner_is_invisible_to_argv_keeps_its_hold
test_a_hold_taken_without_its_home_records_the_working_directory
test_an_acquire_from_the_home_directory_records_no_worktree
test_a_hold_taken_during_the_decision_is_not_broken
test_an_orphaned_runner_keeps_the_holders_hold
test_a_hold_without_a_heartbeat_past_the_ceiling_is_broken_and_names_its_evidence
test_a_ceiling_below_the_stale_age_still_breaks_the_hold
test_a_zero_ceiling_falls_back_rather_than_breaking_a_live_hold
test_a_trailing_slash_on_the_hold_path_still_breaks_an_abandoned_hold
test_dot_terminated_hold_paths_still_break_an_abandoned_hold
test_an_unresolvable_hold_path_refuses_by_name
test_a_relative_hold_path_is_refused_rather_than_held_per_worktree
test_a_hold_path_resolved_through_dotdot_works_under_the_platform_bash
test_a_foreign_break_marker_is_refused_visibly
test_an_active_break_marker_survives_a_low_stale_age
test_a_live_run_outside_the_hold_refuses_a_free_queue
test_a_resource_refusal_is_given_up_rather_than_waited_out_forever
test_a_cleared_run_wait_says_it_waited_and_starts_only_after_the_neighbour
test_run_without_wait_never_starts_under_a_resource_refusal
test_run_wait_that_gives_up_never_starts
test_a_grant_without_a_resource_wait_is_unchanged
test_help_explains_the_resource_wait_lines
test_waiting_workers_do_not_block_each_other
test_a_waiting_worker_holding_the_gate_command_does_not_block_issuance
test_a_dev_server_does_not_block_issuance
test_an_unusable_poll_does_not_spin
test_a_foreign_hold_is_refused_and_never_removed
test_an_unusable_hold_parent_is_refused_rather_than_waited_out
test_secondmate_homes_are_not_counted_as_runs
test_a_live_run_older_than_the_ceiling_keeps_its_hold
test_a_live_heartbeat_keeps_waiters_off_the_break_marker
test_the_oldest_waiter_takes_the_hold_whatever_its_poll_cadence
test_a_waiter_ahead_refuses_a_bare_acquire_and_a_dead_ticket_does_not
test_status_lists_waiters_with_their_ages
test_a_marker_refusal_names_what_it_found
test_an_unreadable_marker_owner_is_retried_not_called_foreign
test_a_foreign_queue_directory_or_journal_is_refused_and_never_removed
test_a_parked_hold_is_neither_abandoned_nor_over_the_ceiling_until_it_expires
test_run_writes_the_running_line_releases_on_failure_and_carries_the_exit_status
test_breaking_a_hold_leaves_a_trace_where_firstmate_reads
test_limits_and_messages_name_thresholds_by_variable
test_a_signal_to_run_reaches_the_whole_group_and_parks_over_an_orphan
test_a_run_does_not_displace_its_own_live_run
test_a_run_command_reads_eof_not_the_wrappers_stdin
test_a_signal_before_the_command_starts_releases_the_hold
test_status_journal_reads_only_this_users_regular_file
