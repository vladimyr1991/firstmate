#!/usr/bin/env bash
# tests/fm-watch-arm.test.sh - the arm layer's cycle-close contract when the arm
# did not own the cycle.
#
# The watcher prints its one reason line to its OWN stdout, so only the arm that
# forked it ever reads that line. An arm that ATTACHED to an existing cycle holds
# no handle on it and can observe only a released lock, which is why a completely
# successful cycle used to be reported as
# "watcher: FAILED - cycle ended without an actionable reason" on every harness
# whose protocol reads that line. These are real-process tests: a real
# bin/fm-watch.sh holds the singleton, a real bin/fm-watch-arm.sh attaches to it,
# and a real status change drives a real wake through the watcher-bound delivery
# record and durable queue.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-arm-tests)

# Both starters background a real process the test later waits on, so they set a
# global instead of echoing: a command substitution would make the pid a child of
# a subshell this shell can no longer wait for.
SEED_PID=
ARM_PID=

# Start the real watcher as the singleton holder.
start_seed_watcher() {  # <state> <fakebin> <watch-out>
  local state=$1 fakebin=$2 out=$3 i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  SEED_PID=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
      && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
    || fail "seed watcher did not take the lock"
}

# Attach a real arm to the live cycle.
start_attached_arm() {  # <state> <fakebin> <arm-out> <confirm-timeout>
  local state=$1 fakebin=$2 armout=$3 confirm=$4 i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_CONFIRM_TIMEOUT="$confirm" "$WATCH_ARM" > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$SEED_PID" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$SEED_PID" "$armout" \
    || fail "arm did not attach to the live watcher: $(cat "$armout")"
}

