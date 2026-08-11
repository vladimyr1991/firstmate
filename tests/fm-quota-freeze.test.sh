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

# An ISO-8601 instant <seconds> from now. Fixture reset times must be computed
# rather than hardcoded: a literal timestamp silently becomes a PAST reset once
# the wall clock passes it, which flips the poll's unverified-grace path on and
# turns "stays silent" assertions into failures on a date nobody changed.
iso_in() {
  perl -e 'my @t = gmtime(time + $ARGV[0]);
    printf "%04d-%02d-%02dT%02d:%02d:%02dZ", $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0];' "$1"
}

# A quota-axi stand-in that prints whichever reading the current step selects,
# so a "reset" is expressed the way it actually reaches firstmate: a later
# reading of the same provider.
make_case() {
  local name=$1 dir fakebin soon later
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  soon=$(iso_in 18000)
  later=$(iso_in 36000)
  mkdir -p "$dir/home/state" "$fakebin"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_QUOTA_LOG:-/dev/null}"
[ "${FM_TEST_QUOTA_FAIL:-0}" = 0 ] || exit 1
cat "$FM_TEST_QUOTA_READING"
SH
  chmod +x "$fakebin/quota-axi"

  cat > "$dir/exhausted.json" <<J
{"schemaVersion":3,"providers":[
 {"provider":"claude","state":{"stale":false},"windows":[
   {"id":"five_hour","percentRemaining":0,"resetsAt":"$soon"},
   {"id":"seven_day","percentRemaining":55,"resetsAt":"$later"}]}]}
J
  cat > "$dir/recovered.json" <<J
{"schemaVersion":3,"providers":[
 {"provider":"claude","state":{"stale":false},"windows":[
   {"id":"five_hour","percentRemaining":100,"resetsAt":"$later"},
   {"id":"seven_day","percentRemaining":54,"resetsAt":"$later"}]}]}
J
  # The window is gone from the reading entirely: quota-axi stopped modelling
  # the axis that froze the work.
  cat > "$dir/window-gone.json" <<J
{"schemaVersion":3,"providers":[
 {"provider":"claude","state":{"stale":false},"windows":[
   {"id":"seven_day","percentRemaining":54,"resetsAt":"$later"}]}]}
J
  # Exactly at the ceiling a freeze may be registered on. Recovery must need
  # strictly more than this, or one reading would justify both the freeze and
  # the wake that says it is over.
  cat > "$dir/at-floor.json" <<J
{"schemaVersion":3,"providers":[
 {"provider":"claude","state":{"stale":false},"windows":[
   {"id":"five_hour","percentRemaining":10,"resetsAt":"$soon"}]}]}
J
  # A credits-style window at zero that carries no resetsAt at all, so the
  # record has no clock evidence to anchor anything on.
  cat > "$dir/no-reset.json" <<'J'
{"schemaVersion":3,"providers":[
 {"provider":"grok","state":{"stale":false},"windows":[
   {"id":"credits","percentRemaining":0}]}]}
J
  # The same credits window with capacity genuinely back, still carrying no
  # resetsAt: a verified recovery on a record that has no clock anchor at all.
  cat > "$dir/no-reset-recovered.json" <<'J'
{"schemaVersion":3,"providers":[
 {"provider":"grok","state":{"stale":false},"windows":[
   {"id":"credits","percentRemaining":100}]}]}
J
  # The same provider once quota-axi stops modelling that window.
  cat > "$dir/no-reset-gone.json" <<'J'
{"schemaVersion":3,"providers":[
 {"provider":"grok","state":{"stale":false},"windows":[
   {"id":"other","percentRemaining":42}]}]}
J
  # Headroom is reported, but the reading is stale, so it is not evidence.
  cat > "$dir/stale.json" <<J
{"schemaVersion":3,"providers":[
 {"provider":"claude","state":{"stale":true},"windows":[
   {"id":"five_hour","percentRemaining":100,"resetsAt":"$later"}]}]}
J
  # Every window has headroom: whatever stopped the work is invisible here.
  cat > "$dir/no-exhausted-window.json" <<'J'
{"schemaVersion":3,"providers":[
 {"provider":"grok","state":{"stale":false},"windows":[
   {"id":"credits","percentRemaining":42,"resetsAt":"2026-09-01T00:00:00Z"}]}]}
