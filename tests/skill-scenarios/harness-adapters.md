# Scenario fixtures: harness-adapters

Answers derived from `.agents/skills/harness-adapters/SKILL.md` at commit `6b39930`, before the compaction pass.
See [README.md](README.md) for how these are used and why the answers predate the edit.

This skill loads before every spawn and every recovery, so it is the most expensive one in the fleet and the one where a silent loss costs the most.
The scenarios below are weighted toward resolution orders, refusals, and the pairs of similar-looking cases that a compaction is most likely to merge by mistake.

## S1 - an unverified adapter named in config

**Situation:** `config/crew-harness` names an adapter that has not been verified. A crewmate needs dispatching now.

**Question:** What do you do about this dispatch, and what do you ask the captain?

**Expected answer:** Never launch the unverified adapter. Tell the captain the requested worker runtime is not verified yet, use firstmate's own verified runtime for the current work, and ask only whether to verify the requested runtime before future use. Do not pause the current work for that future-verification choice.

**Anchor:** "Never dispatch a crewmate or secondmate on an unverified adapter." / "Do not pause current work for that future-verification choice, and never launch an unverified adapter."

## S2 - detection returns unknown

**Situation:** `bin/fm-harness.sh` reports `unknown` for firstmate's own harness.

**Question:** Do you pick the most likely adapter?

**Expected answer:** No. On `unknown`, ask the captain instead of guessing. A captain override always beats detection.

**Anchor:** "On `unknown`, ask the captain instead of guessing." / "A captain override always beats detection."

## S3 - the secondmate harness chain

**Situation:** `config/secondmate-harness` is absent, `config/crew-harness` is absent, and firstmate itself runs on `pi`. A secondmate is being launched.

**Question:** Which harness launches it?

**Expected answer:** `pi` - firstmate's own. The chain is `config/secondmate-harness` -> `config/crew-harness` -> firstmate's own, so with both files absent it falls through to firstmate's own harness.

**Anchor:** "resolved through the fallback chain `config/secondmate-harness` -> `config/crew-harness` -> firstmate's own."

## S4 - inheriting the crew harness with no concrete value

**Situation:** The primary's `config/crew-harness` is `default`. A secondmate inherits the primary's local material and then spawns its own crewmate.

**Question:** Which harness does that crewmate use?

**Expected answer:** The secondmate's own or detected harness. Inheritance copies the literal file, and `default` (like unset) is not a concrete value, so there is nothing to inherit and the fallback is the secondmate's own harness rather than the primary's effective crewmate harness. Only a concrete adapter name such as `codex` propagates.

**Anchor:** "If `config/crew-harness` is unset or `default`, there is no concrete value to inherit, so the secondmate's own crewmates fall back to the secondmate's own/detected harness."

## S5 - the Pi family identity marker

**Situation:** A process tree shows Pi launcher ancestry, and `PI_CODING_AGENT=true` is set, but `FM_PI_HARNESS` is not set.

**Question:** Is this `pi` or `pi-signed`?

**Expected answer:** `pi`. Only the exact launch-boundary marker `FM_PI_HARNESS=pi-signed` alongside `PI_CODING_AGENT=true` selects the signed identity; unmarked shared launcher ancestry remains `pi`. The plain `pi` command also execs the signed launcher, which is why ancestry alone cannot decide it.

**Anchor:** "only the exact launch-boundary marker `FM_PI_HARNESS=pi-signed` alongside `PI_CODING_AGENT=true` selects the signed identity; unmarked shared launcher ancestry remains `pi`."

## S6 - pi-signed unavailable

**Situation:** A spawn selects `pi-signed`, but that wrapper is not available on `PATH`.

**Question:** Does firstmate fall back to `pi`?

**Expected answer:** No. Firstmate records `pi-signed` without normalization and refuses rather than falling back to `pi` when that wrapper is unavailable.

**Anchor:** "records `pi-signed` without normalization, and refuses rather than falling back to `pi` when that wrapper is unavailable."

## S7 - which harness to use during stuck recovery

**Situation:** A crewmate is wedged. The fleet's current `config/crew-harness` has changed since that task was spawned.

**Question:** Which harness's interrupt and exit facts apply?

