---
name: spec-gate
description: >-
  Agent-only procedure for firstmate's mandatory specification gate in front of a non-trivial ship task.
  Load before dispatching any ship task, to judge whether the gate applies and to run it when it does.
  Load when a spec worker's draft comes back, before marking it READY or BLOCKED, and when a blocked specification's question must reach the captain.
user-invocable: false
metadata:
  internal: true
---

# Spec gate

This skill is the single owner of the gate between an authorized ship task and its implementation worker.
`write-implementation-spec` owns what a specification must contain, how the interview questions are written, and what READY and BLOCKED mean; this file owns only who does which part, and when.
The gate is the same whichever intake path produced the work: a captain request, a queued backlog item, and a Notion card all pass through it before an implementer is dispatched.

## When the gate applies

Every ship task passes the gate except genuinely mechanical work: a rename, a typo, a formatting sweep, a single-line edit.
Firstmate judges that line at intake and records which side the task fell on in the backlog item note, in one short phrase.
Work that is only small, not mechanical, is gated; `write-implementation-spec` keeps a small task's specification short, so the cost of gating one is a short specification rather than a ceremony.
A scout is not gated, because a scout already produces knowledge rather than a change.

## Who writes the specification

A dedicated spec worker inspects the repository and drafts the specification.
Firstmate never reads project code to write one: that split is what keeps hard rule 1 intact while the gate still rests on real repository evidence.

1. Scaffold a scout brief with `bin/fm-brief.sh <task-id> <repo> --scout`, and fill `{TASK}` with the captain's own request, the resolved project, and the instruction to follow `write-implementation-spec` and deliver its specification as the scout report.
   A crewmate in a project worktree cannot load a firstmate skill by name, so give the brief the absolute path of that skill's `SKILL.md` in firstmate's own checkout rather than its name alone.
   When the task carries a Notion card, the brief also requires the worker to end its report with a section titled `## Постановка для карточки` holding the card-ready statement block, so firstmate publishes the worker's own words rather than re-deriving them.
2. Spawn it with `bin/fm-spawn.sh` and supervise it as an ordinary direct report under `AGENTS.md` section 8.
3. Read the returned `data/<id>/report.md` when it lands; it is a draft, and marking it READY is firstmate's act, never the spec worker's.
4. Run the interview below, then mark the specification READY or BLOCKED.
5. Only after READY, dispatch the implementation worker, with a brief that points at the READY specification's absolute path and carries the delivery mode and yolo posture resolved at intake.
   For a card-linked task, publish that statement into the card body first and dispatch only once the write is confirmed; `notion-board` owns its format, its bounds, and what a failed or diverged write means.

The spec worker's task author is firstmate, so its questions return as `needs-decision:` events on its own status and never reach the captain directly, exactly as hard rule 4 requires of every crewmate.
Check a draft's structure with `python3 .agents/skills/write-implementation-spec/scripts/validate_spec.py <path>` before reading it closely; a structural pass is necessary and never sufficient.
The spec worker is an ordinary scout, so its report, completion, and teardown follow `AGENTS.md` section 7's scout rules, including the `decision-hold-lifecycle` completion gate.
It leaves no code behind, so the implementation worker is a fresh dispatch rather than a promotion of the spec scout.

## The interview

Firstmate resolves every question it can from what it already holds: `data/projects.md`, `data/captain.md`, prior reports, and the evidence the spec worker inspected and cited.
Ask the captain only where a wrong guess changes user-visible behavior, money, data contracts, scope, or security.
Everything else is firstmate's to settle, and a question the captain should never have seen is a cost rather than diligence.

Put questions to the captain in batches of at most five, numbered, each carrying a recommendation firstmate would act on if the captain answered only "use your recommendation".
Follow `AGENTS.md` section 9: lead with the concrete decision and its consequence, and keep specification mechanics out of captain chat.
Send an answer that changes project detail back to the spec worker rather than rewriting the specification's repository claims yourself.

## When a specification is BLOCKED

A BLOCKED specification parks its own task and nothing else.
Register each genuinely captain-owned question as a hold through `decision-hold-lifecycle`, exactly as for any other unresolved decision found in a report, and leave that task waiting on it.
For a card-linked task, the same questions are also published onto the card, so the captain reads them where he wrote the request; `notion-board` owns that write.
Every other READY task keeps dispatching on its own schedule: one unanswered question must never idle the fleet.
When the captain answers, route it through that same owner, then return the task to this gate rather than straight to an implementation worker.
