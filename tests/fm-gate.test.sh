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
  printf '%s\n' "$dir"
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
age_path() {
  local path=$1 seconds=$2 stamp
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
  n=12
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
  wt="$TMP_ROOT/no-meta-wt"
  mkdir -p "$wt"
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

# The mirror image, and the direction with no recovery: $PPID can name something
# long-lived (a harness reusing one shell across tool calls), and a machine-wide
# hold that can never be broken wedges every home with no escape but a manual
# delete. Past the ceiling the hold goes however alive it looks, and loudly.
test_a_hold_past_the_ceiling_is_broken_however_alive() {
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
  expect_code 0 "$rc" "a hold past the ceiling must be broken however alive its holder looks"
  assert_contains "$out" "queue held by you: task-b" "the ceiling break must hand the queue over"
  # Never silent: the break names the owner it displaced and the age it reached.
  assert_contains "$(cat "$err")" "breaking an abandoned hold (owner task-a" \
    "a ceiling break must name the owner it displaced"
  assert_contains "$(cat "$err")" "ceiling" "a ceiling break must say the ceiling is why"
  pass "fm-gate.sh: a hold past the ceiling is broken however alive its holder looks"
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

  for poll in not-a-number 0; do
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
test_a_hold_taken_during_the_decision_is_not_broken
test_an_orphaned_runner_keeps_the_holders_hold
test_a_hold_past_the_ceiling_is_broken_however_alive
test_a_ceiling_below_the_stale_age_still_breaks_the_hold
test_a_foreign_break_marker_is_refused_visibly
test_an_active_break_marker_survives_a_low_stale_age
test_a_live_run_outside_the_hold_refuses_a_free_queue
test_waiting_workers_do_not_block_each_other
test_a_waiting_worker_holding_the_gate_command_does_not_block_issuance
test_a_dev_server_does_not_block_issuance
test_an_unusable_poll_does_not_spin
test_a_foreign_hold_is_refused_and_never_removed
test_secondmate_homes_are_not_counted_as_runs
