#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR instead
# of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only> [--staging-autonomy] [--sync-base <branch>] [--herdr-lab]
#        fm-brief.sh <task-id> <repo-name> --scout [--sync-base <branch>] [--herdr-lab]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and the
#   caller-supplied repo string cannot reliably identify this repo. Briefs made
#   without it carry a loud declaration so an omitted contract cannot be silent.
# For ship tasks, --mode is REQUIRED and shapes the definition of done. Firstmate
# resolves it per task at intake (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never reads it:
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> configured merge authority
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> configured merge authority
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                the configured merge authority approves, firstmate merges to local main
# no-mistakes-prod-only is a registry policy, not a task mode; resolve it to one of
# the three concrete modes at intake before calling this script.
# --staging-autonomy applies only to --mode local-only. It selects the standing
# staging-inclusive landing autonomy a project's registered posture can grant
# (data/captain.md, "Delivery autonomy"): instead of stopping at a ready branch,
# the worker branches from origin/develop, lands fm/<id> -> develop -> staging
# itself, pushes both, watches CI to a final result, fast-forwards its own local
# develop, and closes with the keyed "done [key=staging]: staging=<sha> ci=<run-id>
# result=green" line; a UI-touching task stops first at the browser-evaluation gate
# with "blocked [key=evaluation]: ...", which only firstmate can clear. Firstmate
# resolves this flag from the project's standing posture at intake, so the captain's
# contract is generated rather than hand-patched over contradicting boilerplate.
# It is not a yolo passthrough: the worker still owns no approval decision beyond
# the landing the captain's standing posture already granted, and releasing main
# still needs the captain's explicit word each time.
# The generated ship brief records the chosen mode as a fixed machine-readable
# "Delivery contract: mode=<mode>" line. bin/fm-spawn.sh reads that line and refuses
# to launch a ship task whose explicit --mode disagrees, so an adjusted brief and the
# recorded task metadata cannot drift apart.
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# --sync-base <branch> adds a mandatory base-sync step as the brief's first numbered
# Setup step, for projects whose task worktrees come from a shared pool. A pooled
# worktree does not refresh its local branches between tasks, so its local <branch>
# can sit many commits behind origin/<branch> and a branch cut from it silently
# targets code that is no longer live. Pass it per task for any such project
# (parlino: --sync-base develop); it is opt-in because the caller-supplied repo
# string cannot identify the project's checkout pattern, and it is deliberately not
# the generic default so ordinary single-checkout projects keep the shorter Setup.
# It applies to scout briefs too, where the same stale base produces a wrong
# diagnosis rather than a wrong branch: a scout on a stale base reports a fix as
# missing when it is already live on origin/<branch>. The scout step differs only in
# the remedy (move the worktree onto the remote base rather than cut a branch from
# it); a secondmate charter still refuses the flag. The step's divergence stop is
# measured from `git merge-base HEAD origin/<branch>` and excludes only commits
# already reachable from `origin/<branch>` or the remote's default branch, which the
# emitted check resolves with this repo's usual `refs/remotes/origin/HEAD` then main
# then master fallback (fm_default_branch in bin/fm-tangle-lib.sh owns that shape) so
# a pool fetched without an `origin/HEAD` still runs the check instead of blocking.
# A default branch that carries a commit the sync base never took - a hotfix landed
# without a back-merge, an ordinary git-flow shape - therefore reads as a lineage
# variant rather than a divergence. Work on the pooled base that is on neither ref,
# an unresolvable merge base, and a check that errors all stop the task. A lineage
# variant is never branched from: whether it is behind `origin/<branch>` or already
# contains it, the step routes it to the same remedy, and the branch step's
# alternative is conditioned on that routing rather than on the drift check.
# --mode is refused on scout and secondmate scaffolds: a scout's deliverable is a
# report rather than a merge, and a charter is not a delivery contract.
# There is no --yolo flag here. The worker never owns approval decisions, so yolo is
# a spawn-time and firstmate-side input only (AGENTS.md section 7).
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path;
# it carries the AGENTS.md authoring bar (widely useful knowledge only, pointers
# over copied detail) and has the crewmate add the fm-ensure-agents-md.sh
# self-governance section when a touched project AGENTS.md lacks it.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
else
  DATA="$FM_HOME/data"
