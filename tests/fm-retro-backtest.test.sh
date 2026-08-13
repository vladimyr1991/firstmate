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
#   (i) a procedure that names or paraphrases the incident under test refuses the run
#   (j) the key content scan reports whether it ran and over how many key lines, catches
#       any key line by number, and does not fire on the key's own quotations of the evidence
#   (k) a transcript containing a tool use is refused however it is spelled or nested,
#       and its answer is quarantined rather than left looking clean
#   (l) a transcript that cannot be parsed, or that carries no answer at all, is refused
#       rather than cleared
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKTEST="$ROOT/bin/fm-retro-backtest.sh"
FIXTURE="$ROOT/tests/fixtures/retro-backtest-0811"

# Every case runs against a scratch home unless it seeds a key of its own, so no case reads the
# operator's private sealed key: a suite whose outcome depends on a file that exists on exactly
# one machine is not a suite.
FM_HOME=$(fm_test_tmproot fm-retro-backtest-scratch-home)
mkdir -p "$FM_HOME"
export FM_HOME

# A scratch copy of the shipped fixture, so a mutation case never edits the
# committed one.
copy_fixture() {
  local dest
  dest=$(fm_test_tmproot fm-retro-backtest)/fixture
  mkdir -p "$dest"
  cp -R "$FIXTURE/." "$dest/"
  printf '%s\n' "$dest"
}

# A scratch copy of the shipped procedure, for the cases that must edit it. The committed
# skill is never touched, so a leak case cannot become a leak.
copy_procedure() {
  local dest
  dest=$(fm_test_tmproot fm-retro-backtest-procedure)/procedure
  mkdir -p "$dest"
  cp "$ROOT/.agents/skills/lessons-learned/SKILL.md" "$dest/SKILL.md"
  printf '%s\n' "$dest/SKILL.md"
}

