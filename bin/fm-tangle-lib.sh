# shellcheck shell=bash
# Shared worktree-tangle guard for the firstmate-on-itself case.
# Usage: . bin/fm-tangle-lib.sh
#
# Firstmate is a treehouse-pooled git repo of itself: disposable crewmate
# worktrees and leased secondmate homes are all linked `git worktree`s of the
# same repo. The "worktree tangle" failure mode is a crewmate spawned to work on
# firstmate ITSELF branching and committing in the OPERATING checkout - the repo
# root the firstmate session actually runs its home from - instead of its own
# disposable worktree, stranding that checkout on a feature branch
# (e.g. fm/readme-restructure-d3).
#
# Two responsibilities, kept separate:
#
#   fm_tangle_checkout   resolves WHICH checkout is the operating home for this
#                        invocation: an explicit FM_ROOT_OVERRIDE, else the
#                        caller-supplied FM_HOME's work tree (how a secondmate
#                        session keeps watching its own leased home), else the
#                        repo's main worktree when the script itself is running
#                        from a linked worktree (the ordinary crewmate case),
#                        else the script-relative root.
#   fm_primary_tangle_branch  classifies THAT one path: a NAMED, non-default
#                        branch is the tangle; the default branch, a detached
#                        HEAD, and a non-git directory are healthy.
#
# The classifier is deliberately path-local, so a disposable worktree sitting on
# the fm/<id> branch its brief mandates is never itself the subject: resolution,
# not classification, is what keeps that correct work silent. A secondmate home
# on a feature branch is still a real tangle, because that home is the operating
# checkout for its own session.

# Resolve the default branch name of the git repo at <dir>: prefer origin/HEAD,
# then fall back to a local main/master. Echoes the name, or returns 1.
fm_default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# If the git checkout at <root> is tangled - on a NAMED branch that is not its
# default branch - echo the offending branch name and return 0. For every healthy
# state (not a git work tree, detached HEAD, or already on the default branch)
# echo nothing and return 1.
#
# This is a PATH-LOCAL classifier and nothing more: it answers "is this one
# directory on a named non-default branch", with no opinion about whether that
# directory is a main worktree, a linked worktree, a secondmate home, or a
# disposable task worktree. Callers must hand it the operating checkout that
# fm_tangle_checkout resolved, never their own script-relative root, or a
# crewmate on its mandated fm/<id> branch reads as a tangle.
fm_primary_tangle_branch() {
  local root=$1 cur default
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  cur=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$cur" ] || return 1
  default=$(fm_default_branch "$root") || return 1
  [ "$cur" = "$default" ] && return 1
  printf '%s\n' "$cur"
  return 0
}

# Absolute physical path of the git dir <kind> (--git-dir or --git-common-dir)
# for the work tree at <dir>. Git may report either as a path relative to <dir>,
# so resolve it against <dir> before comparing the two. Echoes the path, or
# returns 1 when git cannot answer.
fm_tangle_git_dir() {
  local dir=$1 kind=$2 raw
  raw=$(git -C "$dir" rev-parse "$kind" 2>/dev/null) || return 1
  [ -n "$raw" ] || return 1
  (cd "$dir" && cd "$raw" && pwd -P) 2>/dev/null || return 1
}

# Return 0 when the work tree at <dir> is a LINKED worktree rather than the
# repo's main worktree. The git-facing rule is that a linked worktree's git dir
# is a per-worktree subdirectory of the common git dir, so the two differ; in
# the main worktree they are the same directory. ("`.git` is a file" only
# happens to correlate.)
fm_tangle_linked_worktree() {
  local dir=$1 gitdir commondir
  gitdir=$(fm_tangle_git_dir "$dir" --git-dir) || return 1
  commondir=$(fm_tangle_git_dir "$dir" --git-common-dir) || return 1
  [ "$gitdir" != "$commondir" ]
}

# Echo the main worktree path of the repo containing <dir>. Git documents that
# `git worktree list --porcelain` lists the main worktree first. Returns 1 when
# git cannot answer, which callers treat as "no target" rather than as a tangle.
fm_tangle_main_worktree() {
  local dir=$1 line
  line=$(git -C "$dir" worktree list --porcelain 2>/dev/null | grep -m1 '^worktree ') || return 1
  [ -n "$line" ] || return 1
  printf '%s\n' "${line#worktree }"
}

# Resolve the operating-home checkout the tangle classifier should judge.
#   <script_root>  the already-resolved FM_ROOT (script parent, or the override)
#   <env_home>     FM_HOME as seen on ENTRY, before the script defaults it to
#                  FM_ROOT; empty string when it was unset
#   <overridden>   1 when FM_ROOT_OVERRIDE was non-empty on entry, else 0
# Echoes one path and returns 0, or echoes nothing and returns 1 when no
# checkout can be resolved. A resolution failure must stay silent at the call
# site: missing a genuine tangle is preferable to alarming on correct work.
fm_tangle_checkout() {
  local script_root=$1 env_home=$2 overridden=$3 top
  if [ "$overridden" = 1 ]; then
    printf '%s\n' "$script_root"
    return 0
  fi
  if [ -n "$env_home" ] && git -C "$env_home" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    top=$(git -C "$env_home" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ -n "$top" ] || return 1
    printf '%s\n' "$top"
    return 0
  fi
  git -C "$script_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  if fm_tangle_linked_worktree "$script_root"; then
    fm_tangle_main_worktree "$script_root" || return 1
    return 0
  fi
  top=$(git -C "$script_root" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  printf '%s\n' "$top"
}
