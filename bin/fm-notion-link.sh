#!/usr/bin/env bash
# Link a spawned task to the Notion board card it came from, so the
# notion-board skill can sync that card's Status as the task moves and can
# post the result back into the card body when it lands.
#
# Usage: fm-notion-link.sh <task-id> <page-url>
#        fm-notion-link.sh --archive <task-id>
#
# Records link lines in state/<task-id>.meta (replacing any prior link,
# preserving every other meta line):
#   notion_page=<url>          the card this task is currently bound to
#   notion_linked_ts=<epoch>   link time
#
# It ALSO appends the same binding to the durable card index,
# data/notion-cards.tsv (format owned by bin/fm-notion-index-lib.sh), BEFORE
# touching meta. Meta dies with the task at teardown; the index does not, and it
# is what lets bin/fm-board-truth.sh still resolve a card to its branch after
# the task is gone, however it went. A link whose index append fails is
# therefore refused outright rather than recorded in meta alone, because a link
# that only lives in meta is exactly the one the board loses. The task branch is
# recorded as fm/<task-id>, the branch every generated brief creates. Relinking
# a task to a different card archives the previous card in the index first, so
# the index always mirrors meta's single live binding.
#
# --archive is the RECYCLING GUARD and is mandatory before a card is returned
# to the free pool. Cards are reused rather than deleted (the Notion MCP
# surface has no delete or trash tool at all), so a card URL outlives the task
# that used it and will later hold a DIFFERENT task. Archiving rewrites
# notion_page= to notion_page_archived=, which no sync step reads, so a late
# wake on an old task can never push a status into a card that has since been
# handed to someone else. Never hand a card back to the pool while a live
# notion_page= still points at it. The durable index is the source of truth for
# what --archive retires: every card the index still holds live for the task
# gets an archive event (there can be more than one after a meta rewrite failed
# between the index append and the meta write), and a live notion_page= that the
# index never recorded is archived too. Recycling ordinarily happens after the
# task was torn down and its meta erased, so --archive works with no meta at
# all; meta is rewritten only when it exists and still carries notion_page=.
# "No live link" means neither the index nor meta holds one, and is exit 0.
#
# This is a separate step the notion-board skill runs AFTER fm-spawn.sh, so it
# never changes fm-spawn's interface - the same split fm-x-link.sh uses. This
# script is deliberately network-free: it owns only the meta format, while
# every Notion read and write goes through the MCP connector from inside the
# agent's own turn.
#
# The task id composes a path (state/<id>.meta) and is guarded against path
# traversal even though it comes from a trusted caller.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-notion-index-lib.sh
. "$SCRIPT_DIR/fm-notion-index-lib.sh"
INDEX="$DATA/$FM_NOTION_INDEX_NAME"