J
  # Recorded, not recomputed at assertion time: two iso_in calls a second apart
  # would disagree and turn an exact-value assertion into a rare flake.
  printf '%s\n' "$soon" > "$dir/soon.iso"
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
  assert_contains "$(cat "$record")" "resets_at=$(cat "$dir/soon.iso")" \
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

  # Headroom is reported, but the reading is stale, so it is not evidence that
  # capacity came back. The recorded reset is still ahead, so this is simply
  # unknown and the poll stays quiet.
  out=$(run_poll "$dir" stale.json)
  [ -z "$out" ] || fail "a stale reading was treated as recovery: $out"

  out=$(FM_TEST_QUOTA_FAIL=1 run_poll "$dir" recovered.json)
  [ -z "$out" ] || fail "an unreadable quota reading produced a wake: $out"

  [ -f "$dir/home/state/$POLL_CHECK" ] || fail "the poll retired itself while an obligation was open"

  # Once the recorded reset is long past and the reading is STILL stale, staying
  # quiet would be the stall this mechanism removes: the same reading now
  # surfaces as explicitly unverified, never as recovery.
  perl -i -pe 's/^resets_at_epoch=.*$/"resets_at_epoch=" . (time - 10_000)/e' \
    "$dir/home/state/quota-frozen/task-a"
  out=$(run_poll "$dir" stale.json)
  [ "$out" = 'quota reset ready: task-a(claude/five_hour,unverified)' ] \
    || fail "a stale reading past the recorded reset did not surface as unverified: [$out]"
  pass "the poll stays silent while the window is exhausted, stale, or unreadable"
}

test_a_freeze_at_the_floor_is_not_immediately_declared_recovered() {
  local dir out
  dir=$(make_case at-floor)
  setup_root "$dir"
  out=$(run_freeze "$dir" at-floor.json add --subject task-a --provider claude --action nudge) \
    || fail "a window exactly at the freeze ceiling was refused"
  assert_contains "$out" 'frozen: task-a (task) on claude/five_hour' \
    "the freeze did not record the window sitting at the ceiling"

  # One reading must never satisfy both "exhausted enough to freeze" and
  # "recovered": a wake here costs a firstmate turn with no reset behind it.
  out=$(run_poll "$dir" at-floor.json)
  [ -z "$out" ] || fail "the reading that justified the freeze immediately declared recovery: $out"

  out=$(run_poll "$dir" recovered.json)
  assert_contains "$out" 'task-a(claude/five_hour,recovered)' \
    "genuine headroom above the floor did not wake firstmate"
  pass "a freeze at the floor is not declared recovered by the very reading that justified it"
}

test_an_obligation_with_no_recorded_reset_still_surfaces() {
  local dir out record marker
  dir=$(make_case no-reset)
  setup_root "$dir"
  run_freeze "$dir" no-reset.json add --subject task-a --provider grok --action nudge >/dev/null \
    || fail "a window with no reset time was refused"
  record="$dir/home/state/quota-frozen/task-a"
  marker="$dir/home/state/quota-frozen/.notified/task-a"
  assert_contains "$(cat "$record")" 'resets_at=unknown' \
    "the fixture did not produce the no-clock-evidence case it is here to cover"

  # Nothing to verify from, and no recorded reset to measure a grace against.
  # While the freeze is recent that is simply unknown, so the poll stays quiet.
  out=$(run_poll "$dir" no-reset-gone.json)
  [ -z "$out" ] || fail "an obligation with no recorded reset woke firstmate immediately: $out"

  # Well past the grace a RECORDED reset would use, and still quiet. A recorded
  # reset says when capacity is actually due back, so 15 minutes past it is
  # evidence; a freeze time says only when the work stopped and predicts
  # nothing, so treating the two alike turns every quota-axi outage into a wake.
  perl -i -pe 's/^frozen_at=.*$/"frozen_at=" . (time - 3600)/e' "$record"
  out=$(run_poll "$dir" no-reset-gone.json)
  [ -z "$out" ] \
    || fail "an unanchored obligation nagged on the reset-anchored grace: $out"

  # Long past its own much longer grace, with quota-axi still not modelling the
  # window, the freeze time is the only anchor there is - and silence here would
  # be forever, which is the stall this whole mechanism exists to remove.
  perl -i -pe 's/^frozen_at=.*$/"frozen_at=" . (time - 30_000)/e' "$record"
  out=$(run_poll "$dir" no-reset-gone.json)
  [ "$out" = 'quota reset ready: task-a(grok/credits,unverified)' ] \
    || fail "an obligation with no recorded reset never surfaced as unverified: [$out]"

  # It repeats on its own much longer span too: a fixed short repeat would cost
  # a firstmate turn every half hour forever with nothing having reset.
  printf '%s\n' "$(( $(date +%s) - FM_QUOTA_RESET_RESURFACE_SECS - 60 ))" > "$marker"
  out=$(run_poll "$dir" no-reset-gone.json)
  [ -z "$out" ] || fail "an unanchored obligation re-surfaced on the reset-anchored repeat span: $out"
  printf '%s\n' "$(( $(date +%s) - FM_QUOTA_RESET_UNANCHORED_RESURFACE_SECS - 60 ))" > "$marker"
  out=$(run_poll "$dir" no-reset-gone.json)
  assert_contains "$out" 'task-a(grok/credits,unverified)' \
    "an unanchored obligation went quiet forever once its own repeat span elapsed"
  pass "an obligation frozen on a window with no reset time surfaces as unverified on its own longer spans"
}