# A fake claude that ignores the prompt and emits the transcript the case needs, so a
# transcript-inspection case drives the real run path without calling a model.
fake_claude() {
  local body=$1 bin
  bin=$(fm_fakebin "$(fm_test_tmproot fm-retro-backtest-claude)")
  {
    printf '#!/usr/bin/env bash\ncat >/dev/null\n'
    printf 'cat <<%s\n%s\n%s\n' "'STREAM'" "$body" "STREAM"
  } > "$bin/claude"
  chmod +x "$bin/claude"
  printf '%s\n' "$bin"
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

test_procedure_naming_the_incident_refuses() {
  # The procedure is composed verbatim into the prompt, so a provenance note added to it
  # hands the agent the incident it is being tested on.
  local procedure out rc
  procedure=$(copy_procedure)
  printf '\nPrompt 7 came from the blind backtest of the 2026-08-11 fleet stall.\n' >> "$procedure"
  out=$(FM_RETRO_BACKTEST_PROCEDURE="$procedure" "$BACKTEST" check 2>&1); rc=$?
  expect_code 1 "$rc" "check with a procedure that names the incident"
  assert_contains "$out" "names the incident under test" "refusal should name the cause"
  assert_contains "$out" "2026-08-11 fleet stall" "refusal should quote the offending line"
  pass "a procedure that names the incident refuses the run"
}

test_procedure_paraphrasing_the_incident_refuses() {
  # A note that never states the date leaks just as much, so the marker set covers the
  # incident's own vocabulary too.
  local procedure out rc
  procedure=$(copy_procedure)
  printf '\nPrompt 8 came from the morning one session limit stopped three workers.\n' >> "$procedure"
  out=$(FM_RETRO_BACKTEST_PROCEDURE="$procedure" "$BACKTEST" check 2>&1); rc=$?
  expect_code 1 "$rc" "check with a procedure that paraphrases the incident"
  assert_contains "$out" "names the incident under test" "refusal should name the cause"
  pass "a procedure that paraphrases the incident refuses the run"
}

test_prompt_refuses_before_composing_when_the_procedure_leaks() {
  local procedure out rc
  procedure=$(copy_procedure)
  printf '\nSee the retro-backtest-0811 fixture for what this found.\n' >> "$procedure"
  out=$(FM_RETRO_BACKTEST_PROCEDURE="$procedure" "$BACKTEST" prompt 2>&1); rc=$?
  expect_code 1 "$rc" "prompt with a procedure that names the fixture"
  assert_not_contains "$out" "THE PROCEDURE" "a leaking procedure must not be composed at all"
  pass "prompt refuses a leaking procedure instead of printing it"
}

test_key_content_scan_reports_that_it_was_skipped() {
  local home out rc
  home=$(fm_test_tmproot fm-retro-backtest-home)
  out=$(FM_HOME="$home" "$BACKTEST" check 2>&1); rc=$?
  expect_code 0 "$rc" "check with no readable key"
  assert_contains "$out" "key content scan: skipped" \
    "a skipped content scan must say so rather than read as a pass"
  assert_contains "$out" "$home/data" "the skip should name the path the key was sought at"
  pass "the key content scan reports that it was skipped"
}

# A scratch home carrying a two-line sealed key, so the content scan has something to scan
# on a machine that is not the operator's.
seed_key() {
  local home
  home=$(fm_test_tmproot fm-retro-backtest-key)
  mkdir -p "$home/data/retro-backtest-0811"
  cat > "$home/data/retro-backtest-0811/SEALED-expected-answers.md" <<'KEY'
First expected answer of the key, stated at length so that the scan has a usable marker.
Second expected answer of the key, also stated at length so that it too gives the scan one.
Mon Aug 10 21:36:50 2026  ->  signal: $FM_HOME/state/parlino-telegram-verify.turn-ended
KEY
  printf '%s\n' "$home"
}

# A scratch home whose key is ordinary Markdown: headings, bullets, and a blockquote, none of
# which the marker discriminator can use.
seed_markerless_key() {
  local home
  home=$(fm_test_tmproot fm-retro-backtest-markerless)
  mkdir -p "$home/data/retro-backtest-0811"
  cat > "$home/data/retro-backtest-0811/SEALED-expected-answers.md" <<'KEY'
# Expected answers

- the first expected answer, written as a bullet rather than as a bare sentence of prose
- the second expected answer, also written as a bullet and also comfortably past sixty chars

> quoted evidence that justifies the verdicts above and is therefore never usable as a marker
KEY
  printf '%s\n' "$home"
}

test_markerless_key_reports_an_inconclusive_scan() {
  # A key that yields no usable marker compared nothing, and must not report that it ran.
  local home dest out rc
  home=$(seed_markerless_key)
  dest=$(copy_fixture)
  out=$(FM_HOME="$home" FM_RETRO_BACKTEST_FIXTURE="$dest" "$BACKTEST" check 2>&1); rc=$?
  expect_code 0 "$rc" "check with a key that yields no marker"
  assert_contains "$out" "key content scan: inconclusive" \
    "a scan that compared nothing must not report that it ran"
  assert_not_contains "$out" "key content scan: ran against" \
    "an inconclusive scan must not read as a completed one"
  pass "a markerless key reports an inconclusive scan"
}

test_any_key_line_repeated_in_the_evidence_refuses() {
  # Not only the key's first substantial line: a copy that reworded that one line would
  # otherwise walk past the scan.
  local home dest out rc
  home=$(seed_key)
  dest=$(copy_fixture)
  printf 'Second expected answer of the key, also stated at length so that it too gives the scan one.\n' \
    >> "$dest/evidence/INCIDENT.md"
  out=$(FM_HOME="$home" FM_RETRO_BACKTEST_FIXTURE="$dest" "$BACKTEST" check 2>&1); rc=$?
  expect_code 1 "$rc" "check with the key's second line inside the evidence"
  assert_contains "$out" "repeats sealed key line 2" "refusal should point at the key by line"
  assert_not_contains "$out" "Second expected answer of the key" \
    "a refusal must never print the key's own text"
  pass "any repeated key line inside the evidence refuses the run"
}

test_key_quoting_the_evidence_does_not_refuse() {
  # The key's third line is a verbatim copy of a delivery log line, so its first 64 characters
  # do appear in the fixture: only the quotation discriminator keeps this clean fixture from
  # being refused on the one machine that can run the graded test.
  local home dest out rc
  home=$(seed_key)
  dest=$(copy_fixture)
  grep -qF 'Mon Aug 10 21:36:50 2026  ->  signal:' "$dest/evidence/watch-deliveries-0810-0811.log" \
    || fail "the seeded key line must be a verbatim quotation of the shipped evidence"
  out=$(FM_HOME="$home" FM_RETRO_BACKTEST_FIXTURE="$dest" "$BACKTEST" check 2>&1); rc=$?
  expect_code 0 "$rc" "check with a key that quotes the evidence"
  assert_contains "$out" "key content scan: ran against" "the scan should report that it ran"
  assert_contains "$out" "2 key line(s) compared" \
    "the report should say how many key lines were actually compared"
  pass "a key that quotes the evidence does not refuse a clean fixture"
}

test_key_copy_beside_the_evidence_is_scanned_by_name() {
  # The content scan covers evidence/ only, so the filename guard is what covers the rest of
  # the fixture; between them no copy of the key survives.
  local home dest out rc
  home=$(seed_key)
  dest=$(copy_fixture)
  cp "$home/data/retro-backtest-0811/SEALED-expected-answers.md" "$dest/key-copy.md"
  mv "$dest/key-copy.md" "$dest/SEALED-copy.md"
  out=$(FM_HOME="$home" FM_RETRO_BACKTEST_FIXTURE="$dest" "$BACKTEST" check 2>&1); rc=$?
  expect_code 1 "$rc" "check with a key copy outside evidence/"
  assert_contains "$out" "answer-bearing file inside the fixture" "refusal should name the cause"
  pass "a key copy elsewhere in the fixture still refuses the run"
}

test_spaced_tool_use_in_the_transcript_refuses() {
  # The transcript is a third-party CLI's output, so its whitespace is not a contract: a
  # tool use spelled with spaces must still be caught.
  local dest bin out rc
  dest=$(copy_fixture)
  bin=$(fake_claude '{"type":"assistant","message":{"content":[{"type": "tool_use", "name": "Read"}]}}
{"type":"result","result":"a candidate lesson"}')
  out=$(PATH="$bin:$PATH" FM_RETRO_BACKTEST_FIXTURE="$dest" \
    "$BACKTEST" run --out "$dest/run" 2>&1); rc=$?
  expect_code 1 "$rc" "run whose transcript contains a spaced tool use"
  assert_contains "$out" "CONTAMINATED" "a tool use must fail the run"
  assert_contains "$out" "used 1 tool" "the refusal should count the tool uses"
  assert_absent "$dest/run/answer.md" "a contaminated run must not leave a clean-looking answer"
  assert_contains "$out" "answer.CONTAMINATED.md" "the refusal should name the quarantined answer"
  assert_contains "$(cat "$dest/run/answer.CONTAMINATED.md")" "a candidate lesson" \
    "the quarantined answer should still hold what the agent said"
  pass "a tool use spelled with spaces still refuses the run"
}

test_tool_use_in_an_unfamiliar_envelope_refuses() {
  # The envelope shape is not a contract either: a tool use reported outside the two known
  # content paths must still be counted, because this guard has to fail toward contaminated.
  local dest bin out rc
  dest=$(copy_fixture)
  bin=$(fake_claude '{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","name":"Bash"}}
{"type":"result","result":"a candidate lesson"}')
  out=$(PATH="$bin:$PATH" FM_RETRO_BACKTEST_FIXTURE="$dest" \
    "$BACKTEST" run --out "$dest/run" 2>&1); rc=$?
  expect_code 1 "$rc" "run whose transcript reports a tool use in a partial-message envelope"
  assert_contains "$out" "CONTAMINATED" "a tool use anywhere in the event must fail the run"
  assert_contains "$out" "used 1 tool" "the refusal should count the tool uses"
  pass "a tool use in an unfamiliar envelope refuses the run"
}

test_unparseable_transcript_refuses() {
  local dest bin out rc
  dest=$(copy_fixture)
  bin=$(fake_claude '{"type":"result","result":"a candidate lesson"}
not json at all')
  out=$(PATH="$bin:$PATH" FM_RETRO_BACKTEST_FIXTURE="$dest" \
    "$BACKTEST" run --out "$dest/run" 2>&1); rc=$?
  expect_code 1 "$rc" "run whose transcript cannot be parsed"
  assert_contains "$out" "CONTAMINATED" "an unreadable transcript must fail the run"
  assert_contains "$out" "could not be parsed" "the refusal should name the cause"
  assert_absent "$dest/run/answer.md" "a contaminated run must not leave a clean-looking answer"
  pass "an unparseable transcript refuses the run"
}

test_transcript_without_a_result_event_refuses() {
  # An extracted answer of nothing but whitespace must never reach the manual grader as the
  # agent's answer.
  local dest bin out rc
  dest=$(copy_fixture)
  bin=$(fake_claude '{"type":"assistant","message":{"content":[{"type":"text","text":"thinking"}]}}')
  out=$(PATH="$bin:$PATH" FM_RETRO_BACKTEST_FIXTURE="$dest" \
    "$BACKTEST" run --out "$dest/run" 2>&1); rc=$?
  expect_code 1 "$rc" "run whose transcript carries no result event"
  assert_contains "$out" "produced no answer" "the refusal should name the cause"
  assert_contains "$out" "$dest/run" "the refusal should point at the run directory"
  pass "a transcript without a result event refuses the run"
}

test_clean_transcript_passes_and_reports_isolation() {
  local dest bin out rc
  dest=$(copy_fixture)
  bin=$(fake_claude '{"type":"assistant","message":{"content":[{"type":"text","text":"thinking"}]}}
{"type":"result","result":"a candidate lesson"}')
  out=$(PATH="$bin:$PATH" FM_RETRO_BACKTEST_FIXTURE="$dest" \
    "$BACKTEST" run --out "$dest/run" 2>&1); rc=$?
  expect_code 0 "$rc" "run whose transcript contains no tool use"
  assert_contains "$out" "tool uses in run:  0" "a clean run should report zero tool uses"
  assert_contains "$out" "key content scan:" "the report should state the content scan's status"
  assert_contains "$(cat "$dest/run/answer.md")" "a candidate lesson" \
    "the answer should be extracted from the result event"
  pass "a clean transcript passes and reports its isolation"
}

test_check_passes_on_the_shipped_fixture
test_prompt_carries_procedure_and_all_evidence
test_prompt_names_no_answer_bearing_file
test_sealed_key_copy_in_the_fixture_refuses
test_evidence_naming_the_key_refuses
test_grader_readme_inside_evidence_refuses
test_missing_evidence_directory_refuses
test_refusal_precedes_any_model_call
test_procedure_naming_the_incident_refuses
test_procedure_paraphrasing_the_incident_refuses
test_prompt_refuses_before_composing_when_the_procedure_leaks
test_key_content_scan_reports_that_it_was_skipped
test_any_key_line_repeated_in_the_evidence_refuses
test_key_quoting_the_evidence_does_not_refuse
test_markerless_key_reports_an_inconclusive_scan
test_key_copy_beside_the_evidence_is_scanned_by_name
test_spaced_tool_use_in_the_transcript_refuses
test_tool_use_in_an_unfamiliar_envelope_refuses
test_unparseable_transcript_refuses
test_transcript_without_a_result_event_refuses
test_clean_transcript_passes_and_reports_isolation
