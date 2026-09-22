# Scenario fixtures: notion-board

These scenarios probe the four contract defects the first witnessed sprint-board scan reported, plus the witnessed-read rule that had to survive them unchanged.
Unlike a compaction fixture, whose answers predate the edit, S1 to S3, S5, and S6 to S11 record the answer the repaired contract owes, because the pre-edit text settled none of them.
S6 to S11 belong to the later change that publishes a card's structured statement before the implementer starts, and they record what that contract owes: when the write happens relative to the spawn, what proves it landed, what an ambiguous write rules, whether anything is ever retried, how a human-directed new attempt differs from a retry, and where a BLOCKED card sits.
The control run against the pre-edit skill is therefore expected to answer `NOT STATED` for those, which is what makes each one a regression a reader can see close.
S4 is the opposite kind: it records an answer the pre-edit text already gave, so a control and a post-edit run must agree on it.
S12 and S13 belong to the rework-status change and record the answers it owes for a card at `На доработку`, which the pre-edit text settled as never-write because that status sat in neither derived set, so the control run answers that the card is left alone for them both.
The publication form then moved from a block prepended to the card body to one new page-level comment, which the card's author asked for, so S6 to S10 were re-aimed at that form.
Their situations and expected answers now name `notion-create-comment` with `page_id` alone, and S7 no longer asks how a queued write is polled but records that no asynchronous reply and no poll exist on this path, while `async-success`, `async-failed`, and `poll-timeout` stay recorded outcome values.
A control run against the pre-comment skill therefore answers those five with the body form rather than `NOT STATED`, and that difference is what a reader can see close.
S11 was not re-aimed, because who may write the card never depended on the form.
S14 to S16 belong to that same change and record three answers only the comment form owes: what intake makes of a card whose comments are all the fleet's own, what a recycled card does with a statement comment from its previous life, and which page-content command the statement may use.
The control answers `NOT STATED` for all three.

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

**Situation:** A card-linked, non-mechanical specification has just been judged READY, capacity allows the implementation worker to start now, and a `claude` PM is live. The PM's one call returns a clean synchronous success.

**Question:** Which tool and parameters make the card write, in what order do that write, the implementation spawn, and `bin/fm-notion-link.sh` happen, and what does the PM read on the card after the call returns?

**Expected answer:** Exactly one `notion-create-comment` call carrying `page_id` and `markdown` and nothing else, so the statement lands as a new page-level discussion; it comes first, then firstmate spawns the implementation worker, then links it, and the card becomes `В работе` only after that durable link. After the success the PM makes no `fetch`, no `get_comments`, and no comment count, and it writes no card body at all; the connector result alone is the proof.

**Anchor:** "Publishing the structured statement", "The write" and the outcome table's READY-success row, plus "No `fetch`, `get_comments`, or comment count ever follows the write, on success or failure alike."

## S7 - Whether a queued write can happen at all

**Situation:** The PM has the envelope and is about to make its one publication call, and it is deciding how to establish that the statement landed.

**Question:** What releases the READY or BLOCKED lifecycle action for that card, how many polls may the PM make and of what, and what do the `async-success`, `async-failed`, and `poll-timeout` outcome values mean on this path?

**Expected answer:** Only a clean synchronous success releases the lifecycle action, reported as `sync-success`. No poll exists and no polling tool is called: the comment tool takes no `allow_async` parameter and returns no `async_task`, so there is nothing to poll. `async-success`, `async-failed`, and `poll-timeout` are unreachable here and stay recorded values only so every consumer of the `statement_publish:` line and the status-sync row matching anything but a success remain valid unchanged. A `fetch` contributes nothing: it never confirms, denies, deduplicates, bounds, or authorizes a publication.

**Anchor:** "Publishing the structured statement", the paragraph beginning "The connector result is the only authority", and the outcome values under "The outcome".

## S8 - A write whose fate is unknown

**Situation:** The publication call times out after the comment may already have been created, so nobody knows whether it exists.

**Question:** How many further publication calls does the automatic path make for that publish id, what is written into the backlog, what `Status` does the card get, and does the implementation worker start?

**Expected answer:** None: the automatic attempt ends permanently with no retry, no second comment, and no fetch or `get_comments` to infer whether it landed. Firstmate opens one captain-kind hold on the spec task naming the card and the publish id, the status table sets or retains `На ревью`, and no implementation worker starts.

**Anchor:** "Publishing the structured statement", the outcome table's non-success row, and the `statement_publish:` row of the status-sync table.

## S9 - The author asks for another try

**Situation:** A publication failed and its hold is open. The card's author explicitly directs a new publication attempt.

**Question:** What identifies the new attempt, and what happens to whatever the first attempt may have left on the card?

**Expected answer:** A new deliberate publication with a fresh publish id, made through the same single `notion-create-comment` call; it is never an automatic retry. Whatever the first attempt left is never inspected, matched, updated, or deleted, so a comment that did land simply stays on the card beside the new one, and the newest is identified by its publish id.

**Anchor:** "Publishing the structured statement", "A deliberate new publication always posts a fresh comment with a new publish id" and the third exit of the failure holder.

## S10 - A BLOCKED specification with two questions

**Situation:** A card-linked specification is judged BLOCKED with two captain questions, and the PM's publication succeeds.

**Question:** What does the published statement's status line say, what is spawned, and what `Status` does the card carry?

**Expected answer:** The comment carries `статус=нужен ответ` and the two numbered questions with their recommended answers; no implementation worker is spawned; each question becomes a hold through `decision-hold-lifecycle` and the card is at `На ревью`.