test_a_recovery_on_an_unanchored_record_repeats_on_the_standard_span() {
  local dir out marker
  dir=$(make_case unanchored-recovery)
  setup_root "$dir"
  run_freeze "$dir" no-reset.json add --subject task-a --provider grok --action nudge >/dev/null \
    || fail "a window with no reset time was refused"
  marker="$dir/home/state/quota-frozen/.notified/task-a"

  # The long grace and repeat exist for the verdict that has nothing to verify.
  # A recovery has verified evidence that capacity is back, so the record's
  # missing reset time says nothing about how soon it may be repeated.
  out=$(run_poll "$dir" no-reset-recovered.json)
  [ "$out" = 'quota reset ready: task-a(grok/credits,recovered)' ] \
    || fail "a verified recovery on an unanchored record did not wake firstmate: [$out]"

  out=$(run_poll "$dir" no-reset-recovered.json)
  [ -z "$out" ] || fail "the recovery woke firstmate again inside its quiet window: $out"

  # One STANDARD quiet window later. Charging this obligation the six-hour
  # unanchored span would withhold a confirmed recovery for six hours - the
  # idle-fleet-at-full-quota stall this whole mechanism exists to remove.
  printf '%s\n' "$(( $(date +%s) - FM_QUOTA_RESET_RESURFACE_SECS - 60 ))" > "$marker"
  out=$(run_poll "$dir" no-reset-recovered.json)
  assert_contains "$out" 'task-a(grok/credits,recovered)' \
    "an undischarged recovery on an unanchored record was withheld past the standard repeat span"

  # The same record, the same span, but now with nothing to verify from: the
  # unverified verdict still waits for its own much longer span.
  printf '%s\n' "$(( $(date +%s) - FM_QUOTA_RESET_RESURFACE_SECS - 60 ))" > "$marker"
  perl -i -pe 's/^frozen_at=.*$/"frozen_at=" . (time - 30_000)/e' \
    "$dir/home/state/quota-frozen/task-a"
  out=$(run_poll "$dir" no-reset-gone.json)
  [ -z "$out" ] \
    || fail "an unverified verdict on an unanchored record repeated on the standard span: $out"
  pass "a recovery repeats on the standard span whatever the record is anchored on"
}

test_a_failed_re_arm_leaves_the_previously_armed_pair_intact() {
  local dir out check trust before_check before_trust
  dir=$(make_case rearm-failure)
  setup_root "$dir"
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge >/dev/null \
    || fail "first freeze failed"
  run_freeze "$dir" exhausted.json add --subject pm --provider claude --action respawn >/dev/null \
    || fail "second freeze failed"
  check="$dir/home/state/$POLL_CHECK"
  trust="$dir/home/state/$POLL_TRUST"
  before_check=$(shasum -a 256 "$check" | awk '{print $1}')
  before_trust=$(shasum -a 256 "$trust" | awk '{print $1}')

  # A re-arm whose CHECK cannot be renamed into the slot after its trust has
  # already replaced the live one: state/ becoming momentarily unwritable, or a
  # second arming run interleaving with this one. The pair being published over
  # is live and fleet-wide, so a rollback that only deletes what this attempt
  # wrote would leave the previous check with no trust that describes it, which
  # the watcher rejects as an unauthenticated state check - a dead poll plus a
  # noisy wake, with nothing watching ANY open obligation.
  (
    state="$dir/home/state"
    fm_quota_reset_poll_prepare "$state" || exit 1
    doomed=$FM_QUOTA_RESET_POLL_CHECK_TMP
    # shellcheck disable=SC2329 # Invoked indirectly: the publication under test calls mv.
    mv() {
      local dest=${*: -1} src=${*: -2:1}
      [ "$src" = "$doomed" ] && [ "$dest" = "$state/$POLL_CHECK" ] && return 1
      command mv "$@"
    }
    ! fm_quota_reset_poll_publish_prepared || exit 1
    fm_quota_reset_poll_cleanup
    exit 0
  ) || fail "the fixture did not produce a re-arm that fails between its two renames"

  [ "$(shasum -a 256 "$check" | awk '{print $1}')" = "$before_check" ] \
    || fail "the failed re-arm did not leave the previously armed check in place"
  [ "$(shasum -a 256 "$trust" | awk '{print $1}')" = "$before_trust" ] \
    || fail "the failed re-arm left the live check bound to a trust that does not describe it"
  fm_custom_check_registered "$dir/home/state" "$FM_QUOTA_RESET_POLL_ID" \
    || fail "the failed re-arm left the reserved slot unregistered, so the watcher would reject it"

  out=$(run_poll "$dir" recovered.json)
  assert_contains "$out" 'task-a(claude/five_hour,recovered)' \
    "the surviving poll no longer wakes for its obligations"
  assert_contains "$out" 'pm(claude/five_hour,recovered)' \
    "the surviving poll no longer wakes for its obligations"
  pass "a re-arm that fails after publishing its trust restores the pair that was armed"
}

