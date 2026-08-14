#!/usr/bin/env bash
# Behavior tests for the installed specification gate.
#
# The gate is only as real as three things a reader cannot verify by looking:
# the skill's own internal links resolve at the paths it names, its structural
# validator actually refuses an unready specification, and both registration
# checkers still accept the repository with the skill installed.
#
# Everything here drives a public interface: the validator through its command
# line, registration through bin/fm-doc-audience-check.sh and
# bin/fm-skill-trigger-check.sh, and link resolution through the paths the
# installed SKILL.md itself names.
#
# Deliberately absent: byte-identity with the captain's source.
# data/spec-gate-source/ is gitignored captain-private local data, absent from
# every isolated task worktree and from git history by design, so identity with
# it can only be checked from the main checkout that holds it.
# This suite therefore verifies the installed layout's behavior - links
# resolve, the validator accepts and rejects correctly, both registration
# checkers pass - and does not assert byte-identity.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL_DIR="$ROOT/.agents/skills/write-implementation-spec"
TMP_ROOT=$(fm_test_tmproot fm-spec-gate)
# The shared helper registers its cleanup inside the command substitution that
# captured the path, so the directory is already gone by the time it is read.
# Fixture builders in other suites re-create what they need; this suite writes
# spec files directly, so it re-creates the root and owns its removal.
mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

# A structurally complete READY specification, written to <path>. Every later
# case derives from this one so a rejection is attributable to the single
# property it removed.
write_ready_spec() {  # <path>
  cat > "$1" <<'SPEC'
# Add a per-project export button

## 1. Readiness

- Status: READY
- Task type: frontend
- Size: small
- Author/decision owner: captain
- Last clarified: 2026-08-12
- Evidence inspected: src/pages/report.tsx
- Approved assumptions: none
- Blockers: none

## 2. Goal and outcome

- Problem: a report cannot be taken out of the app.
- User/business outcome: the reader downloads the current report as CSV.
- Success measure: the downloaded file opens with the same rows the table shows.

## 3. Current state

The report page renders rows from `useReportRows` and offers no export control.

## 4. Desired behavior

Pressing Export downloads `report.csv` containing the currently filtered rows.

## 5. Scope

### In scope

- One export control on the report page.

### Out of scope

- Scheduled or emailed exports.

### Must not change

- The existing filter behavior.

## 6. Detailed requirements

| ID | Requirement | Source | Priority |
| --- | --- | --- | --- |
| FR-1 | Export downloads the filtered rows as CSV | author | must |

## 7. Interfaces and data contracts

N/A - the export is built client-side from rows already loaded.

## 8. UI and interaction specification

One secondary button labelled `Export`, right-aligned above the table, disabled while rows are loading.

## 9. Edge cases and failure behavior

| Case | Expected behavior | User feedback | Recovery/observability |
| --- | --- | --- | --- |
| No rows after filtering | Button stays disabled | Tooltip `Nothing to export` | None needed |

## 10. Non-functional requirements

- NFR-1: the download starts within one second for 10,000 rows.

## 11. Implementation boundaries

- Likely affected areas: `src/pages/report.tsx`
- Required reuse: the existing button component
- Forbidden changes: the row-loading hook
- Compatibility/migration: none
- Suggested approach: build the CSV in the page component

## 12. Acceptance criteria

### AC-1 - filtered rows download as CSV

- Given a report filtered to three rows
- When the reader presses Export
- Then `report.csv` downloads containing exactly those three rows
- Covers: FR-1

## 13. Verification plan

| Level | Scenario | Method/command | Expected evidence |
| --- | --- | --- | --- |
| Unit | CSV serialization | `npm test -- report-export` | passing test |

## 14. Delivery, rollout, and rollback

Ships with the next release; reverting the component removes the control.

## 15. Risks and open questions

- Risks: large exports block the main thread; mitigated by the row cap; owner implementer.
- Open questions: none

## 16. Implementer handoff

- Deliverables: component change plus unit test
- Completion report must include: changed files, test output, a screenshot of the control
- Stop and escalate if: the rows are not available client-side
SPEC
}

# Run the validator from its installed path. Echoes output, returns its code.
run_validator() {  # <spec-path>
  local out rc
  out=$(cd "$SKILL_DIR" && python3 scripts/validate_spec.py "$1" 2>&1)
  rc=$?
  printf '%s' "$out"
  return "$rc"
}

# Assert the validator rejects <spec-path> and explains it with <expected>.
expect_rejected() {  # <spec-path> <expected-substring> <label>
  local out rc
  out=$(run_validator "$1")
  rc=$?
  expect_code 1 "$rc" "$3"
  assert_contains "$out" "INVALID" "$3 did not report INVALID"
  assert_contains "$out" "$2" "$3 was not explained"
}

