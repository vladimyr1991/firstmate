#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-freeze.sh and the fleet-wide quota reset poll
# it arms (bin/fm-quota-freeze-lib.sh). Covers registration, refusal of a limit
# quota-axi cannot observe, silence while the window is still exhausted, exactly
# one wake once headroom genuinely returns, survival of a firstmate restart,
# re-surfacing of an obligation that was never discharged, removal only after a
# confirmed resume, and dispatch through the real watcher. Everything runs
# through the scripts' actual interfaces; nothing inspects implementation bytes.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-check-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-quota-freeze-lib.sh"

FREEZE="$ROOT/bin/fm-quota-freeze.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-freeze)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
POLL_CHECK="$FM_QUOTA_RESET_POLL_ID.check.sh"
POLL_TRUST="$FM_QUOTA_RESET_POLL_ID.check-trust"

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

state_snapshot() {
  local state=$1 file
  (
    cd "$state" || exit 1
    find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r file; do
      if [ -L "$file" ]; then
        printf 'link %s %s\n' "$file" "$(readlink "$file")"
      else
        printf 'file %s %s ' "$file" "$(file_mode "$file")"
        shasum -a 256 "$file" | awk '{print $1}'
      fi
    done
  )
}

# A quota-axi stand-in that prints whichever reading the current step selects,
# so a "reset" is expressed the way it actually reaches firstmate: a later
# reading of the same provider.
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$fakebin"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_QUOTA_LOG:-/dev/null}"
[ "${FM_TEST_QUOTA_FAIL:-0}" = 0 ] || exit 1
cat "$FM_TEST_QUOTA_READING"
SH
  chmod +x "$fakebin/quota-axi"

  cat > "$dir/exhausted.json" <<'J'
{"schemaVersion":3,"providers":[
 {"provider":"claude","state":{"stale":false},"windows":[
   {"id":"five_hour","percentRemaining":0,"resetsAt":"2026-08-10T17:30:00.801838+00:00"},
   {"id":"seven_day","percentRemaining":55,"resetsAt":"2026-08-14T18:00:00.801858+00:00"}]}]}
J
  cat > "$dir/recovered.json" <<'J'
{"schemaVersion":3,"providers":[
 {"provider":"claude","state":{"stale":false},"windows":[
   {"id":"five_hour","percentRemaining":100,"resetsAt":"2026-08-10T22:30:00.801838+00:00"},
   {"id":"seven_day","percentRemaining":54,"resetsAt":"2026-08-14T18:00:00.801858+00:00"}]}]}
J
  # The window is gone from the reading entirely: quota-axi stopped modelling
  # the axis that froze the work.
  cat > "$dir/window-gone.json" <<'J'
{"schemaVersion":3,"providers":[
 {"provider":"claude","state":{"stale":false},"windows":[
   {"id":"seven_day","percentRemaining":54,"resetsAt":"2026-08-14T18:00:00.801858+00:00"}]}]}
J
  # Reset time has passed but the reading is stale, so it is not evidence.
  cat > "$dir/stale.json" <<'J'
{"schemaVersion":3,"providers":[
 {"provider":"claude","state":{"stale":true},"windows":[
   {"id":"five_hour","percentRemaining":100,"resetsAt":"2026-08-10T22:30:00.801838+00:00"}]}]}
J
  # Every window has headroom: whatever stopped the work is invisible here.
  cat > "$dir/no-exhausted-window.json" <<'J'
{"schemaVersion":3,"providers":[
 {"provider":"grok","state":{"stale":false},"windows":[
   {"id":"credits","percentRemaining":42,"resetsAt":"2026-09-01T00:00:00Z"}]}]}
J
  : > "$dir/quota.log"
  printf '%s\n' "$dir"
}

setup_root() {
  local dir=$1
  ln -s "$ROOT" "$dir/root"
}

run_freeze() {  # <case-dir> <reading> <args...>
  local dir=$1 reading=$2
  shift 2
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_QUOTA_READING="$dir/$reading" FM_TEST_QUOTA_LOG="$dir/quota.log" \
    PATH="$dir/fakebin:$BASE_PATH" "$FREEZE" "$@"
}

