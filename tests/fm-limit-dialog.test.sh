#!/usr/bin/env bash
# Behavior tests for bin/fm-limit-dialog.sh: the path that answers a worker
# parked on a usage-limit dialog. The property that matters most here is
# negative - the option that spends the captain's money is never selected, and
# anything the matcher cannot read unambiguously produces no keystroke at all -
# so most of these drive the real script against dialog shapes it must refuse.
# The live path runs through the reference tmux backend with a fake tmux, so the
# assertions are about keys that actually reached the endpoint.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DIALOG="$ROOT/bin/fm-limit-dialog.sh"
TMP_ROOT=$(fm_test_tmproot fm-limit-dialog)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# The observed shape from the incident this path exists for: a limit banner and
# two numbered options, one of which buys capacity.
OBSERVED_DIALOG='│ Claude usage limit reached. Your limit will reset at 5:30pm.   │
│                                                                │
│ ❯ 1. Stop and wait for the limit to reset                      │
│   2. Upgrade to Max for higher limits                          │'

# An ISO-8601 instant <seconds> from now. Fixture reset times must be computed
# rather than hardcoded: a literal timestamp silently becomes a PAST reset once
# the wall clock passes it, which changes which branch of the freeze registry's
# time-dependent logic the fixture exercises on a date nobody changed.
iso_in() {
  perl -e 'my @t = gmtime(time + $ARGV[0]);
    printf "%04d-%02d-%02dT%02d:%02d:%02dZ", $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0];' "$1"
}

make_case() {  # <name> -> echoes case dir
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$fakebin"

  # A tmux that shows the dialog until a key is sent, then shows a plain pane.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    [ "$literal" = 1 ] && printf '%s' "${1:-}" >> "$FM_TMUX_TYPED"
    [ "${1:-}" = Enter ] && : > "$FM_TMUX_ANSWERED"
    exit 0 ;;
  capture-pane)
    # fm-send's composer reader asks for the styled pane (-e) and inspects the
    # bordered composer; fm-limit-dialog asks for the plain scrollback. Serve
    # each the view it actually reads, so one fake can back both callers.
    for a in "$@"; do
      if [ "$a" = -e ]; then
        printf '╭────╮\n│    │\n╰────╯\n'
        exit 0
      fi
    done
    # FM_TMUX_CAPTURE_FAILS models the endpoint becoming unreadable once the
    # selection has been submitted - the harness exits on "wait" and the window
    # closes - which is only ever observed by the post-answer confirmation.
    if [ -e "$FM_TMUX_ANSWERED" ] && [ -n "${FM_TMUX_CAPTURE_FAILS:-}" ]; then
      printf 'no such pane\n' >&2
      exit 1
    fi
    # FM_TMUX_STICKY models a pane that has not repainted yet: the dialog is
    # still on screen even though the selection was sent and confirmed.
    if [ -e "$FM_TMUX_ANSWERED" ] && [ -z "${FM_TMUX_STICKY:-}" ]; then
      printf 'ready\n> \n'
    else
      cat "$FM_TMUX_SCREEN"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac
    done
    printf '%%1\n'
    exit 0 ;;
  list-windows)
    printf 'sess:fm-task-a\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"

  # quota-axi reporting the exhausted window the dialog is about, so the freeze
  # this path arms has something real to watch.
  cat > "$dir/quota.json" <<J
{"schemaVersion":3,"providers":[
 {"provider":"claude","state":{"stale":false},"windows":[
   {"id":"five_hour","percentRemaining":0,"resetsAt":"$(iso_in 18000)"}]}]}
J
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
cat $(printf '%q' "$dir/quota.json")
SH
  chmod +x "$fakebin/quota-axi"

  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=sess:fm-task-a" "endpoint_task_id=task-a" "kind=ship" "mode=no-mistakes"
  : > "$dir/tmux.log"
  : > "$dir/typed.txt"
  printf '%s\n' "$dir"
}

run_detect() {  # <case-dir> <screen-file> [extra args...]
  local dir=$1 screen=$2
  shift 2
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    "$DIALOG" task-a --detect-only --from-capture "$screen" "$@"
}

