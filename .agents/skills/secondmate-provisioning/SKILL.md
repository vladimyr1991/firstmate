---
name: secondmate-provisioning
description: >-
  Agent-only reference for persistent secondmate setup and retirement.
  Use when creating, seeding, validating, launching, recovering, handing backlog to, pushing inherited local material into, or retiring a secondmate home, or when editing data/secondmates.md.
  Covers home leases, transactional seeding, project clone restrictions, secondmate harness pins, inherited local-material push, idle charter, handoff helper, and teardown safety.
user-invocable: false
metadata:
  internal: true
---

# secondmate-provisioning

Keep the always-inline routing rules in `AGENTS.md` authoritative: route by natural-language `scope:`, local-only projects stay with the main firstmate, and secondmates are idle by default except for a standing-duty secondmate scaffolded with `--standing-duty` (owned below).
Each referenced script's own header owns its exact flags, refusal codes, and data mechanics; this reference owns the decisions and the boundaries.

## Routing table

`data/secondmates.md` has one parser-compatible line per persistent second mate:

```markdown
- <id> - <one-sentence charter summary> (home: <absolute-home-path>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)
```

Keep each entry concise and single-line: one sentence naming the durable charter, then the generated suffix.
The summary and `scope:` text may themselves contain parentheses and semicolons, so keep the `(home: ...; scope: ...; projects: ...; added ...)` suffix intact for operational consumers that resolve its explicit field markers.
Extra prose is limited to genuinely domain-specific hard rules that change routing or safety for that secondmate.

- `scope:` is the natural-language intake responsibility, and it is what routing uses.
- `projects:` is a non-exclusive clone list, not ownership.
- `home:` points at the seeded home containing `data/charter.md`, so no extra registry pointer field is needed.

That home-seeded `data/charter.md` is the sole owner of boilerplate idle-by-default behavior, the normal delegation lifecycle, and standard escalation contracts; point to the charter rather than restating those contracts in the registry entry.

## Charter and seed

```sh
bin/fm-brief.sh <id> --secondmate {<project>...|--no-projects}
bin/fm-brief.sh <id> --secondmate --standing-duty {<project>...|--no-projects}
```

The scaffold writes a charter brief instead of a task brief.
Set `FM_SECONDMATE_CHARTER='<charter>'` to fill the charter text, and `FM_SECONDMATE_SCOPE='<scope>'` when the routing scope differs; scaffolding without `FM_SECONDMATE_CHARTER` leaves a `{TASK}` placeholder that must be replaced before seeding.

`--no-projects` scaffolds a project-less charter for a domain whose subject is the firstmate repo itself, whose home is a firstmate worktree and whose crews take pooled worktrees of the same repo.
It is mutually exclusive with a project list, and omitting both still fails loudly, so an accidental omission is never mistaken for a deliberate project-less seed.
Re-seeding a populated home as project-less is refused non-destructively when the home contains project clones or `data/projects.md` entries: retire or clean that home first, and re-scaffold a stale project-bearing charter with `--no-projects` before seeding.

`--standing-duty` is refused outside `--secondmate` and replaces exactly two idle-by-default passages in the generated charter so the secondmate may perform one named standing duty on its own schedule.
That duty is the complete list of self-started work; everything else still comes from the main firstmate, and the empty-queue resting state must not widen the duty or invent work beside it.
A standing duty may include continuous board or fleet observation, scheduled self-wakes such as `config/sprint-poll.env`, and reporting divergences; it may not grant write access into another home, dispatch implementation work itself, contact the captain, steer or merge foreign tasks, or discover homes by scanning the filesystem.

### Cross-home read grant

A standing-duty secondmate (and only a secondmate whose charter names this need) may read the parent home and every home listed in the parent's `data/secondmates.md` through the existing snapshot owner:

```sh
bin/fm-fleet-snapshot.sh --cross-home <parent-home-path>
bin/fm-fleet-snapshot.sh --home-summary <absolute-home-path>
```

The grant is one-directional (child reads parent and parent's registered siblings; never the reverse and never outside that registry), read-only, and enumerated only from the parent's own registry.
The secondmate's only cross-home write remains the existing parent status line its charter already mandates (`needs-decision:` / `blocked:` / `resolved [key=…]` into the parent home's `state/<id>.status`).
Escalation shape for a fleet or board finding: write a document under the secondmate's own `data/`, append one keyed status line pointing at that absolute path, and append `resolved [key=…]` when the finding clears.
Quiet cycles append nothing.
A home the snapshot could not read is **unknown**, never empty: cards that home might own must not be classified as orphaned.