test_attached_arm_reports_the_delivered_wake() {
  local dir state fakebin out armout status
  dir=$(make_case attached-delivered-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A real captain-relevant status change: the watcher records it in the durable
  # queue, prints its one reason line to its own stdout, and exits.
  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  grep -q '^signal:' "$out" || fail "seed watcher did not surface the signal wake: $(cat "$out")"

  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -q 'demo.status' "$state/.wake-queue" \
    || fail "the wake was not durably recorded, so this case proves nothing"
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported a delivered wake as a failed cycle: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the durably recorded wake reason: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose cycle delivered a wake must close successfully"
  grep -q 'reason=attached-delivered-wake' "$state/.watch-cycle-exits.log" \
    || fail "the delivered-wake close was not classified in the lifecycle ledger"
  pass "watch-arm: an attached arm reports the wake its cycle delivered instead of a false failure"
}

test_attached_arm_reports_the_delivered_wake_after_drain() {
  local dir state fakebin out armout status
  dir=$(make_case attached-drained-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  # A wider confirmation budget keeps the arm in its successor wait while the
  # handling turn drains, which is the ordering this case exists to cover.
  start_attached_arm "$state" "$fakebin" "$armout" 5

  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  # The handling turn consumes the records before the attached arm closes: the
  # queue is empty again, while the watcher's identity-bound terminal record
  # still proves which cycle delivered the reason.
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain failed"
  [ ! -s "$state/.wake-queue" ] || fail "drain left records behind"

  wait_for_exit "$ARM_PID" 200
  status=$?
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported an already-handled wake as a failed cycle: $(cat "$armout")"
  grep -q '^signal:' "$armout" \
    || fail "attached arm did not report the delivered reason after the queue drain: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose wake was already drained must close successfully"
  pass "watch-arm: a delivered wake consumed by the handling turn still closes the attached arm cleanly"
}

test_attached_arm_still_fails_on_a_wake_it_did_not_deliver() {
  local dir state fakebin out armout status
  dir=$(make_case attached-no-delivery)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A process-event producer advances the same home-wide queue while the
  # observed watcher remains uninvolved, so only watcher-bound evidence can
  # distinguish this from a delivered watcher cycle.
  append_wake "$state" check process-event "check: process-event result captured: fixture"
  kill "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" \
    || fail "a cycle that delivered nothing must still fail loudly: $(cat "$armout")"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "arm did not exit nonzero for a cycle that delivered nothing (status $status)"
  pass "watch-arm: a cycle that delivered no wake of its own still fails loudly"
}

# --- confirmation budget: progress-based extension under a hard ceiling ------
#
# These cases need a watcher whose pre-lock startup lasts an exact number of
# seconds, which the real bin/fm-watch.sh cannot be asked for. The arm resolves
# its watcher as a sibling of its own path, so each case runs the SHIPPED arm
# through a directory holding a link to it, a link to the shared wake library,
# and a stub standing in for the watcher. Nothing about the arm is stubbed.

# Build the sibling directory and echo the arm path to invoke.
make_stub_arm_dir() {  # <case-dir>
  local dir=$1
  local bin="$dir/armbin"
  mkdir -p "$bin"
  ln -sf "$ROOT/bin/fm-watch-arm.sh" "$bin/fm-watch-arm.sh"
  ln -sf "$ROOT/bin/fm-wake-lib.sh" "$bin/fm-wake-lib.sh"
  cat > "$bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
# Test stub standing in for bin/fm-watch.sh. It publishes exactly what
# FM_STUB_MODE asks for, so a case can hold the child pre-lock, or beating but
# unhealthy, for a known number of seconds.
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SELF_DIR/fm-wake-lib.sh"
LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"

publish_lock() {
  mkdir -p "$LOCK"
  printf '%s\n' "$FM_HOME" > "$LOCK/fm-home"
  printf '%s\n' "$SELF_DIR/fm-watch.sh" > "$LOCK/watcher-path"
  fm_pid_identity "$$" > "$LOCK/pid-identity"
  printf '%s\n' "$$" > "$LOCK/pid"
}

hold() {
  while :; do sleep 0.2; done
}

case "${FM_STUB_MODE:?}" in
  early-exit)
    printf 'watcher: FAILED - stub refused to start\n'
    exit 3
    ;;
  never-advance)
    trap 'exit 0' TERM INT
    hold
    ;;
  lock-then-stall)
    trap 'exit 0' TERM INT
    sleep 1
    publish_lock
    hold
    ;;
  beat-then-healthy)
    # Beacon movement is the arm's second progress signal. Without the lock the
    # watcher is still UNHEALTHY, so this stub is visibly progressing and not
    # yet confirmable until FM_STUB_HEALTHY_AT seconds have passed.
    trap 'exit 0' TERM INT
    i=0
    while [ "$i" -lt "${FM_STUB_HEALTHY_AT:?}" ]; do
      touch "$BEAT"
      sleep 1
      i=$((i + 1))
    done
    publish_lock
    touch "$BEAT"
    hold
    ;;
  healthy-at)
    # Realistic ordering: nothing at all is published until the pre-lock work
    # finishes, then the lock and the beacon appear together.
    trap 'exit 0' TERM INT
    sleep "${FM_STUB_HEALTHY_AT:?}"
    publish_lock
    touch "$BEAT"
    hold
    ;;
esac
SH
  chmod +x "$bin/fm-watch.sh"
  printf '%s\n' "$bin/fm-watch-arm.sh"
}

# Run the shipped arm against the stub and record its pid in STUB_ARM_PID. Every
# case states its own budget and ceiling, and the ambient FM_ARM_CONFIRM_* pair is
# cleared first: an operator override in the environment would otherwise silently
# decide the outcome of a case about exactly those values. The
# arm is backgrounded so a confirmed cycle (which blocks on the child) can be
# asserted and then signalled, exactly as a real harness retires it. A command
# substitution would make the arm a child of a subshell this shell cannot wait
# for, the same reason the starters above set a global.
STUB_ARM_PID=
run_stub_arm() {  # <arm> <state> <armout> [VAR=VAL ...]
  local arm=$1 state=$2 out=$3
  shift 3
  env -u FM_ARM_CONFIRM_TIMEOUT -u FM_ARM_CONFIRM_MAX \
    FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 "$@" "$arm" > "$out" 2>&1 &
  STUB_ARM_PID=$!
}

