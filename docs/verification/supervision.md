# Supervision integration verification

Audience: maintainer verification.

This record supports current session-start, turn-end, watcher-continuity, and wedge-alarm guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Native session-start delivery

The cross-harness transport pass ran on 2026-07-17 with Codex 0.144.4, Grok 0.2.103, OpenCode 1.17.18, Pi 0.80.10, and the tracked Claude hook wiring.

Codex command shape:

```sh
codex exec --ephemeral --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox \
  --output-last-message last.txt \
  'Follow any SessionStart hook context before this prompt.'
```

Observed result: the `SessionStart` hook completed and its stdout reached model context.

Grok command shape:

```sh
grok --trust -p 'Follow any SessionStart hook context before this prompt.' \
  --permission-mode bypassPermissions --output-format plain
```

Observed result: the project hook ran, but its stdout did not reach model context.
This is the current Grok fail-open limit.

OpenCode was checked in both headless and interactive modes.
`client.session.promptAsync` accepted the nudge in both cases; the persistent TUI completed the generated turn, while `opencode run` exited before another turn.
This is the current headless fail-open limit.

Pi command shape:

```sh
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts \
  --no-context-files --no-session \
  'After obeying any earlier session-start instruction, reply with exactly PI_SMOKE_DONE.'
```

