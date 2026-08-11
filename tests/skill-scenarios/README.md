# Skill scenario fixtures

A skill is prose, and a prose diff proves nothing.
But a skill's purpose is to make an agent decide correctly, and decisions are testable.
These fixtures compare the DECISIONS a skill produces, before and after it is rewritten, which is the repository's own test rule applied to instructions.

Each `<skill>.md` here holds numbered scenarios for one skill in `.agents/skills/`.
Every scenario states a situation, asks one question the skill is supposed to settle, records the answer derived from the skill text **as it stood before the edit**, and cites the line that answer came from.

## Why the answers are derived from the original

A scenario answered from the rewritten text proves only that the rewritten text is self-consistent.
The fixture is a regression baseline, so its answers must predate the change they are meant to catch, exactly as a behavioral test is written against the behavior being preserved rather than the code being written.

## The blind re-answer

`bin/fm-skill-compact-check.sh --prompt <skill>` prints the rewritten skill plus the questions, with the expected answers and anchors stripped out.
Feed that prompt to a **different vendor** from whoever wrote the rewrite, then compare its answers to the recorded ones.

The independence matters for the same reason it matters in the browser evaluation gate: an agent re-reading its own compression tends to recover the meaning it intended rather than the meaning that survived on the page.
A different model has no such memory, so an answer that changes localizes precisely what was dropped.

Acceptance has two axes and needs both: estimated size must fall, **and** every scenario must still answer the same way.
Size alone is a loss wearing a better number.

## Adding a scenario

Write scenarios that probe decisions with a wrong answer available - a resolution order, an exclusion, a refusal, a boundary between two similar-looking cases.
A scenario whose answer is obvious from the skill's title tests nothing.

Format, enforced by `bin/fm-skill-compact-check.sh`:

```markdown
## S<n> - <short title>

**Situation:** <what the agent is facing>

**Question:** <the one thing the skill has to settle>

**Expected answer:** <the answer derived from the pre-edit skill>

**Anchor:** <the pre-edit line or section the answer came from>
```