test_a_record_survives_a_marker_clear_it_cannot_perform() {
  local dir out record marker rc
  dir=$(make_case marker-unclearable)
  setup_root "$dir"
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge \
    --note "first freeze" >/dev/null || fail "first freeze failed"
  record="$dir/home/state/quota-frozen/task-a"
  marker="$dir/home/state/quota-frozen/.notified/task-a"

  # The marker path is occupied by something rm cannot remove. Clearing it is
  # only an optimisation - at worst one delayed wake - so it must never be able
  # to decide the record's fate. Destroying the obligation over it would be the
  # worst outcome this registry has: nothing would ever wake that work again.
  mkdir -p "$marker/occupied" || fail "could not build the unclearable marker fixture"

  set +e
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge \
    --note "second freeze" > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a freeze failed because its marker could not be cleared: $(cat "$dir/err")"
  [ -f "$record" ] || fail "the record was destroyed by a cleanup step that ran after it was committed"
  assert_contains "$(cat "$record")" 'note=second freeze' \
    "the overwriting record did not land, so the write was not the committed result"

  out=$(run_freeze "$dir" exhausted.json list)
  assert_contains "$out" 'subject=task-a' "the surviving obligation is not in the registry"
  pass "a notified-marker clear that cannot succeed never destroys the record it was clearing for"
}