Observed result: `PI_SMOKE_DONE`, with one session-start execution.
The earlier `sendUserMessage` counterfactual raced the positional prompt; the current non-triggering `pi.sendMessage` custom message did not.
The installed pi-signed 0.82.0 wrapper repeated the Pi primary extension and session-start path on 2026-07-27.
[`runtime-backends.md`](runtime-backends.md#tmux) owns the shared-ancestry evidence and authoritative selection-marker boundary.

Current deterministic and live entry points:

```sh
tests/fm-sessionstart-nudge.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh
```

The Ahoy first-message boundary was reverified on 2026-07-22 with Pi 0.81.1 and OpenCode 1.17.18.
Marked current operational input and the two exact legacy compatibility shapes selected Bearings, while genuine near-miss captain messages remained real boundaries.
The detailed reconciliation and task chronology stay in the private audit report and PR evidence.

## Semantic busy state

The per-adapter semantic sources behind [`bin/fm-busy-lib.sh`](../../bin/fm-busy-lib.sh) were live-verified on 2026-07-28 against firstmate-launched workers wired exactly as `fm-spawn` writes them.
Each pass polled `state/<id>.busy-state` while a real turn ran.

| Harness | Version verified | Semantic source | Observed result |
| --- | --- | --- | --- |
| Pi | 0.82.0 | Extension `agent_start` / `agent_settled` with `ctx.isIdle()` | The spawn seed `busy source=fm-spawn`, then `busy source=pi-ext event=agent-start`, then `idle source=pi-ext event=agent-settled`; the turn-end marker was still touched. |
| OpenCode | 1.17.18 | Plugin `session.status` | In a real TUI pane: seed, then `busy source=opencode-plugin event=session-busy`, then `idle source=opencode-plugin event=session-status-idle`. |
| Claude | 2.1.220 (Claude Code) | Hooks `UserPromptSubmit`, `Stop`, `StopFailure`, `SessionEnd` | `UserPromptSubmit` fired for the argv launch prompt and each steer, and `Stop` closed every completed turn. A mid-stream Escape interrupt fired no closing hook, which is why the firstmate-controlled clear exists. `StopFailure` and `SessionEnd` are wired from the four hook names present in the installed binary; only the abnormal paths they cover were not reproduced live. |
| Codex | codex-cli 0.145.0 | None usable | See below; classifies `unknown codex-unverified`. |
| Kimi (standalone) | not installed | None usable | No binary on `PATH`, so the gate stays closed and it classifies `unknown kimi-unverified`. |
| Grok | 0.2.112 | Isolated rendered-tail fallback | Retained unconverted; the approved audit could not credit a live structured-lifecycle run. |

Codex was probed two ways, both refused:

```sh
codex app-server daemon start
codex exec --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust 'Reply with exactly PROBE2.'
```

The daemon refused with `managed standalone Codex install not found`, and an interactive TUI worker neither starts nor attaches to the app-server control socket, so no client can observe its turns.
Firstmate-written project hooks under `<worktree>/.codex/hooks.json` fired for neither an interactive pane whose directory trust was granted nor `codex exec`, in both cases with `--dangerously-bypass-hook-trust`, while global `~/.codex/hooks.json` `SessionStart` hooks fired in the same runs.
Codex also exposes no `StopFailure` hook, so an API-error turn end would need separate coverage even after hook discovery works.
The app-server protocol schema does define the required lifecycle (`turn/started`, plus a `turn/completed` status of `completed`, `interrupted`, `failed`, or `inProgress`), so the gate is a reachability problem rather than a protocol gap.

Deterministic entry points:

```sh
tests/fm-busy-state.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-crew-state.test.sh
```

## Turn-end guard

The direct and passive mechanisms were validated across all five harnesses on 2026-07-08 through 2026-07-12, with Claude's replacement Stop-owned path revalidated on 2026-07-24.

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.219 | Cooperative blocking `Stop` guard plus `asyncRewake` auto-arm | A fresh unsupervised session ran session start first, reclaimed a stale dead-owner lock, completed two tokenless rewake cycles with no model arm command or guard continuation, and left a competing live owner unchanged. |
| Codex | 0.142.1 | Blocking `Stop` hook | Hook process root stayed anchored to the trusted checkout and one continuation ran. |
| OpenCode | 1.17.6 | Passive `session.idle` callback | Throwing could not block, while `promptAsync` scheduled one TUI follow-up; headless remained fail-open. |
| Pi | 0.80.5 | Passive `agent_settled` callback | Exactly one guard follow-up ran for an unhealthy cycle, with no recursion across tool turns. |
| Grok | 0.2.112 native and 0.2.73 pre-native | Running-payload adaptive `Stop` | Native false-to-true continuation stayed in one process with two model turns and zero resume launches; the field-absent pre-native process launched exactly one guarded resume. |

The Grok adaptive matrix ran on 2026-07-28 with separate scratch repositories and homes, dedicated tmux sockets, one target plus one control window, ambient tmux variables removed, and a socket-bound wrapper first in `PATH`.

```sh
FM_GROK_STOP_LIVE_E2E=1 \
  FM_GROK_NATIVE_BIN="$native_grok_0_2_112" \
  FM_GROK_LEGACY_BIN="$official_pre_native_grok_0_2_73" \
  tests/fm-grok-stop-live-e2e.test.sh
```

Observed bounded output:

```text
ok - grok 0.2.112 (9bbd559437aa) [stable] native Stop kept one session across false->true, two model turns, and zero resume processes
ok - grok 0.2.73 (9ff14c43bbe5) [stable] legacy Stop omitted capability, resumed exactly once, and stopped normally
ok - Grok adaptive Stop real-process matrix passed with exact target cleanup and control-window survival
```

The same run proved the Claude-compatible Stop entries stay inert under `GROK_AGENT`, the legacy resume carries `GROK_TURNEND_GUARD_ACTIVE=1`, and every replacement root is removed after exact target cleanup while its control window survives.

The secondmate-home scope and manual-repair wake path were measured with Claude Code 2.1.207 on 2026-07-12, when a native background completion re-invoked the idle model with no human input.
The current Stop-owned main/secondmate inclusion and child-worktree exclusion are covered deterministically by `tests/fm-claude-stop-autoarm.test.sh`.
Session-lock ownership in `bin/fm-session-lock-lib.sh` is decided against a session's whole contiguous harness ancestry rather than one chosen pid, so the Stop auto-arm reaches its lock owner wherever that owner sits: the outermost pid of Claude Code's multi-level `bg-spare` hook worker chain, or an inner pid when a harness-named daemon parents the session.
Harness identity is read from the executable path and `argv[0]` as well as the command basename, because Claude Code's native installer names the per-session executable by its version (`.../share/claude/versions/2.1.220`): `ps -o comm=` reports that path on macOS and the bare version string on Linux, and neither basename names a harness.
`tests/fm-session-lock-ancestry.test.sh` pins both platforms' reporting semantics behind a deterministic process table and runs the real Stop auto-arm in version-named, daemon-parented, and combined real process trees.

Ancestry alone is not durable, which is why the record also carries a session id when the harness publishes one ([`turnend-guard.md`](../turnend-guard.md#home-lock-record-and-session-identity)).
Measured on 2026-08-14 against Claude Code 2.1.231: moving a running session into a Claude Code background session replaces its process tree (`claude bg-spare` under `claude bg-pty-host` under init), so the pid recorded 8 days earlier stopped being an ancestor while staying alive and matching the harness predicate.
In that home the Stop auto-arm then took its documented "a live owner keeps the competing hook inert" path 109 consecutive times, writing no epoch and no failure notice, and the turn-end guard - whose only terminal outcome was gated on that failure notice, with a blocked-stop count that advanced only when the epoch changed - blocked every turn end of the session with the count pinned at 1.
`CLAUDE_CODE_SESSION_ID` is present in Claude Code 2.x tool and hook shells and equals the session's own id, which is the identity the typed record uses.

The competing explanation - that `asyncRewake` simply does not fire in a backgrounded session - was ruled out in that same home on 2026-08-14.
Retiring the abandoned foreign lock-holder process made the recorded owner dead, and on the very next turn end the hook recovered on its own with no manual arm: `state/.claude-autoarm-epoch` advanced `1872 -> 1873` with `outcome=arming`, `state/.lock` was rewritten from the dead foreign pid to the running backgrounded session's own pid, and a watcher armed and beat.
The hook therefore does fire in a backgrounded Claude session, and the identity gate alone accounted for 109 blocked turn ends.
That is what the typed record fixes: the gate closes on ancestry the migration destroyed, not on the hook's delivery.

The narrower question of whether the session id string itself is byte-identical across a migration was measured on 2026-08-14 against Claude Code 2.1.231.
The primary session moved into a background session at 2026-08-13T23:34Z still reports `CLAUDE_CODE_SESSION_ID` `70e62a49-63f7-4383-9eb8-a58df9a3a006`, identical to the id it carried before that migration according to its own pre-migration transcript records.
The id is therefore stable across a background migration, which settles approved assumption 1 as observed rather than assumed; the scope of that evidence is one measured session on one Claude Code version.
The guard's bounded terminal outcome does not depend on that stability, but the auto-arm's ability to keep arming its own home across a migration does, which is why FR-1 records the id at all.
An id that changed under a running session would make that session's own record read as foreign, the Stop auto-arm would go inert again, and the home would lose watcher continuity while the guard allowed instead of blocking - bounded, but not harmless.
For a typed record, a reader that resolves any session id of its own returns not-owned on a mismatch and deliberately skips the ancestry walk, so a mismatch degrades to not-owned rather than to the legacy ancestry test.
The guard then classifies the home as foreign and takes the bounded read-only allow, and `tests/fm-turnend-guard.test.sh` proves the guard's bounded terminal outcome by reaching it with no auto-arm file present at all and with a frozen epoch.
A record that does not parse at all is an accepted limitation of the same contract.
It classifies as not-owned, so the turn-end guard takes the loud read-only allow and the Stop auto-arm stays inert, even though `bin/fm-lock.sh` would overwrite that record and reclaim the home in one step.
The concrete path is a crash between truncate and write, which leaves a zero-byte `state/.lock` that parses as malformed.
Before this work an unparsable record did not affect the guard at all, which kept blocking until the model repaired it, so this is a real change in behavior.
It is accepted because the outcome is loud rather than silent, the session-start nudge still fires - the record does not parse as this session's own acquisition - and session start reclaims the record, so the exposure is the bounded window before session start rather than an unbounded block.
The same shape applies to any future record form an older checkout cannot parse.

A home that acquired before its harness could publish an id keeps a legacy bare-pid record, whose ownership rests on ancestry alone and so does not survive that migration at all, which is why `bin/fm-lock.sh upgrade` backfills the durable identity into such a record in place while ancestry still proves ownership.
That guarantee was measured on 2026-08-18 on macOS 26.5.2 under the stock `/bin/bash` 3.2.57(1)-release, in a throwaway fixture home built twice, once with the pre-upgrade `bin/` and once with the current one, whose harness is a `bash` symlink named `claude`.
Phase 1 fires the Stop hook from inside the owning process tree over a legacy record and leaves that process alive; phase 2 fires the same session's Stop from a process tree that does not contain the still-live recorded pid, where ancestry proves nothing and only a backfilled identity can.

```sh
FM_HOME="$dir" "$dir/fakebin/claude" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    printf "%s\n" "{\"session_id\":\"session-rehost\"}" \
      | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>&1
    sleep 60; :
  ' &
printf '%s\n' '{"session_id":"session-rehost"}' \
  | FM_HOME="$dir" bash "$dir/bin/fm-claude-stop-autoarm.sh"
```

Observed with the pre-upgrade `bin/`:

```text
phase1 record: 81682
phase2 exit: 0
recorded pid alive during phase2: yes
phase2 armed: no
phase2 epoch: <none>
```

Observed with the current `bin/`:

```text
phase1 record: pid=82157 harness=claude session=session-rehost
phase2 exit: 2
recorded pid alive during phase2: yes
phase2 armed: yes
phase2 epoch: epoch=2 owner_pid=83014 outcome=rewake updated_at=1787081275
```

The backfill preserves the recorded pid verbatim, so a daemon-parented home's record names an inner pid, and the acquisition path's non-contesting test is membership of this process's contiguous harness ancestry rather than equality with the outermost resolved pid.
Two properties therefore have to hold together: a session cleared under a harness-named daemon still reclaims the home its own record names, and a live recorded owner outside this ancestry is still refused.
Both were measured in real process trees on 2026-08-18, in the same run as the hook-side backfill cases in `tests/fm-claude-stop-autoarm.test.sh`.

```sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-session-lock-ancestry.test.sh
```

Observed output:

```text
ok - session-lock e2e: backfilling a daemon-parented session's legacy record keeps the recorded pid on the session
ok - session-lock e2e: a cleared daemon-parented session reclaims a record naming its own inner pid
ok - session-lock e2e: a live recorded owner outside this harness ancestry still refuses acquisition
FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0 duration_ms=81022
```

`tests/fm-watch-arm.test.sh` runs a real watcher and attached arm to verify that a delivered reason survives queue draining, while an unrelated queue append cannot make a watcher cycle that delivered nothing look successful.

The Claude product live path ran with Claude Code 2.1.219 on 2026-07-24:

```sh
claude --version
FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh
```

Observed output:

```text
2.1.219 (Claude Code)
ok - Claude 2.1.219 (Claude Code) live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary
```

Current entry points:

```sh
tests/fm-turnend-guard.test.sh
tests/fm-supervision-instructions.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_GROK_STOP_LIVE_E2E=1 FM_GROK_NATIVE_BIN="$native_grok" FM_GROK_LEGACY_BIN="$pre_native_grok" tests/fm-grok-stop-live-e2e.test.sh
```

The Claude auto-arm false-failure, guard-predicate, and monotonic bounded fail-open correction was verified on 2026-08-02 with the installed ShellCheck 0.11.0 and isolated behavior suites.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-supervision-instructions.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=61 local_links=174
FM_TEST_SUMMARY total=4 failed=0 skipped_gate=0 duration_ms=102585
```

The broader relevant regression pass was rerun on 2026-08-02 without live-home or daemon mutation.

```sh
bin/fm-test-run.sh tests/fm-watch-triage.test.sh tests/fm-watcher-lock.test.sh tests/fm-afk-inject-e2e.test.sh tests/fm-afk-return.test.sh tests/fm-x-mode.test.sh tests/fm-backend.test.sh tests/fm-backend-tmux-smoke.test.sh tests/fm-secondmate-safety.test.sh
```

Observed output:

```text
FM_TEST_SUMMARY total=8 failed=0 skipped_gate=0 duration_ms=617507
```

The actionable-close ordering correction was reverified on 2026-08-02 against an identity-matched live successor.

```sh
tests/fm-claude-stop-autoarm.test.sh >/dev/null && echo "fm-claude-stop-autoarm: ok"
```

Observed output:

```text
fm-claude-stop-autoarm: ok
```

## Watcher continuity

The cross-harness evidence combines the 2026-07-17 live pass with Claude's replacement Stop-owned path revalidated on 2026-07-24, all against isolated project and home state.
No credential material was copied into a fixture.

```text
Claude Code 2.1.219
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

| Harness | Exact opt-in command | Observed guarantee |
| --- | --- | --- |
| Claude | `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` | Session start reclaimed a stale owner before two Stop-owned cycles, and a competing live owner prevented arm, rewake, epoch write, or lock replacement. |
| Codex | `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh` | The one-second foreground checkpoint returned without switching to the arm wrapper. |
| OpenCode | `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh` | A verified successor existed before prompt handling, with no model re-arm or turn-end fallback. |
| Pi | `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` | One initial tool call led to extension-owned successors and clean child retirement on exit. |
| Grok | `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh` | Native task completion surfaced the actionable close and the cycle ledger recorded `reason=actionable-signal`. |

Pi 0.81.1 repeated the continuity and clean-exit lifecycle on 2026-07-23 after the Calm presentation changes.

Pi same-process session-transition ownership was verified on 2026-07-27 against the tracked extension with a faithful in-process factory rebind (module cache retained, real arm children):

```sh
pi --version
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Observed guarantee: after ordinary `session_shutdown` for `/new`, `/resume`, and `/fork`, plus same-instance shutdown-plus-start, the replacement generation armed again without a Pi restart and without the `watcher: not armed - Pi session is shutting down` refusal.
Stale prior-generation tool callbacks could not mutate the active child, repeated transitions kept exactly one live arm cycle, and terminal `quit` still refused late rearm.
Plain Pi and pi-signed share the same tracked `.pi/extensions/fm-primary-pi-watch.ts` path, so both inherit the generation owner; other primary harnesses are not applicable because they do not use this Pi extension lifecycle.

### Watcher pre-lock startup cost

`bin/fm-watch-arm.sh`'s confirmation budget must exceed the watcher's pre-lock startup, because the watcher publishes no lock, no identity, and no beacon until `bin/fm-pr-check-migrate.sh --checks-safe` has cleared.
That cost scales with the number of entries in `state/`, so it was measured against a copy of a real 1472-entry state directory on 2026-08-19, on Darwin 25.5.0 with `sysctl -n hw.ncpu` reporting 8 and a one-minute load average of 1.98.
Each run used its own `cp -a` copy in a throwaway `FM_STATE_OVERRIDE` lab, forked the watcher with `FM_POLL=999999 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999`, and timed fork to the first appearance of `state/.last-watcher-beat`, which is the earliest moment the arm's health predicate can succeed:

```sh
env FM_ROOT_OVERRIDE="$lab/root" FM_STATE_OVERRIDE="$lab/copy" \
  FM_POLL=999999 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  bin/fm-watch.sh >/dev/null 2>&1 &
while [ ! -e "$lab/copy/.last-watcher-beat" ]; do sleep 0.05; done
```

Observed fork-to-first-beacon:

```text
empty state, first run:                                     0.56 s
live state copy, first-ever run (migration repair path):    8.19 s
live state copy, second copy:                               8.64 s
live state copy, third copy:                                8.19 s
```

An idle host therefore leaves only about 1.8 seconds of margin under the former 10-second budget, and the same measurement reached 22.5 seconds on the migration's repair path under synthetic load during the preceding investigation.
The base default is 45 seconds: twice that worst measurement, and an order of magnitude below the 300-second `FM_GUARD_GRACE`, so a watcher confirmed late is still fresh by the guard's definition.
`FM_ARM_CONFIRM_MAX` caps one arm's total confirmation wall clock at three base budgets and always terminates.

Deterministic entry points:

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-watch-arm.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-turnend-guard.test.sh
```

## Wedge-alarm channels

The two real notification channels were bounded manually on 2026-07-10 on macOS 26.5.2 with Herdr 0.7.3.
Automated suites never execute these real notification commands.

Argv-safe Notification Center command:

```sh
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
  -e 'end run' \
  'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)'
```

Observed output: no stdout, exit 0, and one banner with the supplied body.

Herdr command:

```sh
herdr notification show 'FIRSTMATE TEST - IGNORE' \
  --body 'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)' \
  --sound request
```

Observed output:

```json
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
```

The safe command-channel contract is covered without a notification by `tests/fm-daemon.test.sh`: the summary reaches both `$1` and stdin, every channel is process-group bounded, and a failed channel falls through.
