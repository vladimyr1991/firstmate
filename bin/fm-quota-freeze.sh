#!/usr/bin/env bash
# Record and discharge quota-freeze obligations: work that stopped because a
# model's usage window was exhausted, plus the poll that wakes the fleet when
# that window genuinely comes back.
# Usage: fm-quota-freeze.sh <add|list|show|resolve> [options]
# See bin/fm-quota-freeze-lib.sh for the record format and poll contract.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-quota-freeze-lib.sh
. "$SCRIPT_DIR/fm-quota-freeze-lib.sh"

usage() {
  cat <<EOF
usage: fm-quota-freeze.sh add --subject <s> --provider <p> --action <a>
                              [--kind task|role] [--window <w>] [--note <text>]
       fm-quota-freeze.sh list
       fm-quota-freeze.sh show <subject>
       fm-quota-freeze.sh resolve <subject>

Durable registry of work frozen on an exhausted model window, plus the watcher
poll that wakes firstmate once that window has actually recovered. The registry
lives in state/quota-frozen/ and survives a firstmate restart, so "I will pick
this up when the limit resets" stops being a promise held only in conversation.

add
  --subject   the frozen task id, or the role "firstmate" or "pm"
  --kind      task or role; inferred from the subject when omitted
  --provider  the quota-axi provider whose window is exhausted (claude, codex,
              grok, ...). Required: firstmate establishes the provider from the
              harness's own authoritative catalog, never from a name, so this
              script does not guess one from a harness or model
  --window    the exhausted window id (five_hour, weekly, model:fable, ...).
              When omitted, the provider's window with the least remaining
              headroom is selected from the same quota-axi reading
  --action    what the wake must cause:
                nudge    a parked worker needs one steer to continue
                respawn  the worker or role is gone and must be launched again
                repeat   an action firstmate deferred and must simply retry
  --note      one line of free text recorded with the obligation

  The window must actually be exhausted (at or below $FM_QUOTA_RESET_FLOOR% remaining) in the
  current quota-axi reading, otherwise add refuses with exit code 4. That
  refusal is the useful answer, not an obstacle: it means the limit that
  stopped the work is one quota-axi does not model, exactly the shape of grok's
  weekly cap sitting invisible behind its credits window, so waiting for a
  "reset" it can never observe would stall the work indefinitely. Reroute the
  work rather than freezing it.

list
  One line per obligation, plus any unreadable registry entry, so a single
  corrupt file never hides the rest of the queue.

show <subject>
  The full record and whether its wake has already been surfaced.

resolve <subject>
  Remove one obligation after the resume is CONFIRMED, never before. The poll
  keeps re-surfacing an obligation that is still on disk, so an unconfirmed
  removal is the one way to lose the work again. When the registry empties,
  the poll retires itself.

The poll is armed as an intentional custom check under the reserved id
"$FM_QUOTA_RESET_POLL_ID", which no task can hold, so it never contests a task's own
merge or CI watch for a check slot. It re-reads quota-axi on every sweep and is
silent until a frozen window reports real headroom again.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

quota_snapshot() {
  local out
  if command -v timeout >/dev/null 2>&1; then
    out=$(timeout 30 quota-axi --json 2>/dev/null </dev/null) || return 1
  elif command -v gtimeout >/dev/null 2>&1; then
    out=$(gtimeout 30 quota-axi --json 2>/dev/null </dev/null) || return 1
  else
    out=$(quota-axi --json 2>/dev/null </dev/null) || return 1
  fi
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Echo "<window-id>\t<percentRemaining>\t<resetsAt>" for the requested window,
# or one uppercase reason token. A stale provider reading is refused rather than
# used: freezing on a number that predates the exhaustion would record the wrong
# window, and the poll would then watch an axis that never blocked anything.
# Freshness is tested as "stale is explicitly false", never through jq's `//`,
# which treats the false the caller is hoping for as an absent value.
lookup_window() {
  local json=$1 provider=$2 window=$3
  if [ -n "$window" ]; then
    printf '%s' "$json" | jq -r --arg p "$provider" --arg w "$window" '
      [ .providers[]? | select(.provider == $p) ] as $ps
      | if ($ps | length) == 0 then "PROVIDER_ABSENT"
        elif ($ps[0].state.stale != false) then "PROVIDER_STALE"
        else
          ([ $ps[0].windows[]? | select(.id == $w) ]) as $ws
          | if ($ws | length) == 0 then "WINDOW_ABSENT"
            elif ($ws[0].percentRemaining == null) then "WINDOW_ABSENT"
            else "\($ws[0].id)\t\($ws[0].percentRemaining)\t\($ws[0].resetsAt // "unknown")"
            end
        end' 2>/dev/null
  else
    printf '%s' "$json" | jq -r --arg p "$provider" '
      [ .providers[]? | select(.provider == $p) ] as $ps
      | if ($ps | length) == 0 then "PROVIDER_ABSENT"
        elif ($ps[0].state.stale != false) then "PROVIDER_STALE"
        else
          ([ $ps[0].windows[]? | select(.percentRemaining != null) ]
            | sort_by(.percentRemaining)) as $ws
          | if ($ws | length) == 0 then "NO_WINDOWS"
            else "\($ws[0].id)\t\($ws[0].percentRemaining)\t\($ws[0].resetsAt // "unknown")"
            end
        end' 2>/dev/null
  fi
}

# The reserved id keeps this slot uncontested, but a slot holding a FOREIGN
# check is still refused rather than overwritten: a supervision primitive whose
# whole purpose is no-missed-wakes must never silently destroy a sibling watch.
# One of our own polls, including one an earlier firstmate rendered, is ours to
# re-arm over; treating it as foreign would refuse every subsequent freeze after
# any change to the render and stall exactly the work this exists to resume.
# Checked BEFORE the record is written, so a refusal never leaves an obligation
# on disk with nothing watching it.
assert_slot_available() {
  local check="$STATE/$FM_QUOTA_RESET_POLL_ID.check.sh"
  [ -e "$check" ] || [ -L "$check" ] || return 0
  if fm_quota_reset_poll_is_ours "$check"; then
    return 0
  fi
  printf 'error: state/%s.check.sh is owned by another check; refusing to replace it\n' \
    "$FM_QUOTA_RESET_POLL_ID" >&2
  exit 3
}

# The record is deliberately kept when arming fails: an obligation nobody
# watches is recoverable, a lost obligation is not. What must not happen is the
# failure reading as "nothing happened", so it names the unwatched subject and
# the exact command that arms it again.
arm_failed() {  # <reason> <subject> <provider> <window> <action>
  local reason=$1 subject=$2 provider=$3 window=$4 action=$5
  printf 'error: %s\n' "$reason" >&2
  printf 'error: the freeze for %s is recorded in state/quota-frozen/%s but NO poll is watching it, so nothing will wake the fleet when %s/%s recovers\n' \
    "$subject" "$subject" "$provider" "$window" >&2
  printf 'error: re-arm it with: fm-quota-freeze.sh add --subject %s --provider %s --window %s --action %s\n' \
    "$subject" "$provider" "$window" "$action" >&2
  exit 1
}

arm_poll() {  # <subject> <provider> <window> <action>
  local subject=$1 provider=$2 window=$3 action=$4
  trap fm_quota_reset_poll_cleanup EXIT
  trap 'exit 1' HUP INT TERM
  fm_quota_reset_poll_prepare "$STATE" \
    || arm_failed "could not prepare the quota reset poll" "$subject" "$provider" "$window" "$action"
  fm_quota_reset_poll_publish_prepared \
    || arm_failed "could not publish the quota reset poll" "$subject" "$provider" "$window" "$action"
  trap - EXIT
}

cmd_add() {
  local subject='' kind='' provider='' window='' action='' note=''
  local json line window_id remaining resets_at epoch frozen_at
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --subject) [ "$#" -ge 2 ] || usage_error "--subject requires a value"; subject=$2; shift 2 ;;
      --kind) [ "$#" -ge 2 ] || usage_error "--kind requires a value"; kind=$2; shift 2 ;;
      --provider) [ "$#" -ge 2 ] || usage_error "--provider requires a value"; provider=$2; shift 2 ;;
      --window) [ "$#" -ge 2 ] || usage_error "--window requires a value"; window=$2; shift 2 ;;
      --action) [ "$#" -ge 2 ] || usage_error "--action requires a value"; action=$2; shift 2 ;;
      --note) [ "$#" -ge 2 ] || usage_error "--note requires a value"; note=$2; shift 2 ;;
      *) usage_error "unknown argument: $1" ;;
    esac
  done

  [ -n "$subject" ] || usage_error "--subject is required"
  [ -n "$provider" ] || usage_error "--provider is required"
  [ -n "$action" ] || usage_error "--action is required"
  if [ -z "$kind" ]; then
    if fm_quota_freeze_role_valid "$subject"; then kind=role; else kind=task; fi
  fi
  fm_quota_freeze_subject_valid "$subject" "$kind" \
    || usage_error "invalid subject for kind $kind: $subject"
  fm_quota_freeze_provider_valid "$provider" || usage_error "invalid provider: $provider"
  [ -z "$window" ] || fm_quota_freeze_window_valid "$window" || usage_error "invalid window: $window"
  fm_quota_freeze_action_valid "$action" || usage_error "invalid action: $action"
  fm_quota_freeze_note_valid "$note" || usage_error "invalid note"

  # A freeze whose recovery can never be observed is worse than no freeze: it
  # would arm a poll that stays silent forever. Both tools are therefore
  # required at registration, the one point where their absence can be reported.
  command -v quota-axi >/dev/null 2>&1 \
    || die "recording a quota freeze requires quota-axi on PATH"
  command -v jq >/dev/null 2>&1 \
    || die "recording a quota freeze requires jq on PATH"
  assert_slot_available
  json=$(quota_snapshot) || die "quota-axi did not return a reading"

  line=$(lookup_window "$json" "$provider" "$window") || line=
  case "$line" in
    ''|PROVIDER_ABSENT)
      die "quota-axi reports no provider '$provider'" ;;
    PROVIDER_STALE)
      die "quota-axi's reading for '$provider' is stale; refusing to freeze on a number that predates the limit" ;;
    NO_WINDOWS)
      printf 'error: quota-axi models no usage window for %s, so a reset cannot be observed; reroute this work instead of freezing it\n' \
        "$provider" >&2
      exit 4 ;;
    WINDOW_ABSENT)
      printf 'error: quota-axi models no window %s for %s, so a reset cannot be observed; reroute this work instead of freezing it\n' \
        "$window" "$provider" >&2
      exit 4 ;;
  esac
  IFS=$(printf '\t') read -r window_id remaining resets_at <<EOF