The scaffolded charter, later copied to `data/charter.md`, owns the standard lifecycle and escalation wording, so preserve its generated sections and keep custom text focused on the persistent responsibility, available project clones, and genuinely domain-specific hard rules.

Provision the persistent home and registry entry after the charter is filled:

```sh
bin/fm-home-seed.sh <id> <home|-> {<project>...|--no-projects}
```

`--no-projects` in the project position seeds the project-less home described above, under the same mutual-exclusion and fail-loud-on-omission rules.
It may only seed a home with no project clones or project-registry entries, and refuses conversion of populated homes without changing them.

`-` durably leases a fresh firstmate worktree via `treehouse get --lease` under the secondmate id.
The lease survives with no live process and is never recycled by later `treehouse get` or `prune`, so the slot stays reserved across restarts until release, which happens only on explicit retirement or seed rollback, never on routine restart or recovery.

`bin/fm-home-seed.sh` copies the charter into the secondmate home as `data/charter.md`, and writes the required `.fm-secondmate-home` identity marker, which is gitignored and must remain in place for home validation.
It refuses to copy a missing or placeholder charter, and a direct seed without a preexisting brief requires `FM_SECONDMATE_CHARTER`.
Run `bin/fm-home-seed.sh validate` when checking registry integrity; its header owns the complete validation and refusal mechanics.

Seeding is transactional.
If validation, cloning, no-mistakes initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.

Secondmate project lists may include `no-mistakes` and `direct-PR` projects only.
`local-only` projects stay with the main firstmate.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.

### Harness, model, and effort

`bin/fm-spawn.sh --secondmate` launches the secondmate through the secondmate harness path, resolving `config/secondmate-harness` -> `config/crew-harness` -> the primary's own harness unless an explicit per-spawn harness override is passed.

`config/secondmate-harness` may also pin a concrete model and effort, in the SAME file rather than a new one: a single whitespace-separated line `<harness> [<model>] [<effort>]`, with only the first non-empty, non-comment line parsed.
A bare `<harness>` such as `claude` is the harness-only form and stays fully backward-compatible.
`bin/fm-harness.sh secondmate-model` and `bin/fm-harness.sh secondmate-effort` print the optional 2nd/3rd tokens (empty when absent, or when the file is absent, `default`, or harness-only); they read only `config/secondmate-harness`, never `config/crew-harness`, which stays a bare adapter name.

For a `--secondmate` spawn, `bin/fm-spawn.sh` populates `MODEL`/`EFFORT` from those tokens only when the harness itself came from the secondmate config path for that spawn.
An explicit per-spawn `--harness` flag, positional harness arg, or raw launch command starts clean on model and effort too, unless the caller also passes explicit `--model` or `--effort`, which always win over the file's token for that axis.
Because this resolves from the file on every spawn, the pin is durable across every respawn - recovery, `/updatefirstmate`, restart - exactly like the harness axis itself, so `claude opus` keeps a secondmate pinned to Opus even if the primary's own default model later changes.
This is secondmate-only: crewmate and scout model resolution is untouched by this file.

## Sync and inherited local material

This section is the single owner of the secondmate sync and inherited-local-material propagation contract; `AGENTS.md` sections 3 and 4 point here.

Before launch, `fm-spawn.sh --secondmate` locally fast-forwards the home to the primary firstmate checkout's current default-branch commit when it is safe; dirty, diverged, or in-flight homes launch unchanged with a warning.
The locked session-start bootstrap sweep runs the same guarded fast-forward for every live secondmate home, discovered from `state/<id>.meta` records with `kind=secondmate` (`data/secondmates.md` only backfills `home=` for older records).
That no-fetch path is a purely local fast-forward of tracked files, never an origin fetch, and it never touches the gitignored operational dirs, so a secondmate's backlog, projects, and in-flight work are never disturbed; a linked worktree advances immediately, while a standalone clone that lacks the target receives firstmate updates through `/updatefirstmate`'s origin refresh.

The same launch and the same locked bootstrap sweep also propagate the primary's declared inherited local material: `config/crew-dispatch.json`, `config/crew-harness`, `config/backlog-backend`, `config/backend`, `config/herdr-presentation-spaces`, `config/startup-memory-budget`, and the one shared captain-preference file `data/captain-shared.md`.
Because these paths are gitignored, that propagation is a separate, primary-authoritative copy independent of the tracked-files fast-forward: it re-converges every live home whether or not its tracked files advanced, and it touches only the declared items.
Propagation failures warn without blocking secondmate launch or session-start continuation, and the destination keeps whatever safely validated state the helper left behind.

