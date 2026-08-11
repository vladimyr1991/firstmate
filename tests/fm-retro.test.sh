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
#   (i) unknown and 0 recorded as different facts, a true zero never laundered
#   (j) a later poorer read never degrades a fact the record already knows
#   (k) a post-teardown re-collect refuses and preserves facts, attestation, prose
#   (l) --none never clears lesson keys an earlier attestation committed
#   (m) a key this version does not emit survives a re-collect unchanged
#   (n) the same holds for the attestation block across a re-complete
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

# Backdate a file's mtime by <seconds>. GNU touch takes an epoch directly; the
# BSD fallback has to format a timestamp, and both halves of that fallback stay
# in LOCAL time because `touch -t` parses local time. Formatting UTC and feeding
# it to `touch -t` silently backdates by the wrong interval east of UTC and lands
# in the FUTURE west of it.
backdate_file() {  # <path> <seconds-ago>
  local path=$1 target
  target=$(( $(date +%s) - $2 ))
  touch -d "@$target" "$path" 2>/dev/null && return 0
  touch -t "$(date -r "$target" +%Y%m%d%H%M.%S)" "$path"
}

# Append lines just inside a block's closing marker, the way a later pass or a
# human extends data/<id>/retro.md - the delimited key=value block is this
# script's own generated text contract.
extend_block() {  # <file> <close-marker> <line>...
  local file=$1 close=$2 line seen=0
  shift 2
  : > "$file.ext"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$seen" = 0 ] && [ "$line" = "$close" ]; then
      printf '%s\n' "$@" >> "$file.ext"
      seen=1
    fi
    printf '%s\n' "$line" >> "$file.ext"
  done < "$file"
  [ "$seen" = 1 ] || fail "extend_block found no '$close' in $file"
  mv "$file.ext" "$file"
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
  local home dispatch landing
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
  touch "$home/data/task-r1/brief.md"
  backdate_file "$home/data/task-r1/brief.md" 7200

  run_retro "$home" collect task-r1 >/dev/null || fail "collect failed on a real worktree"

  [ "$(fact "$home" evaluation_rounds)" = 3 ] \
    || fail "evaluation rounds miscounted: $(fact "$home" evaluation_rounds)"
  [ "$(fact "$home" branch)" = "fm/task-r1" ] \
    || fail "branch not resolved: $(fact "$home" branch)"
  [ "$(fact "$home" commits)" = 2 ] \
    || fail "commits on the task branch miscounted: $(fact "$home" commits)"
  [ "$(fact "$home" dispatch_source)" = "data/task-r1/brief.md" ] \
    || fail "dispatch timestamp provenance wrong: $(fact "$home" dispatch_source)"

  # Assert the backdate itself took effect, so the fixture can never again hand
  # the elapsed assertion a nonsense interval for it to trip over: a fixture that
  # writes a FUTURE dispatch time leaves elapsed_seconds unknown, and the numeric
  # comparison below would then fail on "integer expression expected" rather than
  # on the behaviour it names.
  dispatch=$(fact "$home" dispatch_epoch)
  landing=$(fact "$home" landing_epoch)
  case "$dispatch" in ''|*[!0-9]*) fail "dispatch_epoch must be numeric, got '$dispatch'" ;; esac
  case "$landing" in ''|*[!0-9]*) fail "landing_epoch must be numeric, got '$landing'" ;; esac
  [ "$dispatch" -lt "$landing" ] \
    || fail "the brief.md backdate did not take effect: dispatch_epoch=$dispatch is not older than landing_epoch=$landing"
  [ $((landing - dispatch)) -ge 7000 ] \
    || fail "the backdate moved brief.md only $((landing - dispatch))s before landing"
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

