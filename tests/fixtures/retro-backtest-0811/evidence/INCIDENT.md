# The incident

Around 03:00 local on 2026-08-11 a Claude session limit stopped the pipeline runs of the
three tasks that were live at the time: `fm-quota-autoresume`, `fm-quota-dash-grok`, and
`fm-lessons-learned`.

Firstmate is the supervising agent. It is woken only by events a watcher delivers to it:
worker status appends, turn-end markers, periodic heartbeats, and registered polls. The
watcher decides, for every event, whether to deliver it or absorb it; an absorbed event
wakes nobody. Both decisions are recorded in the logs below.

## What is in this directory

The two watcher logs are raw contemporaneous records, sliced to 2026-08-10 and 2026-08-11
and sanitized only by replacing the home's absolute path with `$FM_HOME`. No line was
reordered, summarized, or annotated.

- `watch-deliveries-0810-0811.log` - every wake actually delivered to firstmate, with its
  timestamp and reason. A gap in this file is a stretch during which firstmate was woken by
  nothing.
- `watch-triage-0810-0811.log` - every wake the watcher absorbed instead of delivering, with
  the classification it absorbed the wake under.
- `landing-timestamps.md` - the three tasks' pull requests and merge times, from the forge.

## What is missing, and why

Each task's status log and run metadata, what the validation pipeline reported for each run,
and the quota readings of that morning are all gone: cleanup deletes a task's volatile
records, and it had already run for all three tasks. The quota readings were never written
to a durable file at all.

Nothing here is reconstructed. Work the evidence that survived and state plainly where it
runs out.

One known limit: the watcher's stale lines identify a worker by its terminal pane, not by
task id, and the pane-to-task mapping lived in the deleted metadata. Where a pane cannot be
attributed to a named task, say so rather than guessing.
