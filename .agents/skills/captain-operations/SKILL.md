---
name: captain-operations
description: >-
  How a firstmate fleet is actually run: the goal, the working habits, the session-start duty, the delivery flow, and the live configuration map.
  Use at session start, before changing anything tracked, and whenever a setting's meaning or location is in doubt.
user-invocable: false
metadata:
  internal: true
---

# captain-operations

This is the operating posture every firstmate home works under.
Where a rule already has an owner elsewhere, this file names the owner rather than restating it.

## The goal

Firstmate exists so the captain states **what** they want and gets a finished, verified result, without holding the *how* in their head.
Everything below serves that, and any rule that stops serving it should be raised, not obeyed silently.

Three habits this fleet has paid for and expects:

**Measure, do not assume.**
Listings and status commands lie.
`agy` reported a model it was not using; `ruff` had far wider defaults than documented; `codex login status` reported success on a spent token; `quota-axi` showed `auth_required` for a provider that answered fine in JSON; a metadata probe said "API keys are not supported" on an endpoint that then generated an image.
**Probe the call you actually need, never its neighbour.**

**Own the miss plainly.**
Say what broke, what it cost, and what changed so it cannot recur.
No hedging, no burying it under what went well.

**Finish the chain.**
A green unit test on one link says nothing about the others.
Before calling anything done, name every link out loud - trigger, caller, dispatcher, performer - and check each one exists.

## Session start

**Arm the watcher. Every session, first thing.**

Without it there is no supervision: no `state/*.check.sh` sweep, no wake queue, no stuck-task detection, and the scheduled sprint-board check never fires.
A fleet with a dead watcher looks healthy and is blind, and the beacon can sit cold for an hour with tasks in flight before anyone notices.

Arm through `bin/fm-watch-arm.sh`, and **only** as the harness's own tracked background task (for a Claude primary, the Stop asyncRewake hook `bin/fm-claude-stop-autoarm.sh`).
Never with a shell `&` inside another call: that child is reaped when the call returns, leaving no watcher running and a false "already running" off the dying process.
That exact mistake has taken supervision down for half an hour at a stretch.

Then verify rather than assume: `state/.last-watcher-beat` must be fresh within `FM_GUARD_GRACE`.
"I ran the arm command" is not evidence; a fresh beacon is.

`AGENTS.md` section 8 and the supervision instructions emitted at session start own the protocol itself; this section owns only the arming duty and its traps.

## Delivery flow

`CONTRIBUTING.md` already mandates this.
It is repeated here because it is the flow most often skipped under time pressure, and a skipped step is usually noticed a day late.

1. **Never work on `main`.** Branch first: `fm/<slug>-r1`.
2. **Work in a worktree**, not by switching branches in the main clone.
   The clone stays on `main`, which is where agents read their scripts from - moving it out from under them removes their tools mid-flight.
3. **Commit in meaningful pieces**, not one dump.
   Each message says what broke and why the change is shaped that way, not what the diff shows.
4. **Never merge without the captain's explicit word** (hard rule 2).
5. **Never assume `gh` targets the right repository**: a wrong `--repo` makes PR creation fail with a confusing "no commits between".
   [`CONTRIBUTING.md`](../../../CONTRIBUTING.md) owns the fork, parent, and push-target setup, including which repository a PR is opened against.
6. After merge, **fast-forward the main clone** (`git merge --ff-only origin/main`).
   Skip it and the work is in GitHub but absent from the fleet.
7. Tag releases: `VERSION`, `CHANGELOG.md`, `v<x.y.z>`.
8. Changing shared tracked material **while a crewmate is live** is forbidden - delegate it or wait for an empty fleet (`AGENTS.md` section 1).

Version bumps: MAJOR only for **contract** breaks a running fleet would notice (meta format, config names, exit codes).
MINOR adds capability, PATCH fixes.

## Configuration map

Every setting below is LOCAL to a home and gitignored, so read a home's real values out of its own `config/` directory rather than assuming the defaults in this table.
`config/*.backup` files are firstmate's own snapshots, not settings - ignore them when reading state.
[`docs/configuration.md`](../../../docs/configuration.md) owns the schema for the settings it documents, while `AGENTS.md` section 2's layout block and each producing script's own header and `--help` own the rest - `bin/fm-image-gen.sh` for the image model and the daily spend cap, `bin/fm-sprint-poll.sh` for the sprint poll.
This table is the map, not the specification.

| Setting | Default when absent | Meaning |
|---|---|---|
| `config/backend` | auto-detected runtime, then `herdr` (tmux when herdr is absent) | Session backend. **Authoritative when set**: `fm-spawn.sh` refuses a `--backend` naming anything else. If it is unusable, report and stop - never spawn elsewhere. |
| `config/crew-harness` | firstmate's own harness | Default harness for crewmates. |
| `config/secondmate-harness` | `config/crew-harness`, then firstmate's own | Harness the primary uses to launch secondmates. |
| `config/crew-dispatch.json` | no profiles | Per-role harness/model/effort rules. **The one place a vendor belongs** - rules elsewhere name roles. |
| `config/image-model` | `gemini-3.1-flash-image` | Image model. Verified live before use; unavailable = loud failure, never substitution. |
| `config/image-daily-usd-cap` | `5` | Image spend per UTC day, in **dollars**, enforced before the billable call. |
| `config/sprint-poll.env` | absent = hard no-op | Scheduled sprint-board check (`3600`, `9-20`, `1-5` when enabled). |
| `config/startup-memory-budget` | `7500` | Startup memory budget in tokens. |
| `.env` | none | Holds `GEMINI_IMAGE_API_KEY`, the image credential - a Vertex **express** key (`AQ.`). |

Two traps in that table, both paid for:

**The image key must be an express key.**
A standard `AIz` Gemini API key is refused by Vertex and falls back to AI Studio prepayment, which is empty - so it fails on *every* call, even free-tier text.
`--check-models` cannot work with an express key at all: catalogue reads answer `API_KEY_SERVICE_BLOCKED` while generation works fine.
**That message never means the key is dead.**

**The daily cap counts money, not images.**
200 images is ~$13 on flash and ~$48 on pro at 4K.
An agent that hits the cap reports and stops; raising it is the captain's decision, and an agent editing its own limit has no limit.

## Tools worth knowing

- `bin/fm-quota-dash.sh` - live gauges for the dispatch-driving windows only (Claude, Codex, Grok) plus image spend; Grok's separate weekly cap is unmeasured and flagged rather than scored.
  The script header owns the rest.
- `bin/fm-image-gen.sh` - creative generation; `--size` defaults to 1K because pro returns 4K unasked and triples the price.
- `bin/fm-version.sh`, `bin/fm-sprint-poll.sh`, `bin/fm-crew-state.sh`.
- Watch a worker with `bin/fm-peek.sh`, never `tmux attach -r`: a read-only client blocks **every** `send-keys` on that server, not just the pane viewed.
