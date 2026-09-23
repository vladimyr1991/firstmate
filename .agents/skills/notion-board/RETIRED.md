# Retired and consolidated statements: notion-board

Read by `bin/fm-skill-compact-check.sh`, not by the agent at startup, so recording why a line went away costs no prompt budget.

The statement publication moved from a block prepended to the card body to one new page-level comment, which is the form the card's author asked for.
The comment tool takes no `allow_async` parameter and returns no `async_task`, so the asynchronous half of the old write has no reachable counterpart: there is no task id to poll, no terminal status to wait for, and no tool that could be called to look.
That is a retired safety boundary rather than a consolidation, because the rule it stated cannot fire on the new path instead of being restated elsewhere.
Everything the rule protected is preserved as the stronger statement that no poll exists at all: the connector reply remains the only authority, a `fetch` still never confirms, denies, deduplicates, bounds, or authorizes a publication, and `async-success`, `async-failed`, and `poll-timeout` stay recorded values of the `statement_publish:` line so every consumer of it and the status-sync row matching anything but a success keep working unchanged.

The guard's pointer aperture does not recognize connector tool names, so the lost `notion-get-async-task` mention below is recorded here deliberately rather than because the check named it.

- retired-pointer <<notion-get-async-task>>: the skill named the polling tool only to poll an `async_task` reply to a page-content write; the comment write returns no `async_task`, so nothing in this skill can call it and no other step ever did.
- retired-boundary <<An `async_task` reply is polled with `notion-get-async-task` for that exact task id, every 5 seconds and at most 12 polls, and only a terminal `succeeded` status is async success; `queued`, `running`, and `retrying` are not.>>: the bounded poll and its terminal-status-only success rule governed an asynchronous page-content write that the comment path cannot produce, so the rule binds nothing; the skill now states instead that no poll exists on this path and that the three async outcome values are unreachable while remaining recorded.

The eligibility filter no longer names a stream: on 2026-09-23 the captain asked the fleet to take current-sprint cards of every stream, not only delivery, after seeing many cards the PM never took.
The eligible and active sets now test `Sprint` and `Status` alone, the dispatchability test routes each card by the nature of its work to an implementation worker, a second mate, or the captain, and every other boundary of the filter - no next sprint, no backlog, no widening to find work - stands unchanged.

- retired-pointer <<Stream=>>: the eligible and active sets tested `Stream=Деливери`; the filter was widened to every stream by the captain's instruction, so no row is ever selected or excluded by its `Stream` value, and routing by the nature of the work replaces what the stream test used to approximate.
