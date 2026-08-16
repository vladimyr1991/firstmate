---
name: write-implementation-spec
description: Turn vague product, UI, frontend, backend, API, data, integration, infrastructure, refactoring, and bug-fix requests into implementation-ready technical specifications. Use when drafting or refining tickets, technical tasks, feature briefs, implementation plans, acceptance criteria, developer handoffs, or agent-ready prompts. Inspect available project context first, interview the task author about material ambiguity, block implementation while consequential questions remain unresolved, and produce a precise READY or BLOCKED specification that a less capable coding agent can execute without guessing.
user-invocable: false
metadata:
  internal: true
---

# Write Implementation Spec

Create a contract for implementation, not a polished restatement of the request. Optimize for a coding agent that has repository access but weak judgment and little product context.

## Non-negotiable rule

Do not mark a task `READY` and do not begin or recommend implementation while a material unknown could change user-visible behavior, scope, data contracts, architecture, security, migration, or acceptance criteria.

Resolve an unknown in exactly one of these ways:

1. Discover the answer from authoritative project context.
2. Ask the task author and receive an answer.
3. Record an explicit assumption that the task author has approved.

Never silently choose a product decision. Safe, local implementation details may remain delegated to the implementer when the specification defines the boundary and verification outcome.

## Workflow

### 1. Inspect before asking

Read the request and all supplied artifacts. When repository access exists, inspect the smallest relevant surface:

- project instructions and architecture notes;
- neighboring components, routes, services, schemas, tests, and conventions;
- screenshots, designs, API documentation, tickets, and linked discussions;
- build, lint, test, preview, and migration commands.

Do not ask the author for facts that can be discovered safely. Cite concrete paths, symbols, endpoints, or screenshots in the eventual specification. If no repository or artifacts are available, say which details could not be verified.
When a specification makes a repository-current-state claim, record the exact inspected ref - branch and resolved SHA - that verified the claim.

### 2. Classify and size the task

Classify it as one or more of: `frontend`, `backend`, `full-stack`, `API/integration`, `data/migration`, `infrastructure`, `bug`, `refactor`, or `research/spike`.

Choose proportional depth:

- `small`: localized change with no contract, data, security, or migration impact;
- `medium`: multiple states/components or one external/internal contract;
- `large`: cross-system behavior, migration, permissions, money, sensitive data, or rollout risk.

Keep small tasks concise. Do not manufacture user stories, layers, or requirements that do not reduce ambiguity.

### 3. Build an ambiguity ledger

Separate the request into:

- `Known`: supported by the author or inspected evidence.
- `Inferred`: likely but not confirmed; include evidence and confidence.
- `Unknown`: missing information.
- `Conflict`: statements or artifacts that disagree.

Audit at least these dimensions:

1. goal, user, and measurable outcome;
2. current behavior and exact desired behavior;
3. in-scope and explicitly out-of-scope work;
4. flows, states, validation, errors, empty/loading/permission cases, and edge cases;
5. data models, API/event contracts, ownership, idempotency, and compatibility;
6. UI layout, content, interaction, responsive rules, accessibility, and visual reference;
7. security, privacy, authorization, abuse, and destructive actions;
8. performance, reliability, observability, migration, rollout, and rollback;
9. verification method and observable acceptance criteria.

Read [references/question-bank.md](references/question-bank.md) for the relevant task types. Do not ask every question in the bank.

### 4. Interview the task author

Ask only questions whose answers can materially change the implementation or its acceptance. Prioritize blockers, then high-impact decisions.

- Ask in batches of at most five numbered questions.
- Explain the affected decision in one short phrase.
- Offer two or three concrete options when the likely choices are known.
- Mark a recommended option and explain its tradeoff.
- Allow a free-form answer and `use your recommendation`.
- Distinguish `must answer` from `optional refinement`.
- After each answer batch, update the ambiguity ledger and ask the next batch only if necessary.

If the author cannot answer, propose a conservative assumption. It remains unresolved until the author explicitly accepts it.

While blockers remain, return a concise `BLOCKED` summary plus questions. Stop there. Do not hide questions inside a seemingly final specification.

### 5. Write the specification

Once blockers are resolved, read [references/spec-contract.md](references/spec-contract.md) and follow its exact section order. Write in the author's language unless the harness requires another language.

Make the specification executable:

- use exact names, paths, routes, endpoints, fields, states, breakpoints, copy, error behavior, and commands when known;
- separate product requirements from suggested implementation;
- label every remaining low-impact assumption;
- use stable requirement IDs such as `FR-1`, `API-1`, and `NFR-1`;
- make acceptance criteria independently observable and express important behavior as Given/When/Then;
- include positive, negative, boundary, loading, empty, permission, retry, and regression coverage where relevant;
- define what must not change;
- specify evidence the implementer must return: changed files, test results, screenshots, API examples, migrations, or logs as appropriate.

When the specification prescribes a test seam - a fixture, environment flag, media emulation, or hook - verify it against the project's own testing documentation and a one-line measurement on the dispatch base.
Prefer project-proven seams over framework documentation.
If the project documents that a Playwright fixture does not reach the page, prescribe the working form, not the non-working framework-default form: for a project whose config force-feeds the fixture form's effect, that is `page.emulateMedia({ reducedMotion: 'reduce' })` called explicitly before `goto` rather than the bare `test.use({ ... })` fixture.

Never invent repository facts. Use `To be discovered by implementer` only for low-impact local details and define how discovery must be performed. A `READY` spec must contain no `TBD`, `TODO`, undecided alternatives, or unanswered product questions.

### 6. Apply the readiness gate

Mark `READY` only when all statements below are true:

- the goal and observable outcome are unambiguous;
- scope and non-goals are explicit;
- behavior is defined for relevant states and failure paths;
- affected contracts and compatibility expectations are defined;
- acceptance criteria can pass or fail without subjective interpretation;
- verification can be run or manually reproduced;
- dependencies, risks, rollout, and required approvals are recorded;
- no unresolved choice can cause meaningful rework;
- A specification that makes a component READ a new record must name the component that WRITES it, or state explicitly that the record is recorded by hand and by whom.
  If it is recorded by hand into a file another component parses, the spec must also name every existing parser of that file and say what the new key's position and format must satisfy - a hand-edited key is a change to that file's contract, not an addition beside it.

Otherwise mark `BLOCKED`, name each blocker, identify its owner, and ask the minimum next questions.

For an existing draft, run `python3 scripts/validate_spec.py path/to/spec.md` from this skill directory. Treat structural success as necessary but not sufficient; manually assess semantics and repository accuracy.

## Handoff behavior

If the user requested only a specification, stop after delivering it.

A specification that makes a repository-current-state claim binds whichever agent implements it, including a separately dispatched implementer that never saw the inspection: before its first edit that implementer re-runs the cited current-state checks against the actual dispatch base, and reports any disagreement as a deviation rather than silently preserving or overturning the claim. Carry this obligation in the specification itself, next to the claim and its recorded ref, so a fresh implementer receives it with nothing but the specification.

If the same agent is also asked to implement:

1. complete the readiness gate first;
2. show the final spec or obtain approval if the change is high-risk;
3. re-run the specification's cited current-state checks against the actual dispatch base before the first edit;
4. implement strictly within scope;
5. verify against every acceptance criterion;
6. report deviations - including disagreement with a cited current-state claim - instead of silently changing the specification.

Do not let implementation discoveries silently rewrite product intent. Escalate any discovery that invalidates a requirement or approved assumption.