run_poll() {  # <case-dir> <reading>
  local dir=$1 reading=$2
  FM_TEST_QUOTA_READING="$dir/$reading" FM_TEST_QUOTA_LOG="$dir/quota.log" \
    PATH="$dir/fakebin:$BASE_PATH" bash "$dir/home/state/$POLL_CHECK"
}

test_add_records_the_obligation_and_arms_the_poll() {
  local dir out record
  dir=$(make_case add)
  setup_root "$dir"

  out=$(run_freeze "$dir" exhausted.json add --subject task-a --provider claude \
    --action nudge --note "waited on a usage-limit dialog") || fail "valid freeze was refused"
  assert_contains "$out" 'frozen: task-a (task) on claude/five_hour' "freeze did not report the frozen axis"
  assert_contains "$out" "armed: state/$POLL_CHECK" "freeze did not report the armed poll"

  record="$dir/home/state/quota-frozen/task-a"
  [ -f "$record" ] || fail "no durable record was written"
  [ "$(file_mode "$record")" = 600 ] || fail "record mode was not 0600"
  [ "$(file_mode "$dir/home/state/$POLL_CHECK")" = 700 ] || fail "poll mode was not 0700"
  [ "$(file_mode "$dir/home/state/$POLL_TRUST")" = 600 ] || fail "trust mode was not 0600"
  assert_contains "$(cat "$record")" 'window=five_hour' "record did not select the exhausted window"
  assert_contains "$(cat "$record")" 'resets_at=2026-08-10T17:30:00.801838+00:00' \
    "record did not carry the window's own reset time"
  assert_contains "$(cat "$record")" 'action=nudge' "record did not carry the resume action"
  fm_custom_check_registered "$dir/home/state" "$FM_QUOTA_RESET_POLL_ID" \
    || fail "the poll was not armed as a properly registered custom check"
  bash -n "$dir/home/state/$POLL_CHECK" || fail "the generated poll is not valid bash"

  out=$(run_freeze "$dir" exhausted.json list)
  assert_contains "$out" 'subject=task-a' "list did not report the obligation"
  assert_contains "$out" 'surfaced=no' "list did not report the obligation as not yet surfaced"
  assert_contains "$out" "poll: armed state/$POLL_CHECK" "list did not report the armed poll"

  pass "a freeze records a durable obligation and arms the reset poll"
}

test_the_explicit_window_and_role_subjects_are_accepted() {
  local dir out
  dir=$(make_case subjects)
  setup_root "$dir"

  out=$(run_freeze "$dir" exhausted.json add --subject pm --provider claude \
    --window five_hour --action respawn) || fail "a role subject was refused"
  assert_contains "$out" 'frozen: pm (role)' "the pm role was not recorded as a role"

  out=$(run_freeze "$dir" exhausted.json add --subject firstmate --provider claude \
    --action repeat) || fail "the firstmate role was refused"
  assert_contains "$out" 'frozen: firstmate (role)' "firstmate was not recorded as a role"

  # The role names are reserved so "pm" in the registry always means the board PM.
  run_freeze "$dir" exhausted.json add --subject pm --kind task --provider claude \
    --action nudge >/dev/null 2>&1 && fail "a task was allowed to claim the pm role name"

  pass "role subjects are recorded as roles and their names cannot be claimed by a task"
}

test_a_limit_quota_axi_cannot_observe_is_refused() {
  local dir rc before after
  dir=$(make_case unobservable)
  setup_root "$dir"
  before=$(state_snapshot "$dir/home/state")

  set +e
  run_freeze "$dir" no-exhausted-window.json add --subject task-a --provider grok \
    --action nudge > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  [ "$rc" -eq 4 ] || fail "an unobservable limit did not produce the dedicated exit code (got $rc)"
  assert_contains "$(cat "$dir/err")" 'not the axis that stopped this work' \
    "refusal did not explain that the exhausted axis is not the one quota-axi reports"

  set +e
  run_freeze "$dir" no-exhausted-window.json add --subject task-a --provider grok \
    --window weekly --action nudge >/dev/null 2> "$dir/err2"
  rc=$?
  set -e
  [ "$rc" -eq 4 ] || fail "an unmodelled window did not produce the dedicated exit code (got $rc)"
  assert_contains "$(cat "$dir/err2")" 'reroute this work' \
    "refusal did not point at rerouting instead of waiting"

  set +e
  run_freeze "$dir" stale.json add --subject task-a --provider claude --action nudge \
    >/dev/null 2> "$dir/err3"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a stale reading was accepted as freeze evidence"
  assert_contains "$(cat "$dir/err3")" 'stale' "stale refusal did not say the reading was stale"

  after=$(state_snapshot "$dir/home/state")
  [ "$after" = "$before" ] || fail "a refused freeze still changed state"
  pass "a limit quota-axi cannot observe is refused instead of armed into a silent wait"
}