**Expected answer:** The one recorded as `harness=` in that task's `state/<id>.meta`, not the current config. Use that recorded value for interrupt, exit, resume, and skill-invocation facts.

**Anchor:** "For stuck recovery, the target window's harness is recorded as `harness=` in `state/<id>.meta`. Use that value for interrupt, exit, resume, and skill-invocation facts."

## S8 - effort precedence

**Situation:** The captain said "run this one on low". A standing dispatch profile matches the task and specifies `high`. The work is ambiguous investigation, which the generic fallback would put at `xhigh`.

**Question:** Which effort is used?

**Expected answer:** `low`. An explicit per-task captain instruction comes first, then any applicable standing dispatch profile or secondmate pin, then the generic fallback. Never replace an effort value supplied by a higher-precedence source, and use the fallback only when neither the captain nor applicable standing configuration specifies effort.

**Anchor:** "Effort precedence is an explicit per-task captain instruction first, then any applicable standing dispatch profile or secondmate pin, then the generic fallback." / "Never replace an effort value supplied by either higher-precedence source."

## S9 - an adapter with no xhigh

**Situation:** The fallback says this ambiguous design work deserves `xhigh`, but the chosen adapter's ceiling is `high`.

**Question:** What effort is selected?

**Expected answer:** `high` - cap the choice at the adapter's highest supported non-`max` level rather than omitting the intended effort silently.

**Anchor:** "When a verified adapter lacks `xhigh`, cap the choice at its highest supported non-`max` level rather than omitting the intended effort silently."

## S10 - reaching for max

**Situation:** The work is the most open-ended, highest-blast-radius task in the queue. The captain has said nothing about effort.

**Question:** May the fallback select `max`?

**Expected answer:** No. Never select `max` from the fallback; use it only when the captain has explicitly expressed that per-task or standing preference.

**Anchor:** "Never select `max` from this fallback; use it only when the captain has explicitly expressed that per-task or standing preference."

## S11 - an effort value the harness rejects

**Situation:** A profile resolves `effort=max` for a harness whose accepted set stops at `high`.

**Question:** What does `fm-spawn` do - fail the launch, or downgrade silently?

**Expected answer:** Neither. It records the requested `effort=` in the task metadata but emits no effort flag for that harness, which preserves launch success instead of passing a known-bad value.

**Anchor:** "`fm-spawn` records the requested `effort=` in meta but emits no effort flag for that harness. This preserves launch success instead of passing a known-bad value."

## S12 - harness identity versus model provider

**Situation:** A dispatch resolves to `harness=pi` with `model=xai/grok-4`.

**Question:** Is this the Grok adapter, and does it need a Grok CLI login?

**Expected answer:** No to both. The concrete `harness` field owns adapter identity independently of the model provider: this is Pi using xAI, not `harness=grok`, and it does not require Grok CLI login. `harness=grok` remains the standalone Grok Build CLI adapter.

**Anchor:** "`harness=pi` with `model=xai/grok-*` is Pi using xAI, not `harness=grok`, and does not require Grok CLI login."

## S13 - a model listing that does not contain the model

**Situation:** You run the harness's own model listing, it reaches the account successfully, and the requested model is not in it.

**Question:** What does that establish?

**Expected answer:** It is concrete evidence the model is unsupported: block that candidate and quote the result.

**Anchor:** "A listing that reaches the account and does not contain the model is concrete evidence the model is unsupported: block that candidate and quote the result."

## S14 - a discovery surface you could not reach

**Situation:** The model listing command fails to run - no auth, no network.

**Question:** Is the model supported or unsupported?

**Expected answer:** Neither is established. A discovery surface you could not reach establishes nothing; report that as uncertainty rather than turning it into a supported or unsupported verdict.

**Anchor:** "A discovery surface you could not reach establishes nothing; report that as uncertainty rather than turning it into a supported or unsupported verdict."

## S15 - invoking the validation skill on codex

**Situation:** A codex crewmate needs `/no-mistakes` sent.

**Question:** What exactly do you send?

**Expected answer:** `$no-mistakes`. Codex uses `$<skill>`; `/<skill>` is claude-only and codex rejects it as "Unrecognized command".

