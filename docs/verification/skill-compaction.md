# Skill compaction verification

Active empirical evidence for the two-axis skill compaction gate.
Date: 2026-08-11.
Baseline commit for every measurement below: `6b39930`.

The rule this records: a skill rewrite is accepted only when estimated size falls **and** the skill's scenario suite still produces the same decisions.
Size alone is a loss wearing a better number, so neither axis is sufficient on its own.

## Tools

- `bin/fm-skill-compact-check.sh` - the deterministic half. Pointer survival, safety-boundary survival, size delta, and fixture presence.
- `tests/skill-scenarios/<skill>.md` - the behavioral half. Answers derived from the pre-edit skill.
- `bin/fm-skill-compact-check.sh --prompt <skill>` - renders the blind re-answer prompt with expected answers and anchors stripped.
- `bin/fm-skill-compact-check.sh --prompt <skill> --baseline <ref>` - renders the same questions against the pre-edit skill, read straight out of git, so producing a control never means stashing over live work.

Size comes from `bin/fm-startup-memory-budget-lib.sh` (`fm_startup_memory_estimated_tokens_for_bytes`, `ceil(UTF-8 bytes / 3)`), the repository's existing estimator, so this gate and the startup budget cannot disagree about the size of the same file.

## Independence of the blind re-answer

The compactions were written by Claude Opus 5.
Every scenario re-answer was produced by `codex exec` on `gpt-5.6-terra` (OpenAI Codex v0.147.0), run from an empty scratch directory with `--skip-git-repo-check` so the answering model saw only the prompt and could not read the repository.

The independence is the point: a model re-reading its own compression tends to recover the meaning it intended rather than the meaning that survived on the page.

## Results

```
$ bin/fm-skill-compact-check.sh
fm-skill-compact-check: firstmate-coding-guidelines changed baseline_tokens=3039 tokens=3429 delta=+390 (+12.8%) pointers=17 boundaries=11 scenarios=0
fm-skill-compact-check: fmx-respond compacted baseline_tokens=10448 tokens=8603 delta=-1845 (-17.7%) pointers=43 boundaries=41 scenarios=30
fm-skill-compact-check: harness-adapters compacted baseline_tokens=15173 tokens=14255 delta=-918 (-6.1%) pointers=96 boundaries=25 scenarios=38
fm-skill-compact-check: secondmate-provisioning compacted baseline_tokens=6811 tokens=6369 delta=-442 (-6.5%) pointers=45 boundaries=29 scenarios=24
fm-skill-compact-check: ok checked=26 changed=4 compacted=3 retired_boundaries=0
```

`firstmate-coding-guidelines` itself grew (+12.8%) documenting this gate, so it counts as `changed` rather than `compacted` and carries no fixture.

| Skill | Baseline tokens | After | Delta | Scenarios | Control (original) | Blind (compacted) |
|---|---|---|---|---|---|---|
| secondmate-provisioning | 6811 | 6369 | -442 (-6.5%) | 24 | 24/24 | 24/24 |
| fmx-respond | 10448 | 8603 | -1845 (-17.7%) | 30 | 30/30 | 30/30 |
| harness-adapters | 15173 | 14255 | -918 (-6.1%) | 38 | 38/38 | 38/38 |

`retired_boundaries=0`: no stated safety boundary was retired in any of the three, so none of this needed the captain-merge path.

That output block is the run as it stood on 2026-08-11 and is left verbatim.
The check has since renamed its per-skill `pointers=` and `boundaries=` fields to `baseline_pointers=` and `baseline_boundaries=`, added `boundaries_now=`, and added `inspected_boundaries=` and `uninspected_skills=` to the summary line, so a run today prints those names instead.
`baseline_boundaries=` is also a different number from the `boundaries=` it replaced, and deliberately so: this is a recorded deviation from the specification, which named only `inspected_boundaries=`, `boundaries_now=` and the `--coverage` column as counts of distinct statements and left the baseline field as raw keyword-family tuples.
Following that literally printed two numbers in two units side by side on one line, so subtracting `boundaries_now=` from `baseline_boundaries=` read as a loss that had not happened, and reporting real coverage is what this check exists to do.
Both fields now count distinct statements; the per-family tuples are still what the survivorship comparison iterates.
The 2026-08-11 `boundaries=` figures above are therefore tuple counts and do not line up with what a run prints today.

Blind numbers are re-runs against the current (post-fix) skill text, same independence setup: prompts rendered from the compacted skill, answered by `codex exec` on `gpt-5.6-terra` (OpenAI Codex v0.147.0) from an empty scratch directory with `--skip-git-repo-check`. No scenario fixture was edited at any point; all three fixtures are byte-identical to the versions the control run used.

