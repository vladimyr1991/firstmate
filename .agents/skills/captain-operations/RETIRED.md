# Retired and consolidated statements: captain-operations

Read by `bin/fm-skill-compact-check.sh`, not by the agent at startup, so recording why a line went away costs no prompt budget.

The skill was written as one home's private notes and declared itself local and unshipped, while `docs/documentation-audiences.json` classified it as a tracked fleet-wide agent-runtime surface.
Resolving that contradiction in favour of the shared classification means the file must be true for every fleet home, so the one hard-coded home-specific value in it was generalized.

The delivery-flow step that carried that value told the reader which repository to give `gh`.
Two attempts to restate it fleet-wide were each wrong in a different way: the first held only in a home whose `origin` is its own fork, and the second inverted the flag's meaning, since it selects the pull request's base repository rather than the branch's push target.
That is the signal that no universally-true form of the rule belongs in this skill, so the step now points at `CONTRIBUTING.md`, which already owns the fork, parent, and push-target setup in full.
The rule still binds; it is stated once, in its owner, instead of being restated here.

- retired-pointer <<vladimyr1991/firstmate>>: the `gh --repo` step named one home's own fork, which is wrong in every other home; the step no longer names or derives any repository and points at `CONTRIBUTING.md` as the owner instead.
- retired-pointer <<--repo>>: the flag was named only to tell the reader which repository to pass it, and that instruction now lives solely in `CONTRIBUTING.md`.
- retired-boundary <<Always pass `--repo vladimyr1991/firstmate`, or PR creation fails with a confusing "no commits between">>: this was a real safety boundary, but it is not restated here under any wording, because every fleet-wide phrasing of it was either false in the layout `CONTRIBUTING.md` documents as standard or silently wrong about the flag; `CONTRIBUTING.md` is now its single owner.
