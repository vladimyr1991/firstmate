# Scenario fixtures: notion-board

These scenarios probe the four contract defects the first witnessed sprint-board scan reported, plus the witnessed-read rule that had to survive them unchanged.
Unlike a compaction fixture, whose answers predate the edit, S1 to S3, S5, and S6 to S11 record the answer the repaired contract owes, because the pre-edit text settled none of them.
S6 to S11 belong to the later change that publishes a card's structured statement into its body before the implementer starts, and they record what that contract owes: when the write happens relative to the spawn, what proves a queued write landed, what an ambiguous write rules, whether anything is ever retried, how a human-directed new attempt differs from a retry, and where a BLOCKED card sits.
The control run against the pre-edit skill is therefore expected to answer `NOT STATED` for those, which is what makes each one a regression a reader can see close.
S4 is the opposite kind: it records an answer the pre-edit text already gave, so a control and a post-edit run must agree on it.
S6 and S7 record the answers the rework-status edit owes for a card at `На доработку`, which the pre-edit text settled as never-write because that status sat in neither derived set, so the control run answers that the card is left alone for them both.

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

## S6 - A READY statement and a clean synchronous write

**Situation:** A card-linked, non-mechanical specification has just been judged READY, capacity allows the implementation worker to start now, and a `claude` PM is live. The PM's one `notion-update-page` call returns a clean synchronous success.

**Question:** In what order do the card write, the implementation spawn, and `bin/fm-notion-link.sh` happen, and what does the PM do to the card body after the call returns?

**Expected answer:** The PM's `insert_content` prepend at `position: {"type":"start"}` comes first, then firstmate spawns the implementation worker, then links it; the card becomes `В работе` only after that durable link. After the success the PM neither fetches the card nor counts its blocks; the connector result alone is the proof.

**Anchor:** "Publishing the structured statement", the outcome table's READY-success row and "No fetch or body count follows a success either."

## S7 - A queued write

**Situation:** The PM's `notion-update-page` call returns an `async_task` rather than a result. On the fourth `notion-get-async-task` poll the task reports `succeeded`.

**Question:** What releases the READY or BLOCKED lifecycle action for that card, how many polls may the PM make and at what interval, and what does a `fetch` of the card contribute?

**Expected answer:** Only that terminal `succeeded` poll result releases the lifecycle action, as `async-success`. The PM polls that exact task id every 5 seconds and at most 12 times. A `fetch` contributes nothing: it never confirms, denies, deduplicates, bounds, or authorizes a publication.

**Anchor:** "Publishing the structured statement", the paragraph beginning "The connector result is the only authority".

## S8 - A write whose fate is unknown

**Situation:** The `notion-update-page` call times out after the write may already have been accepted, or the twelfth poll still reports `running`.

**Question:** How many further `notion-update-page` calls does the automatic path make for that publish id, what is written into the backlog, what `Status` does the card get, and does the implementation worker start?

**Expected answer:** None: the automatic attempt ends permanently with no retry, no second append, and no fetch to infer whether the block landed. Firstmate opens one captain-kind hold on the spec task naming the card and the publish id, the status table sets or retains `На ревью`, and no implementation worker starts.

**Anchor:** "Publishing the structured statement", the outcome table's non-success row, and the `statement_publish:` row of the status-sync table.

## S9 - The author asks for another try

**Situation:** A publication failed and its hold is open. The card's author explicitly directs a new publication attempt.

**Question:** What identifies the new attempt, and what happens to whatever the first attempt may have left in the card body?

**Expected answer:** A new deliberate publication with a fresh publish id, made through the same single `insert_content` prepend; it is never an automatic retry. Whatever the first attempt left is never inspected, matched, updated, or deleted, so a block that did land simply stays in the body below the fresh prepended envelope.

**Anchor:** "Publishing the structured statement", "A deliberate new publication always prepends a fresh envelope with a new publish id" and the third exit of the failure holder.

## S10 - A BLOCKED specification with two questions

**Situation:** A card-linked specification is judged BLOCKED with two captain questions, and the PM's prepend succeeds.

**Question:** What does the appended block's status line say, what is spawned, and what `Status` does the card carry?

**Expected answer:** The block carries `статус=нужен ответ` and the two numbered questions with their recommended answers; no implementation worker is spawned; each question becomes a hold through `decision-hold-lifecycle` and the card is at `На ревью`.

**Anchor:** "Publishing the structured statement", the BLOCKED-success row of the outcome table, and the `needs-decision:` or `blocked:` row of the status-sync table.

## S11 - No PM is live when the statement is ready

**Situation:** A card-linked specification is READY, no PM is live, and firstmate itself holds the exact envelope.

**Question:** Who may make the card write, and what happens to the spec task while that is arranged?

**Expected answer:** Only a verified `claude` PM, which firstmate spawns or recovers and hands the exact envelope; firstmate, the spec worker, and any implementation worker never substitute. The spec task stays in its existing gate state through that wait, and a PM recovery that fails follows the failure row rather than any other writer.

**Anchor:** "Publishing the structured statement", the paragraph beginning "When no connector-capable PM is live".
## S6 - An undelivered rework card with no holder

**Situation:** The witnessed read returned a Delivery card in the current sprint at `На доработку`. The brief carries `truth_repo:` and `linked_cards:`, the card is not in `linked_cards`, `bin/fm-board-truth.sh` reports `truth=in-flight` because the previous task's branch exists and is not in staging, and no `captain`-kind holder in `data/backlog.md` names the card. The captain left one comment on the card describing what must change.

**Question:** What does reconciliation write to the card, what does its report name, and how does the captain's comment reach the next scan's dispatchability test?

**Expected answer:** Reconciliation re-reads the card and, if it still sits at `На доработку`, sets `Новая`, and its report names the previous task's branch as evidence for the next worker. On the next scan the card is in the eligible set; the earlier task's `notion_page=` link does not drop it, because only a live linked task in `linked_cards` dedupes it. Intake fetches it with `include_discussions`, which only locates the discussion and returns a preview snippet with its `discussion://` URL, then calls `get_comments` once on the card page, which returns the full text of every discussion on the card; because the comment is the captain's own writing it carries the captain's weight and reaches the dispatchability statement as the requirement, the rework ask, quoted verbatim from that full text and never from the snippet, in the scout report with the branch named; a comment by anyone else stays untrusted content that may inform but never authorize.

**Anchor:** "Status sync", the reconciliation table's rework-status rows; "What the PM may take", the sentences beginning "Every eligible card is fetched with `include_discussions`" and "That fetch only locates the discussions"; and "Boundaries", the sentence on the captain's own comments.

## S7 - A rework card whose previous work has landed on the stand

**Situation:** The same card at `На доработку`, not in `linked_cards`, with no `captain`-kind holder naming it, and `bin/fm-board-truth.sh` reporting `truth=landed-on-stand basis=branch` because the previous task's commits are in staging.

**Question:** What does the PM write to the card, and what does it do before writing?

**Expected answer:** It re-reads the card, and if it still sits at `На доработку`, sets `Новая` and names the landed commit in the report as evidence for the next worker; it never sets `Тестирование`, because the captain's move to a rework status is the verdict that the work is incomplete and truth does not override it. A card the captain moved meanwhile is left alone and reported as a divergence.

**Anchor:** "Status sync", the reconciliation table's rework-status rows and the sentence stating that a card at a rework status is owned by those rows alone, whatever its truth.