test_invalid_input_is_refused_with_no_side_effect() {
  local dir before after rc args
  dir=$(make_case invalid)
  setup_root "$dir"
  before=$(state_snapshot "$dir/home/state")

  while IFS= read -r args; do
    [ -n "$args" ] || continue
    set +e
    # shellcheck disable=SC2086 # args is intentionally word-split test data
    run_freeze "$dir" exhausted.json add $args >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "invalid freeze accepted: $args"
  done <<'ARGS'
--subject task-a --provider claude
--subject task-a --action nudge
--provider claude --action nudge
--subject ../escape --provider claude --action nudge
--subject task-a --provider CLAUDE --action nudge
--subject task-a --provider claude --action explode
--subject task-a --provider claude --window "bad window" --action nudge
--subject task-a --provider claude --action nudge --extra
ARGS

  set +e
  run_freeze "$dir" exhausted.json resolve task-a >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "resolve accepted a subject with no recorded obligation"

  after=$(state_snapshot "$dir/home/state")
  [ "$after" = "$before" ] || fail "refused input changed state"
  pass "invalid freeze input is refused before any side effect"
}

test_poll_is_silent_until_headroom_actually_returns() {
  local dir out
  dir=$(make_case silence)
  setup_root "$dir"
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge >/dev/null \
    || fail "freeze failed"

  out=$(run_poll "$dir" exhausted.json)
  [ -z "$out" ] || fail "the poll woke firstmate while the window was still exhausted: $out"

  # The clock has passed the recorded reset, but the reading is stale, so it is
  # not evidence that capacity came back.
  out=$(run_poll "$dir" stale.json)
  [ -z "$out" ] || fail "a stale reading was treated as recovery: $out"

  out=$(FM_TEST_QUOTA_FAIL=1 run_poll "$dir" recovered.json)
  [ -z "$out" ] || fail "an unreadable quota reading produced a wake: $out"

  [ -f "$dir/home/state/$POLL_CHECK" ] || fail "the poll retired itself while an obligation was open"
  pass "the poll stays silent while the window is exhausted, stale, or unreadable"
}

test_recovery_wakes_exactly_once_then_resurfaces_only_after_the_quiet_window() {
  local dir out marker
  dir=$(make_case recovery)
  setup_root "$dir"
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge >/dev/null \
    || fail "freeze failed"

  out=$(run_poll "$dir" recovered.json)
  [ "$out" = 'quota reset ready: task-a(claude/five_hour,recovered)' ] \
    || fail "recovery did not produce exactly the expected single wake line: [$out]"

  out=$(run_poll "$dir" recovered.json)
  [ -z "$out" ] || fail "recovery woke firstmate a second time within the quiet window: $out"

  # An obligation firstmate never discharged must not go quiet forever.
  marker="$dir/home/state/quota-frozen/.notified/task-a"
  [ -f "$marker" ] || fail "the surfaced obligation was not marked"
  printf '%s\n' "$(( $(date +%s) - FM_QUOTA_RESET_RESURFACE_SECS - 60 ))" > "$marker"
  out=$(run_poll "$dir" recovered.json)
  assert_contains "$out" 'task-a(claude/five_hour,recovered)' \
    "an undischarged obligation was not re-surfaced after the quiet window"

  [ -f "$dir/home/state/quota-frozen/task-a" ] \
    || fail "the poll removed the obligation, which only a confirmed resume may do"
  pass "recovery wakes firstmate exactly once, then re-surfaces only after the quiet window"
}

