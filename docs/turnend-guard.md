# Primary turn-end supervision guard

This is the authoritative current contract for the "no turn ends blind" primary backstop referenced from AGENTS.md section 8.
The predicate lives in `bin/fm-turnend-guard.sh`.
Primary scope lives in `bin/fm-primary-scope-lib.sh`, shared with the native session-start nudge in [`sessionstart-nudge.md`](sessionstart-nudge.md).
Harness hook files adapt each enabled primary harness integration's turn-end mechanism to that shared predicate.

Related PreToolUse guards deny unsafe commands before execution rather than detecting a blind turn end afterward.
Their separate owners are [`arm-pretool-check.md`](arm-pretool-check.md), [`cd-guard.md`](cd-guard.md), and [`subagent-guard.md`](subagent-guard.md).
Do not infer this guard's scope, loop safety, or compatibility tradeoffs for those guards.

## Current invariant

`bin/fm-guard.sh` is a pull-based warning that runs only when another supervision command invokes it.
The turn-end guard closes the remaining gap at the primary's own turn boundary.
When work, a process-event source, or X-mode relay polling needs supervision and no identity-matched watcher has a fresh beacon, the harness integration must either block the turn end or force one bounded follow-up that uses the recovery instruction from the emitted session-start protocol.
Both guards require the same live lock, process identity, home/path binding, and fresh-beacon predicate.
The guard remains a backstop; [`watcher-continuity.md`](watcher-continuity.md) owns normal continuity.

## Shared predicate

The guard first calls the shared primary scope.
A secondmate home runs its own primary Firstmate session, so a genuine `.fm-secondmate-home` marker includes it whether the home is a linked worktree or plain clone.
The marker must be a regular non-symlink file whose whitespace-stripped first line is a non-empty identifier containing only letters, digits, dots, underscores, and dashes.
An unmarked checkout or invalid marker falls through to the git-dir check.
That check keeps crewmate and scout linked worktrees inert because their git dir differs from their git common dir.
It also requires `AGENTS.md`, `bin/`, and the effective state directory.

For an in-scope primary, the guard counts in-flight work from `state/*.meta`.
Registered `state/procevent/*.source` records also require supervision even though they have no task metadata.
The default cross-harness mode exits silently with no supervision need.
Every mode treats `state/x-watch.check.sh` as supervision need, so X-mode relay polling remains guarded without an in-flight task.
Otherwise it calls `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`, the same identity-matched lock and fresh-beacon check used by `bin/fm-watch-arm.sh`.
`bin/fm-guard.sh` uses that same check rather than treating the status helper's fresh-beacon field as sufficient.
A stale beacon blocks even when a watcher pid is live.
A fresh leftover beacon blocks when the lock is missing, dead, or identity-mismatched.

`FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repository-root `state/`.
`FM_GUARD_GRACE` controls beacon freshness and defaults to 300 seconds.
If `jq` is missing or hook stdin is empty, the guard exits 0 because it cannot safely read loop-guard fields.

## Home-lock record and session identity

`bin/fm-session-lock-lib.sh` is the single owner of the `state/.lock` record contract that `bin/fm-lock.sh`, the Claude Stop auto-arm, the session-start nudge, the session-start digest's Pi loaded-marker check, and this guard all read.
Two forms are accepted: the legacy bare-integer pid, and the typed single line `pid=<n> harness=<name> session=<id>` that the acquisition path writes whenever the harness publishes a durable session id.
Claude Code is the only verified harness that publishes one, in `CLAUDE_CODE_SESSION_ID` for tool and hook shells and as `session_id` in its Stop payload; every other harness keeps writing and reading the legacy form with unchanged behavior.
There is no migration step, and a home that acquired before it could publish an id holds a legacy record until something rewrites it.
`bin/fm-lock.sh upgrade [<session-id>]` is that backfill, and it is the only path other than acquisition that writes the record.
It rewrites a legacy record in place to the typed form, and only when the calling session already owns that record, the record is still legacy, and both a harness name for the recorded pid and a durable session id for this process resolve; any other state is a silent no-op, and a record this session does not own is refused with a diagnostic and exit 1.
The recorded pid is carried over verbatim and never re-resolved, because `fm_harness_ancestry_pid` returns the outermost pid of the contiguous harness run - for a session parented by a harness-named daemon that is the daemon, so re-resolving would migrate the record off the session it names.
The Claude Stop auto-arm calls it once per firing on a legacy record, after its ownership, away-mode, and supervision-need gates and before its single-flight claim, and discards the outcome; that placement is what keeps an idle or away home byte-for-byte inert and keeps the backfill inside the window where ancestry still proves ownership.
The three non-shell primary adapters that cannot source that library - `.pi/extensions/fm-primary-turnend-guard.ts`, `.pi/extensions/fm-primary-pi-watch.ts`, and `.opencode/plugins/fm-primary-watch-arm.js` - read the pid out of either form and then keep their own unchanged ancestry test, because a home that switches from Claude to Pi or OpenCode holds the typed record until its next acquisition and would otherwise read its own home as foreign and lose watcher continuity.
Any future record form has to be taught to every reader that cannot source the library, in the same change that introduces it.

Ownership of a typed record is decided by the recorded session id alone whenever the reading process can resolve one of its own.
That identity is what survives a changed process tree, and it is also the only test that separates two sessions descending from one pooled background host process, whose pid is a genuine ancestor of both.
A legacy record, and a typed record read by a process with no session id, keeps the harness-ancestry membership test unchanged.
The recorded pid remains only a liveness hint: the lock is stale when that pid is dead or is not a harness, and a live pid under a non-matching session id is still another live session's home.
An unrecognized record fails closed as malformed, with no pid any caller can act on.

One residual of that contract is accepted deliberately.
Session-id separation is enforced when ownership is read, but the acquisition path still treats a recorded pid equal to this process's own resolved harness pid as non-contesting, so two primary sessions sharing one pooled background host process in the same home can still take the lock from each other, because that shared pid is a genuine ancestor of both.
Refusing on a typed-record id mismatch regardless of pid would be worse: it would lock a session out of its own home after an ordinary `/clear`, where a new session id meets a still-live recorded pid, which is the same live-but-stale-owner outage this contract exists to end, on a routine daily operation.
The session-start nudge makes that residual actively prompted rather than merely reachable: in the pooled shape the sibling session mismatches on the recorded session id, is told to run session start, and the pid-equality rule above then lets it take the record.
The residual is tolerable because every session is already instructed to run session start, watcher health keys on `state/.watch.lock` rather than `state/.lock` so an existing watcher survives the rewrite, and the displaced session no longer blocks forever - it takes the bounded and loud read-only allow described below.

The backfill narrows that shape deliberately, and the narrowing is the intended one-session-per-home semantics rather than a new restriction.
While a pooled home still holds a legacy record, every session descending from the shared host process reads it as its own, because the shared pid is a genuine ancestor of all of them.
Once one of them upgrades the record, only the session it names reads that home as its own and each sibling takes the read-only non-owner path instead.
That is not a lockout: the displaced sibling is told to run session start, and the pid-equality rule above then lets its acquisition take the record, exactly as it does after an ordinary `/clear`.

## Reaching a bounded outcome without the auto-arm

The `--claude` mode's terminal outcomes must be reachable from evidence this guard observes itself.
An earlier contract gated the one loud allow on `state/.claude-autoarm-failure-notified` and advanced the blocked-stop count only when `state/.claude-autoarm-epoch` changed, both written exclusively by the Stop auto-arm.
Any cause that silences that hook therefore froze the count and made the terminal outcome unreachable, which produced an unbounded, unsatisfiable block.

Three rules close that gap.
The blocked-stop count now advances once per blocking turn end regardless of the epoch, bounded to one advance per Stop event, so a frozen epoch cannot pin it.
The bounded loud allow accepts either proof: the auto-arm's own exhausted-failure episode as before, or the observation that no live `autoarm` owner holds `state/.claude-autoarm.lock` and the epoch ledger is absent or older than `FM_CLAUDE_AUTOARM_EPOCH_FRESH`.
The block banner and the terminal notice both carry one line naming the auto-arm's observable participation - the lock owner when this session does not hold the home, `auto-arm: no epoch recorded`, or the epoch's sequence and age.

A session that does not hold the home lock is a separate case.
It may not arm, drain, or repair supervision at all (`AGENTS.md` section 3), so blocking it can never be satisfied.
When supervision is needed, no watcher is healthy, and the lock is held by another live session or carries an unrecognized record, the guard exits 0 with one `systemMessage` per session naming the holder, and touches neither the block budget nor any other file in the home; the one-per-session marker lives under `TMPDIR` precisely because that session has no write authority over the home.
A missing lock and a reclaimable stale lock are not that case: both are claimable by the auto-arm's own guarded recovery, so they keep the ordinary blocking behavior.
Away mode is excluded from this path and keeps its existing behavior in both scripts.

`bin/fm-lock.sh status` prints the recorded session id when the record carries one, so an operator can see an identity mismatch directly.

## Harness integrations

- Claude registers two `Stop` hooks in `.claude/settings.json`, both anchored through `CLAUDE_PROJECT_DIR`: `bin/fm-turnend-guard.sh --claude`, and `bin/fm-claude-stop-autoarm.sh` with `asyncRewake: true` and `timeout: 28800`.
- Codex registers a `Stop` hook in `.codex/hooks.json`, anchors the executable to the hook process working directory, verifies a Firstmate-shaped hook-bearing root, and passes the original payload to the shared guard.
- OpenCode listens for `session.idle` in `.opencode/plugins/fm-primary-turnend-guard.js`, lets the watcher coordinator act first, and calls `client.session.promptAsync` once when the guard returns 2.
- Pi listens for `agent_settled` in `.pi/extensions/fm-primary-turnend-guard.ts`, runs once per logical agent run, and calls `pi.sendUserMessage(..., { deliverAs: "followUp" })` once when the guard returns 2.
- Grok registers a `Stop` hook in `.grok/hooks/fm-primary-turnend-guard.json` and delegates capability selection to `bin/fm-turnend-guard-grok.sh`.
  The tracked Claude Stop entries are inert when `GROK_AGENT` is present, so Grok's Claude-compatible settings loading cannot create a second continuation path.

Claude and Codex can block a Stop directly with exit status 2 and stderr.
Both payloads carry `stop_hook_active`.
In the default Codex mode, a true value lets the second stop finish after one forced continuation.

Claude runs the guard with `--claude`, which ignores `stop_hook_active` and cooperates with the Stop-owned auto-arm.
Claude Code sets `stop_hook_active=true` on every stop after any stop-hook continuation, including `asyncRewake` rewakes, which re-opened the 2026-07-21 blind window under the default one-shot behavior.
The Claude mode waits up to `FM_CLAUDE_AUTOARM_SYNC_WAIT_MS` (default 800 milliseconds) and allows the stop when the watcher is healthy, `state/.claude-autoarm.lock` has a live `autoarm` role owner whose eventual failure must exit 2, or `state/.claude-autoarm-epoch` contains a fresh actionable rewake owned by this event epoch.
Fresh `failed` and `failed-suppressed` outcomes enter or advance the failure progression instead of acting as unconditional recovery proof.
The auto-arm itself rechecks the healthy watcher predicate and retries a bounded number of times before reporting a genuine failure.
The first fresh exhausted-failure epoch preserves its handoff without consuming a blocked-stop count, while later fresh failed epochs advance the same monotonic progression instead of resetting it.
When none of those proofs appears, it re-blocks up to `FM_CLAUDE_TURNEND_BLOCK_BUDGET` times (default 3, below Claude's 8-block override), then takes the bounded loud allow described under "Reaching a bounded outcome without the auto-arm".
In Claude mode, positive watcher recovery clears the block budget, failure notice, and attended alarm together under the existing budget lock before either hook reports ordinary recovery.
The one loud attended fail-open requires the block budget to be exhausted, a final check finding neither a healthy watcher nor an automatic continuation, and either an auto-arm that recorded an exhausted failure with its one notice already consumed, or an auto-arm that is observably absent.
Each epoch identity is accounted at most once under the budget lock.
Whenever both coordination locks are needed, positive auto-arm recovery and the terminal check acquire the auto-arm owner lock before the budget lock.
After that alarm, the Stop auto-arm suppresses further exit-2 continuations until positive watcher recovery, so the final fail-open remains reachable.
The alarm cannot repeat during that failure episode, and a later unhealthy stop blocks again.
A positively verified healthy watcher clears the failure notice, alarm, and block budget for a future independent episode.
A Claude failure notice describes the automatic mechanism as broken and does not direct a routine manual background arm.

OpenCode, Pi, and pi-signed expose passive callbacks for this purpose.
Their adapters fail open at the hook boundary to protect the user session but schedule one bounded follow-up when the predicate blocks.
The generated prompts use the canonical `turn-end-guard` kind after the U+2063 `FIRSTMATE_OP: ` prefix, so Ahoy does not treat them as captain messages.
Each passive adapter owns a loop latch.
Pi keeps the latch across internal tool turns and clears it only when the generated follow-up settles or delivery fails.
OpenCode's forced follow-up is supported for persistent TUI sessions and remains fail-open in headless `opencode run`.

Grok makes exactly one typed capability decision from each running Stop payload.
A boolean `stopHookActive` selects native blocking, including both false on the initial stop and true on the bounded continuation.
The camel-case field has precedence when both spellings appear; when it is absent, a boolean `stop_hook_active` selects the same native path for compatibility.
The native path returns the shared guard's status and stderr to the same Grok process and never starts `grok --resume`.
When both capability spellings are absent, the adapter preserves one pre-native `grok --resume` fallback guarded by `GROK_TURNEND_GUARD_ACTIVE` and intentionally omits `--permission-mode`.
Malformed JSON, a selected field with a non-boolean type, missing `jq`, missing hook prerequisites, or an already-active legacy guard allows the stop without starting either continuation path.
Grok's project hook requires the checkout to be trusted with `/hooks-trust` or launch-time `--trust`; genuine pre-native builds can run the same tracked hook from an isolated global hook directory.

If a passive adapter cannot invoke its SDK, or the Grok legacy fallback cannot find `grok` or a session id, the next pull-based `fm-guard.sh` call reports the problem.
That warning uses `bin/fm-supervision-instructions.sh --repair-line`, so it always points to the active harness protocol rather than embedding another repair command.

## Compatibility limits

- Child crewmate and scout worktrees are outside scope.
- A valid secondmate home is in scope; an idle secondmate endpoint with no X-mode relay poll remains healthy because it has no supervision need.
- The direct-blocking and bounded passive-follow-up split is limited to the primary integrations listed above.
- OpenCode headless mode and untrusted Grok project hooks remain fail-open at the host boundary.
- Kimi Code CLI 0.29.1 exposes only global `[[hooks]]` configuration in `~/.kimi-code/config.toml`, including a `Stop` event with snake_case payload fields `hook_event_name`, `session_id`, `cwd`, and `stop_hook_active`.
- Kimi has no project-level hook configuration and remains outside the primary guard integrations above.
- Captain-approved Kimi crew wake support uses `bin/fm-kimi-turnend-hook.sh` to edit only one marker-delimited Firstmate region in that global config and install a silent always-zero hook.
- The hook remains inert unless the payload `cwd` contains a per-task token pointer that resolves through Firstmate's private registry to one `state/<id>.turn-ended` marker.
- Installation refuses before writing unless `python3` with `tomllib` and `jq` are available.
- If `jq` is removed after installation, the hook remains silent and exits 0, turn-end wakes stop, and Kimi crews fall back to idle detection.
- Unreadable hook input remains fail-open.
- No harness adapter uses a shell ampersand to manufacture supervision.

## Regression coverage

`tests/fm-turnend-guard.test.sh` covers the predicate, main and secondmate primary scope, child-worktree exclusion, `FM_HOME` and `FM_STATE_OVERRIDE` precedence, the live-lock and fresh-beacon guard predicate, the cooperative `--claude` claim wait, monotonic failed-epoch progression, bounded attended fail-open, post-alarm continuation suppression, positive recovery reset, Pi logical-run latching, missing-`jq` behavior, all five primary registrations, Grok native and legacy selection, typed field precedence, malformed input, and exactly-one-path safety.
It also covers the auto-arm-independent contract above: a silent auto-arm still reaching one bounded loud allow, a frozen epoch failing to pin the blocked-stop count, a still-participating auto-arm continuing to block past the budget, the read-only non-owner allow with its one notice and untouched home, and away mode still blocking a non-owner.
`tests/fm-session-lock-ancestry.test.sh` covers the record contract: a typed record surviving a changed process tree, a different live session still refused, a shared ancestor pid never overriding a recorded session id, unrecognized records failing closed, and legacy records keeping their exact ancestry semantics.
`tests/fm-claude-stop-autoarm.test.sh` covers the hook's side of it: the Stop payload's session id keeping the auto-arm alive across a changed process tree, a home recorded to another live session left byte-for-byte untouched, and stale-lock recovery recording this session's durable identity.
`tests/fm-turnend-guard.test.sh` proves the Pi turn-end extension and `tests/fm-pi-watch-extension.test.sh` proves the OpenCode watcher plugin resolve ownership from both record forms, each against a typed record carrying its own pid and one carrying another live session's.
`tests/fm-session-start.test.sh` proves the same for the session-start digest's Pi loaded-marker check, against a legacy record written by its own acquisition and a typed record left by a foreign live session.
`tests/fm-guard-stale-banner.test.sh` covers the matching pull-guard predicate, including the fresh-leftover-beacon negative control.
`tests/fm-kimi-harness.test.sh` covers the separate Kimi crew hook's format preservation, idempotence, refusal cases, token guard, spawn registration, and teardown cleanup.
`tests/fm-supervision-instructions.test.sh` covers recovery-line ownership and pi-signed's identity-preserving reuse of Pi's protocol.
`FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` is the opt-in isolated Pi path.
[`verification/supervision.md`](verification/supervision.md#turn-end-guard) records the active cross-harness empirical evidence, including the 2026-07-24 Claude `asyncRewake` revalidation.