test_a_re_freeze_is_not_suppressed_by_the_earlier_wake() {
  local dir out marker
  dir=$(make_case refreeze)
  setup_root "$dir"
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge >/dev/null \
    || fail "freeze failed"
  marker="$dir/home/state/quota-frozen/.notified/task-a"

  out=$(run_poll "$dir" recovered.json)
  assert_contains "$out" 'task-a(claude/five_hour,recovered)' "the first recovery did not wake firstmate"
  [ -f "$marker" ] || fail "the first wake was not marked"

  # The resume did not hold - the window is exhausted again and the obligation
  # is re-registered. The marker now describes a wake for an obligation that no
  # longer exists, and leaving it would silence the next recovery for a full
  # quiet window: the same idle stall this mechanism exists to remove.
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge >/dev/null \
    || fail "re-freeze failed"
  [ ! -e "$marker" ] || fail "re-freezing left the earlier wake's marker in place"
  out=$(run_freeze "$dir" exhausted.json list)
  assert_contains "$out" 'surfaced=no' "the re-frozen obligation was still reported as already surfaced"

  out=$(run_poll "$dir" recovered.json)
  assert_contains "$out" 'task-a(claude/five_hour,recovered)' \
    "the re-frozen obligation was skipped until the earlier wake's quiet window expired"
  pass "re-freezing a subject clears the earlier wake so a recovery inside the quiet window still fires"
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

test_our_own_older_poll_is_re_armed_rather_than_refused() {
  local dir out rc
  dir=$(make_case own-older-poll)
  setup_root "$dir"
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge >/dev/null \
    || fail "first freeze failed"

  # A poll armed by an earlier firstmate: same provenance, different bytes.
  # It is ours, so a new freeze re-arms over it. Reading it as a sibling watch
  # and refusing would leave the newly frozen work with no wake at all - the
  # exact silent stall this mechanism exists to remove.
  printf '# an earlier render left this line behind\n' >> "$dir/home/state/$POLL_CHECK"
  if fm_custom_check_registered "$dir/home/state" "$FM_QUOTA_RESET_POLL_ID"; then
    fail "the altered poll still matched its trust binding, so this fixture proves nothing"
  fi

  set +e
  out=$(run_freeze "$dir" exhausted.json add --subject pm --provider claude --action respawn \
    2> "$dir/err")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a freeze was refused because our own older poll held the slot: $(cat "$dir/err")"
  assert_contains "$out" "armed: state/$POLL_CHECK" "the poll was not re-armed over our own older one"
  fm_custom_check_registered "$dir/home/state" "$FM_QUOTA_RESET_POLL_ID" \
    || fail "the re-armed poll is not a properly registered custom check"
  [ -f "$dir/home/state/quota-frozen/pm" ] || fail "the new obligation was not recorded"
  out=$(run_poll "$dir" recovered.json)
  assert_contains "$out" 'pm(claude/five_hour,recovered)' \
    "the re-armed poll does not watch the obligation it was armed for"

  # Retirement recognizes ownership the same way, so an older render is never
  # left armed with an empty registry behind it.
  printf '# and another one\n' >> "$dir/home/state/$POLL_CHECK"
  run_freeze "$dir" exhausted.json resolve task-a >/dev/null || fail "resolve failed"
  out=$(run_freeze "$dir" exhausted.json resolve pm)
  assert_contains "$out" "retired: state/$POLL_CHECK" "our own older poll was not retired"
  [ ! -e "$dir/home/state/$POLL_CHECK" ] || fail "the older poll stayed armed after the registry emptied"
  pass "a poll this mechanism generated is re-armed and retired even when its bytes have changed"
}

test_an_unarmed_freeze_is_reported_as_an_unwatched_obligation() {
  local dir out rc err rearm
  dir=$(make_case arm-failure)
  setup_root "$dir"
  # An obligation already in the registry, and a poll that is not armed - the
  # state a firstmate restart can land in after a partly-published arm.
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge >/dev/null \
    || fail "setup freeze failed"
  rm -f "$dir/home/state/$POLL_CHECK" "$dir/home/state/$POLL_TRUST"

  # Deny state/ any write: the record still lands in the registry subdirectory,
  # but the poll cannot be published. Losing the obligation would be the worse
  # failure, so it is kept - and must not read as "nothing happened".
  chmod 0500 "$dir/home/state"
  set +e
  run_freeze "$dir" exhausted.json add --subject pm --provider claude --action respawn \
    --note "board left unattended" > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  chmod 0700 "$dir/home/state"

  # A dedicated code, not just "non-zero": the caller has to tell "the record is
  # there and unwatched" from "nothing was recorded", because one needs a re-arm
  # and the other needs the freeze recording from scratch.
  [ "$rc" -eq "$FM_QUOTA_FREEZE_EXIT_UNWATCHED" ] \
    || fail "an unwatched obligation did not produce its dedicated exit code (got $rc)"
  assert_contains "$(cat "$dir/out")" 'frozen: pm (role) on claude/five_hour' \
    "the recorded freeze was not reported"
  err=$(cat "$dir/err")
  assert_contains "$err" 'is NOT armed' \
    "the failure did not state that no poll is armed"
  # The poll is one file for the whole registry, so an unarmed poll leaves EVERY
  # obligation unwatched. Reporting only the current subject understates it.
  assert_contains "$err" 'fleet-wide' \
    "the failure did not say the unarmed poll is fleet-wide"
  assert_contains "$err" '2 open obligation' \
    "the failure did not count every obligation the unarmed poll leaves unwatched"
  assert_contains "$err" ' task-a' \
    "the failure did not name the other obligation that is equally unwatched"
  [ -f "$dir/home/state/quota-frozen/pm" ] \
    || fail "the obligation was dropped, losing the work the registry exists to protect"
  out=$(run_freeze "$dir" exhausted.json list)
  assert_contains "$out" 'subject=pm' "list did not report the surviving obligation"
  assert_contains "$out" 'poll: not armed' "list did not report that nothing is watching it"

  # The named command is the whole point, so run exactly it. The note is what
  # tells firstmate on the wake what resuming actually requires - a re-arm that
  # silently drops it leaves an obligation nobody can act on.
  rearm=$(sed -n 's/^error: re-arm it with: fm-quota-freeze\.sh //p' "$dir/err")
  [ -n "$rearm" ] || fail "the failure did not name a command that re-arms the obligation"
  eval "run_freeze \"\$dir\" exhausted.json $rearm" > "$dir/rearm.out" 2> "$dir/rearm.err" \
    || fail "the command the failure named did not re-arm the obligation: $(cat "$dir/rearm.err")"
  out=$(run_freeze "$dir" exhausted.json show pm)
  assert_contains "$out" 'note=board left unattended' \
    "re-arming through the named command discarded the recorded note"
  assert_contains "$out" 'action=respawn' "re-arming through the named command changed the resume action"
  out=$(run_freeze "$dir" exhausted.json list)
  assert_contains "$out" "poll: armed state/$POLL_CHECK" "the named command did not actually arm the poll"
  pass "a freeze whose poll cannot be armed keeps the obligation and names a command that fully restores it"
}

test_an_arming_failure_with_a_live_poll_says_the_wake_is_still_watched() {
  local dir out rc err
  dir=$(make_case arm-failure-live-poll)
  setup_root "$dir"
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge >/dev/null \
    || fail "setup freeze failed"

  # The poll enumerates the registry when it runs, so the one already armed
  # watches obligations recorded after it was written. An arming failure here
  # means it was not refreshed - not that the new wake is lost.
  chmod 0500 "$dir/home/state"
  set +e
  run_freeze "$dir" exhausted.json add --subject pm --provider claude --action respawn \
    > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  chmod 0700 "$dir/home/state"

  # Both durable results this add owes are in hand: the record is on disk and a
  # fleet-wide poll is watching it. Reporting that as a failure is how the
  # caller - bin/fm-limit-dialog.sh, and firstmate behind it - is told to record
  # a freeze that already exists.
  [ "$rc" -eq 0 ] || fail "a recorded freeze a live poll is watching was reported as a failure (exit $rc)"
  assert_contains "$(cat "$dir/out")" 'frozen: pm (role) on claude/five_hour' \
    "the recorded freeze was not reported"
  assert_contains "$(cat "$dir/out")" 'watched:' \
    "the outcome did not distinguish an already-armed poll from a freshly armed one"
  err=$(cat "$dir/err")
  assert_contains "$err" 'is NOT lost' \
    "the failure claimed the wake was lost while a poll was still watching the registry"
  case "$err" in
    *'error:'*) fail "a refresh that lost nothing was reported as an error: $err" ;;
  esac
  fm_custom_check_registered "$dir/home/state" "$FM_QUOTA_RESET_POLL_ID" \
    || fail "the failed refresh disarmed the poll that was already watching the registry"

  out=$(run_poll "$dir" recovered.json)
  assert_contains "$out" 'pm(claude/five_hour,recovered)' \
    "the surviving poll did not wake for the obligation recorded after it was armed"
  assert_contains "$out" 'task-a(claude/five_hour,recovered)' \
    "the surviving poll stopped waking for the obligation it was armed for"
  pass "an arming failure that leaves a live poll reports the wake as still watched, not lost"
}

