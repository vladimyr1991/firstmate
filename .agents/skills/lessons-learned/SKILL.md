---
name: lessons-learned
description: >-
  Agent-only policy for turning a finished task into a durable improvement instead of letting it evaporate.
  Load after a ship task's landing is confirmed and before its teardown, and when adjudicating, routing, or auditing an improvement proposal a landed task produced.
user-invocable: false
metadata:
  internal: true
---

# Lessons learned

This skill is the single policy owner for the retro pass between landing and teardown.
`bin/fm-retro.sh --help` owns the command syntax, the facts block, the attestation, and the teardown gate mechanics.
This file owns only the semantics: who drafts, what routes where, and who may merge it.

## When

After landing is confirmed, before teardown.
Cleanup erases the task's volatile records, so a retro attempted after teardown has lost the evidence it needed.
Ship teardown refuses without the attestation and names the fixing command.

## Who

The landing worker drafts the candidate lessons, because it holds context nobody else has: what it tried first, what the brief failed to say, and which dead end cost the most.
Firstmate then adjudicates routing and authority; the drafting worker never merges its own proposal.
When the collected facts show real struggle - any escalation or blocker, a repeated evaluation round, or a stall the worker itself noticed - a reviewer **on a different vendor** audits the draft before it goes anywhere.
This is the independence principle `frontend-evaluator` already states, for the same reason: a critic sharing the author's model shares its blind spots.

## Draft prompts

Draft from the work, not from the report: the most valuable lessons are what the worker tried and abandoned, which a polished report usually omits.
Answer each of these explicitly, and say "nothing" where nothing applies.

1. What did this work leave behind in a shared or live system, and what removes it?
2. Which probe, command, or tool would have been cheaper, safer, or less destructive than the one reached for first?
3. Which wrong-but-plausible explanation cost the most time, and what evidence would have killed it sooner?
4. Which name, flag, secret, or setting meant two different things in two places?
5. What did the brief fail to say that the worker had to discover?
6. Where did a gate go green without proving what it was written to prove?
7. Which instruction, steer, or hygiene fix from firstmate itself made this outcome more likely, and what would have caught it?
8. Which failure hit more than one worker at once, and what would have turned the first one into a signal to check the rest?

Prompts 7 and 8 come from the blind backtest of the 2026-08-11 fleet stall, recorded in [`docs/verification/retro-backtest.md`](../../../docs/verification/retro-backtest.md).
Prompts 1 to 6 all ask what the worker did, so a retro answering only those blames only the worker and never reaches firstmate's own contribution, which is what that backtest missed.

## Routing

Route every candidate lesson through the seven-tier knowledge-placement decision tree in `firstmate-coding-guidelines`.
Stop at the first tier that answers yes; that skill is the one owner of the tree, and this file deliberately does not restate it.
A lesson that lands in no tier is not a lesson - it is task evidence, and it stays in the task record.
Check the destination before proposing: a lesson the work already wrote into its owner is closed, and re-proposing it produces a second copy the one-owner rule forbids.

## Improve versus create

Improving an existing skill is the default.
Most lessons are a missing sentence, a wrong default, or an unstated failure mode in something that already exists; find that owner and patch its language rather than adding a second, competing statement.
Create a new skill only when no existing skill owns the trigger, and only while naming the load condition in the same breath - "load before X", "load on Y wake".
A skill whose trigger is a vague pointer is dead weight: nothing will ever load it.

## Registration checklist for a new skill

Miss one and the skill is invisible:

1. `SKILL.md` with frontmatter, including `name`, `description`, and `user-invocable`.
2. An `agent-runtime` entry in `docs/documentation-audiences.json`.
3. A one-line trigger in `AGENTS.md` section 13, stated as a load condition, for an agent-only skill; a `user-invocable` skill is exempt because the captain invokes it by name, and adding that line would create exactly the dead entry the trigger rule exists to prevent.
4. Delivery through the no-mistakes PR path like any other tracked change.

`bin/fm-skill-trigger-check.sh` owns and enforces that distinction along with item 1, and `bin/fm-doc-audience-check.sh` enforces item 2.

## Provenance

Every proposal records the originating task id, the concrete evidence behind it, and what it supersedes.
No lesson enters an instruction file as an unattributed assertion.
A reader who disagrees with a rule must be able to find out which task produced it and on what evidence, or the rule cannot be revisited later.

## Authority

Split by blast radius, per the captain's explicit decision:

- Editing an existing skill merges autonomously when green.
- Creating a new skill, or touching `AGENTS.md`, requires the captain's merge.
- **Narrow exception:** an edit that changes a stated safety boundary inside an existing skill - a prohibition, a hard gate, a never/always rule - escalates to the captain regardless of how small the diff is.

Blast radius is about what the change can cause, not how many lines it touches.

## Prohibition

Never edit a skill mid-flight to capture a preference.
A preference noticed during live work goes to the task record or the captain-preference destination `AGENTS.md` selects; it becomes a skill change only through this pass, with its evidence attached.
`/stow`'s "no skill storage" exclusion stays in force: this skill is the human-scoped path that exclusion points at, not a way around it.

## Operating sequence

1. Confirm landing.
2. Run the script's `collect` command while the task's volatile records still exist.
3. Read the collected facts, then answer every draft prompt above from the work itself.
4. Order an independent cross-vendor audit when the facts show real struggle.
5. Route each surviving lesson through the decision tree, choosing improve over create.
6. Run the script's `complete` command with a key per routed lesson, or `--none` when the task taught nothing durable.
7. Deliver each accepted change through its project's delivery path under the authority split above.
8. Tear the task down.
