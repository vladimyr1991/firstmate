# Retro backtest fixture: the 2026-08-11 fleet stall

This fixture exists so the landed retrospective procedure can be tested against a real
incident **blind**: the agent under test sees the evidence and the procedure, never the
expected answers.

Run it with `bin/fm-retro-backtest.sh`.

## The incident, stated without its findings

Around 03:00 local on 2026-08-11 a Claude session limit stopped the pipeline runs of the
three tasks that were live at the time.
Deliberately not recorded here: why the stall lasted as long as it did, what each state
transition meant, or what should change.
Those are the answers, and they live in the sealed key described below.

The three tasks live at the time were `fm-quota-autoresume`, `fm-quota-dash-grok`, and
`fm-lessons-learned`.

## What is in `evidence/`

Both files are raw contemporaneous watcher records, sliced to 2026-08-10 and 2026-08-11 and
sanitized only by replacing this home's absolute path with `$FM_HOME`.
No line was reordered, summarized, or annotated.

- `watch-deliveries-0810-0811.log` - every wake actually delivered to firstmate, with its
  timestamp and reason. A gap in this file is a period in which firstmate was woken by
  nothing.
- `watch-triage-0810-0811.log` - every wake the watcher absorbed instead of delivering, with
  the classification it absorbed the wake under.
- `landing-timestamps.md` - the three tasks' pull requests and their merge times, from the
  forge.

## What could NOT be preserved, and why

The brief for this backtest asked for each task's status log, run metadata, what `axi status`
reported, and the quota readings at each moment.
Teardown had already deleted `state/<id>.status` and `state/<id>.meta` for all three tasks
before this task started, and neither the axi run records nor the quota readings of that
morning were ever written to a durable file.

A smaller honest fixture beats a reconstructed one, so nothing here is reconstructed.
The surviving watcher logs happen to carry the timeline the missing files would have carried:
when each task last produced a wake, when the wakes stopped, how the watcher classified the
silence, and when firstmate was next woken.

One consequence for grading: the watcher's stale lines identify a worker by its pane, not by
task id, and the pane-to-task mapping lived in the deleted metadata.
An agent cannot be marked down for failing to attribute a pane to a named task.

## The sealed key

The grading key is `data/retro-backtest-0811/SEALED-expected-answers.md` in the operator's
private home - `data/` is gitignored, so the key is not in this repository and cannot reach a
checkout of it.
`bin/fm-retro-backtest.sh` refuses to run if the key, or `data/learnings.md`, is reachable
from the fixture or present in the composed prompt.
Read the key only when grading a result that is already final.

[`docs/verification/retro-backtest.md`](../../../docs/verification/retro-backtest.md) records
each run and its verdicts, which necessarily describe the key items in compressed form.
That is safe for the test rather than sloppy: the agent under test runs with every filesystem
tool denied, so no file in this repository is part of its input, and the guards above cover the
one path that could reach it - a copy of the key placed inside the fixture the prompt is built
from.
