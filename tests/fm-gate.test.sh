#!/usr/bin/env bash
# Behavior tests for bin/fm-gate.sh, the self-service full-test-gate queue.
#
# Two guarantees carry the fleet and are asserted directly here, because each one
# already failed once in production:
#   - Handing the queue out looks at the RESOURCE, not only at the permit. A
#     worker who released the hold and then ran the browser half on a
#     neighbouring lane broke no rule and still put a second full run on the
#     machine (2026-09-08).
#   - The live-run probe counts CHECK WORK and never "any process in the
#     worktree". A worker WAITING for the queue keeps wait shells alive, so
#     counting any process made waiters look busy to each other; that hardening
#     shipped untested and would have deadlocked the whole fleet after the first
#     release (2026-09-09).
# The fixtures below drive both directions through the executable: a process
# whose command line carries a worktree path plus real check work must block, and
# one carrying only the worktree path must not.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-gate)
FIXTURE_PIDS=()

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
  FM_STATE_OVERRIDE="$state" FM_GATE_POLL_SECONDS=1 "$GATE" "$@"
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
  pass "fm-gate.sh: --help renders its header"
}

test_unknown_command_is_refused() {
  local state out rc
  state=$(new_state usage)
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

test_release_is_owner_only() {
  local state out rc
  state=$(new_state release)
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
  wt="$TMP_ROOT/abandoned-wt"
  register_task "$state" task-a "$wt"
  gate "$state" acquire task-a >/dev/null 2>&1

  # Owner has no check work: past the stale age, the hold is abandoned.
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_STALE_SECONDS=0 "$GATE" acquire task-b 2>/dev/null); rc=$?
  expect_code 0 "$rc" "an abandoned hold must be broken for the next task"
  assert_contains "$out" "queue held by you: task-b" "breaking an abandoned hold must hand the queue over"

  # Same age, but the owner's run is genuinely alive: the hold stands.
  gate "$state" release task-b >/dev/null 2>&1
  gate "$state" acquire task-a >/dev/null 2>&1
  start_fixture_process "$wt/pytest-suite" >/dev/null
  out=$(FM_STATE_OVERRIDE="$state" FM_GATE_STALE_SECONDS=0 "$GATE" acquire task-b 2>/dev/null); rc=$?
  expect_code 1 "$rc" "a hold whose owner is still running must not be broken by age alone"
  assert_contains "$out" "QUEUE NOT YOURS - held by: task-a" "the live owner must keep the queue"
  pass "fm-gate.sh: an abandoned hold is broken, a live owner's hold is not"
}

test_a_live_run_outside_the_hold_refuses_a_free_queue() {
  local state wt out rc
  state=$(new_state resource)
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

test_secondmate_homes_are_not_counted_as_runs() {
  local state home out rc
  state=$(new_state secondmate)
  home="$TMP_ROOT/secondmate-home"
  mkdir -p "$home"
  fm_write_secondmate_meta "$state/mate-1.meta" "$home"
  register_task "$state" task-b "$TMP_ROOT/secondmate-task-wt"
  # A secondmate home is a firstmate, not a task worktree; its own crews are
  # accounted through their own metadata.
  start_fixture_process "$home/pytest-suite" >/dev/null

  out=$(gate "$state" acquire task-b 2>&1); rc=$?
  expect_code 0 "$rc" "a secondmate home must not hold the fleet's gate queue shut"
  assert_contains "$out" "queue held by you: task-b" "the queue must be granted beside a secondmate home"
  pass "fm-gate.sh: secondmate homes are excluded from the live-run probe"
}

test_help_renders_the_header
test_unknown_command_is_refused
test_one_holder_at_a_time
test_release_is_owner_only
test_abandoned_hold_is_broken_but_a_live_run_is_not
test_a_live_run_outside_the_hold_refuses_a_free_queue
test_waiting_workers_do_not_block_each_other
test_secondmate_homes_are_not_counted_as_runs
