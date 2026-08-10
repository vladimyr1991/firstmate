#!/usr/bin/env bash
# Structural regression tests for the tracked skill trigger inventory.
#
# A skill nothing loads is dead weight and nothing else in the repository
# notices. These tests drive bin/fm-skill-trigger-check.sh against the real
# repository and against synthetic fixture repositories.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-skill-trigger-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-skill-trigger)

run_expect_failure() {
  local expected=$1
  shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected failure containing '$expected'"
  assert_contains "$out" "$expected" "failure did not explain '$expected'"
}

# Build a fixture repo with one skill. Args: name skill-name user-invocable trigger-text
make_fixture() {
  local name=$1 skill=$2 invocable=$3 trigger=$4
  local repo="$TMP_ROOT/$name"
  mkdir -p "$repo/.agents/skills/$skill"
  git init -q "$repo"
  {
    printf -- '---\n'
    printf 'name: %s\n' "$skill"
    printf 'description: fixture skill\n'
    [ "$invocable" = omit ] || printf 'user-invocable: %s\n' "$invocable"
    printf -- '---\n\n# %s\n' "$skill"
  } > "$repo/.agents/skills/$skill/SKILL.md"
  printf '# Fixture instructions\n\n%s\n' "$trigger" > "$repo/AGENTS.md"
  git -C "$repo" add -A
  printf '%s\n' "$repo"
}

test_repository_skills_all_have_triggers() {
  local out
  out=$("$CHECK") || fail "repository skill trigger check failed"
  assert_contains "$out" "fm-skill-trigger-check: ok skills=" \
    "check did not report the skills it inspected"
  assert_contains "$out" "agent_only=" "check did not report the agent-only count"
  assert_contains "$out" "captain_invocable=" "check did not report the captain-invocable count"
  pass "every tracked skill in this repository declares a load trigger"
}

test_agent_only_skill_without_a_trigger_fails() {
  local repo
  repo=$(make_fixture no-trigger lonely-skill false "Nothing here names the skill.")
  run_expect_failure "agent-only skills with no load trigger in AGENTS.md: lonely-skill" \
    "$CHECK" --root "$repo"
  pass "an agent-only skill that AGENTS.md never names is refused"
}

test_agent_only_skill_with_a_trigger_passes() {
  local repo out
  repo=$(make_fixture with-trigger lonely-skill false \
    '- lonely-skill - load before doing the lonely thing.')
  out=$("$CHECK" --root "$repo") || fail "a declared trigger was not accepted"
  assert_contains "$out" "skills=1 agent_only=1 captain_invocable=0" \
    "check miscounted the fixture inventory"
  pass "an agent-only skill named by a load condition in AGENTS.md passes"
}

test_captain_invocable_skill_needs_no_instructions_line() {
  local repo out
  repo=$(make_fixture invocable slashy true "Nothing here names the skill.")
  out=$("$CHECK" --root "$repo") || fail "a captain-invocable skill was wrongly required in AGENTS.md"
  assert_contains "$out" "skills=1 agent_only=0 captain_invocable=1" \
    "check miscounted the captain-invocable carve-out"
  pass "a captain-invocable skill declares its trigger through frontmatter, not AGENTS.md"
}

test_missing_or_invalid_frontmatter_fails() {
  local repo
  repo=$(make_fixture no-field quiet-skill omit "quiet-skill is mentioned here.")
  run_expect_failure "has no user-invocable field" "$CHECK" --root "$repo"

  repo=$(make_fixture bad-field noisy-skill maybe "noisy-skill is mentioned here.")
  run_expect_failure "only true or false declare a trigger" "$CHECK" --root "$repo"

  repo="$TMP_ROOT/no-frontmatter"
  mkdir -p "$repo/.agents/skills/bare-skill"
  git init -q "$repo"
  printf '# bare-skill\n' > "$repo/.agents/skills/bare-skill/SKILL.md"
  printf '# Fixture\n\nbare-skill is mentioned here.\n' > "$repo/AGENTS.md"
  git -C "$repo" add -A
  run_expect_failure "is not registered" "$CHECK" --root "$repo"
  pass "a skill whose own registration metadata is missing or invalid is refused"
}

test_directory_and_declared_name_must_agree() {
  local repo
  repo="$TMP_ROOT/name-mismatch"
  mkdir -p "$repo/.agents/skills/on-disk"
  git init -q "$repo"
  {
    printf -- '---\n'
    printf 'name: in-frontmatter\n'
    printf 'user-invocable: false\n'
    printf -- '---\n'
  } > "$repo/.agents/skills/on-disk/SKILL.md"
  printf '# Fixture\n\non-disk and in-frontmatter are both mentioned.\n' > "$repo/AGENTS.md"
  git -C "$repo" add -A
  run_expect_failure "but lives in directory" "$CHECK" --root "$repo"
  pass "a skill whose declared name disagrees with its directory is refused"
}

test_untracked_skill_is_out_of_scope() {
  local repo out
  repo=$(make_fixture untracked tracked-skill false \
    '- tracked-skill - load before the tracked thing.')
  mkdir -p "$repo/.agents/skills/scratch-skill"
  printf -- '---\nname: scratch-skill\n---\n' > "$repo/.agents/skills/scratch-skill/SKILL.md"
  out=$("$CHECK" --root "$repo") || fail "an untracked scratch skill was wrongly enforced"
  assert_contains "$out" "skills=1" "untracked skills must stay out of scope"
  pass "an untracked working-copy skill is out of scope, exactly like the audience check"
}

test_partial_name_never_lends_a_trigger() {
  local repo
  repo=$(make_fixture partial-name coding false \
    '- coding-guidelines - load before editing shared material.')
  run_expect_failure "agent-only skills with no load trigger in AGENTS.md: coding" \
    "$CHECK" --root "$repo"
  pass "a longer skill name never lends a trigger to a shorter one it contains"
}

test_repository_skills_all_have_triggers
test_agent_only_skill_without_a_trigger_fails
test_agent_only_skill_with_a_trigger_passes
test_captain_invocable_skill_needs_no_instructions_line
test_missing_or_invalid_frontmatter_fails
test_directory_and_declared_name_must_agree
test_untracked_skill_is_out_of_scope
test_partial_name_never_lends_a_trigger