test_an_arming_failure_never_revokes_a_poll_it_did_not_publish() {
  local dir out
  dir=$(make_case revoke-scope)
  setup_root "$dir"
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge >/dev/null \
    || fail "first freeze failed"
  run_freeze "$dir" exhausted.json add --subject pm --provider claude --action respawn >/dev/null \
    || fail "second freeze failed"
  fm_custom_check_registered "$dir/home/state" "$FM_QUOTA_RESET_POLL_ID" \
    || fail "setup did not arm the poll"

  # A replacement poll is prepared and then abandoned before anything is
  # published. Rolling that back may reach only what this attempt renamed into
  # place; the live poll is watching the whole registry, so tearing it down over
  # an unrelated failure would stop the wakes for every open obligation at once.
  (
    fm_quota_reset_poll_prepare "$dir/home/state" || exit 1
    fm_quota_reset_poll_revoke_final
    fm_quota_reset_poll_cleanup
    exit 0
  ) || fail "preparing a replacement poll failed"

  fm_custom_check_registered "$dir/home/state" "$FM_QUOTA_RESET_POLL_ID" \
    || fail "an abandoned arming attempt disarmed the poll it never published over"
  out=$(run_poll "$dir" recovered.json)
  assert_contains "$out" 'task-a(claude/five_hour,recovered)' \
    "the surviving poll no longer wakes for its obligations"
  assert_contains "$out" 'pm(claude/five_hour,recovered)' \
    "the surviving poll no longer wakes for its obligations"
  pass "an arming attempt that publishes nothing leaves the already-armed poll watching the registry"
}

test_a_discharge_completes_even_when_its_marker_cannot_be_cleared() {
  local dir out
  dir=$(make_case discharge-marker)
  setup_root "$dir"
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge >/dev/null \
    || fail "freeze failed"
  out=$(run_poll "$dir" recovered.json)
  assert_contains "$out" 'task-a(claude/five_hour,recovered)' "the setup wake did not fire"

  # The marker path becomes something rm cannot remove. Clearing it is cleanup
  # AFTER the discharge; it may not turn a completed discharge into "no quota
  # freeze recorded", which would tell firstmate to keep waiting on work that is
  # already done, nor skip retiring a poll with nothing left to watch.
  rm -f "$dir/home/state/quota-frozen/.notified/task-a"
  mkdir -p "$dir/home/state/quota-frozen/.notified/task-a/occupied" \
    || fail "could not build the unclearable marker fixture"

  out=$(run_freeze "$dir" exhausted.json resolve task-a) \
    || fail "a completed discharge was reported as a failure because its marker could not be cleared"
  assert_contains "$out" 'resolved: task-a' "the completed discharge was not reported as done"
  assert_contains "$out" "retired: state/$POLL_CHECK" \
    "the marker failure skipped retiring a poll with an empty registry behind it"
  [ ! -e "$dir/home/state/quota-frozen/task-a" ] || fail "the obligation was not actually discharged"
  [ ! -e "$dir/home/state/$POLL_CHECK" ] || fail "the poll stayed armed over an empty registry"
  pass "a discharge whose marker cannot be cleared still reports as done and still retires the poll"
}

