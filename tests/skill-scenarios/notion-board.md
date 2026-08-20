# Scenario fixtures: notion-board

These scenarios probe the four contract defects the first witnessed sprint-board scan reported, plus the witnessed-read rule that had to survive them unchanged.
Unlike a compaction fixture, whose answers predate the edit, S1 to S3, S5, and S6 to S8 record the answer the repaired contract owes, because the pre-edit text settled none of them.
S6 to S8 belong to the later change that publishes a card's refined statement into its body before the implementer starts, and they record what that step owes: when the write happens relative to the spawn, what a write that keeps failing rules, and how much of a specification may reach a card.
The control run against the pre-edit skill is therefore expected to answer `NOT STATED` for those, which is what makes each one a regression a reader can see close.
S4 is the opposite kind: it records an answer the pre-edit text already gave, so a control and a post-edit run must agree on it.

## S1 - A capacity block that contradicts itself

**Situation:** The PM brief carries `active_count: 2` and `linked_cards: https://www.notion.so/card-A`, a one-entry list. The witnessed read came back with rows, and one of them is an eligible, dispatchable `Новая` card.

**Question:** How many cards does the PM dispatch this cycle, what `Status` do the eligible cards sit at when the cycle ends, and what does the PM write about the two capacity figures?

**Expected answer:** It selects and dispatches no card, and every eligible card stays at `Новая` for the next scan. It reports the contradiction with both figures and the `linked_cards` list quoted, in its scout report and on the rolling status page, and never recomputes capacity or picks one of the figures to trust.

**Anchor:** "What the PM may take", the paragraph beginning "`active_count` and `linked_cards` must correspond".

## S2 - A witnessed cycle that found nothing

**Situation:** The read came back witnessed, the eligible set is empty, the orphaned-status sweep found no divergence, and no CHECK FAILED condition occurred.

**Question:** Does the PM still write its scout report and its `done:` status line, and what does it send to the captain or write to the board?

**Expected answer:** The scout report and the `done:` status line are always written, whatever the cycle found. Silence means only that there is no captain-facing update and no board write.

**Anchor:** "Waking on a sprint-check", step 3.

## S3 - Whether the rolling status page is rewritten

**Situation:** Around eleven sprint-check cycles run each weekday. This one is witnessed, dispatched and moved no card, found no divergence and no malformed capacity block, and was not CHECK FAILED.

**Question:** Does the PM call `replace_content` on `📊 PM — текущий спринт` this cycle, and what does that page hold afterwards?

**Expected answer:** No, it writes nothing to the page, which keeps exactly the content it already had. A rewrite is owed only on a cycle that dispatched or moved a card, could not take a card, found a divergence or a malformed capacity block, or was CHECK FAILED.

**Anchor:** "Reporting", the `📊 PM — текущий спринт` entry.

## S4 - A retry that also comes back empty

**Situation:** The witnessed read's first attempt returns zero rows with no error, so the PM re-runs the same read, and the second attempt also returns zero rows.

**Question:** How many further attempts of that read may this cycle make, and what does the PM conclude and report about the board?

**Expected answer:** None: the one retry a zero-row first attempt earns is already spent, and it is never a loop. The cycle is unwitnessed and therefore CHECK FAILED, so the PM draws no conclusion from board content, dispatches nothing, and reports the failed check in its scout report and on the rolling status page.

**Anchor:** The witnessed-read section, "A first attempt that returns zero rows ... earns one retry" through "Every unwitnessed cycle is CHECK FAILED."

## S5 - An active card the malformed list does not name

**Situation:** The same brief as S1, `active_count: 2` beside a `linked_cards` list holding only `card-A`. The orphaned-status sweep's active set holds `card-A` and `card-B`.

**Question:** What does the PM report about `card-B` on this scan?

**Expected answer:** Unknown-not-orphaned, and no divergence at all from that sweep this scan, exactly as an incomplete cross-home snapshot rules. The list may be short by as many entries as the contradiction implies, so a card missing from it is not evidence that no task is working it.

**Anchor:** "Status sync", the orphaned-status sweep rules, which own this verdict and reuse their own incomplete-cross-home-snapshot ruling for it.

## S6 - When the statement reaches the card

**Situation:** A card-linked task's specification has just been marked READY. The card's body holds no `## Постановка (как понята)` heading, and capacity allows the implementation worker to start now.

**Question:** What does firstmate write to the card, and at what point relative to spawning the implementation worker and linking it?

**Expected answer:** It publishes the statement block first, with `notion-update-page` using `insert_content` at `position: {"type":"start"}`, re-reads the card and confirms exactly one `## Постановка (как понята)` heading whose status line reads `готово к работе`, and only then spawns the implementation worker and runs `bin/fm-notion-link.sh`. The card's `Status` is not written by this step at all.

**Anchor:** "Publishing the statement into the card", the fetch-then-write table and the re-read that follows it.

## S7 - The publish call keeps failing

**Situation:** A card-linked task's specification is READY, the block is ready to publish, and the `notion-update-page` call errors. The retry errors too.

**Question:** Does the implementation worker start, and what happens to the card?

**Expected answer:** No worker is spawned for that card. The card is left exactly as it is, `Status` and body both, and firstmate reports one blocker to the captain naming the card and the error. Every other task keeps dispatching on its own schedule.

**Anchor:** "Publishing the statement into the card", the paragraph beginning "A card whose body the publish could not reach".

## S8 - How much of the specification goes on the card

**Situation:** The READY specification runs to sixteen sections and several hundred lines, and names the implementing branch, the delivery mode, and the task id.

**Question:** What of it is published into the card body, and what is the bound on the result?

**Expected answer:** Only the seven fields of the fixed block - `Задача`, `Зачем`, `Делаем`, `Не делаем`, `Готово, когда`, `Вопросы`, and the dated status line - as a summary and never the specification itself, in Russian, within 25 rendered lines and 1500 characters. No branch name, commit hash, pull-request URL, task id, worker, harness, or delivery mode appears in it; those belong to the result write.

**Anchor:** "Publishing the statement into the card", the field table and the bounds paragraph above it.