run_live() {  # <case-dir> [extra args...]
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" \
    FM_TMUX_LOG="$dir/tmux.log" FM_TMUX_TYPED="$dir/typed.txt" \
    FM_TMUX_ANSWERED="$dir/answered" FM_TMUX_SCREEN="$dir/screen.txt" \
    FM_SEND_SETTLE=0 PATH="$dir/fakebin:$BASE_PATH" \
    "$DIALOG" task-a "$@"
}

test_the_observed_dialog_is_recognized() {
  local dir out
  dir=$(make_case observed)
  printf '%s\n' "$OBSERVED_DIALOG" > "$dir/screen.txt"

  out=$(run_detect "$dir" "$dir/screen.txt") || fail "the observed limit dialog was not recognized"
  assert_contains "$out" 'limit-dialog: detected' "detection was not reported"
  assert_contains "$out" 'wait-option: 1' "the waiting option was not identified"
  assert_contains "$out" 'wait-text: Stop and wait for the limit to reset' \
    "the waiting option text was not reported"
  assert_contains "$out" '2=Upgrade to Max' "the remaining options were not reported"
  pass "the observed usage-limit dialog is recognized and its waiting option named"
}

test_an_ordinary_numbered_menu_is_not_a_limit_dialog() {
  local dir rc
  dir=$(make_case ordinary-menu)
  printf '1. yes\n2. no\n' > "$dir/menu.txt"
  set +e
  run_detect "$dir" "$dir/menu.txt" > "$dir/out" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "an ordinary menu was treated as a limit dialog (exit $rc)"
  assert_contains "$(cat "$dir/out")" 'not detected' "no-dialog result was not reported plainly"

  printf 'All quiet. Nothing to answer.\n' > "$dir/idle.txt"
  set +e
  run_detect "$dir" "$dir/idle.txt" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "an idle pane was treated as a limit dialog"
  pass "an ordinary numbered menu and an idle pane are not limit dialogs"
}

test_a_repainted_dialog_is_still_one_dialog() {
  local dir out
  dir=$(make_case repainted)
  # Scrollback keeps the earlier render, so the same options appear twice.
  { printf '%s\n' "$OBSERVED_DIALOG"; printf '\n'; printf '%s\n' "$OBSERVED_DIALOG"; } \
    > "$dir/screen.txt"

  out=$(run_detect "$dir" "$dir/screen.txt") \
    || fail "a redrawn dialog was refused as ambiguous"
  assert_contains "$out" 'wait-option: 1' "the waiting option was not identified in a redrawn dialog"
  pass "a dialog repainted into scrollback still reads as one dialog"
}

test_ambiguous_dialogs_send_nothing() {
  local dir rc name screen
  dir=$(make_case ambiguous)

  # No option waits: this is the grok weekly-cap paywall, where the answer is to
  # reroute the work, not to press something.
  cat > "$dir/paywall.txt" <<'T'
You hit your weekly limit.
1. Upgrade to Pro
2. Buy more credits
T
  # Two options both read as waiting, so which one is meant is a guess.
  cat > "$dir/two-waits.txt" <<'T'
Usage limit reached.
1. Stop and wait for the limit to reset
2. Wait for the limit to reset and retry automatically
T
  # One option both waits and buys. Selecting it would spend money.
  cat > "$dir/mixed.txt" <<'T'
Usage limit reached.
1. Upgrade now and skip the wait until the limit resets
2. Something else entirely
T

  for name in paywall two-waits mixed; do
    screen="$dir/$name.txt"
    set +e
    run_detect "$dir" "$screen" > "$dir/$name.out" 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 3 ] || fail "ambiguous dialog '$name' did not refuse with exit 3 (got $rc)"
    assert_contains "$(cat "$dir/$name.out")" 'no key was sent' \
      "ambiguous dialog '$name' did not state that nothing was sent"
  done
  pass "a dialog whose waiting option cannot be identified unambiguously sends no key at all"
}

