#!/usr/bin/env bash
# Behavior tests for bin/fm-retro-backtest.sh, the blind backtest of the
# lessons-learned retrospective against the preserved 2026-08-11 stall.
#
# The property under test is isolation: the agent under test must see the
# procedure and the evidence, and must not see the expected answers. Every case
# drives the real CLI and asserts on generated output only. No case calls a
# model - the model run is the part a human triggers.
#
# Cases:
#   (a) check passes on the shipped fixtures/retro-backtest-0811 fixture
#   (b) the composed prompt carries the procedure and every evidence file
#   (c) the composed prompt names neither the sealed key nor the learnings file
#   (d) a sealed-key copy anywhere in the fixture refuses the run
#   (e) an evidence file that names the sealed key refuses the run
#   (f) a grader-facing README inside evidence/ refuses the run
#   (g) a fixture with no evidence directory refuses the run
#   (h) refusals happen before any model call, so they cost nothing
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKTEST="$ROOT/bin/fm-retro-backtest.sh"
FIXTURE="$ROOT/tests/fixtures/retro-backtest-0811"

# A scratch copy of the shipped fixture, so a mutation case never edits the
# committed one.
copy_fixture() {
  local dest
  dest=$(fm_test_tmproot fm-retro-backtest)/fixture
  mkdir -p "$dest"
  cp -R "$FIXTURE/." "$dest/"
  printf '%s\n' "$dest"
}

test_check_passes_on_the_shipped_fixture() {
  local out rc
  out=$("$BACKTEST" check 2>&1); rc=$?
  expect_code 0 "$rc" "check on the shipped fixture"
  assert_contains "$out" "isolation guards pass" "check should report passing guards"
  pass "check passes on the shipped fixture"
}

test_prompt_carries_procedure_and_all_evidence() {
  local out f
  out=$("$BACKTEST" prompt) || fail "prompt exited nonzero"
  assert_contains "$out" "Draft prompts" "prompt should carry the procedure's draft prompts"
  assert_contains "$out" "Routing" "prompt should carry the procedure's routing section"
  for f in "$FIXTURE"/evidence/*; do
    assert_contains "$out" "$(basename "$f")" "prompt should name evidence file $(basename "$f")"
  done
  assert_contains "$out" "absorbed stale" "prompt should carry the raw triage log lines"
  assert_contains "$out" "Tue Aug 11 11:04:49 2026" "prompt should carry the raw delivery log lines"
  pass "prompt carries the procedure and every evidence file"
}

test_prompt_names_no_answer_bearing_file() {
  local out
  out=$("$BACKTEST" prompt) || fail "prompt exited nonzero"
  assert_not_contains "$out" "SEALED-expected-answers" "prompt must not name the sealed key"
  assert_not_contains "$out" "data/learnings.md" "prompt must not name the learnings file"
  assert_not_contains "$out" "grading" "prompt must not discuss grading with the agent"
  pass "the composed prompt names no answer-bearing file"
}

test_sealed_key_copy_in_the_fixture_refuses() {
  local dest out rc
  dest=$(copy_fixture)
  printf 'anything\n' > "$dest/SEALED-expected-answers.md"
  out=$(FM_RETRO_BACKTEST_FIXTURE="$dest" "$BACKTEST" check 2>&1); rc=$?
  expect_code 1 "$rc" "check with a sealed key inside the fixture"
  assert_contains "$out" "answer-bearing file inside the fixture" "refusal should name the cause"
  pass "a sealed-key copy inside the fixture refuses the run"
}

test_evidence_naming_the_key_refuses() {
  local dest out rc
  dest=$(copy_fixture)
  printf 'see SEALED-expected-answers.md for the answers\n' >> "$dest/evidence/INCIDENT.md"
  out=$(FM_RETRO_BACKTEST_FIXTURE="$dest" "$BACKTEST" check 2>&1); rc=$?
  expect_code 1 "$rc" "check with evidence naming the key"
  assert_contains "$out" "names the sealed key" "refusal should name the cause"
  pass "an evidence file naming the sealed key refuses the run"
}

test_grader_readme_inside_evidence_refuses() {
  local dest out rc
  dest=$(copy_fixture)
  cp "$dest/README.md" "$dest/evidence/README.md"
  out=$(FM_RETRO_BACKTEST_FIXTURE="$dest" "$BACKTEST" check 2>&1); rc=$?
  expect_code 1 "$rc" "check with the grader README inside evidence/"
  assert_contains "$out" "evidence/" "refusal should name the misplaced file"
  pass "a grader-facing README inside evidence/ refuses the run"
}

test_missing_evidence_directory_refuses() {
  local dest out rc
  dest=$(copy_fixture)
  rm -rf "$dest/evidence"
  out=$(FM_RETRO_BACKTEST_FIXTURE="$dest" "$BACKTEST" check 2>&1); rc=$?
  expect_code 1 "$rc" "check with no evidence directory"
  assert_contains "$out" "no evidence directory" "refusal should name the cause"
  pass "a fixture with no evidence directory refuses the run"
}

test_refusal_precedes_any_model_call() {
  # A refusing run must not reach the agent, so it must not need the CLI at all:
  # emptying PATH of `claude` leaves the refusal unchanged.
  local dest out rc bin
  dest=$(copy_fixture)
  printf 'anything\n' > "$dest/SEALED-expected-answers.md"
  bin=$(fm_test_tmproot fm-retro-backtest-path)
  out=$(PATH="$bin:/usr/bin:/bin" FM_RETRO_BACKTEST_FIXTURE="$dest" \
    "$BACKTEST" run --out "$dest/run" 2>&1); rc=$?
  expect_code 1 "$rc" "run with a contaminated fixture and no claude on PATH"
  assert_contains "$out" "answer-bearing file inside the fixture" \
    "the fixture refusal should come before the missing-CLI complaint"
  assert_absent "$dest/run/stream.jsonl" "a refused run must leave no transcript"
  pass "a refusal precedes any model call"
}

test_check_passes_on_the_shipped_fixture
test_prompt_carries_procedure_and_all_evidence
test_prompt_names_no_answer_bearing_file
test_sealed_key_copy_in_the_fixture_refuses
test_evidence_naming_the_key_refuses
test_grader_readme_inside_evidence_refuses
test_missing_evidence_directory_refuses
test_refusal_precedes_any_model_call
