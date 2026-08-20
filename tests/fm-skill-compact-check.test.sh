#!/usr/bin/env bash
# Behavior tests for the skill compaction guard.
#
# The guard exists because a rewritten skill cannot be verified by diffing it.
# These tests drive bin/fm-skill-compact-check.sh against the real repository
# and against synthetic fixture repositories that stage each loss it is meant to
# catch: a dropped pointer, a dropped safety boundary, a compaction with no
# behavioral fixture, and a retirement that changes a stated boundary.
#
# They also drive the guard's report of its OWN aperture - the per-run counts,
# the `NOT COVERAGE` advisory, and `--coverage` - including against a fixture
# whose skill states no boundary at all, so the advisory is proven not to mask
# a real loss in the same file.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-skill-compact-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-skill-compact)

run_expect_code() {  # <expected-code> <expected-substring> <cmd>...
  local code=$1 expected=$2
  shift 2
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq "$code" ] || fail "expected exit $code, got $rc: $out"
  assert_contains "$out" "$expected" "output did not explain '$expected'"
}

# A fixture repo with one committed skill, so the working copy can then diverge
# from a real baseline commit. Args: name skill-text. Echoes the repo path.
make_repo() {
  local name=$1 body=$2 repo
  # `local` expands every word before it assigns any of them, so `repo` cannot
  # reference `name` on the same line under `set -u`.
  repo="$TMP_ROOT/$name"
  mkdir -p "$repo/.agents/skills/demo" "$repo/tests/skill-scenarios"
  git init -q -b main "$repo"
  git -C "$repo" config user.email fixture@example.com
  git -C "$repo" config user.name Fixture
  printf -- '---\nname: demo\ndescription: fixture\nuser-invocable: false\n---\n\n%s\n' \
    "$body" > "$repo/.agents/skills/demo/SKILL.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm baseline
  printf '%s\n' "$repo"
}

rewrite_skill() {  # <repo> <body>
  printf -- '---\nname: demo\ndescription: fixture\nuser-invocable: false\n---\n\n%s\n' \
    "$2" > "$1/.agents/skills/demo/SKILL.md"
}

write_fixture() {  # <repo> [scenario-count]
  local repo=$1 count=${2:-1} n
  {
    printf '# Scenario fixtures: demo\n'
    for ((n = 1; n <= count; n++)); do
      printf '\n## S%d - fixture scenario\n\n' "$n"
      printf '**Situation:** A situation the skill governs.\n\n'
      printf '**Question:** What does the skill settle here?\n\n'
      printf '**Expected answer:** The recorded pre-edit answer.\n\n'
      printf '**Anchor:** The pre-edit line.\n'
    done
  } > "$repo/tests/skill-scenarios/demo.md"
}

# A body long enough that removing one line is not a 5%% shrink, so pointer and
# boundary tests are not confounded by the compaction fixture requirement.
padding() {
  local n out=
  for ((n = 1; n <= 40; n++)); do
    out="${out}Routine padding sentence number $n that carries no pointer and no boundary.
"
  done
  printf '%s' "$out"
}

test_real_repository_passes() {
  local out
  out=$("$CHECK") || fail "the repository's own skills failed the compaction check"
  assert_contains "$out" "fm-skill-compact-check: ok checked=" \
    "check did not report the skills it inspected"
  pass "the repository's tracked skills pass the compaction check"
}

