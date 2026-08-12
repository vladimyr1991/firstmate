# Specification Contract

## Contents

1. Formatting rules
2. Required template
3. Acceptance-criteria rules
4. Type-specific minimums

## Formatting rules

- Keep the exact top-level section order below.
- Retain every section. Write `Not applicable — <reason>` when genuinely irrelevant.
- Prefer tables for field mappings, API contracts, UI states, permissions, and test matrices.
- Give every requirement a stable ID.
- Link requirements to acceptance criteria and verification where practical.
- Separate confirmed facts, approved assumptions, and implementation suggestions.
- Never use `TBD`, `TODO`, question marks standing in for decisions, or unlabeled alternatives in a `READY` spec.

## Required template

```markdown
# <Imperative task title>

## 1. Readiness

- Status: READY | BLOCKED
- Task type: <one or more types>
- Size: small | medium | large
- Author/decision owner: <name or role>
- Last clarified: <date if known>
- Evidence inspected: <paths, links, screenshots, tickets, or "none provided">
- Approved assumptions: <numbered list or "none">
- Blockers: <numbered list with owner, or "none">

## 2. Goal and outcome

- Problem: <current pain or failure>
- User/business outcome: <observable outcome>
- Success measure: <metric or binary observation>

## 3. Current state

<Reproducible present behavior and relevant architecture. Distinguish evidence from inference.>

## 4. Desired behavior

<End-to-end happy path followed by alternate and failure paths.>

## 5. Scope

### In scope

- <bounded change>

### Out of scope

- <explicit non-goal>

### Must not change

- <protected behavior, contract, component, data, or visual>

## 6. Detailed requirements

| ID | Requirement | Source | Priority |
| --- | --- | --- | --- |
| FR-1 | <single testable behavior> | author/evidence/approved assumption | must/should/could |

## 7. Interfaces and data contracts

<Exact UI inputs/outputs, API/event schemas, fields, validation, errors, persistence, ownership, compatibility, and examples. Use N/A with reason when irrelevant.>

## 8. UI and interaction specification

<Layout, exact content, components, states, responsive behavior, keyboard/focus, accessibility, animation, analytics, and visual references. Use N/A with reason when irrelevant.>

## 9. Edge cases and failure behavior

| Case | Expected behavior | User feedback | Recovery/observability |
| --- | --- | --- | --- |

## 10. Non-functional requirements

<Performance, reliability, security, privacy, accessibility, localization, logging, metrics, limits, and compliance. Use IDs such as NFR-1.>

## 11. Implementation boundaries

- Likely affected areas: <verified paths/symbols when known>
- Required reuse: <existing components/services/patterns>
- Forbidden changes: <boundaries>
- Compatibility/migration: <requirements>
- Suggested approach: <non-binding unless explicitly mandated>

## 12. Acceptance criteria

### AC-1 — <observable outcome>

- Given <specific starting state>
- When <single action/event>
- Then <observable result with exact values where relevant>
- Covers: <FR/API/NFR IDs>

## 13. Verification plan

| Level | Scenario | Method/command | Expected evidence |
| --- | --- | --- | --- |
| Static | <lint/type/schema> | `<exact command or discovery rule>` | <result> |
| Unit | <behavior> | `<command>` | <result> |
| Integration | <contract> | `<command/steps>` | <result> |
| E2E/manual | <user flow> | <steps + viewport/account/data> | <screenshot/log/result> |
| Regression | <protected behavior> | <method> | <result> |

## 14. Delivery, rollout, and rollback

<Dependencies, sequencing, feature flag, migration, deployment, monitoring, rollback trigger and action.>

## 15. Risks and open questions

- Risks: <risk, likelihood/impact, mitigation, owner>
- Open questions: none | <only low-impact questions for READY; blocking questions force BLOCKED>

## 16. Implementer handoff

- Deliverables: <code/tests/docs/migrations/assets>
- Completion report must include: <changed files, commands/results, screenshots/examples, deviations>
- Stop and escalate if: <conditions that invalidate the spec or require a product decision>
```

## Acceptance-criteria rules

- Test one behavior per criterion.
- Use concrete actors, roles, inputs, state, action, and output.
- Replace words such as `fast`, `correct`, `intuitive`, `properly`, and `responsive` with measurable behavior.
- Include exact values and boundary examples when calculations, validation, ordering, time, money, permissions, or limits are involved.
- Include at least one negative or failure criterion when failure is plausible.
- Do not encode internal implementation unless it is itself a constraint.

## Type-specific minimums

| Type | Minimum detail before READY |
| --- | --- |
| Frontend/UI | Source of visual truth; component states; responsive behavior; accessibility; API data states; screenshot/manual verification |
| Backend/API | Schemas and examples; auth/authz; error semantics; idempotency/concurrency; compatibility; contract tests; observability |
| Full-stack | End-to-end flow; ownership boundary; UI-to-API mapping; partial failure; integrated verification |
| Data/migration | Source/target schema; volume; backfill; mixed versions; validation; rollback; data-loss safeguards |
| Bug | Reproduction; actual vs expected; scope/severity; causal evidence or discovery plan; regression test |
| Refactor | Protected behavior; permitted boundary; characterization tests; objective completion condition |
| Infrastructure | Environment scope; desired state; secrets/permissions; rollout; health check; rollback |
| Research/spike | Decision; alternatives; evidence standard; time box; stopping condition; recommendation deliverable |

