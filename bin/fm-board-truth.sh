#!/usr/bin/env bash
# Establish, from sources that are always available, what is TRUE about the
# work behind a Notion board card - so the board can be reconciled against
# reality on every PM cycle instead of waiting for a status event that dies
# with the task that would have sent it.
#
# The board is written only from inside an agent turn (see
# .agents/skills/notion-board/SKILL.md "Access and budget"), so this script never
# touches Notion. It answers the three questions the 2026-09-09 truth pass
# (data/pm-board-truth-pass/report.md, section 2) answered by hand for twenty
# cards, mechanically and for any number of cards:
#
#   1. Is the card's branch an ancestor of the staging and develop refs?
#   2. Does the artifact the card names exist in the staging tree?
#   3. Is the staging deployment alive (latest deploy run succeeded)?
#
# and folds them into one `truth=` verdict per card. The notion-board skill's
# status table is the only owner of what Status each verdict maps to; this
# script states facts, never a board Status.
#
# Usage:
#   fm-board-truth.sh --repo <git-dir> [options] (--card <url> [--branch <b>] [--artifact <re>])...
#   fm-board-truth.sh --repo <git-dir> [options] --all-index
#   fm-board-truth.sh --repo <git-dir> [options] --branch <b>        (a branch with no card)
#
# Subjects:
#   --card <url>        a card. Its branch is resolved from the durable index
#                       written by bin/fm-notion-link.sh (data/notion-cards.tsv)
#                       unless --branch follows. The index survives every task
#                       teardown, forced or not, which is what makes a card whose
#                       task is long gone still resolvable here.
#   --branch <name>     the branch to test for the most recent --card, or a
#                       standalone subject when no --card precedes it.
#   --artifact <re>     an extended regex `git grep -E` must match somewhere in
#                       the staging tree for the card's named artifact to count
#                       as present. Attaches to the most recent subject. The
#                       files that matched are always shown next to the verdict
#                       (artifact_matches=, artifact_files=): a pattern only
#                       proves that SOME file holds the text, never that the
#                       file is the card's subject, and the one time a pattern
#                       was accepted on its verdict alone (2026-09-09,
#                       `mcp_server|booking_mcp`) its single match was
#                       .mcp.json, the harness's own MCP config, and a card
#                       whose work had never started came out landed. Read the
#                       listing before acting on an artifact-based landing.
#   --all-index         every card the index currently holds a live link for;
#                       an index with no live card prints nothing and exits 0.
#
# Options:
#   --repo <dir>        a git repository or worktree holding the project (required)
#   --remote <name>     remote whose refs are consulted (default origin)
#   --staging <branch>  the stand branch (default staging)
#   --develop <branch>  the integration branch (default develop)
#   --no-fetch          skip `git fetch --prune <remote>` before reading refs
#   --deploy-workflow <file>  workflow whose latest run on the staging branch
#                       proves the stand is alive (default deploy.yml)
#   --deploy none       do not consult the forge; deploy= is reported unknown
#   --index <path>      the card index (default <FM_HOME>/data/notion-cards.tsv)
#   --artifact-files <n>  how many matched paths artifact_files= lists before
#                       folding the rest into `+K more` (default 5, minimum 1).
#                       The count in artifact_matches= is always exact.
#
# Output: one line per subject, tab-separated key=value fields, in subject order:
#   card=<url|->  task=<id|->  branch=<name|->  branch_exists=yes|no|-
#   in_staging=yes|no|-  in_develop=yes|no|-  artifact_in_staging=yes|no|-
#   artifact_matches=<count|->  artifact_files=<paths|->
#   deploy=alive|dead|unknown  basis=branch|artifact|-  truth=<verdict>
# where artifact_matches is the exact number of staging-tree files the pattern
# matched (0 when it missed, - when no pattern was given or staging could not be
# read), artifact_files lists the first --artifact-files of them separated by
# commas with `+K more` folded at the end when there are more (- when none),
# basis names what a landed verdict rests on - `branch` when the branch itself is
# an ancestor of staging, `artifact` when only the pattern matched, so the reader
# knows the verdict is exactly as good as the listed files - and truth is one of:
#   landed-on-stand      the branch (or the named artifact) is in staging and the
#                        staging deployment is alive - the work is physically on
#                        the stand
#   landed-not-deployed  in staging, but the latest deploy run failed or could
#                        not be read - do not call it on the stand
#   in-flight            the branch exists and is known not to be in staging
#   not-started          no branch anywhere on the remote and, when an artifact
#                        pattern was given, no match in the staging tree
#   unresolved           no branch could be resolved for the card, or the branch
#                        is absent and no artifact pattern was given to fall back
#                        on (a squash-merged branch is deleted after landing, so
#                        absence alone never proves not-started), or the branch
#                        exists but the staging ref itself could not be read, so
#                        in_staging is `-` and in-flight cannot be claimed
# Facts that cannot be established are reported as `-`, never guessed.
#
# Exit 0 when every subject produced a line, 2 on usage error, 1 when the repo
# or fetch could not be read. A subject that resolves to `unresolved` is still
# exit 0: it is an answer, and the PM decides what to do with it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-notion-index-lib.sh
. "$SCRIPT_DIR/fm-notion-index-lib.sh"