# --- the durable-record invariant -------------------------------------------
#
# Once a durable record is committed, no later step may destroy, degrade, or
# contradict it. These cases fail if a POORER LATER READ can replace a RICHER
# EARLIER ONE, which is the only property that makes the whole design worth
# having: a torn-down task recorded as zero escalations would make the fleet look
# like it was improving precisely because its evidence had been erased.

test_absent_status_records_unknown_not_zero() {
  local home
  home=$(make_home unknown-vs-zero)
  fm_write_meta "$home/state/task-r1.meta" "kind=ship" "mode=no-mistakes"
  # No status file at all, and no prior record to inherit from.
  run_retro "$home" collect task-r1 >/dev/null || fail "collect failed without a status log"

  local key
  for key in status_lines needs_decision_events blocked_events resolved_events \
    paused_events open_decisions; do
    [ "$(fact "$home" "$key")" = unknown ] \
      || fail "$key must be unknown when the status log was never read, got '$(fact "$home" "$key")'"
  done
  [ "$(fact "$home" decision_keys)" = unknown ] \
    || fail "decision_keys must be unknown when the status log was never read"
  # evaluation_rounds is counted from data/, which survives teardown, so zero
  # there is a true zero and must NOT be laundered into unknown.
  [ "$(fact "$home" evaluation_rounds)" = 0 ] \
    || fail "a genuinely zero evaluation-round count must stay 0, not become unknown"

  # And the other direction: a status log that exists and holds no decision
  # events reads none, which is a different fact from never having been read.
  printf 'done: landed\n' > "$home/state/task-r1.status"
  run_retro "$home" collect task-r1 >/dev/null || fail "collect failed with a status log"
  [ "$(fact "$home" decision_keys)" = none ] \
    || fail "decision_keys must be none when the log was read and held no decisions"
  [ "$(fact "$home" blocked_events)" = 0 ] \
    || fail "a read log with no blocked events must record 0, not unknown"
  pass "unknown and 0 are recorded as different facts, and a true zero is never laundered"
}

test_later_read_never_degrades_a_known_fact() {
  local home
  home=$(make_home no-degrade)
  write_meta_fixture "$home"
  cat > "$home/state/task-r1.status" <<'EOF'
needs-decision [key=a]: something
blocked: something else
done: landed
EOF
  run_retro "$home" collect task-r1 >/dev/null || fail "collect failed"
  [ "$(fact "$home" blocked_events)" = 1 ] || fail "precondition: blocked event not counted"
  [ "$(fact "$home" harness)" = claude ] || fail "precondition: harness not recorded"

  # The status log disappears while the metadata survives - the partial case.
  # Every previously known fact must still read exactly as it did.
  rm "$home/state/task-r1.status"
  run_retro "$home" collect task-r1 >/dev/null || fail "re-collect failed in the partial case"
  [ "$(fact "$home" status_lines)" = 3 ] \
    || fail "a known status_lines was degraded to '$(fact "$home" status_lines)'"
  [ "$(fact "$home" blocked_events)" = 1 ] \
    || fail "a known blocked_events was degraded to '$(fact "$home" blocked_events)'"
  [ "$(fact "$home" needs_decision_events)" = 1 ] \
    || fail "a known needs_decision_events was degraded"
  [ "$(fact "$home" decision_keys)" = "a,default" ] \
    || fail "known decision keys were degraded to '$(fact "$home" decision_keys)'"
  [ "$(fact "$home" open_decisions)" = 2 ] \
    || fail "a known open_decisions was degraded"

  # The mirror case: the metadata disappears while the status log survives, so
  # collect proceeds. Every meta-derived fact must still read the value it was
  # first recorded with rather than reverting to unknown, while the
  # status-derived counts are recomputed normally from the log that is still
  # there.
  cat > "$home/state/task-r1.status" <<'EOF'
needs-decision [key=a]: something
blocked: something else
paused: waiting
done: landed
EOF
  rm "$home/state/task-r1.meta"
  run_retro "$home" collect task-r1 >/dev/null || fail "re-collect failed without metadata"
  [ "$(fact "$home" harness)" = claude ] \
    || fail "a known harness was degraded to '$(fact "$home" harness)'"
  [ "$(fact "$home" model)" = opus ] \
    || fail "a known model was degraded to '$(fact "$home" model)'"
  [ "$(fact "$home" effort)" = high ] \
    || fail "a known effort was degraded to '$(fact "$home" effort)'"
  [ "$(fact "$home" mode)" = no-mistakes ] \
    || fail "a known mode was degraded to '$(fact "$home" mode)'"
  [ "$(fact "$home" pr)" = "https://github.com/example/repo/pull/9" ] \
    || fail "a known pr was degraded to '$(fact "$home" pr)'"
  # The still-readable log is the live source, so its counts move with it.
  [ "$(fact "$home" status_lines)" = 4 ] \
    || fail "status counts must be recomputed from a log that is still there: $(fact "$home" status_lines)"
  [ "$(fact "$home" paused_events)" = 1 ] \
    || fail "a newly readable paused event was not counted: $(fact "$home" paused_events)"
  pass "a later, poorer read never replaces a fact the record already knows"
}

