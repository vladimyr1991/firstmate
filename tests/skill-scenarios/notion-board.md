# Scenario fixtures: notion-board

Answers derived from `.agents/skills/notion-board/SKILL.md` at commit `b19e3fe`, which added the orphaned-status sweep.
See [README.md](README.md) for how these are used and why a fixture's answers are normally recorded before the edit.

These scenarios are the exception the README's compaction case does not cover: they probe a decision the skill could not make at all before this change, so the control run against the pre-edit text is expected to answer differently.
That difference is the point - it reproduces the miss the captain found by hand on 2026-08-14, a card sitting at `В работе` with no task behind it that the eligibility sweep structurally cannot see.
From here on they are an ordinary regression baseline for the detection behavior.

## S1 - an active card the live link list does not name

**Situation:** A `sprint-check` wake launches the PM with a brief carrying `active_count: 2` and `linked_cards: https://notion.so/card-A, https://notion.so/card-B`.
The board holds no `Новая` card in `Stream=Деливери` this sprint, and one card `https://notion.so/card-C` sits at `Status=В работе` with `Stream=Деливери` and `Sprint=🏃 Текущий спринт`.

**Question:** By the end of that scan, what writes does the PM make to card C on the board, and what does it put in its scout report and on the rolling status page?

**Expected answer:** None: it leaves card C exactly as it is at `В работе`, does not dispatch work for it, and does not treat it as eligible.
It writes card C into its scout report as a divergence and lists that divergence on the rolling status page `📊 PM — текущий спринт`.

**Anchor:** "The orphaned-status sweep finds the divergence this table cannot produce: a card the board shows as active with no task behind it." / "Reporting a divergence means leaving the card exactly as it is, writing it into the PM's scout report, and listing it on the rolling status page."

## S2 - an idle fleet and an explicitly empty list

**Situation:** The brief carries `active_count: 0` and `linked_cards: none`.
The eligibility sweep returns nothing, and the second sweep returns one card at `Status=На ревью`.

**Question:** Does the PM issue the second query at all, and what does the scan produce for that card - silence, or a named finding?

**Expected answer:** It issues the second query, because `linked_cards: none` arms the sweep exactly like a populated list rather than skipping it.
That card is a divergence and is named in the report, and the "found nothing, end the turn silently" rule does not silence it even though nothing was dispatched.

**Anchor:** "`linked_cards: none` is not that case and never skips the sweep - it is the answer that no task is live, so every card the sweep returns is a divergence." / "A divergence the orphaned-status sweep found is something to say, so it is reported even when no card was dispatched."

## S3 - a brief with no link list at all

**Situation:** The brief carries `active_count: 1` and remaining capacity, but no `linked_cards` line anywhere in it.
The board holds two cards at `Status=В работе` this sprint.

**Question:** What does the PM conclude about those two cards, and how many `query_data_sources` calls does the scan spend?

**Expected answer:** It concludes nothing about them and reports no divergence from that sweep, because a test it cannot answer is not evidence that every active card is orphaned and firstmate owns supplying the list.
It skips the second query for that scan, spending one `query_data_sources` call, and continues to the capacity step.

**Anchor:** "If the brief carries no `linked_cards` line at all, skip this sweep for that scan and report no divergence from it." / "Only when that line is missing entirely, skip the query and the sweep's report for this scan and continue to the next step."

## S4 - a live `notion_page=` link held by a finished task

**Situation:** Card D sits at `Status=В работе` and the backlog still holds a `notion_page=https://notion.so/card-D` note, but that task already reached a terminal status and was never recycled, so the brief's `linked_cards` list does not name card D.

**Question:** Is card D healthy because a `notion_page=` link still points at it, or is it a divergence?

**Expected answer:** It is a divergence, reported exactly like a card with no link at all.
Bare link presence is not the test, because `bin/fm-notion-link.sh` retires a link only on `--archive` at the recycle step, so a task that ended without being recycled leaves an active link behind; only the brief's list proves a task is still working the card.

**Anchor:** "A returned card the list does not name is a divergence and is reported exactly as above, whether no link points at it at all or its only live link is held by a task that already reached a terminal status without being recycled."

## S5 - the same divergence on the next scan

**Situation:** The previous hourly scan already reported card C as a divergence, firstmate has not acted on it yet, and the current scan's sweep returns card C again.

**Question:** Does this scan re-report card C, or suppress it as a repeat already named?

**Expected answer:** It re-reports it.
An unresolved divergence is deliberately re-detected and re-reported every cycle that runs the sweep, and a repeat is never suppressed because an earlier scan named the card.

**Anchor:** "Every scan that runs it re-detects an unresolved divergence, which is deliberately re-reported every such cycle until firstmate acts on it; never suppress a repeat because an earlier scan already named the card."

## S6 - the order of the two sweeps

**Situation:** This scan will both dispatch two eligible `Новая` cards and run the orphaned-status sweep.

**Question:** Which of the two runs first in the sprint-check procedure, and what does the PM do to the dispatched cards' `Status` relative to that?

**Expected answer:** The orphaned-status sweep runs first, as step 2, immediately after reading the board and before the capacity and dispatch step.
The PM only moves its own dispatched cards to `В работе` at the end of the dispatch step, after firstmate confirms which workers are durably running and linked, so the sweep never inspects cards this same scan just moved.

**Anchor:** "2. **Run the orphaned-status sweep when the brief carries a `linked_cards` line, including `linked_cards: none`.**" / "Stay live until firstmate confirms which dispatched workers are durably running and linked, then move only those cards to `В работе`."
