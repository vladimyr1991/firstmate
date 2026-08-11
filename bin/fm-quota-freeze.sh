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

Exit codes (add). They distinguish the three outcomes that matter, because a
recorded obligation reported as unrecorded invites the caller to record it
twice, and an unwatched one reported as watched loses the wake:
  0  recorded AND watched: the poll was armed, or was already armed and still
     watches the whole registry after a refresh that did not land (a warning
     names the refresh command; the obligation itself is safe)
  $FM_QUOTA_FREEZE_EXIT_UNWATCHED  recorded but NOT watched: the obligation is on disk and nothing is armed,
     so no open obligation is being watched until the named command re-arms it
  1  nothing was recorded
  2  usage error
  3  the reserved check slot is held by another check; nothing was recorded
  4  no window of that provider is exhausted, so a reset cannot be observed;
     nothing was recorded

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

# Every subject currently in the registry, one per line, for the arming-failure
# report. The poll is fleet-wide, so what is or is not watched is never about
# one subject.
open_subjects() {
  local dir rec
  dir=$(fm_quota_freeze_dir "$STATE")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  for rec in "$dir"/*; do
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    printf ' %s' "${rec##*/}"
  done
}

# The record is deliberately kept when arming fails: per the commit invariant in
# bin/fm-quota-freeze-lib.sh's header, nothing after the record lands may undo
# it OR misreport it. An obligation nobody watches is recoverable, a lost
# obligation is not, and an obligation reported as neither recorded nor watched
# when it is both sends the caller to record it a second time.
#
# So this reports the true state of the fleet-wide poll - which is one file
# watching the whole registry, not this subject - and names the exact command
# that arms it again, INCLUDING the note, without which re-arming would
# overwrite the record with an empty one and discard the only thing that says
# what resuming actually requires. Echoes the outcome the caller must branch on:
# "watched" when a live poll still covers the registry, "unwatched" when nothing
# does.
arm_failed() {  # <reason> <subject> <provider> <window> <action> <note>
  local reason=$1 subject=$2 provider=$3 window=$4 action=$5 note=$6 rearm
  printf -v rearm 'fm-quota-freeze.sh add --subject %q --provider %q --window %q --action %q' \
    "$subject" "$provider" "$window" "$action"
  [ -z "$note" ] || printf -v rearm '%s --note %q' "$rearm" "$note"
  if fm_quota_reset_poll_armed "$STATE"; then
    # Both durable results this add owes are in hand: the record is on disk and
    # a poll is watching it. The refresh that failed is the only thing missing,
    # so it is a warning - calling it an error here is what told firstmate to
    # redo work that was already done.
    printf 'warning: %s\n' "$reason" >&2
    printf 'warning: the freeze for %s is recorded in state/quota-frozen/%s and the poll already armed at state/%s.check.sh still watches the whole registry, so the wake for %s/%s is NOT lost; that poll was simply not refreshed\n' \
      "$subject" "$subject" "$FM_QUOTA_RESET_POLL_ID" "$provider" "$window" >&2
    printf 'warning: refresh it when convenient with: %s\n' "$rearm" >&2
    printf 'watched\n'
    return 0
  fi
  printf 'error: %s\n' "$reason" >&2
  printf 'error: the freeze for %s is recorded in state/quota-frozen/%s but state/%s.check.sh is NOT armed\n' \
    "$subject" "$subject" "$FM_QUOTA_RESET_POLL_ID" >&2
  printf 'error: that poll is fleet-wide - one check for the whole registry - so nothing is watching ANY of these %s open obligation(s) until it is armed again:%s\n' \
    "$(fm_quota_freeze_count "$STATE")" "$(open_subjects)" >&2
  printf 'error: re-arm it with: %s\n' "$rearm" >&2
  printf 'unwatched\n'
  return 0
}

# Echoes exactly one of: armed (this attempt published the poll), watched (this
# attempt failed but a live fleet-wide poll still covers the registry),
# unwatched (nothing is armed). Never exits: the record is already committed by
# the time this runs, and only the caller may decide how a committed record plus
# a poll state is reported.
arm_poll() {  # <subject> <provider> <window> <action> <note>
  local subject=$1 provider=$2 window=$3 action=$4 note=$5 outcome
  trap fm_quota_reset_poll_cleanup EXIT
  trap 'exit 1' HUP INT TERM
  if ! fm_quota_reset_poll_prepare "$STATE"; then
    outcome=$(arm_failed "could not prepare the quota reset poll" "$subject" "$provider" "$window" "$action" "$note")
  elif ! fm_quota_reset_poll_publish_prepared; then
    outcome=$(arm_failed "could not publish the quota reset poll" "$subject" "$provider" "$window" "$action" "$note")
  else
    outcome=armed
  fi
  fm_quota_reset_poll_cleanup
  trap - EXIT
  printf '%s\n' "$outcome"
}

cmd_add() {
  local subject='' kind='' provider='' window='' action='' note=''
  local json line window_id remaining resets_at epoch frozen_at outcome
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
  outcome=$(arm_poll "$subject" "$provider" "$window_id" "$action" "$note")
  # The record landed, so the freeze is always reported as recorded. Only the
  # poll's state decides the exit code, and only "nothing is watching" is a
  # failure of this command: a live poll already covers the whole registry.
  printf 'frozen: %s (%s) on %s/%s resets_at=%s action=%s\n' \
    "$subject" "$kind" "$provider" "$window_id" "$resets_at" "$action"
  case "$outcome" in
    armed)
      printf 'armed: state/%s.check.sh\n' "$FM_QUOTA_RESET_POLL_ID" ;;
    watched)
      printf 'watched: state/%s.check.sh was already armed and still watches this obligation; its refresh did not land\n' \
        "$FM_QUOTA_RESET_POLL_ID" ;;
    *)
      printf 'unwatched: state/%s.check.sh is not armed\n' "$FM_QUOTA_RESET_POLL_ID"
      exit "$FM_QUOTA_FREEZE_EXIT_UNWATCHED" ;;
  esac
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