**Anchor:** "codex: `$<skill>`, for example `$no-mistakes`; `/<skill>` is claude-only and codex rejects it as 'Unrecognized command'."

## S16 - invoking a skill on opencode or pi

**Situation:** An opencode crewmate needs the validation skill and you are unsure of the exact command form.

**Question:** What do you send?

**Expected answer:** Natural language is acceptable when uncertain. Opencode and pi have no separate verified skill invocation beyond normal slash-command/command behavior, so use natural language rather than guessing at a command form.

**Anchor:** "Natural language is acceptable if uncertain." / "opencode: no separate verified skill invocation beyond normal slash-command behavior."

## S17 - a send that reported success

**Situation:** `fm-send` exited 0 delivering a message to a crewmate, and the pane looks healthy.

**Question:** Is the message delivered?

**Expected answer:** Not proven. A send or key action reporting success is not proof that the intended action happened - OpenCode can accept and queue an Enter while leaving text visible, Grok can consume Enter in its slash popup without submitting, and Kimi can silently drop a message sent before readiness. The shared symptom is a healthy-looking pane with no work in progress, so verify the observable postcondition specific to that TUI.

**Anchor:** "A send or key action reporting success is not proof that the intended action happened."

## S18 - interrupting a grok worker

**Situation:** A grok crewmate is mid-turn and needs interrupting.

**Question:** Does Escape interrupt it?

**Expected answer:** No. On grok, `Esc` only moves focus to the scrollback and does NOT interrupt; the interrupt is a single `Ctrl+C`. `Ctrl+C` is the interrupt rather than the exit.

**Anchor:** "single `Ctrl+C` (cancels the current turn...). `Esc` only moves focus to the scrollback, it does NOT interrupt."

## S19 - interrupting claude versus opencode

**Situation:** One claude crewmate and one opencode crewmate both need interrupting.

**Question:** What is the interrupt for each, and what if the opencode one does not respond?

**Expected answer:** Claude takes a single Escape; opencode takes a double Escape. Opencode's interrupt is known flaky while a long shell command runs, so a wedged opencode pane may need `/exit` and a relaunch.

**Anchor:** "claude ... Interrupt | single Escape" / "opencode ... double Escape; known flaky while a long shell command runs, so a wedged pane may need `/exit` and relaunch."

## S20 - resuming an exited worker

**Situation:** A codex worker and a grok worker have both exited cleanly.

**Question:** How is each resumed?

**Expected answer:** Codex resumes with `codex resume <session-id>`, the id printed on quit. Grok resumes with `grok --resume <session-id>` (id printed on exit), or `grok -c` / `--continue` for the most recent session for the cwd; `--fork-session` branches a new session id.

**Anchor:** "Resume after exit with `codex resume <session-id>`." / "`grok --resume <session-id>` (id printed on exit) or `grok -c` / `--continue`."

## S21 - relaunching opencode after a self-upgrade exit

**Situation:** An opencode pane shows the exit banner after a background auto-upgrade.

**Question:** How do you resume, and will `--prompt` deliver the next instruction?

**Expected answer:** Relaunch with `--continue` to resume the session. `--prompt` does not auto-submit alongside `--continue`, so send the next instruction via `fm-send` once the TUI is up.

**Anchor:** "relaunch with `--continue` to resume the session. `--prompt` does not auto-submit alongside `--continue`."

## S22 - the shape of a Pi brief

**Situation:** A Pi crewmate is being launched with a brief.

**Question:** May the brief be passed as several positional arguments?

**Expected answer:** No. Keep the brief as one positional argument; multiple positional args become separate queued messages. `fm-spawn`'s template already does this correctly.

**Anchor:** "Keep the brief as one positional argument. Multiple positional args become separate queued messages."

## S23 - Pi permissions

**Situation:** A Pi crewmate needs to run autonomously.

**Question:** Which autonomy flag does it need?

**Expected answer:** None. Pi has no permission system, so crewmates are always autonomous.

**Anchor:** "Pi has no permission system, so crewmates are always autonomous."

## S24 - launching Kimi with a brief

**Situation:** A Kimi crewmate is being launched and the brief lives outside the task worktree.

**Question:** Can the brief be passed positionally, and does the path need to be absolute?

