# Retired and consolidated statements: lessons-learned

Read by `bin/fm-skill-compact-check.sh`, not by the agent at startup, so recording why a line went away costs no prompt budget.

The operating sequence's ship-base step used to tell the reader to insert `base=<ref>` above the `pr=` line, because the PR metadata identity check read any unrecognized line after `pr=` as tampering.
That check now names `base=` in its allowed-key whitelist, exactly as it already named the `x_*` link keys, so the key parses in either position and the ordering instruction it justified no longer describes real behavior.
The step keeps the condition that produces the fact and the result it produces: a project shipping from a branch its default ref lags behind records the ship base before collection, and the collected `commit_base` still names the ref that was used.
No safety boundary was retired.

- retired-pointer <<pr=>>: the step named the `pr=` metadata key only to explain why the ship base had to be inserted above it; the identity parser now whitelists `base=` at either position, so nothing in this skill depends on where `pr=` sits.