test_confirmation_extends_for_a_child_that_is_still_advancing() {
  local dir state arm armout started elapsed status
  dir=$(make_case confirm-extends)
  state="$dir/state"
  arm=$(make_stub_arm_dir "$dir")
  armout="$dir/arm.out"
  started=$(date +%s)
  run_stub_arm "$arm" "$state" "$armout" \
    FM_STUB_MODE=beat-then-healthy FM_STUB_HEALTHY_AT=12 \
    FM_ARM_CONFIRM_TIMEOUT=2 FM_ARM_CONFIRM_MAX=30
  local i=0
  while [ "$i" -lt 250 ]; do
    grep -q '^watcher: ' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  elapsed=$(( $(date +%s) - started ))
  grep -qF "watcher: started pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || echo none) (beacon fresh)" "$armout" \
    || fail "a child that kept advancing was not confirmed: $(cat "$armout")"
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "the arm reported a failure for a child it went on to confirm: $(cat "$armout")"
  [ "$elapsed" -ge 10 ] \
    || fail "the fixture confirmed after ${elapsed}s, which does not exercise a start past the old 10s budget"
  ! grep -q 'reason=confirmation-timeout' "$state/.watch-cycle-exits.log" 2>/dev/null \
    || fail "a confirmed cycle recorded a confirmation timeout"
  kill -TERM "$STUB_ARM_PID" 2>/dev/null || true
  wait_for_exit "$STUB_ARM_PID" 80 >/dev/null

  # Counterfactual: the same fixture with extension disabled (ceiling clamped to
  # the base budget) is exactly the old fixed-budget arm, and it kills the child.
  dir=$(make_case confirm-extends-disabled)
  state="$dir/state"
  arm=$(make_stub_arm_dir "$dir")
  armout="$dir/arm.out"
  run_stub_arm "$arm" "$state" "$armout" \
    FM_STUB_MODE=beat-then-healthy FM_STUB_HEALTHY_AT=12 \
    FM_ARM_CONFIRM_TIMEOUT=2 FM_ARM_CONFIRM_MAX=1
  wait_for_exit "$STUB_ARM_PID" 150
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "extension disabled must reproduce the fixed-budget failure (status $status)"
  grep -qF 'watcher: FAILED - no live watcher with a fresh beacon' "$armout" \
    || fail "extension disabled did not emit the unchanged failure line: $(cat "$armout")"
  pass "arm extends confirmation for an advancing child and still fails when extension is disabled"
}


test_confirmation_never_extends_for_a_child_that_shows_no_progress() {
  local dir state arm armout started elapsed status
  dir=$(make_case confirm-no-progress)
  state="$dir/state"
  arm=$(make_stub_arm_dir "$dir")
  armout="$dir/arm.out"
  started=$(date +%s)
  run_stub_arm "$arm" "$state" "$armout" \
    FM_STUB_MODE=never-advance \
    FM_ARM_CONFIRM_TIMEOUT=2 FM_ARM_CONFIRM_MAX=30
  wait_for_exit "$STUB_ARM_PID" 200
  status=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "a child that published nothing must still fail loudly (status $status)"
  grep -qF 'watcher: FAILED - no live watcher with a fresh beacon' "$armout" \
    || fail "no-progress failure changed the arm's failure line: $(cat "$armout")"
  [ "$elapsed" -le 6 ] \
    || fail "a child with no progress was granted an extension: failed only after ${elapsed}s"
  grep -q 'reason=confirmation-timeout' "$state/.watch-cycle-exits.log" \
    || fail "a child that never progressed was not recorded as a confirmation timeout"
  ! grep -q 'reason=confirmation-ceiling' "$state/.watch-cycle-exits.log" \
    || fail "a child that never progressed was misrecorded as reaching the ceiling"
  pass "arm never extends confirmation for a child that published no progress"
}