test_collect_preserves_keys_it_does_not_recognize() {
  local home file before after
  home=$(make_home carried-keys)
  file="$home/data/task-r1/retro.md"
  write_meta_fixture "$home"
  printf 'done: landed\n' > "$home/state/task-r1.status"
  run_retro "$home" collect task-r1 >/dev/null || fail "collect failed"

  # A pass 2 scorer, or a human, extends the open key=value set with keys this
  # version of the script does not emit.
  extend_block "$file" '<!-- /fm-retro:facts -->' struggle_score=4 cause_class=vendor-quota
  before=$(sed 's/^collected_epoch=.*/collected_epoch=X/' "$file")

  run_retro "$home" collect task-r1 >/dev/null || fail "re-collect failed after an added key"
  [ "$(fact "$home" struggle_score)" = 4 ] \
    || fail "an unrecognized key was dropped or altered by re-collect: '$(fact "$home" struggle_score)'"
  [ "$(fact "$home" cause_class)" = vendor-quota ] \
    || fail "a second unrecognized key was dropped or altered: '$(fact "$home" cause_class)'"
  after=$(sed 's/^collected_epoch=.*/collected_epoch=X/' "$file")
  [ "$before" = "$after" ] \
    || fail "re-collect on an unchanged record was not byte-identical apart from collected_epoch"
  pass "a re-collect carries forward keys this version does not emit, unchanged and in place"
}

test_complete_preserves_attestation_keys_it_does_not_recognize() {
  local home file before after
  home=$(make_home carried-attestation)
  file="$home/data/task-r1/retro.md"
  write_meta_fixture "$home"
  printf 'done: landed\n' > "$home/state/task-r1.status"
  run_retro "$home" collect task-r1 >/dev/null || fail "collect failed"
  run_retro "$home" complete task-r1 first-lesson >/dev/null || fail "complete failed"

  # The cross-vendor audit the skill's operating sequence orders records itself
  # inside the attestation markers, and that sequence re-runs complete.
  extend_block "$file" '<!-- /fm-retro:attestation -->' \
    audited_by=codex-gpt5 audit_verdict=accepted-with-edits
  before=$(sed 's/^attested_epoch=.*/attested_epoch=X/' "$file")

  run_retro "$home" complete task-r1 first-lesson >/dev/null \
    || fail "re-complete failed after an added attestation key"
  [ "$(fact "$home" audited_by)" = codex-gpt5 ] \
    || fail "an unrecognized attestation key was dropped or altered: '$(fact "$home" audited_by)'"
  [ "$(fact "$home" audit_verdict)" = accepted-with-edits ] \
    || fail "a second unrecognized attestation key was dropped: '$(fact "$home" audit_verdict)'"
  after=$(sed 's/^attested_epoch=.*/attested_epoch=X/' "$file")
  [ "$before" = "$after" ] \
    || fail "re-complete on an unchanged record was not byte-identical apart from attested_epoch"

  # And the keys survive the other command's rewrite, plus a new lesson key.
  run_retro "$home" complete task-r1 second-lesson >/dev/null || fail "adding a lesson key failed"
  run_retro "$home" collect task-r1 >/dev/null || fail "collect after the added keys failed"
  assert_grep "lesson_keys=first-lesson,second-lesson" "$file" \
    "carrying unrecognized keys must not disturb the lesson-key union"
  [ "$(fact "$home" audited_by)" = codex-gpt5 ] \
    || fail "an unrecognized attestation key was lost by a later collect or complete"
  run_retro "$home" verify task-r1 >/dev/null || fail "verify failed on the extended attestation"
  pass "a re-complete carries forward attestation keys this version does not emit"
}

