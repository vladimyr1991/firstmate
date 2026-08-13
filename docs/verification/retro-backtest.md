# Blind backtest of the lessons-learned retrospective

Audience: maintainer-verification.
This record holds the active evidence that the retrospective procedure in
`.agents/skills/lessons-learned/SKILL.md` finds real lessons from evidence alone, without an
agent being told what to find.

## Why a blind test

The lessons that made the procedure worth building were written by hand, by firstmate, because
firstmate happened to notice.
A retrospective that only reproduces lessons it was handed proves nothing about that noticing.
An earlier backtest was contaminated in exactly that way: the expected findings were listed in
the brief given to the agent under test.

## How isolation is enforced

`bin/fm-retro-backtest.sh` is the runner, and its header owns the mechanics.
The four enforced properties, rather than asserted ones:

1. The entire input is one composed prompt, saved to the run directory before the model is
   called, so what the agent saw is inspectable afterwards.
2. The agent runs with every filesystem, shell, and network tool denied, from an empty
   temporary working directory.
3. The run is rejected if its own transcript contains a single tool use.
4. The fixture is scanned for the grading key and for the learnings file, and the composed
   prompt is scanned for their paths, before any model call.

Property 2 is why grading material may live in this repository at all: the agent under test
has no way to read a file, so a checkout is not part of its input.
The fixture guard exists for the other direction, where a copy of the key is accidentally
placed inside the fixture the prompt is built from.

## The 2026-08-11 fixture

`tests/fixtures/retro-backtest-0811/` preserves what survived the fleet stall of that morning,
when one Claude session limit stopped the pipeline runs of the three live tasks at once.
Its README owns the fixture's provenance and the list of evidence that could not be preserved:
teardown had already deleted every task's status log and metadata, and the quota readings of
that morning were never durable.
Nothing in the fixture is reconstructed.

## Run of 2026-08-13

Commands, from the repository root:

```
bin/fm-retro-backtest.sh check
bin/fm-retro-backtest.sh run --stamp run-1
```

Model under test: `opus`, with no tools.
Isolation report of that run: prompt of 532 lines, sha256
`a8bbdbec0ae6b7482dff7ecaf93384ade4a46ad91e1591290565fd2e9b0d3c26`, `tool uses in run: 0`,
zero references to either the grading key or the learnings file in the prompt.
The answer and its transcript stay in the operator's private run directory, because a graded
answer discusses the key.

Result against the three sealed key items, graded on substance:

| key item | verdict |
| --- | --- |
| work blocked on a quota limit needs an armed re-check at the reset instant, or it idles past it | found |
| a declared pause suppresses supervision, so it must carry a clearing condition someone watches | found |
| one shared vendor quota fails every worker on it at once, so the first limit is a signal to check them all | partially found |
| the hardest sub-item: firstmate's own earlier instruction contributed to the stall | missed |

The procedure produced both leading lessons unprompted, with the timestamps behind them, and
independently named the wrong-but-plausible explanation the key names.
It also declared what the evidence could not settle rather than filling the gaps.

## The change this run produced

The missed sub-item is a prompt gap, not only a fixture gap.
Draft prompts 1 to 6 all ask what the worker did, so a retrospective that answers them
faithfully still never examines the supervisor's own contribution.
Prompts 7 and 8 were added for that reason: prompt 7 asks what firstmate's own instruction or
hygiene fix made the outcome more likely, and prompt 8 asks which failure hit more than one
worker at once, which is the partially found item.

Re-running the backtest after a change to the procedure is the regression test for that
change.
The run is not automated, because grading is a judgment about substance rather than wording,
and because each run calls a model.

## Standing limitation

This fixture can never exercise the missed sub-item to completion: the evidence that would
carry firstmate's own steer lived in the status logs teardown had already deleted.
A future incident retro that runs before teardown is where prompt 7 gets its first real test.
