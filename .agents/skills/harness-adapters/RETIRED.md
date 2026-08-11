# Retired and consolidated statements: harness-adapters

Read by `bin/fm-skill-compact-check.sh`, not by the agent at startup, so recording why a line went away costs no prompt budget.

Nothing here is retired: every rule the skill stated before the compaction still binds.
The single entry below is a statement that carried two separate consequences in one sentence and is now stated as two bullets, one per consequence.
The named survivor is verified to be present in the rewritten skill.

- consolidated-boundary <<This skill owns only the harness-relevant consequence: a secondmate's own crewmates use the primary's inherited dispatch profiles and static harness value, while `config/secondmate-harness` is the primary's own setting and is never inherited - secondmates do not spawn secondmates.>> -> <<`config/secondmate-harness` is the primary's own setting and is never inherited - secondmates do not spawn secondmates.>>: split into one bullet per consequence, the inherited-value half and the never-inherited half, both under the same inherited-local-material list.