test_an_unverifiable_window_surfaces_late_rather_than_never() {
  local dir out record
  dir=$(make_case unverifiable)
  setup_root "$dir"
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge >/dev/null \
    || fail "freeze failed"
  record="$dir/home/state/quota-frozen/task-a"

  # quota-axi stops modelling the window. Before the recorded reset plus its
  # grace this is simply unknown, so the poll stays quiet.
  perl -i -pe 's/^resets_at_epoch=.*$/"resets_at_epoch=" . (time + 10_000)/e' "$record"
  out=$(run_poll "$dir" window-gone.json)
  [ -z "$out" ] || fail "an unreadable window woke firstmate before its reset was even due: $out"

  # Once the reset is well past with still no reading to confirm it, silence
  # would be the stall this whole mechanism exists to prevent.
  perl -i -pe 's/^resets_at_epoch=.*$/"resets_at_epoch=" . (time - 10_000)/e' "$record"
  out=$(run_poll "$dir" window-gone.json)
  [ "$out" = 'quota reset ready: task-a(claude/five_hour,unverified)' ] \
    || fail "a long-overdue unverifiable window did not surface as explicitly unverified: [$out]"

  pass "a window quota-axi stops reporting surfaces late and explicitly unverified, never never"
}

test_an_unreadable_obligation_is_surfaced_not_stepped_over() {
  local dir out
  dir=$(make_case unreadable)
  setup_root "$dir"
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge >/dev/null \
    || fail "freeze failed"
  printf 'fm-quota-freeze-v1\nsubject=task-a\ntruncated\n' > "$dir/home/state/quota-frozen/task-a"

  out=$(run_poll "$dir" exhausted.json)
  [ "$out" = 'quota reset ready: task-a(unreadable)' ] \
    || fail "an unparseable obligation was silently stepped over: [$out]"
  [ -f "$dir/home/state/$POLL_CHECK" ] || fail "the poll retired over an unreadable obligation"
  out=$(run_freeze "$dir" exhausted.json list)
  assert_contains "$out" 'invalid:' "list did not report the unreadable entry"
  pass "an obligation that cannot be read is surfaced rather than silently skipped"
}

test_the_obligation_survives_a_firstmate_restart() {
  local dir out
  dir=$(make_case restart)
  setup_root "$dir"
  run_freeze "$dir" exhausted.json add --subject pm --provider claude --action respawn \
    --note "board left unattended" >/dev/null || fail "freeze failed"

  # A restart is exactly this: nothing in memory survives, only these files. No
  # process from the registering run is involved in anything below.
  [ -f "$dir/home/state/quota-frozen/pm" ] || fail "the obligation did not survive on disk"
  fm_custom_check_registered "$dir/home/state" "$FM_QUOTA_RESET_POLL_ID" \
    || fail "the armed poll did not survive on disk"

  out=$(run_freeze "$dir" exhausted.json show pm)
  assert_contains "$out" 'action=respawn' "the recorded resume action did not survive"
  assert_contains "$out" 'note=board left unattended' "the recorded resume note did not survive"

  out=$(run_poll "$dir" recovered.json)
  assert_contains "$out" 'pm(claude/five_hour,recovered)' \
    "the resume did not still fire for an obligation recorded before the restart"
  pass "a freeze recorded before a restart still wakes the fleet afterwards"
}

test_resolve_removes_one_obligation_and_retires_only_when_empty() {
  local dir out
  dir=$(make_case resolve)
  setup_root "$dir"
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge >/dev/null \
    || fail "first freeze failed"
  run_freeze "$dir" exhausted.json add --subject pm --provider claude --action respawn >/dev/null \
    || fail "second freeze failed"

  out=$(run_freeze "$dir" exhausted.json resolve task-a)
  assert_contains "$out" 'resolved: task-a' "resolve did not report the discharged obligation"
  assert_contains "$out" 'remaining: 1' "resolve did not report the still-open obligation"
  [ -f "$dir/home/state/$POLL_CHECK" ] \
    || fail "the poll retired while another obligation was still open"

  out=$(run_freeze "$dir" exhausted.json resolve pm)
  assert_contains "$out" "retired: state/$POLL_CHECK" "the poll did not retire once nothing was owed"
  [ ! -e "$dir/home/state/$POLL_CHECK" ] || fail "the retired poll left its check behind"
  [ ! -e "$dir/home/state/$POLL_TRUST" ] || fail "the retired poll left its trust binding behind"

  pass "resolve discharges one obligation and the poll retires only once nothing is owed"
}