$line
EOF
  fm_quota_freeze_window_valid "$window_id" || die "quota-axi returned an unusable window id"
  case "$remaining" in
    ''|*[!0-9.]*) die "quota-axi returned an unusable headroom value for $provider/$window_id" ;;
  esac
  if ! awk -v a="$remaining" -v b="$FM_QUOTA_RESET_FLOOR" 'BEGIN { exit !(a + 0 <= b + 0) }'; then
    printf 'error: %s/%s reports %s%% remaining, so it is not the axis that stopped this work; the exhausted limit is one quota-axi does not model, and waiting for a reset it cannot observe would stall indefinitely\n' \
      "$provider" "$window_id" "$remaining" >&2
    exit 4
  fi

  if fm_quota_freeze_resets_at_valid "$resets_at" && [ "$resets_at" != unknown ]; then
    epoch=$(fm_quota_freeze_iso_epoch "$resets_at") || { resets_at=unknown; epoch=0; }
  else
    resets_at=unknown
    epoch=0
  fi
  frozen_at=$(date +%s)

  fm_quota_freeze_record_write "$STATE" "$subject" "$kind" "$provider" "$window_id" \
    "$resets_at" "$epoch" "$action" "$frozen_at" "$note" \
    || die "could not record the quota freeze"
  arm_poll "$subject" "$provider" "$window_id" "$action"
  printf 'frozen: %s (%s) on %s/%s resets_at=%s action=%s\n' \
    "$subject" "$kind" "$provider" "$window_id" "$resets_at" "$action"
  printf 'armed: state/%s.check.sh\n' "$FM_QUOTA_RESET_POLL_ID"
}