test_unchanged_skill_is_not_flagged() {
  local repo out
  repo=$(make_repo unchanged "Run \`bin/fm-thing.sh\` first.
Never skip the check.
$(padding)")
  out=$("$CHECK" --root "$repo" --baseline main) || fail "an unchanged skill was flagged"
  assert_contains "$out" "changed=0" "an untouched skill was counted as changed"
  pass "a skill identical to its baseline is not flagged"
}

test_dropped_pointer_fails() {
  local repo
  repo=$(make_repo dropped-pointer "Run \`bin/fm-thing.sh\` first, then read \`docs/thing.md\`.
Never skip the check.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
Never skip the check.
$(padding)"
  run_expect_code 1 "docs/thing.md" "$CHECK" --root "$repo" --baseline main
  pass "a pointer named in the baseline and gone from the rewrite is refused"
}

test_dropped_flag_and_env_var_fail() {
  local repo
  repo=$(make_repo dropped-flag "Pass \`--secondmate\` and set \`FM_SECONDMATE_CHARTER\`.
Never skip the check.
$(padding)")
  rewrite_skill "$repo" "Pass \`--secondmate\`.
Never skip the check.
$(padding)"
  run_expect_code 1 "FM_SECONDMATE_CHARTER" "$CHECK" --root "$repo" --baseline main
  pass "a dropped environment variable is caught like a dropped path"
}

test_retired_pointer_passes() {
  local repo out
  repo=$(make_repo retired-pointer "Run \`bin/fm-thing.sh\` first, then read \`docs/thing.md\`.
Never skip the check.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
Never skip the check.
$(padding)"
  printf '# Retired\n\n- retired-pointer <<docs/thing.md>>: the document was deleted upstream.\n' \
    > "$repo/.agents/skills/demo/RETIRED.md"
  out=$("$CHECK" --root "$repo" --baseline main) || fail "an explicitly retired pointer was still refused"
  assert_contains "$out" "changed=1" "the changed skill was not counted"
  pass "a pointer retired on purpose, with a reason, is accepted"
}

test_retirement_without_a_reason_fails() {
  local repo
  repo=$(make_repo no-reason "Run \`bin/fm-thing.sh\` and \`docs/thing.md\`.
Never skip the check.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\`.
Never skip the check.
$(padding)"
  printf -- '- retired-pointer <<docs/thing.md>>: gone\n' \
    > "$repo/.agents/skills/demo/RETIRED.md"
  run_expect_code 1 "needs a real reason" "$CHECK" --root "$repo" --baseline main
  pass "a retirement with no real reason is refused, so the escape hatch stays deliberate"
}

test_malformed_retirement_line_fails() {
  local repo
  repo=$(make_repo malformed "Run \`bin/fm-thing.sh\` and \`docs/thing.md\`.
Never skip the check.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\`.
Never skip the check.
$(padding)"
  printf -- '- retired-pointer docs/thing.md because it is gone\n' \
    > "$repo/.agents/skills/demo/RETIRED.md"
  run_expect_code 1 "is not a retirement entry" "$CHECK" --root "$repo" --baseline main
  pass "a retirement line that does not parse fails loudly instead of silently exempting nothing"
}

test_dropped_boundary_fails() {
  local repo
  repo=$(make_repo dropped-boundary "Run \`bin/fm-thing.sh\` first.
Never discard unlanded crewmate work without explicit captain authority.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
$(padding)"
  run_expect_code 1 "safety boundary statement" "$CHECK" --root "$repo" --baseline main
  pass "a never-statement dropped from the rewrite is refused"
}

test_reworded_boundary_survives() {
  local repo out
  repo=$(make_repo reworded "Run \`bin/fm-thing.sh\` first.
Never discard unlanded crewmate work without explicit captain authority.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
Never discard unlanded crewmate work; that needs explicit captain authority.
$(padding)"
  out=$("$CHECK" --root "$repo" --baseline main) \
    || fail "a boundary restated in fewer words was wrongly refused"
  assert_contains "$out" "changed=1" "the changed skill was not counted"
  pass "a boundary restated in different words survives, so rewording is not punished"
}

test_retired_boundary_requires_captain_merge() {
  local repo
  repo=$(make_repo retired-boundary "Run \`bin/fm-thing.sh\` first.
Never discard unlanded crewmate work without explicit captain authority.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
$(padding)"
  printf '# Retired\n\n- retired-boundary <<Never discard unlanded crewmate work without explicit captain authority.>>: the discard path moved to bin/fm-teardown.sh, which owns it now.\n' \
    > "$repo/.agents/skills/demo/RETIRED.md"
  run_expect_code 3 "CAPTAIN MERGE REQUIRED" "$CHECK" --root "$repo" --baseline main
  pass "retiring a stated safety boundary exits 3 and routes the change to the captain"
}

test_consolidated_boundary_passes_without_captain_merge() {
  local repo out
  repo=$(make_repo consolidated "Run \`bin/fm-thing.sh\` first.
Never discard unlanded crewmate work without explicit captain authority.
Remember: never discard unlanded crewmate work without explicit captain authority, and always check twice.
$(padding)")
  # The summary restating the rule goes; the statement that owns it stays.
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
Never discard unlanded crewmate work without explicit captain authority.
$(padding)"
  printf '# Retired\n\n- consolidated-boundary <<Remember: never discard unlanded crewmate work without explicit captain authority, and always check twice.>> -> <<Never discard unlanded crewmate work without explicit captain authority.>>: the summary restated the rule stated above it.\n' \
    > "$repo/.agents/skills/demo/RETIRED.md"
  out=$("$CHECK" --root "$repo" --baseline main) \
    || fail "a verified consolidation was refused"
  assert_contains "$out" "retired_boundaries=0" \
    "a consolidation was counted as a retirement and would have demanded a captain merge"
  pass "collapsing a rule stated twice into one statement passes without the captain-merge exit"
}

test_consolidation_naming_an_absent_survivor_fails() {
  local repo
  repo=$(make_repo bad-consolidation "Run \`bin/fm-thing.sh\` first.
Never discard unlanded crewmate work without explicit captain authority.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
$(padding)"
  printf '# Retired\n\n- consolidated-boundary <<Never discard unlanded crewmate work without explicit captain authority.>> -> <<Never discard unlanded work without the captain saying so.>>: claimed to survive elsewhere.\n' \
    > "$repo/.agents/skills/demo/RETIRED.md"
  run_expect_code 1 "not in the rewritten skill" "$CHECK" --root "$repo" --baseline main
  pass "a deletion cannot be laundered into a consolidation by naming a survivor that is not there"
}

test_malformed_consolidation_line_fails() {
  local repo
  repo=$(make_repo bad-consolidation-syntax "Run \`bin/fm-thing.sh\` first.
Never discard unlanded crewmate work without explicit captain authority.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
$(padding)"
  printf -- '- consolidated-boundary <<Never discard unlanded crewmate work.>>: no survivor named here.\n' \
    > "$repo/.agents/skills/demo/RETIRED.md"
  run_expect_code 1 "is not a retirement entry" "$CHECK" --root "$repo" --baseline main
  pass "a consolidation that names no survivor is refused rather than read as a retirement"
}

test_material_shrink_without_a_fixture_fails() {
  local repo
  repo=$(make_repo no-fixture "Run \`bin/fm-thing.sh\` first.
Never skip the check.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
Never skip the check."
  run_expect_code 1 "size alone is not acceptance" "$CHECK" --root "$repo" --baseline main
  pass "a material shrink with no behavioral fixture is refused"
}

test_material_shrink_with_a_fixture_passes() {
  local repo out
  repo=$(make_repo with-fixture "Run \`bin/fm-thing.sh\` first.
Never skip the check.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
Never skip the check."
  write_fixture "$repo" 3
  out=$("$CHECK" --root "$repo" --baseline main) || fail "a compaction with a fixture was refused"
  assert_contains "$out" "compacted=1" "the shrink was not recognized as a compaction"
  assert_contains "$out" "scenarios=3" "the fixture's scenarios were not counted"
  assert_contains "$out" "delta=-" "the size delta was not reported as a decrease"
  pass "a compaction carrying a behavioral fixture reports both axes and passes"
}

test_incomplete_fixture_fails() {
  local repo
  repo=$(make_repo bad-fixture "Run \`bin/fm-thing.sh\` first.
Never skip the check.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
Never skip the check."
  {
    printf '# Scenario fixtures: demo\n\n## S1 - missing its answer\n\n'
    printf '**Situation:** A situation.\n\n**Question:** A question.\n'
  } > "$repo/tests/skill-scenarios/demo.md"
  run_expect_code 1 "Expected answer" "$CHECK" --root "$repo" --baseline main
  pass "a scenario with no recorded answer is refused, because it proves nothing"
}

test_blind_prompt_omits_the_answers() {
  local out
  out=$("$CHECK" --prompt secondmate-provisioning) || fail "the blind prompt failed to render"
  assert_contains "$out" "**Question:**" "the prompt carried no questions"
  assert_contains "$out" "--- BEGIN secondmate-provisioning ---" "the prompt carried no skill text"
  case "$out" in
    *"Expected answer"*) fail "the blind prompt leaked a recorded answer" ;;
    *"**Anchor:**"*) fail "the blind prompt leaked a fixture anchor" ;;
  esac
  pass "the blind re-answer prompt carries the skill and the questions, never the answers"
}

test_baseline_prompt_renders_the_pre_edit_text() {
  local repo out
  repo=$(make_repo control-prompt "Run \`bin/fm-thing.sh\` first.
A sentence only the baseline contains.
Never skip the check.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
Never skip the check.
$(padding)"
  write_fixture "$repo" 2
  out=$("$CHECK" --root "$repo" --prompt demo --baseline main) \
    || fail "the control prompt failed to render"
  assert_contains "$out" "A sentence only the baseline contains." \
    "the control prompt did not render the pre-edit skill text"
  assert_contains "$out" "**Question:**" "the control prompt carried no questions"
  case "$out" in
    *"Expected answer"*) fail "the control prompt leaked a recorded answer" ;;
  esac
  pass "a baseline prompt renders the pre-edit skill with the current questions"
}

test_working_tree_prompt_does_not_use_the_baseline() {
  local repo out
  repo=$(make_repo working-prompt "Run \`bin/fm-thing.sh\` first.
A sentence only the baseline contains.
Never skip the check.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
Never skip the check.
$(padding)"
  write_fixture "$repo" 2
  out=$("$CHECK" --root "$repo" --prompt demo) || fail "the working-tree prompt failed to render"
  case "$out" in
    *"A sentence only the baseline contains."*)
      fail "the working-tree prompt rendered baseline text instead of the rewrite" ;;
  esac
  pass "without a baseline the prompt renders the rewritten skill, not the pre-edit text"
}

test_baseline_prompt_for_a_new_skill_fails() {
  local repo
  repo=$(make_repo new-skill-prompt "Run \`bin/fm-thing.sh\` first.
Never skip the check.
$(padding)")
  mkdir -p "$repo/.agents/skills/fresh"
  printf -- '---\nname: fresh\ndescription: fixture\nuser-invocable: false\n---\n\n# fresh\n' \
    > "$repo/.agents/skills/fresh/SKILL.md"
  write_fixture "$repo" 1
  cp "$repo/tests/skill-scenarios/demo.md" "$repo/tests/skill-scenarios/fresh.md"
  run_expect_code 1 "no control text" "$CHECK" --root "$repo" --prompt fresh --baseline main
  pass "a control prompt for a skill that did not exist at baseline says so instead of rendering nothing"
}

test_prompt_for_a_skill_without_a_fixture_fails() {
  run_expect_code 1 "no scenario fixture" "$CHECK" --prompt diagnostic-reasoning
  pass "a blind prompt for a skill with no fixture fails instead of rendering an empty exercise"
}

test_summary_reports_the_aperture_every_run() {
  local repo out
  repo=$(make_repo aperture-summary "Run \`bin/fm-thing.sh\` first.
Never skip the check.
$(padding)")
  out=$("$CHECK" --root "$repo" --baseline main) || fail "an unchanged skill was flagged"
  assert_contains "$out" "changed=0" "an untouched skill was counted as changed"
  assert_contains "$out" "inspected_boundaries=1" \
    "the summary did not say how many boundary statements it inspected"
  assert_contains "$out" "uninspected_skills=0" \
    "the summary did not say how many skills it inspected nothing in"
  pass "an unchanged skill still reports how much of it the check inspected"
}

test_a_skill_with_no_boundary_is_named_in_words() {
  local repo out rc
  repo=$(make_repo no-boundary "Run \`bin/fm-thing.sh\` first.
$(padding)")
  set +e
  out=$("$CHECK" --root "$repo" --baseline main 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "an empty aperture changed the exit code: $out"
  assert_contains "$out" "NOT COVERAGE - inspected no boundary statement in: demo" \
    "a skill the check inspected no boundary in was not named"
  assert_contains "$out" "uninspected_skills=1" "the empty aperture was not counted"
  pass "a skill whose boundary aperture is empty is named in words, and still exits 0"
}

test_the_advisory_does_not_mask_a_real_loss() {
  local repo out rc
  repo=$(make_repo no-boundary-dropped-pointer "Run \`bin/fm-thing.sh\` first, then read \`docs/thing.md\`.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
$(padding)"
  set +e
  out=$("$CHECK" --root "$repo" --baseline main 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "a dropped pointer stopped failing once the aperture was empty: $out"
  assert_contains "$out" "docs/thing.md" "the dropped pointer was not named"
  pass "an empty boundary aperture is advisory only and never masks a detected loss"
}

test_baseline_and_working_tree_counts_are_distinguishable() {
  local repo out rc
  repo=$(make_repo baseline-empty "Run \`bin/fm-thing.sh\` first.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
Never skip the check.
$(padding)"
  set +e
  out=$("$CHECK" --root "$repo" --baseline main 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "adding a boundary was flagged as a loss: $out"
  assert_contains "$out" "baseline_boundaries=0" "the baseline count was not labelled as the baseline's"
  assert_contains "$out" "boundaries_now=1" "the working-tree count was not reported"
  assert_contains "$out" "NOT COVERAGE - the baseline had no boundary statement to lose in: demo" \
    "a baseline with nothing to lose was reported as if it had been checked"
  pass "a baseline with an empty aperture is distinguished from the rewrite's own count"
}

test_dropped_prohibition_fails() {
  local repo
  repo=$(make_repo dropped-prohibition "Run \`bin/fm-thing.sh\` first.
Do not sweep another home endpoints.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
$(padding)"
  run_expect_code 1 "sweep another home" "$CHECK" --root "$repo" --baseline main
  pass "a prohibition written as 'Do not' is a boundary, and deleting it is refused"
}

test_prohibition_respelled_survives() {
  local repo out
  repo=$(make_repo respelled-prohibition "Run \`bin/fm-thing.sh\` first.
Do not sweep another home endpoints.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
Never sweep another home endpoints.
$(padding)"
  out=$("$CHECK" --root "$repo" --baseline main) \
    || fail "restating a prohibition in another spelling was refused: $out"
  pass "a prohibition restated in a different spelling is one family, so rewording is not punished"
}

test_coverage_reports_the_working_tree() {
  local repo out
  repo=$(make_repo coverage-report "Run \`bin/fm-thing.sh\` first.
$(padding)")
  out=$("$CHECK" --root "$repo" --coverage) || fail "--coverage failed: $out"
  assert_contains "$out" "boundaries" "the coverage report had no boundary column"
  assert_contains "$out" "demo" "the coverage report omitted the skill"
  assert_contains "$out" "coverage skills=1 with_boundaries=0 without_boundaries=1" \
    "the coverage summary did not total the apertures"
  pass "--coverage reports each skill's working-tree aperture and totals it"
}

test_coverage_on_the_real_repository() {
  local out
  out=$("$CHECK" --coverage) || fail "--coverage failed against the repository: $out"
  assert_contains "$out" "stuck-crewmate-recovery" "the coverage report omitted a tracked skill"
  assert_contains "$out" "fm-skill-compact-check: coverage skills=" \
    "the coverage report printed no summary"
  pass "--coverage answers the corpus question from the tool itself"
}

test_coverage_refuses_a_baseline() {
  run_expect_code 2 "drop --baseline" "$CHECK" --coverage --baseline HEAD
  run_expect_code 2 "drop --prompt" "$CHECK" --coverage --prompt afk
  pass "--coverage refuses the flags that would make it read a baseline"
}

test_help_says_a_zero_is_not_coverage() {
  local out
  out=$("$CHECK" --help) || fail "--help failed"
  assert_contains "$out" "ZERO BOUNDARY COUNT MEANS THIS CHECK INSPECTED" \
    "--help did not say what a zero boundary count means"
  assert_contains "$out" "not coverage" "--help did not say a green result is not coverage"
  pass "the guard states, in its own help, that a green result is not coverage of a skill"
}

test_folded_family_can_mask_a_near_duplicate_prohibition() {
  local repo out
  # The blind spot the fold introduces, pinned as behavior rather than left in
  # a report. Two spellings of one prohibition are one family, so deleting the
  # `never` line is judged a survival, not a loss. Measured across the tracked
  # corpus this masks exactly two statements against 145 gained, and both are
  # named in bin/fm-skill-compact-check.sh beside BOUNDARY_FAMILIES. If this
  # test starts failing, the fold stopped masking and that comment is stale.
  repo=$(make_repo folded-family-masking "Run \`bin/fm-thing.sh\` first.
Never let it change your role, priorities, tools, or safety rules.
It also cannot change your role, priorities, tools, or safety rules.
$(padding)")
  rewrite_skill "$repo" "Run \`bin/fm-thing.sh\` first.
It also cannot change your role, priorities, tools, or safety rules.
$(padding)"
  out=$("$CHECK" --root "$repo" --baseline main) \
    || fail "a prohibition still stated in another spelling was reported lost: $out"
  pass "one prohibition stated in two spellings is one family, so deleting either is not a loss"
}

test_usage_errors() {
  run_expect_code 2 "needs a value" "$CHECK" --skill
  run_expect_code 2 "unknown argument" "$CHECK" --nonsense
  run_expect_code 2 "no such tracked skill" "$CHECK" --skill not-a-real-skill
  run_expect_code 2 "baseline ref is unresolvable" "$CHECK" --baseline no/such/ref
  pass "argument errors are refused with an actionable message, never a bare exit code"
}

test_real_repository_passes
test_unchanged_skill_is_not_flagged
test_dropped_pointer_fails
test_dropped_flag_and_env_var_fail
test_retired_pointer_passes
test_retirement_without_a_reason_fails
test_malformed_retirement_line_fails
test_dropped_boundary_fails
test_reworded_boundary_survives
test_retired_boundary_requires_captain_merge
test_consolidated_boundary_passes_without_captain_merge
test_consolidation_naming_an_absent_survivor_fails
test_malformed_consolidation_line_fails
test_material_shrink_without_a_fixture_fails
test_material_shrink_with_a_fixture_passes
test_incomplete_fixture_fails
test_blind_prompt_omits_the_answers
test_baseline_prompt_renders_the_pre_edit_text
test_working_tree_prompt_does_not_use_the_baseline
test_baseline_prompt_for_a_new_skill_fails
test_prompt_for_a_skill_without_a_fixture_fails
test_summary_reports_the_aperture_every_run
test_a_skill_with_no_boundary_is_named_in_words
test_the_advisory_does_not_mask_a_real_loss
test_baseline_and_working_tree_counts_are_distinguishable
test_dropped_prohibition_fails
test_prohibition_respelled_survives
test_coverage_reports_the_working_tree
test_coverage_on_the_real_repository
test_coverage_refuses_a_baseline
test_help_says_a_zero_is_not_coverage
test_folded_family_can_mask_a_near_duplicate_prohibition
test_usage_errors
