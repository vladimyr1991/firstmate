#!/usr/bin/env bash
# Behavior tests for bin/fm-retro.sh, the lessons-learned mechanics that run
# between confirmed landing and teardown.
#
# Everything here drives the real CLI against synthetic state/ and data/
# fixtures and asserts through generated output only.
#
# Cases:
#   (a) signal counting from a crafted status log (verbs, keys, open decisions)
#   (b) evaluation rounds, branch commit count, and elapsed wall-clock
#   (c) collect is idempotent and preserves an existing attestation
#   (d) complete is idempotent and unions repeated lesson keys
#   (e) verify refuses before complete, and complete refuses before collect
#   (f) --none is accepted, recorded, and cannot be mixed with lesson keys
#   (g) a non-slug lesson key is refused
#   (h) every artifact lands under data/, never under state/
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RETRO="$ROOT/bin/fm-retro.sh"
TMP_ROOT=$(fm_test_tmproot fm-retro)

# Build a home with state/ and data/ for one task. Echoes the home dir.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data/task-r1"
  printf '%s\n' "$home"
}

run_retro() {  # <home> <args>...
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$RETRO" "$@"
}

run_retro_expect_failure() {  # <home> <expected-fragment> <args>...
  local home=$1 expected=$2 out rc
  shift 2
  set +e
  out=$(run_retro "$home" "$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected a refusal containing '$expected', got success: $out"
  assert_contains "$out" "$expected" "refusal did not explain '$expected'"
}

# Read one key from the facts block of a task's retro record.
fact() {  # <home> <key>
  sed -n "s/^$2=//p" "$1/data/task-r1/retro.md" | tail -1
}

write_meta_fixture() {  # <home>
  fm_write_meta "$1/state/task-r1.meta" \
    "window=firstmate:fm-task-r1" \
    "worktree=$1/wt" \
    "project=$1/project" \
    "harness=claude" \
    "model=opus" \
    "effort=high" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "backend=tmux" \
    "pr=https://github.com/example/repo/pull/9"
}

test_collect_counts_status_signals() {
  local home
  home=$(make_home signals)
  write_meta_fixture "$home"
  cat > "$home/state/task-r1.status" <<'EOF'
working: setup done

needs-decision [key=api-shape]: keep or replace the adapter
resolved [key=api-shape]: replace it
blocked: credential missing for the staging bot
paused: waiting on the vendor rate-limit reset
needs-decision: which environment owns the secret
done: PR checks green
EOF

  run_retro "$home" collect task-r1 >/dev/null || fail "collect failed on a crafted status log"

  [ "$(fact "$home" status_lines)" = 7 ] \
    || fail "blank lines must not be counted: got $(fact "$home" status_lines)"
  [ "$(fact "$home" needs_decision_events)" = 2 ] \
    || fail "needs-decision events miscounted: $(fact "$home" needs_decision_events)"
  [ "$(fact "$home" blocked_events)" = 1 ] \
    || fail "blocked events miscounted: $(fact "$home" blocked_events)"
  [ "$(fact "$home" resolved_events)" = 1 ] \
    || fail "resolved events miscounted: $(fact "$home" resolved_events)"
  [ "$(fact "$home" paused_events)" = 1 ] \
    || fail "paused events miscounted: $(fact "$home" paused_events)"
  [ "$(fact "$home" decision_keys)" = "api-shape,default" ] \
    || fail "distinct decision keys wrong: $(fact "$home" decision_keys)"
  # api-shape was resolved; the bare blocked/needs-decision pair folds to one
  # still-open `default` decision.
  [ "$(fact "$home" open_decisions)" = 1 ] \
    || fail "open decisions wrong: $(fact "$home" open_decisions)"
  [ "$(fact "$home" mode)" = no-mistakes ] || fail "mode not carried from meta"
  [ "$(fact "$home" harness)" = claude ] || fail "harness not carried from meta"
  [ "$(fact "$home" pr)" = "https://github.com/example/repo/pull/9" ] \
    || fail "pr not carried from meta"
  pass "collect counts decision, blocked, and pause signals and carries metadata fields"
}

test_collect_counts_rounds_commits_and_elapsed() {
  local home now
  home=$(make_home rounds)
  fm_git_init_commit "$home/project"
  git -C "$home/project" branch -M main
  git -C "$home/project" worktree add -q -b fm/task-r1 "$home/wt" main
  git -C "$home/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
  git -C "$home/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
  fm_write_meta "$home/state/task-r1.meta" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'done: landed\n' > "$home/state/task-r1.status"
  touch "$home/data/task-r1/evaluation-1.md" "$home/data/task-r1/evaluation-2.md" \
    "$home/data/task-r1/evaluation-3.md"
  now=$(date -u +%s)
  touch -t "$(date -u -r $((now - 7200)) +%Y%m%d%H%M.%S 2>/dev/null \
    || date -u -d "@$((now - 7200))" +%Y%m%d%H%M.%S)" "$home/data/task-r1/brief.md"

  run_retro "$home" collect task-r1 >/dev/null || fail "collect failed on a real worktree"

  [ "$(fact "$home" evaluation_rounds)" = 3 ] \
    || fail "evaluation rounds miscounted: $(fact "$home" evaluation_rounds)"
  [ "$(fact "$home" branch)" = "fm/task-r1" ] \
    || fail "branch not resolved: $(fact "$home" branch)"
  [ "$(fact "$home" commits)" = 2 ] \
    || fail "commits on the task branch miscounted: $(fact "$home" commits)"
  [ "$(fact "$home" dispatch_source)" = "data/task-r1/brief.md" ] \
    || fail "dispatch timestamp provenance wrong: $(fact "$home" dispatch_source)"
  [ "$(fact "$home" elapsed_seconds)" -ge 7000 ] \
    || fail "elapsed wall-clock wrong: $(fact "$home" elapsed_seconds)"
  pass "collect counts evaluation rounds, branch commits, and dispatch-to-landing wall-clock"
}

test_collect_records_unknown_rather_than_guessing() {
  local home
  home=$(make_home unknowns)
  fm_write_meta "$home/state/task-r1.meta" "kind=ship" "mode=no-mistakes"
  printf 'done: landed\n' > "$home/state/task-r1.status"

  run_retro "$home" collect task-r1 >/dev/null || fail "collect failed without a worktree"

  [ "$(fact "$home" commits)" = unknown ] || fail "an unresolvable commit count must be unknown"
  [ "$(fact "$home" branch)" = unknown ] || fail "an unresolvable branch must be unknown"
  [ "$(fact "$home" project)" = unknown ] || fail "an absent meta field must be unknown"
  [ "$(fact "$home" decision_keys)" = none ] || fail "an empty decision-key set must read none"
  pass "an unavailable fact is recorded as unknown instead of guessed"
}

test_collect_and_complete_are_idempotent() {
  local home first second
  home=$(make_home idempotent)
  write_meta_fixture "$home"
  printf 'done: landed\n' > "$home/state/task-r1.status"

  run_retro "$home" collect task-r1 >/dev/null || fail "first collect failed"
  run_retro "$home" complete task-r1 delete-test-messages >/dev/null || fail "first complete failed"
  first=$(sed 's/^collected_epoch=.*/collected_epoch=X/; s/^attested_epoch=.*/attested_epoch=X/' \
    "$home/data/task-r1/retro.md")

  run_retro "$home" collect task-r1 >/dev/null || fail "re-collect failed"
  run_retro "$home" complete task-r1 delete-test-messages >/dev/null || fail "re-complete failed"
  second=$(sed 's/^collected_epoch=.*/collected_epoch=X/; s/^attested_epoch=.*/attested_epoch=X/' \
    "$home/data/task-r1/retro.md")

  [ "$first" = "$second" ] || fail "re-running collect and complete changed the record"
  run_retro "$home" verify task-r1 >/dev/null || fail "verify failed after idempotent reruns"

  run_retro "$home" complete task-r1 prefer-existence-probe >/dev/null \
    || fail "adding a second lesson key failed"
  assert_grep "lesson_keys=delete-test-messages,prefer-existence-probe" \
    "$home/data/task-r1/retro.md" "later lesson keys must union with earlier ones"

  # A re-collect after attestation must not erase the attestation.
  run_retro "$home" collect task-r1 >/dev/null || fail "collect after attestation failed"
  assert_grep "lessons_reviewed=1" "$home/data/task-r1/retro.md" \
    "re-collect erased the attestation it must preserve"
  pass "collect and complete are idempotent and never clobber each other"
}

test_verify_refuses_before_complete() {
  local home out
  home=$(make_home ordering)
  write_meta_fixture "$home"
  printf 'done: landed\n' > "$home/state/task-r1.status"

  run_retro_expect_failure "$home" "has no retro record" verify task-r1
  run_retro_expect_failure "$home" "run: bin/fm-retro.sh collect" complete task-r1 --none

  run_retro "$home" collect task-r1 >/dev/null || fail "collect failed"
  run_retro_expect_failure "$home" "has no lessons-learned attestation" verify task-r1

  out=$(run_retro "$home" complete task-r1 --none) || fail "complete --none failed"
  assert_contains "$out" "lessons reviewed (none)" "complete --none did not report its outcome"
  out=$(run_retro "$home" verify task-r1) || fail "verify failed after complete --none"
  assert_contains "$out" "verified: task-r1 lessons-learned attestation" \
    "verify did not report the attestation it read"
  assert_grep "lesson_keys=none" "$home/data/task-r1/retro.md" \
    "an explicit --none must be recorded, not left as silence"
  pass "verify refuses until complete runs, and --none is an accepted explicit attestation"
}

test_invalid_input_is_refused() {
  local home
  home=$(make_home invalid)
  write_meta_fixture "$home"
  printf 'done: landed\n' > "$home/state/task-r1.status"
  run_retro "$home" collect task-r1 >/dev/null || fail "collect failed"

  run_retro_expect_failure "$home" "lesson-key must be a non-empty privacy-safe slug" \
    complete task-r1 'not a slug'
  run_retro_expect_failure "$home" "lesson-key must be a non-empty privacy-safe slug" \
    complete task-r1 'captain@example.com'
  run_retro_expect_failure "$home" "--none cannot be combined with lesson keys" \
    complete task-r1 --none some-lesson
  run_retro_expect_failure "$home" "origin-id must be a non-empty privacy-safe slug" \
    collect '../escape'
  assert_no_grep "lessons_reviewed=1" "$home/data/task-r1/retro.md" \
    "a refused attestation must not be recorded"
  pass "non-slug lesson keys, mixed --none, and unsafe task ids are refused"
}

test_artifacts_live_under_data() {
  local home leaked
  home=$(make_home placement)
  write_meta_fixture "$home"
  printf 'done: landed\n' > "$home/state/task-r1.status"

  run_retro "$home" collect task-r1 >/dev/null || fail "collect failed"
  run_retro "$home" complete task-r1 one-lesson >/dev/null || fail "complete failed"

  assert_present "$home/data/task-r1/retro.md" "the retro record must live under data/"
  leaked=$(find "$home/state" -name '*retro*' -o -name '*lesson*' | head -5)
  [ -z "$leaked" ] || fail "retro artifacts leaked into state/, which teardown erases: $leaked"
  assert_no_grep "lessons_reviewed" "$home/state/task-r1.meta" \
    "the attestation must never be written into task metadata, which teardown deletes"
  pass "every retro artifact lands under data/ and none under state/"
}

test_collect_refuses_an_unknown_task() {
  local home
  home=$(make_home unknown-task)
  run_retro_expect_failure "$home" "is not owned by the active home" collect task-r9
  pass "collect refuses a task this home does not own"
}

test_collect_counts_status_signals
test_collect_counts_rounds_commits_and_elapsed
test_collect_records_unknown_rather_than_guessing
test_collect_and_complete_are_idempotent
test_verify_refuses_before_complete
test_invalid_input_is_refused
test_artifacts_live_under_data
test_collect_refuses_an_unknown_task
