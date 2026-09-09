#!/usr/bin/env bash
# The durable card index: which Notion card each task was bound to, and on
# which branch its work lives, recorded in data/ so that it outlives every
# state/<id>.meta teardown - forced, ordinary, or crashed halfway.
#
# state/<id>.meta carries notion_page= only while the task exists, and teardown
# erases it. A board reconciliation that needs to know "which branch belongs to
# this card" after the task is gone therefore cannot use meta at all; this file
# is the record that remains. It is written only by bin/fm-notion-link.sh and
# read by bin/fm-board-truth.sh.
#
# Format - data/notion-cards.tsv, append-only, one event per line:
#   <epoch>\t<event>\t<task-id>\t<card-url>\t<branch>\t<project>
#   event = link     the card was bound to the task; branch is the task branch
#   event = archive  the link was retired (recycle step 3, a spec task handed
#                    its card to the implementation task, or the task was
#                    relinked to another card); this task no longer owns the card
# Links are tracked per task: a `link` adds the task to the card's live set and
# an `archive` removes only that task, so the handover order "link impl, then
# archive spec" leaves the card live and owned by impl. A card is live while any
# linked task remains, and a lookup resolves it to the most recently linked task
# still live. Fields are tab-separated; the url and branch are validated to
# contain no whitespace and the project no tab or newline before they are
# written, so the file always parses.

# shellcheck disable=SC2034 # Read by bin/fm-notion-link.sh and bin/fm-board-truth.sh after sourcing.
FM_NOTION_INDEX_NAME='notion-cards.tsv'

fm_notion_index_url_safe() {  # <url>
  case "${1-}" in
    https://*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *notion.so/*|*notion.com/*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[[:space:]]*|*'$'*|*'`'*|*'"'*|*"'"*|*"\\"*|*'<'*|*'>'*) return 1 ;;
  esac
  return 0
}

# Append one event. Args: <index> <event> <task-id> <url> <branch> <project>
fm_notion_index_append() {
  local index=$1 event=$2 id=$3 url=$4 branch=$5 project=$6 dir ts
  case "$event" in link|archive) ;; *) return 1 ;; esac
  case "$branch" in *[[:space:]]*) return 1 ;; esac
  case "$project" in *$'\t'*|*$'\n'*) return 1 ;; esac
  dir=${index%/*}
  [ "$dir" != "$index" ] || dir=.
  mkdir -p "$dir" || return 1
  ts=${FM_NOW_OVERRIDE:-$(date +%s)}
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$event" "$id" "$url" "$branch" "$project" >> "$index"
}

# Resolve a card to its live task and branch: prints "<task-id>\t<branch>" for
# the most recently linked task that has not been archived, or nothing when no
# live link remains. Args: <index> <url>
fm_notion_index_lookup() {
  local index=$1 url=$2
  [ -f "$index" ] || return 0
  awk -F'\t' -v url="$url" '
    $4 != url { next }
    $2 == "link" { live[$3] = ++seq; br[$3] = $5 }
    $2 == "archive" { delete live[$3] }
    END {
      best = ""
      for (id in live) if (best == "" || live[id] > live[best]) best = id
      if (best != "") printf "%s\t%s\n", best, br[best]
    }' "$index"
}

# Resolve a task to the card it still holds: prints "<url>\t<branch>\t<project>"
# for the most recently linked card the task has not archived, or nothing. This
# is what lets --archive retire a link after teardown erased the task's meta.
# Args: <index> <task-id>
fm_notion_index_task_live_link() {
  local index=$1 id=$2
  [ -f "$index" ] || return 0
  awk -F'\t' -v id="$id" '
    $3 != id { next }
    $2 == "link" { live[$4] = ++seq; br[$4] = $5; pr[$4] = $6 }
    $2 == "archive" { delete live[$4] }
    END {
      best = ""
      for (u in live) if (best == "" || live[u] > live[best]) best = u
      if (best != "") printf "%s\t%s\t%s\n", best, br[best], pr[best]
    }' "$index"
}

# Every card that still has at least one live linked task, one url per line, in
# first-seen order. Args: <index>
fm_notion_index_live_cards() {
  local index=$1
  [ -f "$index" ] || return 0
  awk -F'\t' '
    !($4 in order) { order[$4] = ++n; urls[n] = $4 }
    $2 == "link" && !(($4 SUBSEP $3) in live) { live[$4, $3] = 1; cnt[$4]++ }
    $2 == "archive" && (($4 SUBSEP $3) in live) { delete live[$4, $3]; cnt[$4]-- }
    END { for (i = 1; i <= n; i++) if (cnt[urls[i]] > 0) print urls[i] }' "$index"
}