**Expected answer:** It cannot be passed positionally - Kimi rejects a positional brief as an unknown command, so the launch is a bare interactive TUI with `--auto` followed by readiness-gated pointer delivery. The brief path must be absolute, because the brief lives outside the task worktree and Kimi reads it there without `--add-dir`.

**Anchor:** "This launch-then-send shape is mandatory because Kimi rejects a positional brief as an unknown command." / "The brief path must be absolute."

## S25 - Kimi autonomy flags

**Situation:** Kimi offers `--auto`, `-y`, and `--yolo`.

**Question:** Which does firstmate use?

**Expected answer:** `--auto`. `-y` and `--yolo` are weaker and are not used.

**Anchor:** "Autonomy | `--auto`; `-y` and `--yolo` are weaker and are not used."

## S26 - proving a guarded silent hook fired

**Situation:** Kimi's guarded turn-end hook appears not to be firing - nothing happened.

**Question:** Does that absence prove it did not fire?

**Expected answer:** No. A guarded silent hook cannot be verified from absence of effect, so prove invocation with an unguarded probe before concluding that the hook did not fire.

**Anchor:** "A guarded silent hook cannot be verified from absence of effect, so prove invocation with an unguarded probe before concluding that the hook did not fire."

## S27 - where grok's turn-end hook is installed

**Situation:** Grok needs a per-turn wake signal for a crewmate in a fresh worktree.

**Question:** Does firstmate install a project hook in the worktree?

**Expected answer:** No. Grok loads project hooks only after the folder is granted hook-trust in `~/.grok/trusted_folders.toml`, which is not automatic and which firstmate will not establish by editing grok's own managed trust store. Global hooks in `~/.grok/hooks/` are always trusted, so `fm-spawn` installs one firstmate-owned global hook, guarded as a no-op for every non-firstmate grok session.

**Anchor:** "GLOBAL hooks in `~/.grok/hooks/` are always trusted and load on first launch. So `fm-spawn` installs ONE firstmate-owned global hook."

## S28 - grok's startup project picker

**Situation:** A grok crewmate is being spawned into a treehouse worktree.

**Question:** Do you need to send a keystroke to clear the project picker?

**Expected answer:** No. The picker appears only when grok is launched from a non-project directory. `fm-spawn` launches inside the treehouse worktree, a git repo root, so the picker never appears and grok treats the worktree as a trusted project automatically - no post-launch keystroke is needed.

**Anchor:** "the picker never appears and grok treats the worktree as a trusted project automatically - no post-launch keystroke is needed."

## S29 - Claude's ghost text

**Situation:** A claude pane's composer appears to contain text after a turn completes.

**Question:** Is that pending input, and what prevents the misreading?

**Expected answer:** It may be Claude's predicted-next-prompt suggestion rendered as dim/faint text in an otherwise-empty composer, which a plain `tmux capture-pane` cannot tell apart from typed text. Firstmate launches every claude crewmate and secondmate with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, scoped to firstmate-launched agents so it never touches the captain's global config. The CLI's `--prompt-suggestions` flag is print/SDK-mode only and does not suppress the interactive composer ghost text.

**Anchor:** "The CLI's `--prompt-suggestions` flag is print/SDK-mode only and does not suppress the interactive composer ghost text."

## S30 - what the styled capture is used for

**Situation:** The ghost-stripping extractor reads styled output with escape codes.

**Question:** Do `fm-peek` and other human-facing captures use that styled read?

**Expected answer:** No. That styled capture is internal to the boolean detector only; `fm-peek` and every other human or LLM-facing capture path stays plain `tmux capture-pane` with no escape codes.

**Anchor:** "That styled capture is internal to the boolean detector only. `fm-peek` and every other human or LLM-facing capture path stays plain `tmux capture-pane` with no escape codes."

## S31 - the Claude delegation deny list

**Situation:** A Claude primary needs known delegation tools removed from the model's schema.

**Question:** Should that deny list ship in the repo's tracked `.claude/settings.json`?

**Expected answer:** No. Use an untracked per-home local `permissions.deny` list. It must not ship in tracked `.claude/settings.json` because it is Claude-only rather than harness-agnostic, and because tracked project settings propagate into linked worktrees where they would disarm legitimate crewmates.