- `secondmate-provisioning` 24/24: S16 now returns the control's answer verbatim - "pending config-reread generations are discarded or quarantined after cleanup failure" - confirming the restored branch is back in the reader-facing text.
- `harness-adapters` 38/38: the only flagged row is the long-standing S35 wording artifact, where the control opens "No specific harness is assumed" and the re-run opens "Harness is unknown" with an identical decision; S29 and S30, the scenarios nearest the corrected pointer sentence, both match.
- `fmx-respond` is unchanged by the fix commit (byte-identical `SKILL.md`), so its 30/30 stands from the original run and needed no re-run.

## Why the control run is mandatory

Every fixture was answered against the **original** skill before the compaction was written.
That baseline is what makes a later mismatch attributable.

It paid for itself immediately.
`fmx-respond` S19 ("Does the reply post?") came back with correct reasoning and an inverted yes/no label - and reproduced the inversion on the **unedited** skill across samples.
Without the control it would have read as damage the compaction caused; with it, the diagnosis was an unstable question, and the fixture was repaired to ask for the observable (`relay` vs `state/x-outbox/`) instead of a polarity.

## What each half caught that the other could not

Both halves found real losses, and neither would have found the other's.

The deterministic check caught, in `fmx-respond`, three statements whose rewrite had drifted so far that the rule was no longer recognisably present: the acknowledge-first sequence, the link-before-cleanup ordering, and its deliberate restatement at the cleanup step.
A prose diff shows those as "shorter and still reads fine".

The scenario suite caught what the check structurally cannot.
In `harness-adapters`, collapsing the per-concern watcher section dropped the *reason* Codex uses a bounded foreground checkpoint - that it cannot reason while a foreground tool call is running.
That sentence contains no pointer and no never/always/must/refuse/stop keyword, so nothing deterministic could flag it; scenario S36 asks "why", and the answer changed.
Restored, and re-verified.

The scenario suite also caught, then nearly lost, a real miss in `secondmate-provisioning`: the compaction dropped the "or quarantined after cleanup failure" branch from a reader-facing answer.
That sentence carries no pointer and no never/always/must/refuse/stop keyword, so the deterministic check could not see it either.
The scenario suite did detect it - S16's answer changed - but the first comparison of control vs. blind was polarity-based, and both the control and blind answers happened to begin with "No", so the divergence was missed and the compaction was first reported as a clean 24/24.
The true pre-fix figure was 23/24.
The pipeline's own review step caught the miss, the branch was restored, and the re-run above is the genuine 24/24.
This is the strongest evidence in this document for why the two-axis rule needs both a deterministic check and a scenario suite: each covers a gap the other has, and even the scenario suite's own comparison step can miss a divergence if the comparison is too shallow.

## Detector calibration

Two false-positive classes were found and fixed against real repository text, both in the boundary detector:

- Hyphen-joined uses are adjectival or are flag names, not rules: "the never-observed zero-whitespace form" and `--always-approve`.
- Harnesses name an event `Stop`, so "Stop hook", "Stop payload", and "Stop `asyncRewake` continuation" are things rather than rules. As a rule verb, "stop" is lowercase mid-sentence or imperative at the start of a statement, and that split is what the detector encodes.

## Honest limits

Boundary matching pairs statements by keyword family and shared significant terms.
It reliably catches deletion, which is the failure mode compaction causes.
It does not prove that a surviving statement still *means* the same thing - that is the scenario suite's job, and no amount of string matching substitutes for it.

The count itself is the other limit, and the check now states it rather than leaving it to be inferred: `inspected_boundaries=` is how many statements the boundary half looked at, and a zero for a skill means it looked at none of that skill's rules rather than that the skill is intact.
Every such skill is named on stderr as `NOT COVERAGE`, and `bin/fm-skill-compact-check.sh --help` owns the full statement of what a green result does and does not assert.

Only one of the two axes is machine-enforced.
The check owns the size delta and refuses a material shrink that carries no fixture, but it cannot run the blind re-answer, because that needs a second vendor's model.
So "the scenario suite passed 100%" is an agent-run result recorded here with its evidence, not something CI can assert - treat a compaction whose blind run was never done as unverified, however green the check is.

`harness-adapters` compacted least (-6.1%) because it is dense per-adapter reference material rather than prose: most of its length is empirically verified facts with one owner each.
Pushing it further would have meant deleting verified facts rather than duplication, so it was left there deliberately.

## Reproducing

```sh
bin/fm-skill-compact-check.sh                      # all changed skills, both axes
bin/fm-skill-compact-check.sh --skill fmx-respond  # one skill
bin/fm-skill-compact-check.sh --prompt fmx-respond # blind re-answer prompt
bin/fm-skill-compact-check.sh --prompt fmx-respond --baseline <ref>   # control prompt
bin/fm-skill-compact-check.sh --coverage           # how much of each skill the boundary half inspects
bash tests/fm-skill-compact-check.test.sh          # 39 behavior tests for the gate itself
```