test_recollect_after_teardown_refuses_and_preserves_everything() {
  local home facts_before attest_before
  home=$(make_home post-teardown)
  write_meta_fixture "$home"
  printf 'blocked: needed help\ndone: landed\n' > "$home/state/task-r1.status"
  run_retro "$home" collect task-r1 >/dev/null || fail "collect failed"
  run_retro "$home" complete task-r1 a-real-lesson >/dev/null || fail "complete failed"
  printf '\n## Narrative\n\nHand-written prose that must survive.\n' \
    >> "$home/data/task-r1/retro.md"
  facts_before=$(sed -n '/fm-retro:facts/,/\/fm-retro:facts/p' "$home/data/task-r1/retro.md")
  attest_before=$(sed -n '/fm-retro:attestation/,/\/fm-retro:attestation/p' "$home/data/task-r1/retro.md")

  # Exactly the post-teardown state: both volatile records erased, data/ intact.
  rm "$home/state/task-r1.status" "$home/state/task-r1.meta"
  run_retro_expect_failure "$home" "refusing to re-collect over them" collect task-r1

  [ "$(sed -n '/fm-retro:facts/,/\/fm-retro:facts/p' "$home/data/task-r1/retro.md")" = "$facts_before" ] \
    || fail "the refused re-collect still altered the facts block"
  [ "$(sed -n '/fm-retro:attestation/,/\/fm-retro:attestation/p' "$home/data/task-r1/retro.md")" = "$attest_before" ] \
    || fail "the refused re-collect altered the attestation"
  assert_grep "Hand-written prose that must survive" "$home/data/task-r1/retro.md" \
    "narrative prose outside both blocks must survive every command"
  run_retro "$home" verify task-r1 >/dev/null \
    || fail "verify must still succeed on the preserved record after teardown"
  pass "a post-teardown re-collect refuses, names why, and leaves facts, attestation and prose intact"
}

test_complete_none_never_clears_attested_lessons() {
  local home
  home=$(make_home none-after-keys)
  write_meta_fixture "$home"
  printf 'done: landed\n' > "$home/state/task-r1.status"
  run_retro "$home" collect task-r1 >/dev/null || fail "collect failed"
  run_retro "$home" complete task-r1 first-lesson second-lesson >/dev/null || fail "complete failed"
  run_retro "$home" complete task-r1 --none >/dev/null || fail "complete --none failed"
  assert_grep "lesson_keys=first-lesson,second-lesson" "$home/data/task-r1/retro.md" \
    "a later --none must not erase lessons already attested"
  pass "--none never clears lesson keys an earlier attestation committed"
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
test_absent_status_records_unknown_not_zero
test_later_read_never_degrades_a_known_fact
test_collect_preserves_keys_it_does_not_recognize
test_complete_preserves_attestation_keys_it_does_not_recognize
test_recollect_after_teardown_refuses_and_preserves_everything
test_complete_none_never_clears_attested_lessons
test_collect_refuses_an_unknown_task
