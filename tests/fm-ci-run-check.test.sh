#!/usr/bin/env bash
# Behavior tests for bin/fm-ci-run-check.sh and the generated per-task raw
# GitHub Actions run poll it arms (bin/fm-ci-run-lib.sh). Covers registration
# (private sidecar plus a properly hash-bound custom check), in-progress
# silence, a terminal-state wake line through both the generated check
# directly and the real watcher custom-check dispatch, and the
# interrupted-retirement / already-terminal recovery case, all exercised
# through the scripts' actual interfaces rather than by inspecting source
# bytes.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-check-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-ci-run-lib.sh"

CI_CHECK="$ROOT/bin/fm-ci-run-check.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-run-check)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

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

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case " $* " in
  *" --json status,conclusion "*)
    [ "${FM_TEST_GH_FAIL:-0}" = 0 ] || exit 1
    [ "${FM_TEST_GH_SLEEP:-0}" = 0 ] || sleep "$FM_TEST_GH_SLEEP"
    printf '%s\n' "${FM_TEST_GH_RESULT-}"
    ;;
esac
SH
  chmod +x "$fakebin/gh"
  : > "$dir/gh.log"
  printf '%s\n' "$dir"
}

write_task_meta() {
  local dir=$1 id=${2:-task-a}
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "kind=ship" \
    "mode=local-only"
}

run_ci_check() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" \
    "$CI_CHECK" "$@"
}

run_generated_check() {
  local dir=$1 id=${2:-task-a}
  FM_TEST_GH_LOG="$dir/gh.log" PATH="$dir/fakebin:$BASE_PATH" \
    bash "$dir/home/state/$id.check.sh"
}

# fm-guard.sh is not on the exercised path for this entrypoint, but
# FM_ROOT_OVERRIDE must still resolve to a real firstmate root; reuse ROOT.
setup_root() {
  local dir=$1
  ln -s "$ROOT" "$dir/root"
}

test_registration_records_sidecar_and_arms_check() {
  local dir out rc
  dir=$(make_case registration)
  setup_root "$dir"
  write_task_meta "$dir"

  out=$(run_ci_check "$dir" task-a myorg/myrepo 123456) || fail "valid registration failed"
  [ "$out" = 'armed: state/task-a.check.sh' ] || fail "registration did not print the expected armed line"

  [ "$(cat "$dir/home/state/task-a.ci-run-poll")" = $'github\nmyorg/myrepo\n123456' ] \
    || fail "sidecar bytes were not exact"
  [ "$(file_mode "$dir/home/state/task-a.ci-run-poll")" = 600 ] || fail "sidecar mode was not 0600"
  [ "$(file_mode "$dir/home/state/task-a.check.sh")" = 700 ] || fail "check mode was not 0700"
  [ "$(file_mode "$dir/home/state/task-a.check-trust")" = 600 ] || fail "trust mode was not 0600"
  [ "$(fm_pr_file_link_count "$dir/home/state/task-a.check.sh")" = 1 ] \
    && [ "$(fm_pr_file_link_count "$dir/home/state/task-a.ci-run-poll")" = 1 ] \
    && [ "$(fm_pr_file_link_count "$dir/home/state/task-a.check-trust")" = 1 ] \
    || fail "published artifacts were not single-link files"
  fm_custom_check_registered "$dir/home/state" task-a \
    || fail "generated check was not a properly registered custom check"
  fm_ci_run_poll_artifacts_valid "$dir/home/state" task-a \
    || fail "published poll artifacts did not validate as a whole"
  bash -n "$dir/home/state/task-a.check.sh" || fail "generated check was not syntactically valid bash"

  set +e
  run_ci_check "$dir" task-a myorg/myrepo 999999 >/dev/null 2>/dev/null
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "re-registration over a still-armed poll failed"
  [ "$(cat "$dir/home/state/task-a.ci-run-poll")" = $'github\nmyorg/myrepo\n999999' ] \
    || fail "re-registration did not replace the sidecar with the new run id"

  pass "registration records an exact sidecar and arms a validly registered custom check"
}