usage() { sed -n '2,/^set -u/{/^set -u/d;s/^# \{0,1\}//p;}' "$0" >&2; }
die() { echo "fm-board-truth: $1" >&2; exit "${2:-1}"; }

REPO=
REMOTE=origin
STAGING=staging
DEVELOP=develop
FETCH=1
DEPLOY_WORKFLOW=deploy.yml
INDEX=
ALL_INDEX=0
ARTIFACT_FILES_MAX=5
# Parallel arrays: one subject per slot.
S_CARD=()
S_BRANCH=()
S_ARTIFACT=()
n=0

new_subject() {  # <card>
  S_CARD[n]=$1
  S_BRANCH[n]=
  S_ARTIFACT[n]=
  n=$((n + 1))
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || die "--repo needs a path" 2; REPO=$2; shift 2 ;;
    --remote) [ $# -ge 2 ] || die "--remote needs a name" 2; REMOTE=$2; shift 2 ;;
    --staging) [ $# -ge 2 ] || die "--staging needs a branch" 2; STAGING=$2; shift 2 ;;
    --develop) [ $# -ge 2 ] || die "--develop needs a branch" 2; DEVELOP=$2; shift 2 ;;
    --no-fetch) FETCH=0; shift ;;
    --deploy-workflow) [ $# -ge 2 ] || die "--deploy-workflow needs a file" 2; DEPLOY_WORKFLOW=$2; shift 2 ;;
    --deploy) [ $# -ge 2 ] || die "--deploy needs none" 2; [ "$2" = none ] || die "--deploy accepts only none" 2; DEPLOY_WORKFLOW=; shift 2 ;;
    --index) [ $# -ge 2 ] || die "--index needs a path" 2; INDEX=$2; shift 2 ;;
    --artifact-files)
      [ $# -ge 2 ] || die "--artifact-files needs a count" 2
      case "$2" in ''|*[!0-9]*|0) die "--artifact-files needs a positive integer: $2" 2 ;; esac
      ARTIFACT_FILES_MAX=$2; shift 2 ;;
    --all-index) ALL_INDEX=1; shift ;;
    --card)
      [ $# -ge 2 ] || die "--card needs a url" 2
      fm_notion_index_url_safe "$2" || die "unsafe card url: $2" 2
      new_subject "$2"; shift 2 ;;
    --branch)
      [ $# -ge 2 ] || die "--branch needs a name" 2
      case "$2" in ''|*[[:space:]]*|-*) die "unsafe branch name: $2" 2 ;; esac
      git check-ref-format --branch "$2" >/dev/null 2>&1 || die "unsafe branch name: $2" 2
      [ "$n" -gt 0 ] && [ -z "${S_BRANCH[n-1]}" ] || new_subject -
      S_BRANCH[n-1]=$2; shift 2 ;;
    --artifact)
      [ $# -ge 2 ] || die "--artifact needs a pattern" 2
      [ "$n" -gt 0 ] || die "--artifact must follow a --card or --branch" 2
      S_ARTIFACT[n-1]=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

[ -n "$REPO" ] || { usage; die "--repo is required" 2; }
[ -n "$INDEX" ] || INDEX="$DATA/$FM_NOTION_INDEX_NAME"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $REPO"

if [ "$ALL_INDEX" = 1 ]; then
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    new_subject "$url"
  done < <(fm_notion_index_live_cards "$INDEX")
fi
if [ "$n" -eq 0 ]; then
  [ "$ALL_INDEX" = 1 ] && exit 0
  usage; die "no subject given (--card, --branch, or --all-index)" 2
fi

if [ "$FETCH" = 1 ]; then
  git -C "$REPO" fetch --prune --quiet "$REMOTE" 2>/dev/null \
    || die "git fetch $REMOTE failed in $REPO; pass --no-fetch to read the refs as they are"
fi

ref_exists() { git -C "$REPO" rev-parse --verify --quiet "refs/remotes/$REMOTE/$1^{commit}" >/dev/null 2>&1; }
is_ancestor() {  # <branch> <base-branch> -> yes|no|-
  ref_exists "$2" || { printf -- '-'; return; }
  if git -C "$REPO" merge-base --is-ancestor "refs/remotes/$REMOTE/$1" "refs/remotes/$REMOTE/$2" 2>/dev/null; then
    printf 'yes'
  else
    printf 'no'
  fi
}
# The files a pattern matched in the base branch's tree, one path per line, in
# tree order; empty when nothing matched. `-` on stdout means the ref itself
# could not be read. git grep prefixes every path with "<ref>:", which is
# stripped exactly, so a path holding a colon survives.
artifact_files_in() {  # <pattern> <base-branch>
  local ref line
  ref="refs/remotes/$REMOTE/$2"
  ref_exists "$2" || { printf -- '-\n'; return; }
  git -C "$REPO" grep -l -E -e "$1" "$ref" -- 2>/dev/null | while IFS= read -r line; do
    printf '%s\n' "${line#"$ref:"}"
  done
}
# Fold a path list into the artifact_files= cell: the first ARTIFACT_FILES_MAX
# paths comma-separated, then `+K more` when the list is longer.
artifact_files_cell() {  # <count> <files...>
  local count=$1 shown=0 cell=
  shift
  [ "$count" -gt 0 ] || { printf -- '-'; return; }
  for f in "$@"; do
    [ "$shown" -lt "$ARTIFACT_FILES_MAX" ] || break
    cell="${cell:+$cell,}$f"
    shown=$((shown + 1))
  done
  [ "$shown" -ge "$count" ] || cell="$cell,+$((count - shown)) more"
  printf '%s' "$cell"
}

# Deploy liveness: the latest run of the deploy workflow on the staging branch.
# Read once per invocation; every subject shares the answer.
deploy_state() {
  local out row status conclusion
  [ -n "$DEPLOY_WORKFLOW" ] || { printf 'unknown'; return; }
  command -v gh-axi >/dev/null 2>&1 || { printf 'unknown'; return; }
  out=$( (cd "$REPO" && gh-axi run list --workflow "$DEPLOY_WORKFLOW" --branch "$STAGING" \
           --limit 1) 2>/dev/null) || { printf 'unknown'; return; }
  # Default row shape after the "runs[N]{id,title,status,conclusion,...}:" header:
  #   <id>,"<title>",<status>,<conclusion>,<workflow>,<branch>,<event>,<created>
  # The title is double-quoted and may itself hold commas (a literal quote inside
  # it is doubled), or it may be bare when it needs no quoting. Strip the id and
  # the title with one quote-aware substitution; status and conclusion follow.
  row=$(printf '%s\n' "$out" | sed -n '/^runs\[[0-9]/,$p' | sed -n '2p')
  row=$(printf '%s' "$row" | sed -E 's/^[[:space:]]*[^,]*,("([^"]|"")*"|[^,]*),//')
  [ -n "$row" ] || { printf 'unknown'; return; }
  status=$(printf '%s' "$row" | cut -d, -f1)
  conclusion=$(printf '%s' "$row" | cut -d, -f2)
  if [ "$status" = completed ] && [ "$conclusion" = success ]; then
    printf 'alive'
  elif [ "$status" = completed ]; then
    printf 'dead'
  else
    printf 'unknown'
  fi
}
DEPLOY=$(deploy_state)

i=0
while [ "$i" -lt "$n" ]; do
  card=${S_CARD[i]}
  branch=${S_BRANCH[i]}
  artifact=${S_ARTIFACT[i]}
  task=-
  if [ "$card" != - ]; then
    hit=$(fm_notion_index_lookup "$INDEX" "$card")
    if [ -n "$hit" ]; then
      task=${hit%%$'\t'*}
      [ -n "$branch" ] || branch=${hit#*$'\t'}
    fi
  fi
  [ -n "$branch" ] || branch=-

  exists=- staging=- develop=- art=- art_count=- art_files=- basis=-
  if [ "$branch" != - ]; then
    if ref_exists "$branch"; then
      exists=yes
      staging=$(is_ancestor "$branch" "$STAGING")
      develop=$(is_ancestor "$branch" "$DEVELOP")
    else
      exists=no
    fi
  fi
  if [ -n "$artifact" ]; then
    matched=()
    while IFS= read -r line; do
      [ -n "$line" ] && matched+=("$line")
    done < <(artifact_files_in "$artifact" "$STAGING")
    if [ "${#matched[@]}" -eq 1 ] && [ "${matched[0]}" = - ]; then
      art=-
    else
      art_count=${#matched[@]}
      if [ "$art_count" -gt 0 ]; then art=yes; else art=no; fi
      art_files=$(artifact_files_cell "$art_count" "${matched[@]+"${matched[@]}"}")
    fi
  fi

  if [ "$staging" = yes ] || [ "$art" = yes ]; then
    if [ "$staging" = yes ]; then basis=branch; else basis=artifact; fi
    if [ "$DEPLOY" = alive ]; then truth=landed-on-stand; else truth=landed-not-deployed; fi
  elif [ "$exists" = yes ] && [ "$staging" = no ]; then
    truth=in-flight
  elif [ "$exists" = no ] && [ "$art" = no ]; then
    truth=not-started
  else
    truth=unresolved
  fi

  printf 'card=%s\ttask=%s\tbranch=%s\tbranch_exists=%s\tin_staging=%s\tin_develop=%s\tartifact_in_staging=%s\tartifact_matches=%s\tartifact_files=%s\tdeploy=%s\tbasis=%s\ttruth=%s\n' \
    "$card" "$task" "$branch" "$exists" "$staging" "$develop" "$art" "$art_count" "$art_files" "$DEPLOY" "$basis" "$truth"
  i=$((i + 1))
done
