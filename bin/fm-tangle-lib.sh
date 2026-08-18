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
#                        else the script-relative root. A bare repository is
#                        never an operating checkout, so a bare-backed layout -
#                        where every work tree is a linked worktree - resolves
#                        to nothing and stays silent.
#   fm_primary_tangle_branch  classifies THAT one path: a NAMED, non-default
#                        branch is the tangle; the default branch, a detached
#                        HEAD, a bare repository, and a non-git directory are
#                        healthy.
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

# Return 0 only when <dir> is inside a real WORK TREE. `git rev-parse
# --is-inside-work-tree` prints `false` and still exits 0 inside a bare
# repository, so the exit status alone would accept a bare repo as a checkout;
# the printed value is the only reliable answer.
fm_tangle_work_tree() {
  local dir=$1 answer
  answer=$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null) || return 1
  [ "$answer" = true ]
}

# Absolute physical path of <path>, resolved against the caller's working
# directory when it is relative. CDPATH is cleared so a stray CDPATH entry
# cannot redirect the resolution. Echoes the path, or returns 1 when it does
# not resolve to an existing directory.
fm_tangle_abs_dir() {
  local path=$1
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  (CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || return 1
}

# If the git checkout at <root> is tangled - on a NAMED branch that is not its
# default branch - echo the offending branch name and return 0. For every healthy
# state (not a git work tree, a bare repository, detached HEAD, or already on the
# default branch) echo nothing and return 1.
#
# This is a PATH-LOCAL classifier and nothing more: it answers "is this one
# directory on a named non-default branch", with no opinion about whether that
# directory is a main worktree, a linked worktree, a secondmate home, or a
# disposable task worktree. Callers must hand it the operating checkout that
# fm_tangle_checkout resolved, never their own script-relative root, or a
# crewmate on its mandated fm/<id> branch reads as a tangle.
fm_primary_tangle_branch() {
  local root=$1 cur default
  fm_tangle_work_tree "$root" || return 1
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
  (CDPATH='' cd -- "$dir" && CDPATH='' cd -- "$raw" && pwd -P) 2>/dev/null || return 1
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
#
# When the repo is backed by a BARE repository the first record is that bare
# repo (a `bare` line in its porcelain block) and every other record is a linked
# worktree, so the repo has no operating primary checkout at all. Returning 1
# there keeps the caller silent; picking a linked worktree instead would recreate
# the false fire on a crewmate doing exactly what its brief mandates.
fm_tangle_main_worktree() {
  local dir=$1 line path=
  while IFS= read -r line; do
    [ -n "$line" ] || break
    case $line in
      bare) return 1 ;;
      'worktree '*) path=${line#worktree } ;;
    esac
  done < <(git -C "$dir" worktree list --porcelain 2>/dev/null)
  [ -n "$path" ] || return 1
  printf '%s\n' "$path"
}

# Resolve the operating-home checkout the tangle classifier should judge.
#   <script_root>  the already-resolved FM_ROOT (script parent, or the override)
#   <env_home>     FM_HOME as seen on ENTRY, before the script defaults it to
#                  FM_ROOT; empty string when it was unset
#   <overridden>   1 when FM_ROOT_OVERRIDE was non-empty on entry, else 0
# Echoes one path and returns 0, or echoes nothing and returns 1 when no
# checkout can be resolved. A resolution failure must stay silent at the call
# site: missing a genuine tangle is preferable to alarming on correct work.
#
# A relative FM_HOME is absolutized against the caller's working directory
# first, the same CDPATH-immune way fm-spawn.sh and fm-brief.sh resolve
# directory input, so the branch depends on the intended home and never on a
# same-named directory that happens to sit under the caller's cwd. An FM_HOME
# that does not resolve to a work tree falls through to script-relative
# resolution rather than claiming a target.
fm_tangle_checkout() {
  local script_root=$1 env_home=$2 overridden=$3 top home_abs=
  if [ "$overridden" = 1 ]; then
    printf '%s\n' "$script_root"
    return 0
  fi
  if [ -n "$env_home" ]; then
    home_abs=$(fm_tangle_abs_dir "$env_home") || home_abs=
  fi
  if [ -n "$home_abs" ] && fm_tangle_work_tree "$home_abs"; then
    top=$(git -C "$home_abs" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ -n "$top" ] || return 1
    printf '%s\n' "$top"
    return 0
  fi
  fm_tangle_work_tree "$script_root" || return 1
  if fm_tangle_linked_worktree "$script_root"; then
    fm_tangle_main_worktree "$script_root" || return 1
    return 0
  fi
  top=$(git -C "$script_root" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  printf '%s\n' "$top"
}