test_one_unchanging_progress_fact_grants_at_most_one_extension() {
  local dir state arm armout started elapsed status
  dir=$(make_case confirm-single-fact)
  state="$dir/state"
  arm=$(make_stub_arm_dir "$dir")
  armout="$dir/arm.out"
  started=$(date +%s)
  run_stub_arm "$arm" "$state" "$armout" \
    FM_STUB_MODE=lock-then-stall \
    FM_ARM_CONFIRM_TIMEOUT=2 FM_ARM_CONFIRM_MAX=8
  wait_for_exit "$STUB_ARM_PID" 250
  status=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "a child that stalled after one progress fact must be terminated (status $status)"
  [ "$elapsed" -le 12 ] \
    || fail "a single unchanging progress fact kept extending: terminated only after ${elapsed}s"
  grep -qF 'watcher: FAILED - no live watcher with a fresh beacon' "$armout" \
    || fail "the stalled-child failure line changed: $(cat "$armout")"
  grep -q 'reason=confirmation-ceiling' "$state/.watch-cycle-exits.log" \
    || fail "a child that progressed then stalled was not distinguished from one that never started"
  pass "one unchanging progress fact grants at most one extension and records the ceiling reason"
}

test_the_ceiling_terminates_a_child_that_keeps_progressing() {
  local dir state arm armout started elapsed status
  # The child beats forever and so publishes a NEW progress fact at every
  # deadline. Only the ceiling can end this, which is the bound that keeps an
  # extension policy from becoming an unbounded wait.
  dir=$(make_case confirm-ceiling)
  state="$dir/state"
  arm=$(make_stub_arm_dir "$dir")
  armout="$dir/arm.out"
  started=$(date +%s)
  run_stub_arm "$arm" "$state" "$armout" \
    FM_STUB_MODE=beat-then-healthy FM_STUB_HEALTHY_AT=9999 \
    FM_ARM_CONFIRM_TIMEOUT=2 FM_ARM_CONFIRM_MAX=6
  wait_for_exit "$STUB_ARM_PID" 250
  status=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "the ceiling must terminate a forever-progressing child (status $status)"
  [ "$elapsed" -ge 5 ] \
    || fail "the child was terminated at ${elapsed}s, before any extension was granted"
  [ "$elapsed" -le 14 ] \
    || fail "the ceiling did not bound confirmation: terminated only after ${elapsed}s"
  grep -qF 'watcher: FAILED - no live watcher with a fresh beacon' "$armout" \
    || fail "the ceiling changed the arm's failure line: $(cat "$armout")"
  grep -q 'reason=confirmation-ceiling' "$state/.watch-cycle-exits.log" \
    || fail "the ceiling close was not classified in the lifecycle ledger"
  pass "the confirmation ceiling always terminates and records a distinguishable reason"
}


test_a_non_numeric_ceiling_falls_back_to_the_default() {
  local dir state arm armout started elapsed status
  # A junk ceiling must behave like the default (three base budgets), not like a
  # disabled or absent bound.
  dir=$(make_case confirm-ceiling-junk)
  state="$dir/state"
  arm=$(make_stub_arm_dir "$dir")
  armout="$dir/arm.out"
  started=$(date +%s)
  run_stub_arm "$arm" "$state" "$armout" \
    FM_STUB_MODE=beat-then-healthy FM_STUB_HEALTHY_AT=9999 \
    FM_ARM_CONFIRM_TIMEOUT=2 FM_ARM_CONFIRM_MAX=not-a-number
  wait_for_exit "$STUB_ARM_PID" 250
  status=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "a junk ceiling must still terminate the child (status $status)"
  [ "$elapsed" -ge 5 ] \
    || fail "a junk ceiling behaved as a disabled ceiling instead of the default (${elapsed}s)"
  [ "$elapsed" -le 15 ] \
    || fail "a junk ceiling did not fall back to three base budgets (${elapsed}s)"
  grep -q 'reason=confirmation-ceiling' "$state/.watch-cycle-exits.log" \
    || fail "a junk ceiling did not behave as a ceiling"
  pass "a non-numeric confirmation ceiling falls back to the default bound"
}

test_attached_arm_reports_the_delivered_wake
test_attached_arm_reports_the_delivered_wake_after_drain
test_attached_arm_still_fails_on_a_wake_it_did_not_deliver
test_confirmation_extends_for_a_child_that_is_still_advancing
test_confirmation_never_extends_for_a_child_that_shows_no_progress
test_one_unchanging_progress_fact_grants_at_most_one_extension
test_the_ceiling_terminates_a_child_that_keeps_progressing
test_a_non_numeric_ceiling_falls_back_to_the_default
