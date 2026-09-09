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
#   event = archive  the link was retired (recycle step 3); the card is about to
#                    belong to someone else, so no lookup resolves it to this
#                    task any more
# The latest line for a card wins. A card whose latest line is `archive` has no
# live link. Fields are tab-separated and the url and branch are validated to
# contain no whitespace before they are written, so the file always parses.

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
  case "$branch$project" in *[[:space:]]*) return 1 ;; esac
  dir=${index%/*}
  [ "$dir" != "$index" ] || dir=.
  mkdir -p "$dir" || return 1
  ts=${FM_NOW_OVERRIDE:-$(date +%s)}
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$event" "$id" "$url" "$branch" "$project" >> "$index"
}

# Resolve a card to its live task and branch: prints "<task-id>\t<branch>" or
# nothing when the card has no live link. Args: <index> <url>
fm_notion_index_lookup() {
  local index=$1 url=$2
  [ -f "$index" ] || return 0
  awk -F'\t' -v url="$url" '
    $4 == url { ev = $2; id = $3; br = $5 }
    END { if (ev == "link") printf "%s\t%s\n", id, br }' "$index"
}

# Every card whose latest event is a live link, one url per line, in first-seen
# order. Args: <index>
fm_notion_index_live_cards() {
  local index=$1
  [ -f "$index" ] || return 0
  awk -F'\t' '
    !($4 in order) { order[$4] = ++n; urls[n] = $4 }
    { ev[$4] = $2 }
    END { for (i = 1; i <= n; i++) if (ev[urls[i]] == "link") print urls[i] }' "$index"
}