fi
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  STATE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
else
  STATE="$FM_HOME/state"
fi
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
STAGING_AUTONOMY=0
MODE=
MODE_SET=0
SYNC_BASE=
SYNC_BASE_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      sync-base) SYNC_BASE=$a; SYNC_BASE_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    --staging-autonomy) STAGING_AUTONOMY=1 ;;
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --sync-base) want_value=sync-base ;;
    --sync-base=*) SYNC_BASE=${a#--sync-base=}; SYNC_BASE_SET=1 ;;
    # yolo never reaches the worker: it is firstmate's approval authority, not a
    # brief input. Refuse it loudly so it is never silently dropped here and then
    # believed to have been recorded.
    --yolo|--yolo=*) echo "error: --yolo is not a brief input; pass it to bin/fm-spawn.sh, which records the task's approval posture" >&2; exit 1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }

# Ship delivery mode is an explicit per-task decision (AGENTS.md section 7). A
# missing or invalid value stops the scaffold rather than silently defaulting.
if [ "$KIND" = ship ]; then
  [ "$MODE_SET" -eq 1 ] || {
    echo "error: ship briefs require --mode <no-mistakes|direct-PR|local-only>; resolve it at intake from the captain's instruction and the project's registered posture in data/projects.md" >&2
    exit 1
  }
  case "$MODE" in
    no-mistakes|direct-PR|local-only) ;;
    no-mistakes-prod-only)
      echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake" >&2
      exit 1 ;;
    *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
  esac
elif [ "$MODE_SET" -eq 1 ]; then
  echo "error: --mode applies only to ship briefs; a scout delivers a report and a secondmate charter is not a delivery contract" >&2
  exit 1
fi

# The base-sync step guards the base a crewmate works from, so it applies to ship
# and scout briefs alike; a secondmate charter names no base to sync. An empty
# value is refused rather than silently dropped: a brief that looks synced but
# carries no sync step is exactly the failure this flag exists to prevent.
if [ "$SYNC_BASE_SET" -eq 1 ]; then
  case "$KIND" in
    ship|scout) ;;
    *) echo "error: --sync-base applies only to ship and scout briefs; a secondmate charter is not tied to one task's base" >&2
       exit 1 ;;
  esac
  [ -n "$SYNC_BASE" ] || { echo "error: --sync-base requires a branch name (e.g. --sync-base develop)" >&2; exit 1; }
fi

# Staging-inclusive landing autonomy is a shape of local-only delivery, never a
# mode of its own: it still opens no PR and runs no pipeline. Refuse it anywhere
# else rather than accepting and discarding it, which would read as recorded.
if [ "$STAGING_AUTONOMY" -eq 1 ]; then
  if [ "$KIND" != ship ]; then
    echo "error: --staging-autonomy applies only to ship briefs; a scout delivers a report and a secondmate charter is not a delivery contract" >&2
    exit 1
  fi
  if [ "$MODE" != local-only ]; then
    echo "error: --staging-autonomy applies only to --mode local-only; a PR-based mode already has its own landing authority (got mode '$MODE')" >&2
    exit 1
  fi
fi
ID=${POS[0]}

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")