notified_at() {
  local subject=$1 marker value
  marker="$(fm_quota_freeze_notified_dir "$STATE")/$subject"
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    value=$(cat "$marker" 2>/dev/null) || value=
    case "$value" in
      ''|*[!0-9]*) printf 'unknown\n' ;;
      *) printf '%s\n' "$value" ;;
    esac
  else
    printf 'no\n'
  fi
}

cmd_list() {
  local dir rec subject any=0
  dir=$(fm_quota_freeze_dir "$STATE")
  if [ ! -d "$dir" ] || [ -L "$dir" ]; then
    printf 'no quota freezes recorded\n'
    return 0
  fi
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    subject=${rec##*/}
    any=1
    if fm_quota_freeze_record_parse "$rec"; then
      printf 'subject=%s kind=%s provider=%s window=%s resets_at=%s action=%s frozen_at=%s surfaced=%s note=%s\n' \
        "$FM_QUOTA_FREEZE_SUBJECT" "$FM_QUOTA_FREEZE_KIND" "$FM_QUOTA_FREEZE_PROVIDER" \
        "$FM_QUOTA_FREEZE_WINDOW" "$FM_QUOTA_FREEZE_RESETS_AT" "$FM_QUOTA_FREEZE_ACTION" \
        "$FM_QUOTA_FREEZE_FROZEN_AT" "$(notified_at "$subject")" "$FM_QUOTA_FREEZE_NOTE"
    else
      printf 'invalid: %s\n' "$rec"
    fi
  done < <(find "$dir" -maxdepth 1 \( -type f -o -type l \) -print 2>/dev/null | LC_ALL=C sort)
  [ "$any" -eq 1 ] || printf 'no quota freezes recorded\n'
  if fm_quota_reset_poll_armed "$STATE"; then
    printf 'poll: armed state/%s.check.sh\n' "$FM_QUOTA_RESET_POLL_ID"
  else
    printf 'poll: not armed\n'
  fi
}

cmd_show() {
  local subject=${1-} dir rec
  [ -n "$subject" ] || usage_error "show requires a subject"
  fm_task_id_path_safe "$subject" || usage_error "invalid subject: $subject"
  dir=$(fm_quota_freeze_dir "$STATE")
  rec="$dir/$subject"
  fm_quota_freeze_record_parse "$rec" || die "no readable quota freeze for $subject"
  printf 'subject=%s\nkind=%s\nprovider=%s\nwindow=%s\nresets_at=%s\nresets_at_epoch=%s\naction=%s\nfrozen_at=%s\nsurfaced=%s\nnote=%s\n' \
    "$FM_QUOTA_FREEZE_SUBJECT" "$FM_QUOTA_FREEZE_KIND" "$FM_QUOTA_FREEZE_PROVIDER" \
    "$FM_QUOTA_FREEZE_WINDOW" "$FM_QUOTA_FREEZE_RESETS_AT" "$FM_QUOTA_FREEZE_RESETS_AT_EPOCH" \
    "$FM_QUOTA_FREEZE_ACTION" "$FM_QUOTA_FREEZE_FROZEN_AT" "$(notified_at "$subject")" \
    "$FM_QUOTA_FREEZE_NOTE"
}

cmd_resolve() {
  local subject=${1-} remaining
  [ -n "$subject" ] || usage_error "resolve requires a subject"
  fm_task_id_path_safe "$subject" || usage_error "invalid subject: $subject"
  fm_quota_freeze_record_remove "$STATE" "$subject" || die "no quota freeze recorded for $subject"
  printf 'resolved: %s\n' "$subject"
  remaining=$(fm_quota_freeze_count "$STATE")
  if [ "$remaining" -eq 0 ]; then
    if fm_quota_reset_poll_retire "$STATE"; then
      printf 'retired: state/%s.check.sh\n' "$FM_QUOTA_RESET_POLL_ID"
    else
      printf 'note: state/%s.check.sh is owned by another check and was left alone\n' \
        "$FM_QUOTA_RESET_POLL_ID"
    fi
  else
    printf 'remaining: %s\n' "$remaining"
  fi
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
COMMAND=$1
shift
case "$COMMAND" in
  -h|--help|help) usage; exit 0 ;;
  add) cmd_add "$@" ;;
  list) [ "$#" -eq 0 ] || usage_error "list takes no arguments"; cmd_list ;;
  show) [ "$#" -eq 1 ] || usage_error "show takes exactly one subject"; cmd_show "$@" ;;
  resolve) [ "$#" -eq 1 ] || usage_error "resolve takes exactly one subject"; cmd_resolve "$@" ;;
  *) usage_error "unknown command: $COMMAND" ;;
esac
