#!/usr/bin/env bash
# Behavior tests for the skill compaction guard.
#
# The guard exists because a rewritten skill cannot be verified by diffing it.
# These tests drive bin/fm-skill-compact-check.sh against the real repository
# and against synthetic fixture repositories that stage each loss it is meant to
# catch: a dropped pointer, a dropped safety boundary, a compaction with no
# behavioral fixture, and a retirement that changes a stated boundary.
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

test_prompt_for_a_skill_without_a_fixture_fails() {
  run_expect_code 1 "no scenario fixture" "$CHECK" --prompt diagnostic-reasoning
  pass "a blind prompt for a skill with no fixture fails instead of rendering an empty exercise"
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
test_material_shrink_without_a_fixture_fails
test_material_shrink_with_a_fixture_passes
test_incomplete_fixture_fails
test_blind_prompt_omits_the_answers
test_prompt_for_a_skill_without_a_fixture_fails
test_usage_errors