# The pooled-base sync step has exactly one owner, used by both the ship and the
# scout path. They differ only in what a stale base calls for - a branch cut from
# the remote versus a worktree moved onto it - and in what skipping the check
# costs. The parts that would silently drift if copied (the fetch, the drift
# check, the divergence stop, and the mandatory framing) stay stated once here.
# Args: <step-number> <action-clause> <current-remedy> <stale-remedy> <consequence>
sync_base_step() {
  local step=$1 action=$2 current=$3 stale=$4 consequence=$5 text
  IFS= read -r -d '' text <<EOF || true
$step. **First action: sync the base branch, $action.** This worktree comes from a shared pool that does not refresh its local branches between tasks, so its local \`$SYNC_BASE\` can sit many commits behind \`origin/$SYNC_BASE\`.
   Run \`git fetch origin && git log --oneline HEAD..origin/$SYNC_BASE\`.
   If it prints nothing, confirm the base is not a lineage variant with \`git log --oneline origin/$SYNC_BASE..HEAD\`: if that prints nothing too, the base is current: $current
   If that second command prints commits, this base already contains \`origin/$SYNC_BASE\` and carries extra commits of its own, so taking it as-is would work from code the sync base does not have: take the stale remedy below instead of treating the base as current.
   If the first command prints any commits, the base is stale: $stale
   Before acting on any of those, resolve the merge base with \`git merge-base HEAD origin/$SYNC_BASE\`. If that command fails or prints nothing, HEAD shares no history with the remote base, which is a diverged base: append \`blocked: pooled base diverged from origin/$SYNC_BASE\` to the status file and stop.
   Otherwise rule out a genuinely divergent base with \`git log --oneline "\$(git merge-base HEAD origin/$SYNC_BASE)..HEAD" --not origin/$SYNC_BASE \$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD || git rev-parse --verify --quiet origin/main || git rev-parse --verify --quiet origin/master)\`, which measures divergence from the merge base rather than counting every commit HEAD holds that \`origin/$SYNC_BASE\` does not, and spares only the sync base and the remote's default branch rather than every branch on the remote.
   That trailing substitution is the default-branch fallback: a pool fetched without an \`origin/HEAD\` resolves main, then master, and excludes nothing extra if none of them exist, so a missing \`origin/HEAD\` narrows the check rather than stopping the task.
   If it prints nothing, this base is compatible: a default branch carrying a commit the sync base never took, such as a hotfix landed without a back-merge, is an ordinary lineage variant, and the remedy above is safe even though HEAD is not a direct ancestor of \`origin/$SYNC_BASE\`.
   If it prints any commits, this base carries work that is on neither \`origin/$SYNC_BASE\` nor the remote's default branch - a previous task's leftover tip, or local work that was never pushed - and has diverged rather than merely fallen behind: append \`blocked: pooled base diverged from origin/$SYNC_BASE\` to the status file and stop.
   If that command itself errors, take the same stop rather than reading its empty output as compatible.
   This check is mandatory, not a judgement call: $consequence
EOF
  printf '%s' "${text%$'\n'}"
}

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a persistent second mate managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe \`corr=<id>\` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
Optional helper: \`bin/fm-secondmate-report.sh\` can append a correlated status line for you, but a plain \`echo\` that includes the same \`corr=<id>\` is equally valid - do not depend on the helper being present.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
Before treating an investigation or visual review as complete, load \`decision-hold-lifecycle\` from this home's \`.agents/skills/\` and pass its shared completion gate.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
A marked request requires one correlated answer after the work; it does not require a separate receipt or start acknowledgement.
Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started.
When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above, give that reported phase a stable key.
If its first reportable event is \`working [key=<work-slug>]: {material phase}\`, use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append \`resolved [key=<work-slug>]: {why it is no longer active}\`.
When a decision you escalated is answered or a blocker clears and your domain resumes, append \`resolved: {how it was decided or unblocked}\` (keyed with \`[key=<slug>]\` if you opened it with one) so it is durably closed instead of resurfacing behind later unrelated events.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install `trap '\''"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"'\'' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
IFS= read -r -d '' HERDR_SECTION <<'EOF' || true
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
HERDR_SECTION=${HERDR_SECTION%$'\n'}
fi

if [ "$KIND" = scout ]; then
# A scout cuts no branch, so its sync step guards the base it investigates on
# instead: a diagnosis drawn on a stale pooled base reports a fix as missing when
# it is already live. Without the flag the Setup keeps its original prose exactly.
SCOUT_SYNC=""
if [ -n "$SYNC_BASE" ]; then
  SCOUT_SYNC="
$(sync_base_step 1 \
    "before investigating anything" \
    "investigate on it as-is." \
    "move this worktree onto the remote base instead, with \`git checkout --detach origin/$SYNC_BASE\`, and re-read every file this task names on that fresh base before drawing any conclusion - the code the task describes can look different there, or live somewhere else entirely." \
    "a scout that skipped it has already diagnosed code that is no longer live.")
"
fi
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.
$SCOUT_SYNC
# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (waiting for a pipeline gate to return, a CI
   run to finish, an upstream release, a rate-limit reset): firstmate then leaves your idle pane
   alone and rechecks it on a long cadence instead of treating it as a possible wedge.
   Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.
