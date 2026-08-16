#!/usr/bin/env bash
# fm-teardown-hook-list-check.sh - assert every per-task hook artifact is removed
# by every one of fm-teardown.sh's hook-removal lists.
#
# Usage:
#   bin/fm-teardown-hook-list-check.sh
#   bin/fm-teardown-hook-list-check.sh --root <repo> [--script <path>]
#
# fm-spawn writes a per-task, git-excluded harness hook into the task worktree
# (.claude/settings.local.json for claude, .opencode/plugins/fm-busy-state.js for
# opencode, .fm-grok-turnend and .fm-kimi-turnend for the grok/kimi token
# pointers). Each carries the task's id and busy-state generation, so a copy left
# behind in a pooled worktree can fire events for a dead task, and `treehouse
# return` does not cover for it: it leaves git-excluded untracked files in place.
#
# fm-teardown.sh removes them from four separate places - the top-level default
# and orca paths, and the secondmate-child sweep's default and orca branches - and
# nothing makes those four lists agree. Commit 96542a4 renamed the opencode plugin
# and added the new name to only two of the four, stranding
# .opencode/plugins/fm-busy-state.js on the path every ordinary task takes. This
# check is the cheap standing guard against that drift repeating: equal occurrence
# counts across every artifact name, with the expected count being the number of
# removal lists.
#
# The legacy .opencode/plugins/fm-turn-end.js name is deliberate back-compat for
# worktrees pooled before that rename and is expected on every list too; see the
# comment at fm-teardown.sh's default-path removal.
#
# Because the guard counts PATH-PREFIXED names, prose in fm-teardown.sh must refer
# to these artifacts by bare filename only. A path-prefixed mention in a comment
# would inflate a count and could mask a real omission.
#
# Adding a fifth removal list legitimately fails this check with the counts
# printed. That is the intent, not brittleness: it forces whoever adds the list to
# confirm it is complete and to update EXPECTED_LISTS here.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT=

# The number of hook-removal lists in fm-teardown.sh that every artifact must
# appear in. Deliberately a literal: see the header.
EXPECTED_LISTS=4

need_value() {  # <flag> <remaining-arg-count>
  [ "$2" -gt 1 ] || {
    printf 'fm-teardown-hook-list-check: %s needs a path\n' "$1" >&2
    exit 2
  }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    # Guard the value before shifting, matching bin/fm-skill-trigger-check.sh:
    # with the value missing, the loop's trailing `shift` runs at $# = 0 and
    # `set -eu` would exit before the actionable message above could print.
    --root) need_value --root "$#"; shift; ROOT=$1 ;;
    --script) need_value --script "$#"; shift; SCRIPT=$1 ;;
    -h|--help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0
      ;;
    *) printf 'fm-teardown-hook-list-check: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$ROOT" ] || { printf 'fm-teardown-hook-list-check: --root needs a path\n' >&2; exit 2; }
ROOT=$(cd "$ROOT" 2>/dev/null && pwd) \
  || { printf 'fm-teardown-hook-list-check: root is not a directory\n' >&2; exit 2; }
[ -n "$SCRIPT" ] || SCRIPT="$ROOT/bin/fm-teardown.sh"

fail() {
  printf 'fm-teardown-hook-list-check: %s\n' "$*" >&2
  exit 1
}

[ -f "$SCRIPT" ] || fail "teardown script is missing: $SCRIPT"

# Report the script by its repo-relative path when it is inside the root, so the
# usual run names bin/fm-teardown.sh rather than an absolute path.
script_display=${SCRIPT#"$ROOT/"}

counts=
for name in .claude/settings.local.json .opencode/plugins/fm-turn-end.js \
  .opencode/plugins/fm-busy-state.js .fm-grok-turnend .fm-kimi-turnend; do
  # grep -c prints 0 and exits 1 when nothing matches; keep that a count, not an abort.
  current=$(grep -cF -- "$name" "$SCRIPT" || true)
  [ "$current" -gt 0 ] || fail "hook-removal-lists: $name is never removed by $script_display"
  [ "$current" -eq "$EXPECTED_LISTS" ] || mismatch=1
  counts="$counts$name=$current "
done

if [ -n "${mismatch:-}" ]; then
  fail "hook-removal-lists: every hook artifact must be removed by all four removal lists in $script_display, got: $counts"
fi

printf 'fm-teardown-hook-list-check: ok lists=%s %s\n' "$EXPECTED_LISTS" "$counts"