test_answering_selects_wait_and_never_upgrade() {
  local dir rc typed log
  dir=$(make_case answer)
  printf '%s\n' "$OBSERVED_DIALOG" > "$dir/screen.txt"

  set +e
  run_live "$dir" --provider claude > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "answering the dialog failed (exit $rc): $(cat "$dir/err")"

  typed=$(cat "$dir/typed.txt")
  [ "$typed" = 1 ] || fail "the waiting option was not the key typed (typed [$typed])"
  log=$(cat "$dir/tmux.log")
  assert_contains "$log" 'literal=0 arg=Enter' "the selection was never submitted"
  case "$log" in
    *'literal=1 arg=2'*) fail "the upgrade option was typed" ;;
  esac
  assert_contains "$(cat "$dir/out")" 'selected: 1' "the answered selection was not reported"

  # Answering only unparks the pane; the resume is what makes the work continue.
  assert_contains "$(cat "$dir/home/state/quota-frozen/task-a")" 'window=five_hour' \
    "answering the dialog did not record the freeze it created"
  assert_contains "$(cat "$dir/home/state/quota-frozen/task-a")" 'action=nudge' \
    "the recorded resume action was not the steer a waiting worker needs"
  [ -f "$dir/home/state/fm-quota-reset.check.sh" ] \
    || fail "answering the dialog did not arm the resume"
  pass "answering a limit dialog selects the waiting option, never the paid one, and arms the resume"
}

test_a_pane_that_has_not_repainted_is_a_warning_not_a_failed_answer() {
  local dir rc
  dir=$(make_case sticky-pane)
  printf '%s\n' "$OBSERVED_DIALOG" > "$dir/screen.txt"

  set +e
  FM_TMUX_STICKY=1 run_live "$dir" --provider claude > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  # The key was sent, the submit was confirmed, and the freeze is recorded.
  # Reporting failure here would tell the caller to re-answer an answered
  # dialog, which types another selection into a live worker's composer.
  [ "$rc" -eq 0 ] || fail "a pane still showing the answered dialog was reported as a failed answer (exit $rc)"
  [ "$(cat "$dir/typed.txt")" = 1 ] || fail "the waiting option was not the key typed"
  assert_contains "$(cat "$dir/err")" 'still in the pane output' \
    "the unrepainted pane was not reported at all"
  assert_contains "$(cat "$dir/err")" 'rather than re-answering' \
    "the warning did not steer away from answering the dialog twice"
  [ -f "$dir/home/state/quota-frozen/task-a" ] || fail "the freeze was not recorded"
  [ -f "$dir/home/state/fm-quota-reset.check.sh" ] || fail "the resume was not armed"
  pass "a dialog still visible after a confirmed answer warns instead of reporting the answer as failed"
}

test_an_unreadable_pane_after_a_confirmed_answer_is_a_warning_not_a_failure() {
  local dir rc
  dir=$(make_case unreadable-after-answer)
  printf '%s\n' "$OBSERVED_DIALOG" > "$dir/screen.txt"

  set +e
  FM_TMUX_CAPTURE_FAILS=1 run_live "$dir" --provider claude > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  # The endpoint went away because the worker acted on the answer. Reporting
  # that as "no dialog detected, or answering it failed" would invite the caller
  # to answer an already-answered dialog.
  [ "$rc" -eq 0 ] || fail "an unreadable pane after a confirmed answer was reported as a failure (exit $rc)"
  [ "$(cat "$dir/typed.txt")" = 1 ] || fail "the waiting option was not the key typed"
  assert_contains "$(cat "$dir/err")" 'could not re-read the pane' \
    "the unreadable confirmation was not reported at all"
  assert_contains "$(cat "$dir/err")" 'the freeze recorded regardless' \
    "the warning did not say the durable part was already done"
  assert_contains "$(cat "$dir/home/state/quota-frozen/task-a")" 'window=five_hour' \
    "the freeze recorded before the confirmation did not survive it"
  [ -f "$dir/home/state/fm-quota-reset.check.sh" ] || fail "the resume was not armed"
  pass "a pane that cannot be re-read after a confirmed answer warns and keeps the recorded freeze"
}

