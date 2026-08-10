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
    if [ -e "$FM_TMUX_ANSWERED" ]; then
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
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'J'
{"schemaVersion":3,"providers":[
 {"provider":"claude","state":{"stale":false},"windows":[
   {"id":"five_hour","percentRemaining":0,"resetsAt":"2026-08-10T17:30:00.801838+00:00"}]}]}
J
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
  assert_contains "$out" '--detect-only' "help text missing --detect-only documentation"
  pass "--help states the usage and the boundary that the paid option is never selected"
}

test_the_observed_dialog_is_recognized
test_an_ordinary_numbered_menu_is_not_a_limit_dialog
test_a_repainted_dialog_is_still_one_dialog
test_ambiguous_dialogs_send_nothing
test_answering_selects_wait_and_never_upgrade
test_answering_without_a_provider_still_answers_but_reports_no_resume
test_a_paywall_dialog_never_reaches_the_endpoint
test_a_saved_capture_cannot_answer_a_live_dialog
test_invalid_arguments_are_refused
test_help_documents_the_safety_boundary
