# Retired and consolidated statements: captain-operations

Read by `bin/fm-skill-compact-check.sh`, not by the agent at startup, so recording why a line went away costs no prompt budget.

The skill was written as one home's private notes and declared itself local and unshipped, while `docs/documentation-audiences.json` classified it as a tracked fleet-wide agent-runtime surface.
Resolving that contradiction in favour of the shared classification means the file must be true for every fleet home, so the one hard-coded home-specific value in it was generalized.
No safety boundary was retired: the delivery-flow rule it belonged to still binds, now stated against whatever fork the home actually pushes to.

- retired-pointer <<vladimyr1991/firstmate>>: the `gh --repo` step named one home's own fork, which is wrong in every other home; the step now says to pass the fork the home pushes to, which is the gate's push target from `no-mistakes init --fork-url` and matches `origin` only when the clone is itself the fork.