test_a_freeze_that_cannot_be_recorded_reports_no_resume_not_the_child_code() {
  local dir rc
  dir=$(make_case freeze-refused)
  printf '%s\n' "$OBSERVED_DIALOG" > "$dir/screen.txt"
  # A foreign check owns the reserved slot, so fm-quota-freeze.sh refuses with
  # ITS exit 3 - a code that means "ambiguous dialog, nothing sent" in this
  # script's own table. Propagating it would tell the caller no key was sent
  # while the pane has in fact been answered.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/home/state/fm-quota-reset.check.sh"
  chmod 0700 "$dir/home/state/fm-quota-reset.check.sh"

  set +e
  run_live "$dir" --provider claude > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  [ "$rc" -eq 4 ] || fail "a failed freeze was not reported as an answered dialog with no resume (exit $rc)"
  [ "$(cat "$dir/typed.txt")" = 1 ] || fail "the dialog was not answered"
  assert_contains "$(cat "$dir/err")" 'no resume was armed' "the missing resume was not reported"
  [ ! -e "$dir/home/state/quota-frozen/task-a" ] || fail "a freeze was recorded despite the refusal"
  pass "a dialog answered while the freeze is refused exits 4, never the freeze script's own code"
}

test_a_recorded_freeze_a_live_poll_watches_is_not_reported_as_no_resume() {
  local dir rc
  dir=$(make_case live-poll)
  printf '%s\n' "$OBSERVED_DIALOG" > "$dir/screen.txt"

  # A poll is already armed for an earlier obligation. The poll is fleet-wide,
  # so it watches obligations recorded after it was written, including the one
  # this dialog is about.
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" PATH="$dir/fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-quota-freeze.sh" add --subject pm --provider claude --action respawn >/dev/null \
    || fail "the setup freeze that arms the poll failed"

  # state/ becomes unwritable, so the freeze this dialog records lands in the
  # registry subdirectory but the poll cannot be refreshed. Nothing is lost: the
  # record is on disk and the live poll is watching it.
  chmod 0500 "$dir/home/state"
  set +e
  run_live "$dir" --provider claude > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  chmod 0700 "$dir/home/state"

  [ "$rc" -eq 0 ] \
    || fail "an answered dialog whose freeze is recorded and watched was not reported as done (exit $rc)"
  [ "$(cat "$dir/typed.txt")" = 1 ] || fail "the dialog was not answered"
  [ -f "$dir/home/state/quota-frozen/task-a" ] || fail "the freeze was not recorded"
  case "$(cat "$dir/err")" in
    *'no resume was armed'*)
      fail "a recorded obligation a live poll is watching was reported as having no resume" ;;
  esac
  pass "an answered dialog whose freeze is recorded and already watched reports success, not a missing resume"
}

test_a_recorded_freeze_with_no_poll_armed_is_reported_apart_from_a_missing_record() {
  local dir rc
  dir=$(make_case unwatched-freeze)
  printf '%s\n' "$OBSERVED_DIALOG" > "$dir/screen.txt"
  # The registry directory exists so the record can still land, but no poll is
  # armed and state/ cannot be written, so none can be. The obligation is real
  # and unwatched, which is different work from a freeze that was never
  # recorded: re-arm the poll, never record the freeze again.
  mkdir -p "$dir/home/state/quota-frozen/.notified"
  chmod 0700 "$dir/home/state/quota-frozen" "$dir/home/state/quota-frozen/.notified"

  chmod 0500 "$dir/home/state"
  set +e
  run_live "$dir" --provider claude > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  chmod 0700 "$dir/home/state"

  [ "$rc" -eq 5 ] \
    || fail "a recorded but unwatched obligation did not get its own exit code (got $rc)"
  [ "$(cat "$dir/typed.txt")" = 1 ] || fail "the dialog was not answered"
  [ -f "$dir/home/state/quota-frozen/task-a" ] || fail "the freeze was not recorded"
  assert_contains "$(cat "$dir/err")" 'do not record the freeze again' \
    "the report did not distinguish a recorded obligation from an unrecorded one"
  pass "a recorded obligation with no poll armed is reported apart from a freeze that was never recorded"
}

