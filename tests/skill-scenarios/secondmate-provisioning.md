# Scenario fixtures: secondmate-provisioning

Answers derived from `.agents/skills/secondmate-provisioning/SKILL.md` at commit `6b39930`, before the compaction pass.
See [README.md](README.md) for how these are used and why the answers predate the edit.

## S1 - which registry field routes work

**Situation:** A registry entry reads `- docs-mate - keeps the documentation domain shipshape (home: /Users/x/docs-mate; scope: documentation, developer guides, and reference prose; projects: firstmate, treehouse; added 2026-07-02)`. A request arrives to fix a failing test in `treehouse`.

**Question:** Does the `projects:` field make that request this secondmate's work?

**Expected answer:** No. Routing is by the natural-language `scope:` field, and a failing test is not documentation work. `projects:` is a non-exclusive clone list, not ownership, so a project appearing there does not make every request against that project the secondmate's.

**Anchor:** "The `scope:` field is used during intake." / "The `projects:` field is a non-exclusive clone list, not ownership."

## S2 - seeding with neither a project list nor --no-projects

**Situation:** You run `bin/fm-home-seed.sh docs-mate -` and pass no project names and no `--no-projects`.

**Question:** What happens, and is a project-less home a reasonable thing to infer?

**Expected answer:** It fails loudly. Omitting both still fails rather than being read as a deliberate project-less seed, so an accidental omission is never mistaken for one. `--no-projects` and a project list are mutually exclusive; one of the two must be stated explicitly.

**Anchor:** "`--no-projects` is mutually exclusive with a project list, and omitting both still fails loudly, so an accidental omission is never mistaken for a deliberate project-less seed."

## S3 - re-seeding a populated home as project-less

**Situation:** An existing secondmate home already holds two project clones. You want to convert it to a project-less firstmate-repo domain and re-run the seed with `--no-projects`.

**Question:** Does the seed convert it, and what is the correct sequence?

**Expected answer:** It refuses, non-destructively, and leaves the home unchanged. Retire or clean that home first, re-scaffold the stale project-bearing charter with `--no-projects`, then seed. The seed may only create a home with no project clones and no project-registry entries.

**Anchor:** "Re-seeding a populated home as project-less is refused non-destructively when the home contains project clones or `data/projects.md` entries." / "Retire or clean that home first."

## S4 - which harness launches the secondmate

**Situation:** `config/secondmate-harness` is absent. `config/crew-harness` contains `codex`. The primary firstmate is running on `claude`. You spawn a secondmate with no per-spawn harness override.

**Question:** Which harness launches it?

**Expected answer:** `codex`. Resolution is `config/secondmate-harness` -> `config/crew-harness` -> the primary's own harness, and the first concrete value in that order wins.

**Anchor:** "`bin/fm-spawn.sh --secondmate` launches it through the secondmate harness path, resolving `config/secondmate-harness` -> `config/crew-harness` -> the primary's own harness unless an explicit per-spawn harness override is passed."

## S5 - an explicit per-spawn harness and the pinned model

**Situation:** `config/secondmate-harness` contains `claude opus xhigh`. You spawn the secondmate with an explicit `--harness codex` and no other flags.

**Question:** Does the spawn run on `codex` with `opus`/`xhigh`, or on `codex` with no model or effort pin?

**Expected answer:** `codex` with no model and no effort pin. The file's model and effort tokens apply only when the harness itself came from the secondmate config path for that spawn; an explicit `--harness`, a positional harness argument, or a raw launch command starts clean on model and effort too, unless the caller also passes explicit `--model` or `--effort`.

**Anchor:** "For a `--secondmate` spawn, `bin/fm-spawn.sh` populates `MODEL`/`EFFORT` from those tokens only when the harness itself came from the secondmate config path for that spawn." / "An explicit per-spawn `--harness` flag, positional harness arg, or raw launch command starts clean on model and effort too."

## S6 - is the secondmate harness pin inherited