test_help_documents_usage() {
  local out
  out=$("$CI_CHECK" --help)
  assert_contains "$out" 'fm-ci-run-check.sh <task-id> <repo> <run-id>' "help text missing usage line"
  assert_contains "$out" '--forge' "help text missing --forge documentation"
  pass "--help documents exact usage"
}

test_invalid_inputs_have_zero_side_effects() {
  local dir before after rc
  dir=$(make_case invalid-inputs)
  setup_root "$dir"
  write_task_meta "$dir"
  before=$(state_snapshot "$dir/home/state")

  for args in \
    'task-a not-a-repo 123' \
    'task-a myorg/myrepo abc' \
    'task-a myorg/myrepo 0123' \
    'task-a myorg/myrepo 0' \
    'task-a myorg/myrepo -1' \
    '../escape myorg/myrepo 123' \
    'task-a myorg/myrepo 123 --forge gitlab' \
    'task-a myorg/myrepo' \
    'task-a myorg/myrepo 123 extra'
  do
    set +e
    # shellcheck disable=SC2086 # args is intentionally word-split test data
    run_ci_check "$dir" $args >/dev/null 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "invalid input accepted: $args"
  done

  set +e
  run_ci_check "$dir" no-such-task myorg/myrepo 123 >/dev/null 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "registration accepted a task id with no live metadata"

  after=$(state_snapshot "$dir/home/state")
  [ "$after" = "$before" ] || fail "invalid or refused input changed state"
  [ ! -s "$dir/gh.log" ] || fail "invalid input reached gh"
  pass "invalid CI run check input is refused before any side effect"
}

test_check_is_silent_while_in_progress_or_on_error() {
  local dir out
  dir=$(make_case in-progress)
  setup_root "$dir"
  write_task_meta "$dir"
  run_ci_check "$dir" task-a myorg/myrepo 42 >/dev/null || fail "registration failed"

  out=$(FM_TEST_GH_RESULT='' run_generated_check "$dir")
  [ -z "$out" ] || fail "check emitted output for an in-progress run"
  [ -e "$dir/home/state/task-a.check.sh" ] || fail "in-progress poll retired itself"

  out=$(FM_TEST_GH_FAIL=1 run_generated_check "$dir")
  [ -z "$out" ] || fail "check emitted output after a gh failure"
  [ -e "$dir/home/state/task-a.check.sh" ] || fail "a failed lookup retired the poll"

  out=$(FM_TEST_GH_RESULT='success;drop' run_generated_check "$dir")
  [ -z "$out" ] || fail "check emitted output for a malformed conclusion"
  [ -e "$dir/home/state/task-a.check.sh" ] || fail "a malformed conclusion retired the poll"

  pass "the armed check stays silent while the run is in progress or unreadable"
}