The helper rejects unsafe directories, symlinked or nonordinary source or destination artifacts, and hardlinked destination files.
Every propagation point converges the secondmate copy to the primary bytes; when the primary file is absent, any existing secondmate copy is quarantined and removed so absence converges too.
Before replacing divergent secondmate bytes, the helper hash-compares source and destination, quarantines the secondmate-local version to a collision-safe private dated sibling file, and emits a `SECONDMATE_SYNC:` diagnostic naming the home and quarantine artifact.

What each inherited item means for the destination home:

- `config/crew-harness` is inherited as the literal file, so a secondmate's own crewmates use the primary's crewmate harness only when it names a concrete adapter such as `codex`; an unset or `default` value has nothing concrete to inherit, and the secondmate's own crewmates fall back to the secondmate's own or detected harness instead.
- `config/backend` becomes that home's local runtime-backend default for future spawns only; it never retargets, rewrites, migrates, stops, or restarts an already-live worker endpoint. A present primary value always converges byte-exact into validated secondmate homes, and primary absence removes the destination so those homes keep runtime auto-detection. `FM_BACKEND` remains the one-off override stronger than every home's local `config/backend`, including an inherited default, while an explicit per-spawn `--backend` that contradicts a set `config/backend` is refused instead of honored ([`docs/configuration.md`](../../../docs/configuration.md) "Runtime backend" owns that selection contract).
- `config/secondmate-harness` is not inherited because it is only the primary's knob for launching secondmate agents.
- `data/captain-shared.md` is main-authoritative in the primary home and read-only in secondmate homes. Its primary file header must state that the file is main-authoritative, read-only in secondmate homes, must not be edited there, and that new captain-preference discoveries are routed to the main firstmate through marked status or a document pointer. Between propagation runs the secondmate copy is filesystem read-only; the helper may make its owned destination writable only around a guarded update, and restores read-only mode on success, unchanged bytes, and recoverable failure paths. Never copy any secondmate `data/captain-shared.md` back into the primary.
- `data/captain.md` stays domain-local in every home. After first propagation to an existing home, trim that home's local `data/captain.md` by hand to domain-specific content plus pointers to `data/captain-shared.md`; do not automate or silently delete private content.
- `data/learnings.md` stays fully local by captain decision. Route fleet-general machinery facts into tracked documentation through the normal firstmate repo path rather than inventing shared learnings propagation.

### Config reread

No AGENTS.md reread nudge is needed at spawn or respawn because the agent reads instructions fresh on launch; only the bootstrap sweep's running-home instruction-surface advance needs that AGENTS.md re-read.
Bootstrap reports successful AGENTS.md re-read sends as `BOOTSTRAP_INFO:` and only emits `NUDGE_SECONDMATES:` when that send fails and needs retry.

A separate, literal-content config reread is required whenever inherited `config/*` material changes under an already-running secondmate.
Both the locked bootstrap convergence path and mid-session `bin/fm-config-push.sh` publish one per-home generation-specific private instruction file from the validated destination post-write bytes, then deliver only a single-line `CONFIG_REREAD: <absolute generation-specific instruction path>` pointer over the routed secondmate path (`fm-send`).
`bin/fm-config-inherit-lib.sh` owns the publication, retry-queue, quarantine, bounded-history, and per-home locking mechanics.
What this reference owns is the content contract and what the instruction must never claim:

- It carries only the allowlisted config items that actually changed for that home (`config/crew-dispatch.json`, `config/crew-harness`, `config/backlog-backend`, `config/backend`, `config/herdr-presentation-spaces`, `config/startup-memory-budget`), in deterministic allowlist order, each with clear begin/end delimiters and the destination file's full exact new bytes unparsed, or the explicit token `ABSENT` when propagation removed the destination copy.
- It uses only minimal framing that these are defaults and rules that do not remove judgment, and it never includes SHA values, selected profiles, parsed summaries, or any other generated interpretation.
- `data/captain-shared.md` is not a config file and is never inlined into this instruction file or message.
- Every failed publication, retry, or send surfaces a concrete `CONFIG_REREAD:` diagnostic and never claims the live agent already re-read the values.
- Homes whose allowlisted config files were all unchanged receive no config-reread message when no retry is pending, so different homes may receive different changed-file sets.
- A newly launched or relaunched secondmate already reads its files at launch, so its pending config-reread generations are discarded or quarantined after cleanup failure, and it needs no redundant live-agent config nudge unless propagation changes files after launch.
Quarantine skips creating an empty generation when the destination has no artifacts to preserve.