# Checks the installed layout only; identity with the captain's source at
# data/spec-gate-source/ is untestable here (see the header comment).
test_installed_links_resolve() {
  local skill="$SKILL_DIR/SKILL.md" target found=0
  assert_present "$skill" "the skill is not installed at .agents/skills/write-implementation-spec/SKILL.md"
  # Every relative reference the skill's own text names, whether written as a
  # markdown link or as a command argument, must exist where it points.
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    found=$((found + 1))
    assert_present "$SKILL_DIR/$target" \
      "the installed skill names $target, which does not exist beside it"
  done < <(grep -oE '(references|scripts)/[A-Za-z0-9._-]+' "$skill" | sort -u)
  [ "$found" -ge 3 ] \
    || fail "expected the skill to name its references and its validator, found $found"
  pass "every internal path the installed skill names resolves in the installed layout"
}

test_ready_spec_passes() {
  local spec="$TMP_ROOT/ready.md" out
  write_ready_spec "$spec"
  out=$(run_validator "$spec") || fail "a complete READY specification was rejected: $out"
  assert_contains "$out" "VALID" "an accepted specification was not reported as valid"
  pass "a structurally complete READY specification passes the installed validator"
}

# The skill now requires a current-state claim to carry the exact verified ref
# and the implementer's re-check obligation. That annotation lands inside the
# specification the validator reads, so the gate has to keep accepting it: a
# resolved SHA, a branch name, and the re-check sentence must not read as an
# unresolved placeholder or a structural break.
test_current_state_claim_with_verified_ref_still_validates() {
  local spec="$TMP_ROOT/current-state-ref.md" out
  write_ready_spec "$spec"
  awk '
    { print }
    /^The report page renders rows from/ {
      print "Verified on branch `fm/example` at resolved SHA `8930ea64878e9cffc8c66f690b488ddf4a5f9293` (`git rev-parse HEAD`, `grep -n useReportRows src/pages/report.tsx`)."
      print "Before your first edit, re-run those checks against the base you were actually dispatched onto and report any disagreement as a deviation, instead of silently preserving or overturning this claim."
    }
  ' "$spec" > "$spec.tmp" && mv "$spec.tmp" "$spec"
  out=$(run_validator "$spec") \
    || fail "a READY specification recording its verified current-state ref was rejected: $out"
  assert_contains "$out" "VALID" \
    "a current-state claim carrying its branch, resolved SHA, and re-check obligation was not accepted"
  pass "a current-state claim carrying its verified ref and re-check obligation passes the installed validator"
}

test_missing_required_section_is_rejected() {
  local spec="$TMP_ROOT/no-verification.md"
  write_ready_spec "$spec"
  # Drop section 13 entirely, heading and body.
  awk '/^## 13\. Verification plan$/{skip=1} /^## 14\./{skip=0} !skip' \
    "$spec" > "$spec.tmp" && mv "$spec.tmp" "$spec"
  expect_rejected "$spec" "Missing section: Verification plan" \
    "a specification missing a required section"
  pass "a specification missing a required section is rejected"
}

test_ready_spec_with_placeholder_is_rejected() {
  local spec="$TMP_ROOT/placeholder.md"
  write_ready_spec "$spec"
  printf -- '- The export file name is TBD.\n' >> "$spec"
  expect_rejected "$spec" "unresolved placeholder" \
    "a READY specification carrying a placeholder"
  pass "a READY specification containing TBD is rejected"
}

test_ready_spec_with_open_blockers_is_rejected() {
  local spec="$TMP_ROOT/blocked.md"
  write_ready_spec "$spec"
  sed 's/^- Blockers: none$/- Blockers: 1. the CSV column order is undecided (captain)/' \
    "$spec" > "$spec.tmp" && mv "$spec.tmp" "$spec"
  expect_rejected "$spec" "READY spec must declare '- Blockers: none'" \
    "a READY specification with an open blocker"
  pass "a READY specification with an open blocker is rejected"
}

test_spec_without_acceptance_criterion_is_rejected() {
  local spec="$TMP_ROOT/no-criterion.md"
  write_ready_spec "$spec"
  # Keep the acceptance-criteria section, remove the criterion inside it.
  sed 's/^### AC-1 .*$/Acceptance criteria are described in prose below./' \
    "$spec" > "$spec.tmp" && mv "$spec.tmp" "$spec"
  expect_rejected "$spec" "No acceptance criterion heading found" \
    "a specification with no acceptance criterion"
  pass "a specification with no acceptance criterion is rejected"
}

test_registration_checkers_accept_the_installed_gate() {
  local out
  out=$("$ROOT/bin/fm-doc-audience-check.sh") \
    || fail "the documentation audience check rejected the installed gate: $out"
  assert_contains "$out" "fm-doc-audience-check: ok" \
    "the audience check did not report success"
  out=$("$ROOT/bin/fm-skill-trigger-check.sh") \
    || fail "the skill trigger check rejected the installed gate: $out"
  assert_contains "$out" "fm-skill-trigger-check: ok" \
    "the trigger check did not report success"
  pass "both registration checkers accept the repository with the gate installed"
}

test_installed_links_resolve
test_ready_spec_passes
test_current_state_claim_with_verified_ref_still_validates
test_missing_required_section_is_rejected
test_ready_spec_with_placeholder_is_rejected
test_ready_spec_with_open_blockers_is_rejected
test_spec_without_acceptance_criterion_is_rejected
test_registration_checkers_accept_the_installed_gate