test_answering_without_a_provider_still_answers_but_reports_no_resume() {
  local dir rc
  dir=$(make_case no-provider)
  printf '%s\n' "$OBSERVED_DIALOG" > "$dir/screen.txt"

  set +e
  run_live "$dir" > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  [ "$rc" -eq 4 ] || fail "a missing provider did not produce the dedicated exit code (got $rc)"
  [ "$(cat "$dir/typed.txt")" = 1 ] || fail "the dialog was not answered without a provider"
  assert_contains "$(cat "$dir/err")" 'no resume was armed' \
    "the missing resume was not reported"
  [ ! -e "$dir/home/state/quota-frozen/task-a" ] \
    || fail "a freeze was recorded without an established provider"
  pass "without an established provider the dialog is still answered and the missing resume is reported"
}

test_close_variants_of_the_waiting_option_are_still_recognized() {
  local dir out variant screen n=0
  dir=$(make_case wait-variants)
  # The allowlist has to be narrow without being a transcript of one harness:
  # seven harnesses word this differently, and an allowlist that only knows the
  # single observed sentence would refuse real dialogs it is meant to answer.
  while IFS= read -r variant; do
    [ -n "$variant" ] || continue
    n=$((n + 1))
    screen="$dir/variant-$n.txt"
    printf 'Usage limit reached.\n1. %s\n2. Upgrade to Max for higher limits\n' \
      "$variant" > "$screen"
    out=$(run_detect "$dir" "$screen") \
      || fail "a close variant of the waiting option was not recognized: $variant"
    assert_contains "$out" 'wait-option: 1' "the waiting option was not identified in: $variant"
  done <<'VARIANTS'
Stop and wait for the limit to reset
Wait for the limit to reset
Wait for reset
Wait until the usage limit resets
Pause and wait for the limit to reset, then continue
VARIANTS
  pass "close variants of the wait-for-reset option are recognized, not just the one observed sentence"
}

test_an_unrecognized_option_is_never_typed_into_the_pane() {
  local dir rc name err
  dir=$(make_case unrecognized)

  # Neither of these carries a word any denylist of paid phrasings knows, and
  # that is the point: the boundary must not depend on having anticipated the
  # wording. Each keeps working NOW and settles up later, which is spending.
  cat > "$dir/overage.txt" <<'T'
Usage limit reached for this window.
1. Skip the wait and keep going at standard overage rates until the limit resets
2. Something else entirely
T
  cat > "$dir/metered.txt" <<'T'
You have reached your usage limit.
1. Continue immediately; further usage this cycle is charged to your workspace
2. Do nothing for now
T

  for name in overage metered; do
    cp "$dir/$name.txt" "$dir/screen.txt"
    : > "$dir/typed.txt"
    : > "$dir/tmux.log"
    set +e
    run_live "$dir" --provider claude > "$dir/$name.out" 2> "$dir/$name.err"
    rc=$?
    set -e
    err=$(cat "$dir/$name.err")
    [ "$rc" -eq 3 ] \
      || fail "an unrecognized dialog '$name' did not refuse with exit 3 (got $rc): $err"
    [ ! -s "$dir/typed.txt" ] \
      || fail "an unrecognized dialog '$name' reached the endpoint: $(cat "$dir/typed.txt")"
    case "$(cat "$dir/tmux.log")" in
      *send-keys*) fail "an unrecognized dialog '$name' sent a key to the pane" ;;
    esac
    [ ! -e "$dir/home/state/quota-frozen/task-a" ] \
      || fail "an unrecognized dialog '$name' still recorded a freeze"
    # The refusal has to hand the dialog to a human as captured, not describe it.
    assert_contains "$err" "$(sed -n '2s/^1\. //p' "$dir/$name.txt")" \
      "the refusal for '$name' did not report the option text verbatim"
    assert_contains "$err" 'no key was sent' \
      "the refusal for '$name' did not state that nothing was sent"
  done
  pass "a plausibly worded option that is not a recognized wait choice is never typed into a live pane"
}