These config values remain defaults and rules only; they must not harden `fm-spawn` to reject a deliberate runtime choice that differs from the configured defaults.
For already-live secondmates, use `bin/fm-config-push.sh` to push a mid-session inherited local-material change without running the tracked-file fast-forward; it shares bootstrap's live-home discovery and propagation helper, and reports each item as `pushed`, `unchanged`, `skipped`, or `error`.

## Backlog handoff

Apply `AGENTS.md` section 10's work-items-only backlog contract before creation or handoff.
When a secondmate is created for a domain, existing main-backlog items that fall under its scope should become its work instead of staying stranded in the main backlog.
Scope-matching is firstmate's judgment against the secondmate's natural-language scope, not a keyword rule.
Read `data/backlog.md`, pick queued items that fit the new scope, and move them with:

```sh
bin/fm-backlog-handoff.sh <secondmate-id> <item-key>...
```

Run this handoff for the new secondmate's in-scope queued items after seeding.
The helper resolves and validates the secondmate home from `data/secondmates.md`, then delegates the item move to `tasks-axi mv` (the single owner of the backlog format), which moves each named item - and a whole connected set, blocker plus dependents, atomically - from the main `data/backlog.md` into the secondmate home's `data/backlog.md`, byte-exact under the same section.
This delegated route remains required when `config/backlog-backend=manual`, which controls only routine firstmate backlog edits.

The helper's own header owns the exact block-extraction rules; the refusals that decide whether to call it at all are:

- It accepts in-scope `## Queued` entries only, and refuses `## In flight` and historical `## Done` entries; Done records stay with their home for pruning or archiving.
- It refuses a selected item with a single-space or tab-indented continuation rather than risk leaving content orphaned in the main backlog.
- It refuses any destination that is not a genuine seeded firstmate home with safe operational directories and a matching `.fm-secondmate-home` marker, so a move can never land in a project.
- It is idempotent; an item already in the secondmate backlog is skipped.

Do not hand off `local-only` items.

## Recovery

For `kind=secondmate` meta with no window, treat the secondmate as a dead persistent direct report and respawn it with:

```sh
bin/fm-spawn.sh <id> --secondmate
```

Use the recorded `home=` in meta.
If meta is missing but `data/secondmates.md` still registers the secondmate, respawn from the registry entry and its persistent on-disk home.
Respawn re-resolves the secondmate harness from current config, uses the same guarded pre-launch sync, and re-propagates inherited local material, so recovered secondmates converge inherited config items and shared captain preferences whenever their home validates; tracked-file sync remains guarded separately.
If the secondmate is already running and only inherited local material changed, prefer `bin/fm-config-push.sh` over respawning.

Do not reconstruct a secondmate's whole tree from the main home.
The main firstmate reconciles only direct reports.
Each secondmate is a firstmate in its own home, so it runs recovery on startup and reconciles its own crewmates.
A secondmate's recovery reconciles only work that is already its own and then idles.
It never initiates a survey or audit during recovery.

## Retirement and teardown

A secondmate is persistent by default.
An empty queue is healthy and does not trigger teardown.
Run `bin/fm-teardown.sh <id>` for `kind=secondmate` only when the captain or main firstmate explicitly decides to retire that persistent second mate.

The safety check is the secondmate's own home.
Teardown refuses while its `state/*.meta` contains in-flight work.
When safe, teardown kills the direct tmux window, removes the `data/secondmates.md` route, clears the main home metadata, and removes the retired secondmate home.
Removing a leased home releases its durable treehouse lease via `treehouse return`, so the pool slot is freed for reuse rather than left leased forever; a plain-clone home with no pool slot is simply removed.
If `treehouse return` fails for a leased home, teardown stops with state intact rather than raw-removing the directory and hiding a held lease.

Before either return or direct removal, teardown asks the target home's process-event runner to retire its registrations and physically owned machine-wide claims through the safe generation-bound path.
It refuses retirement while that cleanup is uncertain or unavailable, preserving the home and retirement records for a later retry.
Raw deletion is unsupported because a blocking process-event child can outlive its home.

With `--force`, teardown is the explicit discard path: it does all of the above, and additionally kills child windows and discards child work and state inside the secondmate home.
Never use `--force` unless the captain explicitly said to discard the work.
