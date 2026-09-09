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
    fi
  done
  [ "$wins" -eq 1 ] || fail "a race of $n contenders produced $wins winners, not exactly one"
  [ "$refusals" -eq $((n - 1)) ] || fail "a race of $n contenders produced $refusals refusals, not $((n - 1))"
  out=$(gate "$state" status 2>&1)
  assert_contains "$out" "held by: task-" "the single winner must be the recorded holder"
  pass "fm-gate.sh: a real race of $n contenders produces exactly one winner"
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
  gate "$state" acquire task-a >/dev/null 2>&1

  # Owner has no check work: past the stale age, the hold is abandoned.
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>/dev/null); rc=$?
  expect_code 0 "$rc" "an abandoned hold must be broken for the next task"
  assert_contains "$out" "queue held by you: task-b" "breaking an abandoned hold must hand the queue over"

  # Same age, but the owner's run is genuinely alive: the hold stands.
  gate "$state" release task-b >/dev/null 2>&1
  gate "$state" acquire task-a >/dev/null 2>&1
  start_fixture_process "$wt/pytest-suite" >/dev/null
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
  gate_home "$home_a" acquire task-a >/dev/null 2>&1
  start_fixture_process "$wt/pytest-suite" >/dev/null

  # home-b knows nothing about task-a; only the hold itself records its worktree.
  out=$(FM_HOME="$home_b" FM_GATE_LOCK_DIR="$GATE_LOCK" FM_GATE_STALE_SECONDS=0 \
    "$GATE" acquire task-b 2>/dev/null); rc=$?
  expect_code 1 "$rc" "a hold whose owner runs in another home must not be broken by age"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-a" "the cross-home holder must keep the queue"
  out=$(gate_home "$home_b" status 2>&1)
  assert_contains "$out" "held by: task-a" "the hold must survive the other home's stale probe"
  pass "fm-gate.sh: a live run in another home keeps its hold across the stale rule"
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
test_two_homes_contend_for_one_hold
test_release_is_owner_only
test_abandoned_hold_is_broken_but_a_live_run_is_not
test_a_live_run_in_another_home_keeps_its_hold
test_a_live_run_outside_the_hold_refuses_a_free_queue
test_waiting_workers_do_not_block_each_other
test_a_dev_server_does_not_block_issuance
test_a_foreign_hold_is_refused_and_never_removed
test_secondmate_homes_are_not_counted_as_runs