test_a_paywall_dialog_never_reaches_the_endpoint() {
  local dir rc
  dir=$(make_case paywall-live)
  cat > "$dir/screen.txt" <<'T'
You hit your weekly limit.
1. Upgrade to Pro
2. Buy more credits
T
  set +e
  run_live "$dir" --provider claude >/dev/null 2> "$dir/err"
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a paywall dialog did not refuse with exit 3 (got $rc)"
  [ ! -s "$dir/typed.txt" ] || fail "a paywall dialog produced a keystroke: $(cat "$dir/typed.txt")"
  [ ! -e "$dir/home/state/quota-frozen/task-a" ] \
    || fail "a refused dialog still recorded a freeze"
  pass "a paywall-only dialog produces no keystroke and no freeze"
}

test_a_saved_capture_cannot_answer_a_live_dialog() {
  local dir rc
  dir=$(make_case saved-capture)
  printf '%s\n' "$OBSERVED_DIALOG" > "$dir/screen.txt"
  set +e
  FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" \
    FM_TMUX_LOG="$dir/tmux.log" FM_TMUX_TYPED="$dir/typed.txt" \
    FM_TMUX_ANSWERED="$dir/answered" FM_TMUX_SCREEN="$dir/screen.txt" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$DIALOG" task-a --from-capture "$dir/screen.txt" --provider claude >/dev/null 2> "$dir/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a saved capture was allowed to answer a live dialog"
  [ ! -s "$dir/typed.txt" ] || fail "a saved capture produced a keystroke"
  pass "a saved screen is never used to answer a live dialog"
}

test_invalid_arguments_are_refused() {
  local dir rc args
  dir=$(make_case invalid)
  printf '%s\n' "$OBSERVED_DIALOG" > "$dir/screen.txt"
  while IFS= read -r args; do
    [ -n "$args" ] || continue
    set +e
    # shellcheck disable=SC2086 # args is intentionally word-split test data
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" \
      "$DIALOG" $args >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "invalid arguments accepted (exit $rc): $args"
  done <<'ARGS'
../escape --detect-only
task-a --action explode
task-a --lines 0
task-a --provider
task-a --provider CLAUDE
task-a --provider bad/provider
task-a --nonsense
ARGS
  [ ! -s "$dir/typed.txt" ] || fail "invalid arguments still produced a keystroke"
  pass "invalid arguments are refused before anything is captured or sent"
}

test_help_documents_the_safety_boundary() {
  local out
  out=$("$DIALOG" --help)
  assert_contains "$out" 'fm-limit-dialog.sh <task-id>' "help text missing the usage line"
  assert_contains "$out" 'The upgrade option is never selected' \
    "help text does not state the money boundary"
  assert_contains "$out" 'ALLOWLIST' \
    "help text does not state that selection is an allowlist rather than a paid-wording veto"
  assert_contains "$out" '--detect-only' "help text missing --detect-only documentation"
  pass "--help states the usage and the boundary that the paid option is never selected"
}

test_the_observed_dialog_is_recognized
test_an_ordinary_numbered_menu_is_not_a_limit_dialog
test_a_repainted_dialog_is_still_one_dialog
test_ambiguous_dialogs_send_nothing
test_answering_selects_wait_and_never_upgrade
test_a_pane_that_has_not_repainted_is_a_warning_not_a_failed_answer
test_an_unreadable_pane_after_a_confirmed_answer_is_a_warning_not_a_failure
test_a_freeze_that_cannot_be_recorded_reports_no_resume_not_the_child_code
test_a_recorded_freeze_a_live_poll_watches_is_not_reported_as_no_resume
test_a_recorded_freeze_with_no_poll_armed_is_reported_apart_from_a_missing_record
test_answering_without_a_provider_still_answers_but_reports_no_resume
test_close_variants_of_the_waiting_option_are_still_recognized
test_an_unrecognized_option_is_never_typed_into_the_pane
test_a_paywall_dialog_never_reaches_the_endpoint
test_a_saved_capture_cannot_answer_a_live_dialog
test_invalid_arguments_are_refused
test_help_documents_the_safety_boundary
