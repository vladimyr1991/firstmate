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
fm-skill-compact-check: fmx-respond compacted baseline_tokens=10448 tokens=8603 delta=-1845 (-17.7%) pointers=43 boundaries=41 scenarios=30
fm-skill-compact-check: harness-adapters compacted baseline_tokens=15173 tokens=14267 delta=-906 (-6.0%) pointers=96 boundaries=25 scenarios=38
fm-skill-compact-check: secondmate-provisioning compacted baseline_tokens=6811 tokens=6324 delta=-487 (-7.2%) pointers=45 boundaries=29 scenarios=24
fm-skill-compact-check: ok checked=26 changed=3 compacted=3 retired_boundaries=0
```

| Skill | Baseline tokens | After | Delta | Scenarios | Control (original) | Blind (compacted) |
|---|---|---|---|---|---|---|
| secondmate-provisioning | 6811 | 6324 | -487 (-7.2%) | 24 | 24/24 | 24/24 |
| fmx-respond | 10448 | 8603 | -1845 (-17.7%) | 30 | 30/30 | 30/30 |
| harness-adapters | 15173 | 14267 | -906 (-6.0%) | 38 | 38/38 | 38/38 |

`retired_boundaries=0`: no stated safety boundary was retired in any of the three, so none of this needed the captain-merge path.

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

## Detector calibration

Two false-positive classes were found and fixed against real repository text, both in the boundary detector:

- Hyphen-joined uses are adjectival or are flag names, not rules: "the never-observed zero-whitespace form" and `--always-approve`.
- Harnesses name an event `Stop`, so "Stop hook", "Stop payload", and "Stop `asyncRewake` continuation" are things rather than rules. As a rule verb, "stop" is lowercase mid-sentence or imperative at the start of a statement, and that split is what the detector encodes.

## Honest limits

Boundary matching pairs statements by keyword family and shared significant terms.
It reliably catches deletion, which is the failure mode compaction causes.
It does not prove that a surviving statement still *means* the same thing - that is the scenario suite's job, and no amount of string matching substitutes for it.

`harness-adapters` compacted least (-6.0%) because it is dense per-adapter reference material rather than prose: most of its length is empirically verified facts with one owner each.
Pushing it further would have meant deleting verified facts rather than duplication, so it was left there deliberately.

## Reproducing

```sh
bin/fm-skill-compact-check.sh                      # all changed skills, both axes
bin/fm-skill-compact-check.sh --skill fmx-respond  # one skill
bin/fm-skill-compact-check.sh --prompt fmx-respond # blind re-answer prompt
bin/fm-skill-compact-check.sh --prompt fmx-respond --baseline <ref>   # control prompt
bash tests/fm-skill-compact-check.test.sh          # 22 behavior tests for the gate itself
```