test_check_fires_once_and_retires() {
  local dir out
  dir=$(make_case fires-once)
  setup_root "$dir"
  write_task_meta "$dir"
  run_ci_check "$dir" task-a myorg/myrepo 42 >/dev/null || fail "registration failed"

  out=$(FM_TEST_GH_RESULT=success run_generated_check "$dir")
  [ "$out" = success ] || fail "terminal check did not emit exactly one conclusion line"
  [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "fired poll did not remove its check"
  [ ! -e "$dir/home/state/task-a.check-trust" ] || fail "fired poll did not remove its trust binding"
  [ ! -e "$dir/home/state/task-a.ci-run-poll" ] || fail "fired poll did not remove its sidecar"
  [ ! -e "$dir/home/state/task-a.ci-run-poll-retirement" ] || fail "fired poll left its receipt behind"
  [ -f "$dir/home/state/task-a.meta" ] || fail "retirement removed unrelated task metadata"

  dir=$(make_case fires-once-failure)
  setup_root "$dir"
  write_task_meta "$dir"
  run_ci_check "$dir" task-a myorg/myrepo 7 >/dev/null || fail "registration failed"
  out=$(FM_TEST_GH_RESULT=failure run_generated_check "$dir")
  [ "$out" = failure ] || fail "a failed run's conclusion was not reported exactly"

  pass "the armed check fires exactly one conclusion line then retires every artifact"
}

test_watcher_dispatch_delivers_exactly_one_wake() {
  local dir rc
  dir=$(make_case watcher-dispatch)
  setup_root "$dir"
  write_task_meta "$dir"
  run_ci_check "$dir" task-a myorg/myrepo 42 >/dev/null || fail "registration failed"

  set +e
  FM_TEST_GH_RESULT=success \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=5 \
    FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 PATH="$dir/fakebin:$BASE_PATH" \
    perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 10; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "watcher did not exit cleanly after an actionable wake: $(cat "$dir/watch.err")"
  [ "$(grep -c '^check: .*: success$' "$dir/watch.out")" -eq 1 ] \
    || fail "watcher did not surface exactly one conclusion wake: $(cat "$dir/watch.out")"
  [ ! -e "$dir/home/state/task-a.check.sh" ] \
    || fail "real watcher dispatch left the fired poll armed"

  pass "the real watcher custom-check dispatch delivers exactly one wake then the poll is gone"
}

test_interrupted_retirement_recovers_without_duplicate_wake() {
  local dir out
  dir=$(make_case interrupted-retirement)
  setup_root "$dir"
  write_task_meta "$dir"
  run_ci_check "$dir" task-a myorg/myrepo 42 >/dev/null || fail "registration failed"

  # Simulate a prior execution that claimed the receipt and printed its one
  # wake line, then was killed before it finished removing every artifact.
  printf 'success\n' > "$dir/home/state/task-a.ci-run-poll-retirement"
  chmod 0600 "$dir/home/state/task-a.ci-run-poll-retirement"

  out=$(run_generated_check "$dir")
  [ -z "$out" ] || fail "recovery execution reported the result a second time"
  [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "recovery execution left the check armed"
  [ ! -e "$dir/home/state/task-a.check-trust" ] || fail "recovery execution left the trust binding"
  [ ! -e "$dir/home/state/task-a.ci-run-poll" ] || fail "recovery execution left the sidecar"
  [ ! -e "$dir/home/state/task-a.ci-run-poll-retirement" ] || fail "recovery execution left its own receipt"

  pass "a leftover receipt from an interrupted retirement finishes cleanup without a duplicate wake"
}

test_registration_recovers_leftover_retirement_before_arming() {
  local dir
  dir=$(make_case registration-recovery)
  setup_root "$dir"
  write_task_meta "$dir"
  run_ci_check "$dir" task-a myorg/myrepo 42 >/dev/null || fail "first registration failed"

  # An earlier poll already fired and claimed its receipt but was interrupted
  # before finishing removal - simulate that exact leftover state.
  printf 'success\n' > "$dir/home/state/task-a.ci-run-poll-retirement"
  chmod 0600 "$dir/home/state/task-a.ci-run-poll-retirement"

  run_ci_check "$dir" task-a myorg/myrepo 555 >/dev/null \
    || fail "registration did not recover a leftover interrupted retirement"
  [ ! -e "$dir/home/state/task-a.ci-run-poll-retirement" ] \
    || fail "registration left the stale receipt in place"
  [ "$(cat "$dir/home/state/task-a.ci-run-poll")" = $'github\nmyorg/myrepo\n555' ] \
    || fail "registration after recovery did not arm the fresh run id"
  fm_custom_check_registered "$dir/home/state" task-a \
    || fail "registration after recovery did not leave a validly registered custom check"

  pass "a fresh registration recovers a leftover interrupted retirement before arming cleanly"
}

write_pr_poll_meta() {
  local dir=$1 id=${2:-task-a} url=${3:-https://github.com/my-org/my-repo/pull/7}
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=$url"
}

arm_pr_poll() {
  local dir=$1 id=${2:-task-a} url=${3:-https://github.com/my-org/my-repo/pull/7}
  (
    fm_pr_poll_prepare "$dir/home/state" "$id" github "$url" github.com my-org/my-repo 7 \
      "$ROOT/bin/fm-pr-poll.sh" || exit 1
    fm_pr_poll_publish_prepared
  )
}

test_refuses_to_replace_live_pr_merge_poll() {
  local dir before after rc
  dir=$(make_case pr-slot-refusal)
  setup_root "$dir"
  write_pr_poll_meta "$dir"
  arm_pr_poll "$dir" || fail "arming the PR merge poll fixture failed"
  fm_pr_poll_artifacts_valid "$dir/home/state" task-a "$ROOT/bin/fm-pr-poll.sh" \
    || fail "PR merge poll fixture did not validate as live"
  before=$(state_snapshot "$dir/home/state")

  set +e
  run_ci_check "$dir" task-a myorg/myrepo 42 >/dev/null 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "registration over a live PR merge poll did not refuse with exit 3"
  grep -q 'PR merge poll' "$dir/stderr" || fail "refusal did not name the PR merge poll owner"

  after=$(state_snapshot "$dir/home/state")
  [ "$after" = "$before" ] || fail "refused registration changed state"
  pass "registration refuses loudly instead of replacing a live PR merge poll"
}

test_stale_receipt_never_removes_a_foreign_check() {
  local dir rc
  dir=$(make_case stale-receipt-foreign-check)
  setup_root "$dir"
  write_pr_poll_meta "$dir"
  arm_pr_poll "$dir" || fail "arming the PR merge poll fixture failed"

  # A stale receipt from an earlier CI run poll whose slot has since been
  # re-armed as a PR merge poll: recovery must remove only the receipt.
  printf 'success\n' > "$dir/home/state/task-a.ci-run-poll-retirement"
  chmod 0600 "$dir/home/state/task-a.ci-run-poll-retirement"

  set +e
  run_ci_check "$dir" task-a myorg/myrepo 42 >/dev/null 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "registration did not still refuse over the live PR merge poll"
  [ ! -e "$dir/home/state/task-a.ci-run-poll-retirement" ] \
    || fail "recovery left the stale receipt in place"
  cmp -s "$ROOT/bin/fm-pr-poll.sh" "$dir/home/state/task-a.check.sh" \
    || fail "recovery removed or altered the PR merge poll's check"
  [ -e "$dir/home/state/task-a.pr-poll" ] && [ -e "$dir/home/state/task-a.pr-poll-registration" ] \
    || fail "recovery removed the PR merge poll's sidecar or registration"
  pass "a stale CI run receipt recovers without touching a check slot owned by another poll"
}

test_refuses_to_arm_without_gh() {
  local dir nogh bindir entry name before after rc
  dir=$(make_case no-gh)
  setup_root "$dir"
  write_task_meta "$dir"

  # The whole search path is mirrored without gh, because a real gh anywhere
  # on PATH would make this prove nothing.
  nogh="$dir/nogh"
  mkdir -p "$nogh"
  while IFS= read -r bindir; do
    [ -d "$bindir" ] || continue
    for entry in "$bindir"/*; do
      [ -e "$entry" ] || continue
      name=$(basename "$entry")
      [ "$name" = gh ] && continue
      [ -e "$nogh/$name" ] || ln -s "$entry" "$nogh/$name" 2>/dev/null
    done
  done <<EOF
$(printf '%s\n' "$BASE_PATH" | tr ':' '\n')
EOF
  ! PATH="$nogh" command -v gh >/dev/null 2>&1 \
    || fail "the gh-free search path still resolved gh"
  before=$(state_snapshot "$dir/home/state")

  set +e
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" PATH="$nogh" \
    "$CI_CHECK" task-a myorg/myrepo 42 >/dev/null 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming succeeded with gh absent from PATH"
  grep -q 'requires gh on PATH' "$dir/stderr" \
    || fail "arming with gh absent did not report the missing CLI"
  after=$(state_snapshot "$dir/home/state")
  [ "$after" = "$before" ] || fail "refused arming without gh changed state"
  [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "refused arming left a poll armed"

  pass "arming refuses loudly when gh is not on PATH instead of watching nothing"
}

test_terminal_result_is_reported_even_when_retirement_cannot_proceed() {
  local dir out
  dir=$(make_case print-before-claim)
  setup_root "$dir"
  write_task_meta "$dir"
  run_ci_check "$dir" task-a myorg/myrepo 42 >/dev/null || fail "registration failed"

  # Deny the check any write to state/: the receipt claim and every removal
  # fail, exactly like an interruption landing right after the print. The
  # wake line must still come out - it can never be gated on retirement work.
  chmod 0500 "$dir/home/state"
  out=$(FM_TEST_GH_RESULT=success run_generated_check "$dir" 2>/dev/null)
  chmod 0700 "$dir/home/state"
  [ "$out" = success ] || fail "terminal result was not reported when retirement could not proceed"
  [ -e "$dir/home/state/task-a.check.sh" ] && [ -e "$dir/home/state/task-a.ci-run-poll" ] \
    || fail "write-denied retirement somehow removed poll artifacts"
  [ ! -e "$dir/home/state/task-a.ci-run-poll-retirement" ] \
    || fail "write-denied retirement somehow claimed a receipt"
  [ -z "$(find "$dir/home/state" -name '.fm-ci-run-poll-retirement.*' -print)" ] \
    || fail "write-denied retirement left a receipt temporary behind"

  # With the receipt absent but check.sh and the sidecar still present, the
  # next execution re-reports the same terminal result rather than staying
  # silent, then finishes the retirement.
  out=$(FM_TEST_GH_RESULT=success run_generated_check "$dir")
  [ "$out" = success ] || fail "partially cleaned-up poll stayed silent instead of re-reporting"
  [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "re-report did not retire the check"
  [ ! -e "$dir/home/state/task-a.check-trust" ] || fail "re-report did not retire the trust binding"
  [ ! -e "$dir/home/state/task-a.ci-run-poll" ] || fail "re-report did not retire the sidecar"
  [ ! -e "$dir/home/state/task-a.ci-run-poll-retirement" ] || fail "re-report left its receipt behind"

  pass "a terminal result is printed before any retirement side effect and survives partial cleanup"
}

test_publish_failure_leaves_no_temp_files() {
  local dir rc
  dir=$(make_case publish-failure-temps)
  setup_root "$dir"
  write_task_meta "$dir"
  ln -s missing-target "$dir/home/state/task-a.ci-run-poll"

  set +e
  run_ci_check "$dir" task-a myorg/myrepo 42 >/dev/null 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "publication over a symlinked destination succeeded"
  [ -z "$(find "$dir/home/state" -name '.fm-ci-run-poll-*' -print)" ] \
    || fail "a failed registration left mktemp temporaries in state/"
  pass "a failed registration sweeps every staged temporary out of state/"
}

test_registration_records_sidecar_and_arms_check
test_help_documents_usage
test_invalid_inputs_have_zero_side_effects
test_check_is_silent_while_in_progress_or_on_error
test_check_fires_once_and_retires
test_watcher_dispatch_delivers_exactly_one_wake
test_interrupted_retirement_recovers_without_duplicate_wake
test_registration_recovers_leftover_retirement_before_arming
test_refuses_to_replace_live_pr_merge_poll
test_stale_receipt_never_removes_a_foreign_check
test_refuses_to_arm_without_gh
test_terminal_result_is_reported_even_when_retirement_cannot_proceed
test_publish_failure_leaves_no_temp_files