8. Report status and findings to firstmate only. Never address "the captain" or "you" (the human)
   anywhere in your output or your report; firstmate is the sole channel to the captain.
9. A test or probe that writes into a real outward-facing surface must delete what it wrote: capture
   the evidence first, then delete, then re-probe to confirm it is gone. A consumed id is fine;
   visible text left behind is not. That cleanup belongs in the test's own teardown, including the
   failure path, never in your memory. Prefer a non-writing probe when the surface offers one.

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
Before reporting done, read and follow \`$FM_ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any visual review.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

# Ship task: shape Setup / Rule 1 / Definition of done by this task's explicit
# delivery mode, validated above. The generated DOD opens with the fixed
# "Delivery contract: mode=<mode>" line that bin/fm-spawn.sh checks against its own
# explicit --mode before launching.
BRANCH_CMD="git checkout -b fm/$ID"
case "$MODE" in
  direct-PR)
    SETUP_DOCTOR=""
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
    ;;
  local-only)
    SETUP_DOCTOR=""
    if [ "$STAGING_AUTONOMY" -eq 1 ]; then
    # Staging-inclusive landing autonomy: the captain's standing posture for this
    # project already granted the landing, so the generated contract states it
    # rather than contradicting the task section with a "stop and wait" default.
    BRANCH_CMD="git fetch origin && git checkout -b fm/$ID origin/develop"
    RULE1="1. Never push to \`main\`, never tag, and never release. You land your own work only along this project's git-flow: \`fm/$ID\` -> \`develop\` -> \`staging\`."
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
Delivery contract: mode=local-only
Delivery autonomy: staging-inclusive
This task ships **local-only with standing staging autonomy**: no PR and no pipeline, but you land your own work along this project's git-flow without waiting for a go-ahead.
Run the project's own test gate first and land only genuinely clean work; never land red or failing work.
If this task touched the UI, stop before merging anything and append \`blocked [key=evaluation]: test gate green, UI touched, awaiting browser evaluation before merge\`, then wait.
Only firstmate can spawn the independent browser evaluator, so that key stays open until firstmate answers \`resolved [key=evaluation]:\` and releases you to land.
To land: merge \`fm/$ID\` -> \`develop\` -> \`staging\`, push both branches, and watch CI to a final result.
Then fast-forward this worktree's own local \`develop\` to what you pushed, so the next task branching here does not start from a stale base.
If CI ends red you are not done: fix it forward along the same git-flow, or append \`blocked: {the failing run}\` and stop.
Close with the keyed line, never free prose:
   \`done [key=staging]: staging=<sha> ci=<run-id> result=green\`
Tagging or releasing \`main\` is never yours: it needs the captain's current explicit word every time, obtained through firstmate (rule 6).
EOF
    else
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`."
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$ID\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$ID\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
    fi
    ;;
  *)  # no-mistakes
    SETUP_DOCTOR="Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    RULE1='1. Never push to the default branch. Never merge a PR.'
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
Delivery contract: mode=no-mistakes
**\`done:\` on a no-mistakes ship task means a real PR exists with checks green (or the CI-cannot-run exception below) - a local commit plus local lint/test checks is NOT done, even if every local check passes.**
CI-cannot-run exception: when the forge reports that no CI checks are configured for this PR, say so explicitly and name the local gate you re-ran green against the pushed head, as \`done: PR {url} - no CI checks configured; {gate} re-run green on the pushed head\`. Never report absent checks as green checks.
You report twice on this task, and only the second report is completion.
The first is a HANDOFF, not a finish: when the work is implemented and committed on your branch, append \`done: implemented and committed; ready for /no-mistakes\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies the authority contract in its \`AGENTS.md\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: it would silently bypass firstmate's authority check and any required captain escalation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
    ;;
esac

# read -r -d '' preserves the heredoc's trailing newline that the removed
# $(...) command substitution used to strip. Drop that one newline so generated
# briefs stay byte-identical to the historical Bash 5 output.
DOD=${DOD%$'\n'}

# Numbered Setup steps. The base-sync step (--sync-base) comes first because a
# branch cut from a stale local base is already wrong - the task then edits code
# that no longer matches what is live, which no later check catches. Without the
# flag the step list is the original branch (+ doctor) pair, byte for byte.
SETUP_STEPS=""
SETUP_STEP_N=1
if [ -n "$SYNC_BASE" ]; then
  SETUP_SYNC=$(sync_base_step "$SETUP_STEP_N" \
    "before creating any branch" \
    "branch normally below." \
    "cut your branch from the remote instead, with \`git checkout -b fm/$ID origin/$SYNC_BASE\`, and re-read every file this task names on that fresh base before editing - the code the task describes can look different there, or live somewhere else entirely." \
    "a task that skipped it has already shipped a fix to the wrong code.")
  SETUP_STEPS="$SETUP_SYNC
"
  SETUP_STEP_N=$((SETUP_STEP_N + 1))
  BRANCH_STEP="Create your branch: \`$BRANCH_CMD\` - or \`git checkout -b fm/$ID origin/$SYNC_BASE\` when step 1 sent you to the remote base, whether the base was stale or a lineage variant."
else
  BRANCH_STEP="First action: create your branch: \`$BRANCH_CMD\`"
fi
SETUP_STEPS="$SETUP_STEPS$SETUP_STEP_N. $BRANCH_STEP"
if [ -n "$SETUP_DOCTOR" ]; then
  SETUP_STEPS="$SETUP_STEPS
$((SETUP_STEP_N + 1)). $SETUP_DOCTOR"
fi

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

$SETUP_STEPS

**Establish a test baseline before your first edit.** Run the project's own test gate the way its \`AGENTS.md\` or \`README.md\` documents it, before you change anything.
A green baseline is what makes a later failure attributable to your work; without one you cannot tell your own breakage apart from breakage you inherited.
If the baseline is already red, treat that as inherited breakage: append \`blocked: {the failing gate and what it printed}\` and stop, rather than folding the repair into this task or building on top of it.
If the gate runs long enough that you would otherwise sit silent, append one \`working:\` line first so supervision does not read the wait as a wedged pane.

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined \`done:\` gate under Definition of done.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (waiting for a pipeline gate to return, a CI
   run to finish, an upstream release, a rate-limit reset, a scheduled window): firstmate then leaves
   your idle pane alone and rechecks it on a long cadence instead of treating it as a possible wedge.
   Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs above the implementation worker (product choices, destructive actions, ask-user findings),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will apply the configured authority and reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.
8. Implement what the task asks for, completely. Leave behind no placeholder or unimplemented code:
   no handler that accepts input and does nothing, no control wired to nothing, no branch returning a
   fixed value that stands in for real work, no "wire this up later" comment. Code that compiles and
   renders is not evidence that it works - an element a user can click and get nothing from is not done.
   If the task turns out larger than it looked and you cannot finish it honestly, append
   \`needs-decision: {what is missing and what you propose}\` and stop; never quietly ship a reduced version.
9. Report status and findings to firstmate only. Never address "the captain" or "you" (the human)
   anywhere in your output; firstmate is the sole channel to the captain.
10. A test that writes into a real outward-facing surface must delete what it wrote: capture the
    evidence first, then delete, then re-probe to confirm it is gone. A consumed id is fine; visible
    text left behind is not. That cleanup belongs in the test's own teardown, including the failure
    path, never in your memory. Prefer a non-writing probe when the surface offers one.

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\` that lacks \`## Maintaining this file\`, add that short self-governance section from \`$FM_ROOT/bin/fm-ensure-agents-md.sh\` in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

$DOD
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