**Situation:** The primary home has `config/secondmate-harness` containing `claude opus`. A secondmate home is being converged with the primary's inherited local material.

**Question:** Does that file propagate into the secondmate home?

**Expected answer:** No. `config/secondmate-harness` is not inherited, because it is only the primary's knob for launching secondmate agents, and secondmates do not spawn secondmates. The inherited items are `config/crew-dispatch.json`, `config/crew-harness`, `config/backlog-backend`, `config/backend`, `config/herdr-presentation-spaces`, `config/startup-memory-budget`, and `data/captain-shared.md`.

**Anchor:** "`config/secondmate-harness` is not inherited because it is only the primary's knob for launching secondmate agents."

## S7 - an inherited backend and a live worker

**Situation:** The primary's `config/backend` changes. A secondmate home has a crewmate already running on the previously configured backend. The inherited value propagates.

**Question:** What happens to the running worker, and can a per-spawn `--backend` still differ from the inherited default?

**Expected answer:** Nothing happens to the running worker. The inherited value becomes that home's local default for future spawns only; it never retargets, rewrites, migrates, stops, or restarts an already-live worker endpoint. An explicit per-spawn `--backend` and `FM_BACKEND` remain stronger than every home's local `config/backend`, including an inherited one.

**Anchor:** "Inherited `config/backend` becomes that secondmate home's local runtime-backend default for future spawns only; it never retargets, rewrites, migrates, stops, or restarts an already-live worker endpoint." / "Explicit per-spawn `--backend` and `FM_BACKEND` remain stronger."

## S8 - a captain preference discovered inside a secondmate home

**Situation:** A secondmate learns a durable captain preference that applies across every domain. Its own `data/captain-shared.md` is present, propagated from the primary.

**Question:** May it edit that file, and how does the preference reach the fleet?

**Expected answer:** No. `data/captain-shared.md` is main-authoritative in the primary home and read-only in secondmate homes; it must not be edited there, and no secondmate copy is ever copied back into the primary. New captain-preference discoveries are routed to the main firstmate through marked status or a document pointer. Between propagation runs the secondmate copy is filesystem read-only.

**Anchor:** "`data/captain-shared.md` is main-authoritative in the primary home and read-only in secondmate homes." / "Never copy any secondmate `data/captain-shared.md` back into the primary."

## S9 - divergent shared-captain bytes on the secondmate side

**Situation:** A secondmate home's `data/captain-shared.md` has somehow diverged from the primary's. Propagation runs.

**Question:** Are the secondmate's bytes silently overwritten?

**Expected answer:** No. Before replacing divergent bytes the helper hash-compares source and destination, quarantines the secondmate-local version to a collision-safe private dated sibling file, and emits a `SECONDMATE_SYNC:` diagnostic naming the home and the quarantine artifact. When the primary file is absent instead, any existing secondmate copy is quarantined and removed, so absence converges too.

**Anchor:** "Before replacing divergent secondmate bytes, the helper hash-compares source and destination, quarantines the secondmate-local version to a collision-safe private dated sibling file, and emits a `SECONDMATE_SYNC:` diagnostic."

## S10 - propagating learnings

**Situation:** A secondmate records an operational gotcha in its `data/learnings.md` that would help every home in the fleet.

**Question:** Should a learnings propagation path be built or used?

**Expected answer:** No. Every `data/learnings.md` stays fully local by captain decision. Fleet-general machinery facts are routed into tracked documentation through the normal firstmate repo path rather than inventing shared learnings propagation.

**Anchor:** "Keep every `data/learnings.md` fully local by captain decision; route fleet-general machinery facts into tracked documentation through the normal firstmate repo path rather than inventing shared learnings propagation."

## S11 - handing off an in-flight backlog item

**Situation:** A new secondmate covers a domain. The main backlog has one matching item under `## Queued` and one matching item under `## In flight`.

**Question:** Which can `bin/fm-backlog-handoff.sh` move?

