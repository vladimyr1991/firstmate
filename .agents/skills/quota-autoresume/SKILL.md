---
name: quota-autoresume
description: >-
  Agent-only procedure for work frozen on an exhausted model window.
  Use before ending any turn that defers, parks, or abandons work because a
  quota or usage limit is exhausted, on a `quota reset ready: ...` check wake,
  and whenever a worker is found parked on a usage-limit dialog.
  Owns the freeze registration decision, the provider and window evidence, the
  resume procedure per action, PM respawn, and the confirmed-resume rule that
  governs when an obligation may be discharged.
user-invocable: false
metadata:
  internal: true
---

# quota-autoresume

Load this at three moments:

- Before ending a turn in which any work is deferred, parked, or left unfinished **because a model window is exhausted**.
- On a `check:` wake whose line reads `quota reset ready: <subject>(<provider>/<window>,<verdict>) ...`.
- Whenever a worker is found parked on a usage-limit dialog, before touching its endpoint.

It exists because the wake system has no quota-reset event of its own.
On 2026-08-10 the fleet sat idle for roughly 28 minutes at full quota: the last wake fired six minutes before Claude's five-hour window reset, firstmate correctly deferred the work, and then nothing existed to wake it again.
A deferral whose only record is the sentence "I'll pick this up when the limit resets" is a silent stall.

The rule this skill enforces: **never end a turn on an unarmed intention.**
If work is frozen on a limit, either the reset is minutes away and the next ordinary wake will carry it knowingly, or the obligation goes on disk with a poll armed against it.

`bin/fm-quota-freeze.sh --help` owns the exact commands, flags, and exit codes; `bin/fm-quota-freeze-lib.sh`'s header owns the record format and the poll contract.
This skill owns only the decisions.

## Registering a freeze

Establish the exhausted provider before recording anything.
Take the provider family from the harness's own authoritative catalog, exactly as `AGENTS.md` section 4 requires for dispatch; never infer it from a harness, model, or source name.
The window itself does not need establishing: `fm-quota-freeze.sh add` selects the provider's least-remaining window from the same `quota-axi` reading and records that window's own `resetsAt`.

Choose the subject and the action together, because the action is what the wake will cause:

| Subject | When | Action |
| --- | --- | --- |
| the task id | a live worker is parked and will continue from where it stopped | `nudge` |
| the task id | the worker is gone, or was torn down, and must be launched again | `respawn` |
| `pm` | the board scan could not run, so the board is unattended | `respawn` |
| `firstmate` | firstmate itself deferred an action and must simply retry it | `repeat` |

Put what resuming actually requires into `--note`.
On the wake, that note is what tells you which board scan, which steer, or which deferred action was owed - the subject alone does not.

### When add refuses with exit 4

`add` refuses when no window of that provider is at or below the recovery floor.
That refusal is evidence, not an obstacle: it means the limit that stopped the work is one `quota-axi` does not model.
Grok's weekly usage cap is the known case - it sits invisible behind a healthy `credits` percentage, so two workers can hit a paywall while the reading still shows 42% remaining.

Do not force a freeze around that refusal.
There is nothing to observe, so the poll could only either stay silent forever or fire on a clock that means nothing.
Reroute instead: for grok specifically, tear the worker down while its worktree is still clean and respawn the same task on another vendor.
Tell the captain when a vendor is out for the week, since that changes what the fleet can be dispatched onto.

## On a `quota reset ready` wake

1. Read the registry with `bin/fm-quota-freeze.sh list` before anything else.
   The wake line names the subjects; the registry carries the action and the note that say what to do.
2. Take a fresh `quota-axi --json` reading.
   The poll's verdict is evidence, not authorization - a window can be exhausted again by the time you act on it.
3. Work each subject named in the wake, by its recorded action:
   - `nudge` - confirm the worker is alive with `bin/fm-crew-state.sh <id>`, then send one steer to continue.
     A worker that turns out to be dead is a `respawn`, not a failed nudge.
   - `respawn` - relaunch through the ordinary dispatch path for that kind of work, preserving the recorded worktree and any unlanded work.
     For a task that had commits, the replacement continues from them; never discard unlanded work to make a resume simpler.
   - `repeat` - perform the deferred action itself.
   - `pm` - dispatch the board PM through the durable fleet path per `notion-board`, never a harness-native subagent.
     Spawn at most one scanning PM, and none while one is already live.
4. Discharge each obligation with `bin/fm-quota-freeze.sh resolve <subject>` **only after the resume is confirmed** - the worker is running again, the PM is durably live, the deferred action is done.
   Resolving on intent rather than on confirmation is the one way to lose the work permanently: the record is what re-surfaces the obligation, and removing it early removes the only thing that would.
5. A verdict of `unverified` means the recorded reset is long past and `quota-axi` can no longer see that window at all.
   Confirm real headroom yourself before resuming, and treat a window that has genuinely vanished from the reading as the unobservable-limit case above.

A wake that re-surfaces an obligation you already saw means it was never discharged.
Either finish the resume, or - if it turned out the work should not resume - resolve it deliberately and say so, rather than leaving it to nag.

## A worker parked on a usage-limit dialog

Answer it with `bin/fm-limit-dialog.sh <task-id> --provider <provider>`, which selects the waiting option and arms the resume in one step.
Establish the provider first, the same way as for any freeze.

Two boundaries hold absolutely:

- **The paid option is never selected**, by the tool or by hand.
  Upgrading spends the captain's money and is their decision alone.
  If the dialog offers only paid options, that is the unobservable-limit case: reroute the work and tell the captain.
- **An ambiguous dialog is never answered by guessing a number.**
  The tool refuses with exit 3 and sends nothing.
  Read the pane yourself, and if the waiting option still cannot be identified with certainty, escalate rather than pressing a key.

Choosing to wait only unparks the pane; it does not make the work continue when the limit lifts.
That is why the freeze is armed as part of answering the dialog rather than left as a separate step to remember.
If the tool exits 4, the dialog was answered but nothing was armed - record the freeze before ending the turn.
A warning that the dialog is still on the visible pane is not a failed answer: the selection was sent, confirmed, and recorded, so read the pane rather than running the tool again, which would type a second selection into a live composer.

## What the captain hears

The registry and the poll are internal machinery and stay out of captain-facing chat.
Say what happened to the work: which project is waiting, roughly when it can continue, and that it will continue by itself.
Escalate immediately when a vendor is exhausted in a way that changes what can be dispatched, when a limit cannot be observed and work had to be rerouted, or when an upgrade decision is the only way forward.