**Anchor:** "That deny list must not ship in tracked `.claude/settings.json` ... tracked project settings propagate into linked worktrees where they disarm legitimate crewmates."

## S32 - a positive allowlist for Claude tools

**Situation:** You want a fail-closed positive allowlist so only approved tools are ever available on a Claude primary.

**Question:** Does `permissions.allow` give you that?

**Expected answer:** No. `permissions.allow` is a pre-approval list rather than an availability list, so there is no fail-closed positive allowlist.

**Anchor:** "`permissions.allow` is a pre-approval list rather than an availability list, so there is no fail-closed positive allowlist."

## S33 - where a Claude primary is launched from

**Situation:** A Claude primary's `.claude/settings.json` hooks are not taking effect.

**Question:** What is the likely cause?

**Expected answer:** The session was not launched from the exact project root. A project-level `.claude/settings.json` only takes effect when Claude Code's project root is that exact directory - it does not walk up from a subdirectory - which is why firstmate launches the primary from the repo root. Hook command resolution is separately cwd-sensitive, so tracked commands stay anchored through `"$CLAUDE_PROJECT_DIR"/bin/...`.

**Anchor:** "it does not walk up from a subdirectory looking for one, so firstmate launches the primary from the repo root."

## S34 - the codex `$` popup settle

**Situation:** A plain steer containing `$HOME` is being sent to a claude crewmate.

**Question:** Does it get the codex `$`-popup settle delay?

**Expected answer:** No. The `$` settle is scoped to `harness=codex`, read from the target metadata, precisely because a leading `$` commonly starts ordinary text (`$5/month`, `$HOME`) and a universal rule would needlessly slow plain steers to claude, opencode, and pi.

**Anchor:** "only a codex target receiving a `$...` message gets the popup-settle."

## S35 - a target with no metadata

**Situation:** A message is sent to an explicit `session:window` target rather than a task id.

**Question:** Which harness is assumed?

**Expected answer:** An explicit `session:window` target has no meta, so its harness is unknown and it is treated as non-codex - the safe fast-path default.

**Anchor:** "An explicit `session:window` target has no meta, so its harness is unknown and treated as non-codex (the safe fast-path default)."

## S36 - why codex supervises with a bounded checkpoint

**Situation:** Codex's primary watcher protocol uses `bin/fm-watch-checkpoint.sh` rather than `bin/fm-watch-arm.sh`.

**Question:** Why, and what does that buy?

**Expected answer:** Because Codex cannot reason while a foreground tool call is running. The checkpoint is deliberately foreground and bounded so Codex regains control regularly to process user messages and queued wakes.

**Anchor:** "Codex uses bounded foreground checkpoints through `bin/fm-watch-checkpoint.sh` because Codex cannot reason while a foreground tool call is running."

## S37 - who re-arms the watcher on Claude

**Situation:** A Claude primary finishes a turn and supervision needs to stay live.

**Question:** Does the model run a re-arm command?

**Expected answer:** No. Claude Code's primary watcher protocol is Stop-owned: the auto-arm hook fires on every Stop and foregrounds `bin/fm-watch-arm.sh` when the home is eligible and still needs supervision, and its exit-2 `asyncRewake` rewake is the wake. The model drains and handles wakes but never runs a routine re-arm command.

**Anchor:** "the model drains and handles wakes but never runs a routine re-arm command."

## S38 - verifying a brand-new harness

**Situation:** The captain asks for a harness firstmate has never used.

**Question:** What is the verification path before it can carry real work?

**Expected answer:** Propose verifying it first: spawn a trivial supervised task using `fm-spawn`'s raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics in `fm-spawn`, its semantic busy source and trust gate in `bin/fm-busy-lib.sh`, any needed `FM_COMPOSER_IDLE_RE` empty-composer override plus any novel bare agent prompt glyph in `bin/fm-composer-lib.sh`, the tmux agent-process liveness classification in `bin/backends/tmux.sh` when the harness can launch a secondmate, and the verified knowledge in this skill.

**Anchor:** "spawn a trivial supervised task using `fm-spawn`'s raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics..."