test_the_poll_reads_quota_axi_once_per_sweep() {
  local dir out calls
  dir=$(make_case one-reading)
  setup_root "$dir"
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge >/dev/null \
    || fail "first freeze failed"
  run_freeze "$dir" exhausted.json add --subject pm --provider claude --action respawn >/dev/null \
    || fail "second freeze failed"

  # quota-axi is a network call and the watcher runs this whole check under one
  # timeout, so one invocation per obligation is how a sweep with a hung
  # provider runs out of budget and loses the wake entirely. It is also what
  # would let two records in one sweep be judged against different readings.
  : > "$dir/quota.log"
  out=$(run_poll "$dir" recovered.json)
  assert_contains "$out" 'task-a(claude/five_hour,recovered)' "the sweep did not wake for task-a"
  assert_contains "$out" 'pm(claude/five_hour,recovered)' "the sweep did not wake for pm"
  calls=$(wc -l < "$dir/quota.log" | tr -d '[:space:]')
  [ "$calls" -eq 1 ] || fail "one sweep over two obligations read quota-axi $calls times"

  # Both obligations are now inside their quiet window, so the sweep has nothing
  # to look at and must not pay for a reading at all.
  : > "$dir/quota.log"
  out=$(run_poll "$dir" recovered.json)
  [ -z "$out" ] || fail "a fully suppressed sweep still woke firstmate: $out"
  calls=$(wc -l < "$dir/quota.log" | tr -d '[:space:]')
  [ "$calls" -eq 0 ] || fail "a sweep with every obligation suppressed still read quota-axi $calls times"
  pass "a sweep reads quota-axi once for the whole registry, and not at all when nothing is due"
}

test_a_marker_that_cannot_be_read_never_silences_its_obligation() {
  local dir out marker content
  dir=$(make_case marker-unreadable)
  setup_root "$dir"
  run_freeze "$dir" exhausted.json add --subject task-a --provider claude --action nudge >/dev/null \
    || fail "freeze failed"
  marker="$dir/home/state/quota-frozen/.notified/task-a"

  out=$(run_poll "$dir" recovered.json)
  assert_contains "$out" 'task-a(claude/five_hour,recovered)' "the recovery did not wake firstmate"
  [ -f "$marker" ] || fail "the surfaced obligation was not marked"

  # The marker survives but its contents no longer say anything - a truncated
  # write, a foreign file at the path, a mode this process cannot read. A marker
  # that cannot be read is NO evidence that anything was surfaced. Reading it as
  # "surfaced just now" suppresses the record before it is ever evaluated, so it
  # is never re-marked either, and the obligation goes quiet on every sweep from
  # then on - permanent silence, which is the failure this registry removes.
  printf 'not-a-timestamp\n' > "$marker"
  out=$(run_poll "$dir" recovered.json)
  assert_contains "$out" 'task-a(claude/five_hour,recovered)' \
    "an obligation whose marker cannot be parsed was silenced instead of surfaced"

  # And the sweep that surfaced it put a usable timestamp back, so the recovery
  # of the marker is not itself something a human has to perform.
  content=$(cat "$marker")
  case "$content" in
    ''|*[!0-9]*) fail "the unparseable marker was not rewritten with a valid timestamp: [$content]" ;;
  esac
  out=$(run_poll "$dir" recovered.json)
  [ -z "$out" ] || fail "the rewritten marker did not restore the quiet window: $out"

  # The same silence hole entered from the other side. A marker is written from
  # date +%s, so a backwards clock step - an NTP correction, a resume from
  # sleep, a shared state dir written by a skewed host - leaves it dated ahead
  # of now. The negative age that produces is less than every span, so the
  # record would be suppressed and never re-marked for the whole skew.
  printf '%s\n' "$(( $(date +%s) + FM_QUOTA_RESET_RESURFACE_SECS * 4 ))" > "$marker"
  out=$(run_poll "$dir" recovered.json)
  assert_contains "$out" 'task-a(claude/five_hour,recovered)' \
    "an obligation whose marker is dated in the future was silenced instead of surfaced"
  content=$(cat "$marker")
  case "$content" in
    ''|*[!0-9]*) fail "the future-dated marker was not rewritten with a usable timestamp: [$content]" ;;
  esac
  [ "$content" -le "$(date +%s)" ] \
    || fail "the rewritten marker is still dated in the future: [$content]"
  out=$(run_poll "$dir" recovered.json)
  [ -z "$out" ] || fail "the marker rewritten over a future timestamp did not restore the quiet window: $out"

  [ -f "$dir/home/state/quota-frozen/task-a" ] \
    || fail "the poll removed the obligation, which only a confirmed resume may do"
  pass "a notified marker that cannot be read or is dated ahead of now surfaces its obligation and is rewritten"
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