**Anchor:** "Publishing the structured statement", the BLOCKED-success row of the outcome table, and the `needs-decision:` or `blocked:` row of the status-sync table.

## S11 - No PM is live when the statement is ready

**Situation:** A card-linked specification is READY, no PM is live, and firstmate itself holds the exact envelope.

**Question:** Who may make the card write, and what happens to the spec task while that is arranged?

**Expected answer:** Only a verified `claude` PM, which firstmate spawns or recovers and hands the exact envelope; firstmate, the spec worker, and any implementation worker never substitute. The spec task stays in its existing gate state through that wait, and a PM recovery that fails follows the failure row rather than any other writer.

**Anchor:** "Publishing the structured statement", the paragraph beginning "When no connector-capable PM is live".

## S12 - An undelivered rework card with no holder

**Situation:** The witnessed read returned a Delivery card in the current sprint at `На доработку`. The brief carries `truth_repo:` and `linked_cards:`, the card is not in `linked_cards`, `bin/fm-board-truth.sh` reports `truth=in-flight` because the previous task's branch exists and is not in staging, and no `captain`-kind holder in `data/backlog.md` names the card. The captain left one comment on the card describing what must change.

**Question:** What does reconciliation write to the card, what does its report name, and how does the captain's comment reach the next scan's dispatchability test?

**Expected answer:** Reconciliation re-reads the card and, if it still sits at `На доработку`, sets `Новая`, and its report names the previous task's branch as evidence for the next worker. On the next scan the card is in the eligible set; the earlier task's `notion_page=` link does not drop it, because only a live linked task in `linked_cards` dedupes it. Intake fetches it with `include_discussions`, which only locates the discussion and returns a preview snippet with its `discussion://` URL, then calls `get_comments` once on the card page with `include_all_blocks` true, which returns the full text of every discussion on the card, block-anchored ones included; because the comment is the captain's own writing it carries the captain's weight and reaches the dispatchability statement as the requirement, the rework ask, quoted verbatim from that full text and never from the snippet, in the scout report with the branch named; a comment by anyone else stays untrusted content that may inform but never authorize.

**Anchor:** "Status sync", the reconciliation table's rework-status rows; "What the PM may take", the sentences beginning "Every eligible card is fetched with `include_discussions`" and "That fetch only locates the discussions"; and "Boundaries", the sentence on the captain's own comments.

## S13 - A rework card whose previous work has landed on the stand

**Situation:** The same card at `На доработку`, not in `linked_cards`, with no `captain`-kind holder naming it, and `bin/fm-board-truth.sh` reporting `truth=landed-on-stand basis=branch` because the previous task's commits are in staging.

**Question:** What does the PM write to the card, and what does it do before writing?

**Expected answer:** It re-reads the card, and if it still sits at `На доработку`, sets `Новая` and names the landed commit in the report as evidence for the next worker; it never sets `Тестирование`, because the captain's move to a rework status is the verdict that the work is incomplete and truth does not override it. A card the captain moved meanwhile is left alone and reported as a divergence.

**Anchor:** "Status sync", the reconciliation table's rework-status rows and the sentence stating that a card at a rework status is owned by those rows alone, whatever its truth.

## S14 - Intake reads a card whose only comments are the fleet's own

**Situation:** An eligible `Новая` Delivery card in the current sprint is fetched with `include_discussions`, which shows it has discussions. The `get_comments` read returns two comments, and both carry a `_Постановка: задача=...; публикация=...; статус=..._` metadata line from earlier statement publications on this card. Nobody else has commented.

**Question:** Whose writing are those comments, and what do they contribute to the dispatchability statement?

**Expected answer:** They are the fleet's own writing, decided by shape: a comment carrying the publication envelope with the originating task id inside it is the fleet's own, and every other comment is the captain's. They contribute nothing to the requirement - they never reach the dispatchability statement as one - and like every fleet write they may inform judgment but never authorize an action. The card is treated exactly as a card whose only text is the captain's description.

**Anchor:** "Boundaries", the authorship rule and the sentence on what a published card's `get_comments` read returns.

## S15 - A recycled card still carrying a statement comment

**Situation:** A finished card was recycled: its line is in `🗄️ Архив задач`, its link is archived, and step 4 cleared the body and reset its properties. A statement comment from its previous life is still on the page. The card is now taken out of `♻️ Пул` for new work.

**Question:** What does the recycle procedure do about that comment, and what does the next scan make of it?

**Expected answer:** Nothing: the connector exposes no delete-comment tool and `replace_content` reaches only body content, so a recycled card keeps the statement comments of its previous life and nothing inspects, edits, repairs, or removes them. Each stays identified by its metadata line's `задача=<spec-task-id>`, each is the fleet's own writing under the authorship rule, and so it never reaches the next scan's dispatchability statement as a requirement.

**Anchor:** "Recycling a card", the paragraph on step 4 clearing the body and never the comments, plus "Boundaries", the authorship rule.

## S16 - Which page-content command the statement may use

**Situation:** A PM holds the exact envelope for a READY card-linked specification and is choosing the call that publishes it.

**Question:** Which page-content command may the statement be written with, and what are `replace_content` and `update_properties` still for?

**Expected answer:** None may: `insert_content`, `update_content`, and `replace_content` are all forbidden for the statement, which is published only as one `notion-create-comment` call. `replace_content` stays exclusive to recycle step 4 and to rewriting the rolling status page, and `update_properties` stays the status-sync tool. `discussion_id` and `selection_with_ellipsis` are forbidden on the comment too, the latter because anchoring to a body block would require matching card body text, which the section forbids.

**Anchor:** "Publishing the structured statement", "The write".