**Expected answer:** Only the `## Queued` item. The helper accepts in-scope `## Queued` entries only and refuses `## In flight` and historical `## Done` entries; Done records stay with their home for pruning or archiving. It is idempotent, so an item already in the secondmate backlog is skipped.

**Anchor:** "It accepts in-scope `## Queued` entries only and refuses `## In flight` and historical `## Done` entries."

## S12 - handoff with an odd indent

**Situation:** A queued item's continuation lines are indented with a single space, and another selected item uses a tab.

**Question:** Does the handoff move them anyway?

**Expected answer:** No. It refuses a selected item with a single-space or tab-indented continuation rather than risk leaving content orphaned in the main backlog. It moves the whole block only for the two-or-more-space-indented body form, byte-exact.

**Anchor:** "It refuses a selected item with a single-space or tab-indented continuation rather than risk leaving content orphaned in the main backlog."

## S13 - a local-only project's work

**Situation:** A secondmate's scope plainly covers a `local-only` project, and there is a queued `local-only` item that matches.

**Question:** Should the project be cloned into that home and the item handed off?

**Expected answer:** No on both counts. Secondmate project lists may include `no-mistakes` and `direct-PR` projects only; `local-only` projects stay with the main firstmate, and `local-only` items are not handed off.

**Anchor:** "Secondmate project lists may include `no-mistakes` and `direct-PR` projects only." / "Do not hand off `local-only` items."

## S14 - a live secondmate and a changed inherited config

**Situation:** A secondmate is running and healthy. Only the primary's `config/crew-dispatch.json` changed.

**Question:** Respawn it, or push?

**Expected answer:** Push. Prefer `bin/fm-config-push.sh` over respawning when the secondmate is already running and only inherited local material changed. It uses the same live-home discovery and propagation helper as bootstrap, reports each item as `pushed`, `unchanged`, `skipped`, or `error`, and follows the config-reread contract.

**Anchor:** "If the secondmate is already running and only inherited local material changed, prefer `bin/fm-config-push.sh` over respawning."

## S15 - what a config-reread message may contain

**Situation:** Propagation changed two allowlisted config files for one home, and `data/captain-shared.md` changed as well. A config-reread instruction file is being generated.

**Question:** What goes into it, and how is it delivered?

**Expected answer:** Only the allowlisted config items that actually changed for that home, in deterministic allowlist order, each printed with clear begin/end delimiters and the destination file's full exact new bytes unparsed, or the literal token `ABSENT` when propagation removed the destination copy. It never includes SHA values, selected profiles, parsed summaries, or any other generated interpretation. `data/captain-shared.md` is not a config file and is never inlined into that instruction file or message. Delivery uses the routed `fm-send` path carrying only a single-line `CONFIG_REREAD: <absolute path>` pointer.

**Anchor:** "The instruction uses only minimal framing... it never includes SHA values, selected profiles, parsed summaries, or any other generated interpretation." / "`data/captain-shared.md` is not a config file and is never inlined into this instruction file or message."

## S16 - a freshly relaunched secondmate with a pending generation

**Situation:** A secondmate is relaunched. A config-reread generation was pending for it at the time.

**Question:** Does it still need the live-agent config nudge?

**Expected answer:** No. A newly launched or relaunched secondmate already reads its files at launch, so its pending generations are discarded or quarantined after cleanup failure, and it needs no redundant live-agent config nudge unless propagation changes files after launch.

**Anchor:** "A newly launched or relaunched secondmate already reads its files at launch, so its pending config-reread generations are discarded or quarantined after cleanup failure and it needs no redundant live-agent config nudge unless propagation changes files after launch."

## S17 - a dead secondmate's crew

**Situation:** Session start reports a `kind=secondmate` record whose window is gone. That secondmate had three crewmates of its own.

**Question:** What does the main firstmate reconcile?

**Expected answer:** Only the secondmate itself: respawn it with `bin/fm-spawn.sh <id> --secondmate` using the recorded `home=`. Do not reconstruct or supervise its whole tree from the main home. Each secondmate is a firstmate in its own home, so it runs recovery on startup and reconciles its own crewmates, then idles; it never initiates a survey or audit during recovery.