test_a_foreign_check_in_the_slot_is_never_overwritten() {
  local dir rc before
  dir=$(make_case foreign-slot)
  setup_root "$dir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/home/state/$POLL_CHECK"
  chmod 0700 "$dir/home/state/$POLL_CHECK"
  before=$(shasum -a 256 "$dir/home/state/$POLL_CHECK" | awk '{print $1}')

  set +e
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge \
    >/dev/null 2> "$dir/err"
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a foreign check in the slot did not produce the refusal exit code (got $rc)"
  [ "$(shasum -a 256 "$dir/home/state/$POLL_CHECK" | awk '{print $1}')" = "$before" ] \
    || fail "the foreign check was overwritten"
  # A refusal must not leave an obligation on disk with nothing watching it.
  [ ! -e "$dir/home/state/quota-frozen/task-a" ] \
    || fail "the refused freeze still recorded an unwatched obligation"
  pass "a check slot owned by something else is refused loudly rather than replaced"
}

test_the_poll_id_cannot_be_taken_by_a_task() {
  # The poll and the task-id validator must agree about the reserved name, or a
  # task could silently evict the poll from the shared check slot.
  fm_task_id_creation_valid "$FM_QUOTA_RESET_POLL_ID" \
    && fail "a task may be created with the reserved quota reset poll id"
  fm_task_id_creation_valid "${FM_QUOTA_RESET_POLL_ID}-2" \
    || fail "the reservation leaked onto an ordinary task id"
  pass "no task can be created under the reserved quota reset poll id"
}

test_watcher_dispatch_delivers_the_reset_wake() {
  local dir rc
  dir=$(make_case watcher-dispatch)
  setup_root "$dir"
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge >/dev/null \
    || fail "freeze failed"

  set +e
  FM_TEST_QUOTA_READING="$dir/recovered.json" FM_TEST_QUOTA_LOG="$dir/quota.log" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=10 \
    FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 PATH="$dir/fakebin:$BASE_PATH" \
    perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 20; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "watcher did not exit cleanly after the reset wake: $(cat "$dir/watch.err")"
  [ "$(grep -c '^check: .*quota reset ready: task-a(claude/five_hour,recovered)$' "$dir/watch.out")" -eq 1 ] \
    || fail "watcher did not surface exactly one reset wake: $(cat "$dir/watch.out")"
  [ -f "$dir/home/state/quota-frozen/task-a" ] \
    || fail "the watcher run discharged the obligation, which only a confirmed resume may do"

  pass "the real watcher custom-check dispatch delivers the quota reset wake"
}

test_help_documents_usage() {
  local out
  out=$("$FREEZE" --help)
  assert_contains "$out" 'fm-quota-freeze.sh add --subject' "help text missing the add usage line"
  assert_contains "$out" '--provider' "help text missing --provider documentation"
  assert_contains "$out" 'resolve <subject>' "help text missing resolve documentation"
  assert_contains "$out" 'exit code 4' "help text does not document the unobservable-limit refusal"
  pass "--help documents the registry commands and the refusal it can produce"
}

test_add_records_the_obligation_and_arms_the_poll
test_the_explicit_window_and_role_subjects_are_accepted
test_a_limit_quota_axi_cannot_observe_is_refused
test_invalid_input_is_refused_with_no_side_effect
test_poll_is_silent_until_headroom_actually_returns
test_recovery_wakes_exactly_once_then_resurfaces_only_after_the_quiet_window
test_an_unverifiable_window_surfaces_late_rather_than_never
test_an_unreadable_obligation_is_surfaced_not_stepped_over
test_the_obligation_survives_a_firstmate_restart
test_resolve_removes_one_obligation_and_retires_only_when_empty
test_a_foreign_check_in_the_slot_is_never_overwritten
test_the_poll_id_cannot_be_taken_by_a_task
test_watcher_dispatch_delivers_the_reset_wake
test_help_documents_usage
