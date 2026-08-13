# Retired and consolidated statements: captain-operations

Read by `bin/fm-skill-compact-check.sh`, not by the agent at startup, so recording why a line went away costs no prompt budget.

The skill was written as one home's private notes and declared itself local and unshipped, while `docs/documentation-audiences.json` classified it as a tracked fleet-wide agent-runtime surface.
Resolving that contradiction in favour of the shared classification means the file must be true for every fleet home, so the one hard-coded home-specific value in it was generalized.

The delivery-flow step that carried that value also told the reader which repository to give `gh`.
Two attempts to restate that answer fleet-wide were each wrong in a different way: the first held only in a home whose `origin` is its own fork, and the second inverted the flag's meaning, since it selects the pull request's base repository rather than the branch's push target.
No safety boundary was retired.
What the step keeps is the part that is true in every home - the hazard itself, that `gh` cannot be assumed to target the right repository - while the fork, parent, and push-target setup stays owned by `CONTRIBUTING.md` rather than being restated here.

- retired-pointer <<vladimyr1991/firstmate>>: the `gh --repo` step named one home's own fork, which is wrong in every other home; the step now states the hazard without naming or deriving any repository, and points at `CONTRIBUTING.md` for the setup.
- consolidated-boundary <<Always pass `--repo vladimyr1991/firstmate`, or PR creation fails with a confusing "no commits between">> -> <<Never assume `gh` targets the right repository: a wrong `--repo` makes PR creation fail with a confusing "no commits between".>>: the boundary still binds and still names the same flag and the same failure, but it is stated as the hazard rather than as one home's answer, because no single repository name or derivation rule is true fleet-wide.