**Anchor:** "Do not reconstruct a secondmate's whole tree from the main home." / "A secondmate's recovery reconciles only work that is already its own and then idles."

## S18 - an idle secondmate

**Situation:** A secondmate has had an empty queue for a week.

**Question:** Is that a teardown trigger?

**Expected answer:** No. A secondmate is persistent by default and an empty queue is healthy. Teardown runs only when the captain or main firstmate explicitly decides to retire that persistent second mate.

**Anchor:** "A secondmate is persistent by default." / "An empty queue is healthy and does not trigger teardown."

## S19 - teardown when the lease will not return

**Situation:** Retirement is authorized. The home is safe to remove, but `treehouse return` fails for its leased home.

**Question:** Should teardown remove the directory anyway?

**Expected answer:** No. Teardown stops with state intact rather than raw-removing the directory and hiding a held lease. Removing a leased home releases its lease via `treehouse return` so the pool slot is freed; a plain-clone home with no pool slot is simply removed.

**Anchor:** "If `treehouse return` fails for a leased home, teardown stops with state intact rather than raw-removing the directory and hiding a held lease."

## S20 - process-event cleanup before removal

**Situation:** Retirement is authorized and the home is otherwise safe, but the target home's process-event runner cannot be reached to confirm its registrations retired.

**Question:** Does teardown proceed?

**Expected answer:** No. It refuses retirement while that cleanup is uncertain or unavailable, preserving the home and retirement records for a later retry. Raw deletion is unsupported because a blocking process-event child can outlive its home.

**Anchor:** "It refuses retirement while that cleanup is uncertain or unavailable." / "Raw deletion is unsupported because a blocking process-event child can outlive its home."

## S21 - forcing teardown over unlanded child work

**Situation:** Teardown refuses because the secondmate's `state/*.meta` shows in-flight work. The captain has said "retire docs-mate" and nothing else.

**Question:** Is `--force` authorized?

**Expected answer:** No. `--force` is the explicit discard path - it kills child windows and discards child work and state inside the home - and it is never used unless the captain explicitly said to discard the work. "Retire it" is not that instruction.

**Anchor:** "Never use `--force` unless the captain explicitly said to discard the work."

## S22 - a seed that fails halfway

**Situation:** `bin/fm-home-seed.sh` gets as far as cloning two projects, then no-mistakes initialization fails on the second.

**Question:** What state is left behind?

**Expected answer:** None of it. Seeding is transactional: if validation, cloning, no-mistakes initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.

**Anchor:** "Seeding is transactional." / "If validation, cloning, no-mistakes initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back."

## S23 - seeding with a placeholder charter

**Situation:** A charter was scaffolded without `FM_SECONDMATE_CHARTER` and still carries its `{TASK}` placeholder. You run the seed.

**Question:** Does it seed?

**Expected answer:** No. `bin/fm-home-seed.sh` refuses to copy a missing or placeholder charter; the placeholder must be replaced before seeding. A direct seed with no preexisting brief requires `FM_SECONDMATE_CHARTER`.

**Anchor:** "`bin/fm-home-seed.sh` refuses to copy a missing or placeholder charter." / "Direct seed without a preexisting brief requires `FM_SECONDMATE_CHARTER`."

## S24 - what a leased home survives

**Situation:** A secondmate home was leased with `-`. The machine reboots and no secondmate process is running.

**Question:** Can a later `treehouse get` or `prune` recycle that slot?

**Expected answer:** No. The lease survives with no live process and is never recycled by later `treehouse get` or `prune`. The slot stays reserved across restarts until the lease is released, which happens only on explicit retirement or seed rollback - never on routine restart or recovery.

**Anchor:** "The lease survives with no live process and is never recycled by later `treehouse get` or `prune`." / "Release happens only on explicit retirement or seed rollback, never on routine restart or recovery."