test_the_role_names_cannot_be_taken_by_a_task() {
  local dir role rc
  # A task created under a role name would have its freeze recorded as that
  # role's - "pm" in the registry always means the board PM - so the wake would
  # respawn a board PM while the frozen task is never resumed, and the
  # obligation would be discharged as though it had been. The registry and the
  # task-id validator must therefore agree on the reserved names, and the
  # refusal has to be a refusal rather than a rename onto some fallback id.
  for role in $FM_QUOTA_FREEZE_ROLES; do
    fm_task_id_creation_valid "$role" \
      && fail "a task may be created under the reserved role name $role"
    fm_task_id_creation_valid "${role}-1" \
      || fail "the $role reservation leaked onto an ordinary task id"
    # The reservation answers only the creation question. A task created under
    # that name before the reservation landed still exists, and every site
    # judging an id it finds on disk must still recognize it, or that task's
    # state is stranded with nothing left that will act on it.
    fm_task_id_recognized "$role" \
      || fail "the $role reservation leaked into the shape predicate that recognizes existing ids"
  done
  fm_task_id_recognized "$FM_QUOTA_RESET_POLL_ID" \
    || fail "the check-slot reservation leaked into the shape predicate that recognizes existing ids"

  # And the registry's own door stays shut from the other side: the same name
  # offered as a task subject is refused rather than recorded as the role.
  dir=$(make_case role-names)
  setup_root "$dir"
  for role in $FM_QUOTA_FREEZE_ROLES; do
    set +e
    run_freeze "$dir" exhausted.json add --subject "$role" --kind task --provider claude \
      --action nudge >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "the registry recorded a task freeze under the reserved role name $role"
    [ ! -e "$dir/home/state/quota-frozen/$role" ] \
      || fail "a refused task freeze still wrote a record under the role name $role"
  done
  pass "no task can be created or frozen under a reserved registry role name"
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
  assert_contains "$out" "$FM_QUOTA_FREEZE_EXIT_UNWATCHED  recorded but NOT watched" \
    "help text does not document the recorded-but-unwatched outcome as its own exit code"
  pass "--help documents the registry commands, its exit codes, and the refusal it can produce"
}

test_add_records_the_obligation_and_arms_the_poll
test_the_explicit_window_and_role_subjects_are_accepted
test_a_limit_quota_axi_cannot_observe_is_refused
test_invalid_input_is_refused_with_no_side_effect
test_poll_is_silent_until_headroom_actually_returns
test_a_freeze_at_the_floor_is_not_immediately_declared_recovered
test_an_obligation_with_no_recorded_reset_still_surfaces
test_a_recovery_on_an_unanchored_record_repeats_on_the_standard_span
test_a_failed_re_arm_leaves_the_previously_armed_pair_intact
test_a_record_survives_a_marker_clear_it_cannot_perform
test_recovery_wakes_exactly_once_then_resurfaces_only_after_the_quiet_window
test_a_re_freeze_is_not_suppressed_by_the_earlier_wake
test_an_unverifiable_window_surfaces_late_rather_than_never
test_an_unreadable_obligation_is_surfaced_not_stepped_over
test_the_obligation_survives_a_firstmate_restart
test_resolve_removes_one_obligation_and_retires_only_when_empty
test_a_foreign_check_in_the_slot_is_never_overwritten
test_our_own_older_poll_is_re_armed_rather_than_refused
test_an_unarmed_freeze_is_reported_as_an_unwatched_obligation
test_an_arming_failure_with_a_live_poll_says_the_wake_is_still_watched
test_an_arming_failure_never_revokes_a_poll_it_did_not_publish
test_a_discharge_completes_even_when_its_marker_cannot_be_cleared
test_the_poll_reads_quota_axi_once_per_sweep
test_a_marker_that_cannot_be_read_never_silences_its_obligation
test_the_poll_id_cannot_be_taken_by_a_task
test_the_role_names_cannot_be_taken_by_a_task
test_watcher_dispatch_delivers_the_reset_wake
test_help_documents_usage