meta_get() {  # <meta-file> <key> - last value, empty when absent
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

usage() {
  echo "usage: fm-notion-link.sh <task-id> <page-url>" >&2
  echo "       fm-notion-link.sh --archive <task-id>" >&2
}

# Atomic replace of the notion_* lines, preserving every other meta line.
notion_meta_write() {  # <meta> <mode:link|archive> [url] [ts]
  local meta=$1 mode=$2 url=${3:-} ts=${4:-} dir base tmp
  [ -f "$meta" ] || return 1
  dir=${meta%/*}
  base=${meta##*/}
  [ "$dir" != "$meta" ] || dir=.
  [ -d "$dir" ] || return 1
  tmp=$(mktemp "$dir/.${base}.fm-notion.XXXXXX") || return 1
  if [ "$mode" = archive ]; then
    # Keep the value, retire the key: history stays readable, no sync step
    # will ever act on it again.
    if ! sed -e 's/^notion_page=/notion_page_archived=/' \
             -e 's/^notion_linked_ts=/notion_archived_ts=/' "$meta" > "$tmp"; then
      rm -f "$tmp"; return 1
    fi
  else
    if ! { grep -vE '^notion_page=|^notion_linked_ts=' "$meta" || true; } > "$tmp"; then
      rm -f "$tmp"; return 1
    fi
    printf 'notion_page=%s\n' "$url" >> "$tmp" || { rm -f "$tmp"; return 1; }
    printf 'notion_linked_ts=%s\n' "$ts" >> "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}

MODE="link"
if [ "${1:-}" = "--archive" ]; then
  MODE=archive
  shift
fi

ID=${1:-}
URL=${2:-}
if [ -z "$ID" ]; then
  usage
  exit 2
fi
if [ "$MODE" = link ] && [ -z "$URL" ]; then
  usage
  exit 2
fi
if [ "$MODE" = archive ] && [ -n "$URL" ]; then
  usage
  exit 2
fi

fm_pr_task_id_valid "$ID" || { echo "fm-notion-link: unsafe task id: $ID" >&2; exit 2; }

META="$STATE/$ID.meta"

if [ "$MODE" = archive ]; then
  LIVE=$(fm_notion_index_task_live_links "$INDEX" "$ID")
  META_URL=
  if [ -f "$META" ]; then
    META_URL=$(meta_get "$META" notion_page)
    if [ -n "$META_URL" ] && ! printf '%s\n' "$LIVE" | cut -f1 | grep -qxF -- "$META_URL"; then
      LIVE="${LIVE:+$LIVE
}$META_URL"$'\t'"fm/$ID"$'\t'"$(meta_get "$META" project)"
    fi
  fi
  if [ -z "$LIVE" ]; then
    # Idempotent: re-archiving an already-archived task is a no-op success, so
    # a retried cleanup pass never fails the recycle.
    printf 'no live Notion link on %s\n' "$ID"
    exit 0
  fi
  ARCHIVED=0
  while IFS=$'\t' read -r HIT_URL HIT_BRANCH HIT_PROJECT; do
    [ -n "$HIT_URL" ] || continue
    if ! fm_notion_index_append "$INDEX" archive "$ID" "$HIT_URL" "$HIT_BRANCH" "$HIT_PROJECT"; then
      echo "fm-notion-link: failed to record the archive of $HIT_URL in $INDEX; link left live" >&2
      exit 1
    fi
    ARCHIVED=$((ARCHIVED + 1))
  done <<EOF
$LIVE
EOF
  if [ -n "$META_URL" ]; then
    if ! notion_meta_write "$META" archive; then
      echo "fm-notion-link: failed to archive the link in state/$ID.meta" >&2
      exit 1
    fi
    printf 'archived %s Notion link(s) on %s; its card may now be recycled\n' "$ARCHIVED" "$ID"
  elif [ -f "$META" ]; then
    printf 'archived %s Notion link(s) on %s from the index (meta held no live link); its card may now be recycled\n' "$ARCHIVED" "$ID"
  else
    printf 'archived %s Notion link(s) on %s from the index (task already torn down); its card may now be recycled\n' "$ARCHIVED" "$ID"
  fi
  exit 0
fi

if [ ! -f "$META" ]; then
  echo "fm-notion-link: no such task: state/$ID.meta" >&2
  exit 1
fi

# The URL lands in a line-oriented meta file and is echoed into later prompts;
# the index lib owns the rule for what is safe to write.
if ! fm_notion_index_url_safe "$URL"; then
  echo "fm-notion-link: page url must be an https:// notion.so or notion.com link with no whitespace or shell characters - got: $URL" >&2
  exit 2
fi

# FM_NOW_OVERRIDE keeps tests deterministic; production uses the wall clock.
LINK_TS=${FM_NOW_OVERRIDE:-$(date +%s)}
case "$LINK_TS" in
  ''|*[!0-9]*) echo "fm-notion-link: could not read the current time" >&2; exit 1 ;;
esac

# Index first: it is the record that survives teardown, so a binding must exist
# there before meta claims it. FM_NOW_OVERRIDE flows into the index timestamp too.
# A task moving to a different card releases the old one in the index first, so
# no card stays resolvable to a task that meta no longer binds to it.
PROJECT=$(meta_get "$META" project)
PREVIOUS_URL=$(meta_get "$META" notion_page)
if [ -n "$PREVIOUS_URL" ] && [ "$PREVIOUS_URL" != "$URL" ]; then
  if ! fm_notion_index_append "$INDEX" archive "$ID" "$PREVIOUS_URL" "fm/$ID" "$PROJECT"; then
    echo "fm-notion-link: failed to release the previous card $PREVIOUS_URL in $INDEX; nothing written to meta" >&2
    exit 1
  fi
fi
if ! fm_notion_index_append "$INDEX" link "$ID" "$URL" "fm/$ID" "$PROJECT"; then
  echo "fm-notion-link: failed to record the link in $INDEX; nothing written to meta" >&2
  exit 1
fi
if ! notion_meta_write "$META" link "$URL" "$LINK_TS"; then
  echo "fm-notion-link: failed to record the link in state/$ID.meta" >&2
  exit 1
fi

printf 'linked %s to Notion card %s\n' "$ID" "$URL"
