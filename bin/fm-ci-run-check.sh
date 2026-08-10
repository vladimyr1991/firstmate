#!/usr/bin/env bash
# Arm a private, one-shot watch on a raw GitHub Actions run, independent of
# any pull or merge request. This generalizes bin/fm-pr-check.sh's safety
# shape (private atomic sidecar, revalidated identity, one-shot retirement)
# for a task with no PR in the loop at all, such as a local-only project that
# lands by pushing directly to a shared branch. See bin/fm-ci-run-lib.sh for
# the full contract and rationale.
# Usage: fm-ci-run-check.sh <task-id> <repo> <run-id> [--forge github]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-ci-run-lib.sh
. "$SCRIPT_DIR/fm-ci-run-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-ci-run-check.sh <task-id> <repo> <run-id> [--forge github]

Registers a private, one-shot watcher poll for a raw GitHub Actions run,
independent of any pull or merge request. Use this for a local-only project
(a task that lands by pushing directly to a shared branch, with no PR ever
opened) or any other task whose CI must be watched to a terminal result with
no PR in the loop.

  <task-id>  an existing task id; state/<task-id>.meta must exist and be live
  <repo>     the GitHub repository as owner/name
  <run-id>   the numeric GitHub Actions run id (as printed by
             `gh-axi run view <run-id>` or `gh-axi run list`)
  --forge    the forge to watch; only "github" is supported and it is also
             the default, so this flag is normally unnecessary

On success this records the run identity in a private sidecar
(state/<task-id>.ci-run-poll) and arms state/<task-id>.check.sh as an
intentional custom check through the same contract as
bin/fm-check-register.sh (a single-link, mode-0700 file whose exact bytes are
hash-bound to state/<task-id>.check-trust). The armed poll is silent while
the run is in progress or on any lookup error, and prints exactly one line
naming the run's terminal conclusion (success, failure, cancelled, or any
other value GitHub reports) the first time it observes one, then retires
itself: the check, its trust binding, and the sidecar are all removed, so the
watch fires exactly once and never lingers to fire again.

Registering a new watch for a task id that already has a leftover, fully
retired poll (an interrupted cleanup after an earlier watch already fired)
finishes that cleanup first, then arms cleanly; it never refuses on stale
state left behind by its own prior retirement.

The per-task check slot (state/<task-id>.check.sh plus its trust binding) is
shared with the PR merge poll armed by bin/fm-pr-check.sh. If a live PR merge
poll currently owns that slot, registration refuses with exit code 3 instead
of silently destroying the merge watch; tear that watch down first if
replacement is intended. bin/fm-pr-check.sh applies the same refusal in the
other direction over a live CI run poll.

GitLab is not supported by this script. bin/fm-pr-check.sh already covers
GitLab merge-request polling, and a raw-pipeline analog for GitLab would be a
separate follow-up if it is ever needed; unlike GitHub Actions runs, a GitLab
pipeline has no single id/CLI shape this script could reuse without inventing
one, so it is left out rather than guessed at.
EOF
}

if [ "$#" -eq 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
  usage
  exit 0
fi

FORGE=github
if [ "$#" -eq 5 ] && [ "$4" = --forge ]; then
  FORGE=$5
  set -- "$1" "$2" "$3"
fi
if [ "$#" -ne 3 ]; then
  echo "error: invalid CI run check request" >&2
  exit 2
fi
ID=$1
REPO=$2
RUN_ID=$3

if [ "$FORGE" != github ]; then
  echo "error: only --forge github is supported" >&2
  exit 2
fi
if ! fm_pr_task_id_valid "$ID" || ! fm_ci_run_repo_valid "$REPO" || ! fm_ci_run_id_valid "$RUN_ID"; then
  echo "error: invalid CI run check request" >&2
  exit 2
fi

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# An earlier ci-run poll for this task id may have fired and been interrupted
# before it finished removing its own artifacts; finish that quietly before
# arming a replacement poll.
fm_ci_run_poll_retirement_recover_one "$STATE" "$ID" || {
  echo "error: pending CI run poll retirement could not be validated" >&2
  exit 1
}

# The check slot is shared with the PR merge poll. A supervision primitive
# whose whole purpose is no-missed-wakes must never silently destroy a sibling
# watch, so a slot owned by a live PR merge poll is refused loudly (exit 3)
# rather than overwritten.
if fm_pr_poll_artifacts_valid "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh"; then
  echo "error: a live PR merge poll already owns state/$ID.check.sh; refusing to replace it" >&2
  exit 3
fi

# Refuse to arm a watch with no gh on PATH. The poll is silent on every error
# by design, so a missing CLI would be indistinguishable from a run that never
# completes. Arming is the one point where that can be reported, so the absent
# tool stops the watch here instead of watching nothing.
if ! command -v gh >/dev/null 2>&1; then
  echo "error: watching a GitHub Actions run requires gh on PATH" >&2
  exit 1
fi

trap fm_ci_run_poll_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_ci_run_poll_prepare "$STATE" "$ID" "$FORGE" "$REPO" "$RUN_ID" || {
  echo "error: could not prepare CI run poll" >&2
  exit 1
}
fm_ci_run_poll_publish_prepared || {
  echo "error: could not publish CI run poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"
