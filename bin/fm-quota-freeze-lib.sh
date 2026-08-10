#!/usr/bin/env bash
# Shared record format, validation, and poll publication for the quota-freeze
# registry: the durable answer to "work stopped because a model window was
# exhausted, and nothing will ever wake the fleet when that window comes back".
#
# The wake system has no quota-reset event of its own. Wakes come from worker
# status appends, turn-end markers, heartbeats, and registered
# state/<id>.check.sh polls, so a turn that ends on "I'll pick this up when the
# limit resets" ends on an unarmed intention: the fleet idles at full quota
# until some unrelated event happens to fire. This file makes that promise a
# durable file plus an armed poll instead.
#
# Two artifacts, with deliberately different lifetimes:
#
#   state/quota-frozen/<subject>            one freeze obligation, mode 0600
#   state/quota-frozen/.notified/<subject>  "this obligation was already
#                                            surfaced at <epoch>", mode 0600
#
# A record is created when work freezes and removed ONLY after firstmate has
# confirmed the resume (bin/fm-quota-freeze.sh resolve). The notified marker is
# owned by the poll and only suppresses repeat wakes; it never means resumed.
# Keeping them separate is what makes the obligation survive a firstmate
# restart: the record outlives both the conversation and the wake it produced.
#
# The poll itself is armed as an intentional custom check
# (bin/fm-check-register.sh's contract: state/<id>.check.sh bound by content
# hash to state/<id>.check-trust), taking its shape from bin/fm-ci-run-lib.sh's
# one-shot CI run watch. It differs from that watch in three ways, each forced
# by what a quota freeze actually is:
#
#   * It is fleet-wide, not per task. Freezes span tasks and roles (the PM, or
#     firstmate's own deferred work), and a per-task poll would also collide
#     with that task's own PR merge watch over the shared check slot. It
#     therefore owns one reserved id, FM_QUOTA_RESET_POLL_ID, which
#     fm_task_id_creation_valid refuses for a real task so the slot can never
#     be contested.
#   * It is not one-shot. It stays armed while any obligation remains and
#     retires only when the registry is empty, so an obligation that firstmate
#     surfaced but never discharged is re-surfaced every
#     FM_QUOTA_RESET_RESURFACE_SECS rather than rotting invisibly - the same
#     "a wait cannot go quiet forever" rule bin/fm-watch.sh already applies to
#     a declared pause.
#   * Recovery is verified from quota-axi, never assumed from the clock. A
#     window's resetsAt can move, and a limit can exist that quota-axi does not
#     model at all (grok's weekly cap is invisible behind its credits window),
#     so a recorded timestamp alone is not evidence that capacity came back.
#
# Nothing in the registry is ever silently skipped. A window quota-axi stops
# reporting surfaces as an explicitly unverified obligation once its recorded
# reset is well past, and a record the poll cannot parse surfaces as unreadable.
# Both are worse answers than a verified recovery and better answers than
# silence, which is the failure this mechanism exists to remove.
#
# Print-then-mark ordering matches bin/fm-ci-run-lib.sh's reasoning exactly: the
# wake line is printed with no preceding side effect that could fail, and only
# then is the notified marker written. An interruption in between costs one
# duplicate wake; the opposite ordering could silently lose the reset event
# forever, which is the failure this whole mechanism exists to prevent.

# The reserved check id this poll publishes under. Not a task id: see
# fm_task_id_creation_valid in bin/fm-pr-lib.sh, which refuses it at task
# creation so no task can ever own state/<this>.check.sh.
FM_QUOTA_RESET_POLL_ID=fm-quota-reset

# Percent of a window that must be free before it counts as recovered. Also the
# ceiling below which a window counts as exhausted enough to freeze on: a
# freeze registered above this would be satisfied by the very next poll, which
# means the axis that actually blocked the work was a different one.
FM_QUOTA_RESET_FLOOR=10

# How long a surfaced-but-undischarged obligation stays quiet before it is
# surfaced again.
FM_QUOTA_RESET_RESURFACE_SECS=1800

# How long after a record's own recorded reset time the poll waits before
# reporting an obligation it cannot verify from quota-axi. Reaching this means
# quota-axi stopped modelling that window (or stopped answering), which must
# surface as an explicitly unverified obligation rather than as silence.
FM_QUOTA_RESET_UNVERIFIED_GRACE_SECS=900

# Roles that freeze without being a task: firstmate's own deferred work, and
# the board PM, which exists only while firstmate spawns it and so can never
# recover itself.
FM_QUOTA_FREEZE_ROLES="firstmate pm"

FM_QUOTA_FREEZE_SUBJECT=
FM_QUOTA_FREEZE_KIND=
FM_QUOTA_FREEZE_PROVIDER=
FM_QUOTA_FREEZE_WINDOW=
FM_QUOTA_FREEZE_RESETS_AT=
FM_QUOTA_FREEZE_RESETS_AT_EPOCH=
FM_QUOTA_FREEZE_ACTION=
FM_QUOTA_FREEZE_FROZEN_AT=
FM_QUOTA_FREEZE_NOTE=

FM_QUOTA_RESET_POLL_CHECK_TMP=
FM_QUOTA_RESET_POLL_TRUST_TMP=
FM_QUOTA_RESET_POLL_CHECK_DEST=
FM_QUOTA_RESET_POLL_TRUST_DEST=
FM_QUOTA_RESET_POLL_STATE=
FM_QUOTA_RESET_POLL_STATE_DEVICE=

fm_quota_freeze_dir() {
  printf '%s\n' "$1/quota-frozen"
}

fm_quota_freeze_notified_dir() {
  printf '%s\n' "$1/quota-frozen/.notified"
}

fm_quota_freeze_role_valid() {
  local role=${1-} candidate
  for candidate in $FM_QUOTA_FREEZE_ROLES; do
    [ "$role" = "$candidate" ] && return 0
  done
  return 1
}

# A subject is one registry file name, so it must be path-safe and bounded. The
# two role names are reserved: a task may not claim them, and a role subject
# must be one of them, so "pm" in the registry always means the board PM.
fm_quota_freeze_subject_valid() {
  local subject=${1-} kind=${2-}
  fm_task_id_path_safe "$subject" || return 1
  [ "${#subject}" -le 64 ] || return 1
  case "$kind" in
    role) fm_quota_freeze_role_valid "$subject" ;;
    task) ! fm_quota_freeze_role_valid "$subject" ;;
    *) return 1 ;;
  esac
}

# quota-axi provider ids observed in schemaVersion 3 output are lowercase
# tokens (claude, codex, grok, kimi, cursor, copilot). Accepting the shape
# rather than an enumerated list keeps a newly modelled provider usable without
# a firstmate release, while still refusing anything that is not a plain token.
fm_quota_freeze_provider_valid() {
  local provider=${1-}
  local LC_ALL=C
  [ "${#provider}" -ge 1 ] && [ "${#provider}" -le 64 ] || return 1
  case "$provider" in
    [a-z0-9]*) ;;
    *) return 1 ;;
  esac
  case "$provider" in
    *[!a-z0-9._-]*) return 1 ;;
  esac
}

# Window ids carry a namespace separator in quota-axi's own output
# ("model:fable", "product:grok_build") alongside plain ids ("five_hour").
fm_quota_freeze_window_valid() {
  local window=${1-}
  local LC_ALL=C
  [ "${#window}" -ge 1 ] && [ "${#window}" -le 64 ] || return 1
  case "$window" in
    [A-Za-z0-9]*) ;;
    *) return 1 ;;
  esac
  case "$window" in
    *[!A-Za-z0-9._:-]*) return 1 ;;
  esac
}

# What the wake must cause. nudge: a live worker is parked and needs one steer.
# respawn: the worker or role is gone and must be launched again. repeat: an
# action firstmate deferred and must simply retry.
fm_quota_freeze_action_valid() {
  case "${1-}" in
    nudge|respawn|repeat) return 0 ;;
  esac
  return 1
}

fm_quota_freeze_epoch_valid() {
  local value=${1-}
  local LC_ALL=C
  [[ "$value" =~ ^(0|[1-9][0-9]{0,18})$ ]]
}

fm_quota_freeze_resets_at_valid() {
  local value=${1-}
  local LC_ALL=C
  [ "$value" = unknown ] && return 0
  [ "${#value}" -le 64 ] || return 1
  [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,9})?(Z|[+-][0-9]{2}:?[0-9]{2})$ ]]
}

# The note is free-form but lands in a single-line record and, indirectly, in a
# watcher wake line, so control characters and length are bounded.
fm_quota_freeze_note_valid() {
  local note=${1-}
  local LC_ALL=C
  [ "${#note}" -le 200 ] || return 1
  case "$note" in
    *[[:cntrl:]]*) return 1 ;;
  esac
}

# Convert an ISO-8601 instant to a Unix epoch without depending on GNU or BSD
# date flags, both of which are wrong on the other platform. Prints nothing and
# fails when the input is not a valid instant; a caller that cannot resolve an
# epoch records 0, the explicit "no clock evidence" sentinel.
fm_quota_freeze_iso_epoch() {
  local iso=${1-} out
  fm_quota_freeze_resets_at_valid "$iso" || return 1
  [ "$iso" != unknown ] || return 1
  out=$(LC_ALL=C awk -v iso="$iso" '
    BEGIN {
      if (match(iso, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/) == 0) exit 1
      y = substr(iso, 1, 4) + 0
      mo = substr(iso, 6, 2) + 0
      d = substr(iso, 9, 2) + 0
      hh = substr(iso, 12, 2) + 0
      mi = substr(iso, 15, 2) + 0
      ss = substr(iso, 18, 2) + 0
      if (mo < 1 || mo > 12 || d < 1 || d > 31) exit 1
      if (hh > 23 || mi > 59 || ss > 60) exit 1
      rest = substr(iso, 20)
      sub(/^[.][0-9]+/, "", rest)
      off = 0
      if (rest != "Z" && rest != "") {
        sign = substr(rest, 1, 1)
        if (sign != "+" && sign != "-") exit 1
        body = substr(rest, 2)
        gsub(/:/, "", body)
        if (length(body) != 4) exit 1
        off = (substr(body, 1, 2) + 0) * 3600 + (substr(body, 3, 2) + 0) * 60
        if (sign == "-") off = -off
      } else if (rest == "") {
        exit 1
      }
      # Days from civil (proleptic Gregorian), so no libc date parsing is needed.
      yy = y - (mo <= 2 ? 1 : 0)
      era = int((yy >= 0 ? yy : yy - 399) / 400)
      yoe = yy - era * 400
      doy = int((153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      days = era * 146097 + doe - 719468
      printf "%d\n", days * 86400 + hh * 3600 + mi * 60 + ss - off
    }
  ') || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Render one record. The order is fixed and the parser below requires it, so a
# record written by a future version with extra or reordered fields is rejected
# rather than half-read.
fm_quota_freeze_record_render() {
  local subject=$1 kind=$2 provider=$3 window=$4 resets_at=$5 resets_epoch=$6 \
    action=$7 frozen_at=$8 note=$9
  printf '%s\n' fm-quota-freeze-v1
  printf 'subject=%s\n' "$subject"
  printf 'kind=%s\n' "$kind"
  printf 'provider=%s\n' "$provider"
  printf 'window=%s\n' "$window"
  printf 'resets_at=%s\n' "$resets_at"
  printf 'resets_at_epoch=%s\n' "$resets_epoch"
  printf 'action=%s\n' "$action"
  printf 'frozen_at=%s\n' "$frozen_at"
  printf 'note=%s\n' "$note"
}

fm_quota_freeze_record_parse() {
  local file=$1 version subject kind provider window resets_at resets_epoch \
    action frozen_at note
  FM_QUOTA_FREEZE_SUBJECT=
  FM_QUOTA_FREEZE_KIND=
  FM_QUOTA_FREEZE_PROVIDER=
  FM_QUOTA_FREEZE_WINDOW=
  FM_QUOTA_FREEZE_RESETS_AT=
  FM_QUOTA_FREEZE_RESETS_AT_EPOCH=
  FM_QUOTA_FREEZE_ACTION=
  FM_QUOTA_FREEZE_FROZEN_AT=
  FM_QUOTA_FREEZE_NOTE=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 7< "$file" || return 1
  if ! { IFS= read -r version <&7 && IFS= read -r subject <&7 && IFS= read -r kind <&7 \
    && IFS= read -r provider <&7 && IFS= read -r window <&7 \
    && IFS= read -r resets_at <&7 && IFS= read -r resets_epoch <&7 \
    && IFS= read -r action <&7 && IFS= read -r frozen_at <&7 \
    && IFS= read -r note <&7; }; then
    exec 7<&-
    return 1
  fi
  if IFS= read -r _extra <&7; then
    exec 7<&-
    return 1
  fi
  exec 7<&-

  [ "$version" = fm-quota-freeze-v1 ] || return 1
  subject=${subject#subject=}
  kind=${kind#kind=}
  provider=${provider#provider=}
  window=${window#window=}
  resets_at=${resets_at#resets_at=}
  resets_epoch=${resets_epoch#resets_at_epoch=}
  action=${action#action=}
  frozen_at=${frozen_at#frozen_at=}
  note=${note#note=}

  fm_quota_freeze_subject_valid "$subject" "$kind" || return 1
  [ "$subject" = "$(basename "$file")" ] || return 1
  fm_quota_freeze_provider_valid "$provider" || return 1
  fm_quota_freeze_window_valid "$window" || return 1
  fm_quota_freeze_resets_at_valid "$resets_at" || return 1
  fm_quota_freeze_epoch_valid "$resets_epoch" || return 1
  fm_quota_freeze_action_valid "$action" || return 1
  fm_quota_freeze_epoch_valid "$frozen_at" || return 1
  fm_quota_freeze_note_valid "$note" || return 1

  # shellcheck disable=SC2034  # the parsed record is the caller's output: bin/fm-quota-freeze.sh's list and show read these.
  FM_QUOTA_FREEZE_SUBJECT=$subject
  # shellcheck disable=SC2034
  FM_QUOTA_FREEZE_KIND=$kind
  # shellcheck disable=SC2034
  FM_QUOTA_FREEZE_PROVIDER=$provider
  # shellcheck disable=SC2034
  FM_QUOTA_FREEZE_WINDOW=$window
  # shellcheck disable=SC2034
  FM_QUOTA_FREEZE_RESETS_AT=$resets_at
  # shellcheck disable=SC2034
  FM_QUOTA_FREEZE_RESETS_AT_EPOCH=$resets_epoch
  # shellcheck disable=SC2034
  FM_QUOTA_FREEZE_ACTION=$action
  # shellcheck disable=SC2034
  FM_QUOTA_FREEZE_FROZEN_AT=$frozen_at
  # shellcheck disable=SC2034
  FM_QUOTA_FREEZE_NOTE=$note
}

# Create the registry directories with private modes, refusing a symlinked or
# hijacked path rather than writing an obligation somewhere unexpected.
fm_quota_freeze_dir_ensure() {
  local state=$1 dir notified
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  dir=$(fm_quota_freeze_dir "$state")
  notified=$(fm_quota_freeze_notified_dir "$state")
  [ ! -L "$dir" ] || return 1
  mkdir -p "$dir" || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  chmod 0700 "$dir" || return 1
  [ ! -L "$notified" ] || return 1
  mkdir -p "$notified" || return 1
  [ -d "$notified" ] && [ ! -L "$notified" ] || return 1
  chmod 0700 "$notified" || return 1
}

# Write one record atomically, then read it back through the same parser that
# the poll uses, so a record that cannot be parsed is never published.
fm_quota_freeze_record_write() {
  local state=$1 subject=$2 kind=$3 provider=$4 window=$5 resets_at=$6 \
    resets_epoch=$7 action=$8 frozen_at=$9 note=${10} dir dest tmp device rc=0
  fm_quota_freeze_subject_valid "$subject" "$kind" || return 1
  fm_quota_freeze_provider_valid "$provider" || return 1
  fm_quota_freeze_window_valid "$window" || return 1
  fm_quota_freeze_resets_at_valid "$resets_at" || return 1
  fm_quota_freeze_epoch_valid "$resets_epoch" || return 1
  fm_quota_freeze_action_valid "$action" || return 1
  fm_quota_freeze_epoch_valid "$frozen_at" || return 1
  fm_quota_freeze_note_valid "$note" || return 1
  fm_quota_freeze_dir_ensure "$state" || return 1
  dir=$(fm_quota_freeze_dir "$state")
  dest="$dir/$subject"
  device=$(fm_pr_file_device "$dir") || return 1
  fm_pr_regular_destination_on_device_or_absent "$dest" "$device" || return 1
  umask 077
  tmp=$(mktemp "$dir/.fm-quota-freeze.XXXXXX") || return 1
  if ! fm_quota_freeze_record_render "$subject" "$kind" "$provider" "$window" \
      "$resets_at" "$resets_epoch" "$action" "$frozen_at" "$note" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_regular_destination_on_device_or_absent "$dest" "$device" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
  fm_pr_private_file_valid "$dest" 600 "$device" || rc=1
  fm_quota_freeze_record_parse "$dest" || rc=1
  [ "$rc" -eq 0 ] || rm -f -- "$dest"
  return "$rc"
}

# Every valid record in the registry, one subject per line, sorted. Invalid or
# unreadable entries are skipped here and reported separately by the CLI, so a
# single corrupt file cannot hide the rest of the queue.
fm_quota_freeze_subjects() {
  local state=$1 dir rec subject
  dir=$(fm_quota_freeze_dir "$state")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  for rec in "$dir"/*; do
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    subject=${rec##*/}
    fm_quota_freeze_record_parse "$rec" >/dev/null 2>&1 || continue
    printf '%s\n' "$subject"
  done | LC_ALL=C sort
}

fm_quota_freeze_count() {
  local state=$1 dir rec n=0
  dir=$(fm_quota_freeze_dir "$state")
  [ -d "$dir" ] && [ ! -L "$dir" ] || { printf '0\n'; return 0; }
  for rec in "$dir"/*; do
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# Remove one obligation and the marker that suppressed its repeat wakes.
fm_quota_freeze_record_remove() {
  local state=$1 subject=$2 dir notified
  fm_task_id_path_safe "$subject" || return 1
  dir=$(fm_quota_freeze_dir "$state")
  notified=$(fm_quota_freeze_notified_dir "$state")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ -e "$dir/$subject" ] || [ -L "$dir/$subject" ] || return 1
  rm -f -- "$dir/$subject" "$notified/$subject" || return 1
  [ ! -e "$dir/$subject" ] && [ ! -L "$dir/$subject" ]
}

# Render the generated, self-contained poll. Only the state directory and the
# three tuning constants are baked in as %q-quoted literals: fm-watch.sh's
# custom-check dispatch runs an armed check with no arguments and no reliable
# "$0", so the poll has nowhere else to learn where its own registry lives. The
# obligations themselves are read from disk and revalidated on every execution,
# never trusted from this script's bytes.
fm_quota_reset_poll_render() {
  local state=$1 qstate qid
  printf -v qstate '%q' "$state"
  printf -v qid '%q' "$FM_QUOTA_RESET_POLL_ID"
  cat <<EOF
#!/usr/bin/env bash
# Generated by bin/fm-quota-freeze.sh. Watches every obligation in
# state/quota-frozen/ and wakes firstmate when the window that froze the work
# has genuinely recovered, verified from a fresh quota-axi reading rather than
# from the recorded reset time. Silent while every obligation is still frozen.
# This file's exact bytes are hash-bound by state/$FM_QUOTA_RESET_POLL_ID.check-trust
# (bin/fm-check-register.sh contract); do not hand-edit it, re-run
# bin/fm-quota-freeze.sh instead.
set -u
LC_ALL=C
export LC_ALL

STATE_DIR=$qstate
POLL_ID=$qid
FLOOR=$FM_QUOTA_RESET_FLOOR
RESURFACE=$FM_QUOTA_RESET_RESURFACE_SECS
UNVERIFIED_GRACE=$FM_QUOTA_RESET_UNVERIFIED_GRACE_SECS
DIR="\$STATE_DIR/quota-frozen"
NOTIFIED="\$DIR/.notified"
CHECK="\$STATE_DIR/\$POLL_ID.check.sh"
TRUST="\$STATE_DIR/\$POLL_ID.check-trust"

# An absent registry means every obligation was discharged; retire rather than
# poll a directory that will never produce work again.
if [ ! -d "\$DIR" ] || [ -L "\$DIR" ]; then
  rm -f -- "\$CHECK" "\$TRUST" 2>/dev/null
  exit 0
fi

now=\$(date +%s 2>/dev/null) || exit 0
case "\$now" in
  ''|*[!0-9]*) exit 0 ;;
esac

QUOTA_JSON=
QUOTA_TRIED=0
quota_snapshot() {
  [ "\$QUOTA_TRIED" -eq 0 ] || return 0
  QUOTA_TRIED=1
  command -v quota-axi >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  if command -v timeout >/dev/null 2>&1; then
    QUOTA_JSON=\$(timeout 20 quota-axi --json 2>/dev/null </dev/null) || QUOTA_JSON=
  elif command -v gtimeout >/dev/null 2>&1; then
    QUOTA_JSON=\$(gtimeout 20 quota-axi --json 2>/dev/null </dev/null) || QUOTA_JSON=
  else
    QUOTA_JSON=\$(quota-axi --json 2>/dev/null </dev/null) || QUOTA_JSON=
  fi
}

# Echo the window's percentRemaining, or a reason token when the reading cannot
# support a recovery claim. A stale provider reading is deliberately NOT
# evidence: it is the same number as before the reset, and acting on it would
# reintroduce exactly the guesswork this poll replaces. Freshness is tested as
# "stale is explicitly false" rather than through jq's alternative operator,
# which treats the false this test is looking for as an absent value.
window_remaining() {
  local provider=\$1 window=\$2 out
  quota_snapshot
  [ -n "\$QUOTA_JSON" ] || { printf 'unreadable\\n'; return 0; }
  out=\$(printf '%s' "\$QUOTA_JSON" | jq -r --arg p "\$provider" --arg w "\$window" '
      [ .providers[]? | select(.provider == \$p) ] as \$ps
      | if (\$ps | length) == 0 then "absent"
        elif (\$ps[0].state.stale != false) then "stale"
        else
          ([ \$ps[0].windows[]? | select(.id == \$w) ]) as \$ws
          | if (\$ws | length) == 0 then "absent"
            elif (\$ws[0].percentRemaining == null) then "absent"
            else (\$ws[0].percentRemaining | tostring)
            end
        end' 2>/dev/null) || { printf 'unreadable\\n'; return 0; }
  [ -n "\$out" ] || { printf 'unreadable\\n'; return 0; }
  printf '%s\\n' "\$out"
}

# Read one record and decide what, if anything, firstmate should be told about
# it. Echoes "<provider>/<window>,<verdict>" when it should be surfaced and
# nothing when it should stay quiet. A record this cannot parse is surfaced as
# unreadable rather than skipped: an obligation nobody can read is still an
# obligation, and silently stepping over it is the exact stall this poll exists
# to remove.
evaluate_record() {  # <record-path> <subject>
  local rec=\$1 subject=\$2 provider window epoch remaining
  local f_version f_subject f_kind f_provider f_window f_resets f_epoch f_action f_frozen f_note f_extra
  { exec 7< "\$rec"; } 2>/dev/null || { printf 'unreadable\\n'; return 0; }
  if ! { IFS= read -r f_version <&7 && IFS= read -r f_subject <&7 && IFS= read -r f_kind <&7 \\
    && IFS= read -r f_provider <&7 && IFS= read -r f_window <&7 \\
    && IFS= read -r f_resets <&7 && IFS= read -r f_epoch <&7 \\
    && IFS= read -r f_action <&7 && IFS= read -r f_frozen <&7 \\
    && IFS= read -r f_note <&7; }; then
    exec 7<&-
    printf 'unreadable\\n'
    return 0
  fi
  if IFS= read -r f_extra <&7; then
    exec 7<&-
    printf 'unreadable\\n'
    return 0
  fi
  exec 7<&-

  provider=\${f_provider#provider=}
  window=\${f_window#window=}
  epoch=\${f_epoch#resets_at_epoch=}
  if [ "\$f_version" != fm-quota-freeze-v1 ] || [ "\$f_subject" != "subject=\$subject" ]; then
    printf 'unreadable\\n'
    return 0
  fi
  case "\$provider" in
    ''|*[!a-z0-9._-]*) printf 'unreadable\\n'; return 0 ;;
  esac
  case "\$window" in
    ''|*[!A-Za-z0-9._:-]*) printf 'unreadable\\n'; return 0 ;;
  esac
  case "\$epoch" in
    ''|*[!0-9]*) printf 'unreadable\\n'; return 0 ;;
  esac

  remaining=\$(window_remaining "\$provider" "\$window")
  case "\$remaining" in
    ''|*[!0-9.]*)
      # No usable number: absent, stale, or unreadable. Report it only once the
      # recorded reset is well past, so a limit quota-axi cannot see (grok's
      # weekly cap behind its credits window) surfaces as an explicitly
      # unverified obligation instead of silence forever.
      if [ "\$epoch" -gt 0 ] && [ "\$now" -ge "\$((epoch + UNVERIFIED_GRACE))" ]; then
        printf '%s/%s,unverified\\n' "\$provider" "\$window"
      fi
      ;;
    *)
      if awk -v a="\$remaining" -v b="\$FLOOR" 'BEGIN { exit !(a + 0 >= b + 0) }'; then
        printf '%s/%s,recovered\\n' "\$provider" "\$window"
      fi
      ;;
  esac
}

ready=
to_mark=
records=0

for rec in "\$DIR"/*; do
  [ -f "\$rec" ] && [ ! -L "\$rec" ] || continue
  subject=\${rec##*/}
  case "\$subject" in
    ''|.*|*[!A-Za-z0-9._-]*) continue ;;
  esac
  records=\$((records + 1))

  marker="\$NOTIFIED/\$subject"
  if [ -f "\$marker" ] && [ ! -L "\$marker" ]; then
    marked=\$(cat "\$marker" 2>/dev/null) || marked=
    case "\$marked" in
      ''|*[!0-9]*) marked=\$now ;;
    esac
    [ "\$((now - marked))" -ge "\$RESURFACE" ] || continue
  fi

  verdict=\$(evaluate_record "\$rec" "\$subject")
  [ -n "\$verdict" ] || continue
  ready="\$ready \$subject(\$verdict)"
  to_mark="\$to_mark \$subject"
done

# Print first, with no preceding side effect that could fail or be interrupted,
# so a reset event can never be silently lost. Marking is best effort after it;
# at worst an interruption here costs one duplicate wake next cycle.
if [ -n "\$ready" ]; then
  printf 'quota reset ready:%s\\n' "\$ready"
  umask 077
  if [ -d "\$NOTIFIED" ] && [ ! -L "\$NOTIFIED" ]; then
    for subject in \$to_mark; do
      marker="\$NOTIFIED/\$subject"
      [ ! -L "\$marker" ] || continue
      if tmp=\$(mktemp "\$NOTIFIED/.fm-quota-notified.XXXXXX" 2>/dev/null); then
        if printf '%s\\n' "\$now" > "\$tmp" 2>/dev/null && chmod 0600 "\$tmp" 2>/dev/null; then
          mv -f -- "\$tmp" "\$marker" 2>/dev/null || rm -f -- "\$tmp" 2>/dev/null
        else
          rm -f -- "\$tmp" 2>/dev/null
        fi
      fi
    done
  fi
fi

# Retire only when nothing is owed. An obligation that was surfaced but never
# discharged keeps this poll armed, so it re-surfaces every RESURFACE seconds
# instead of going quiet after one wake.
if [ "\$records" -eq 0 ]; then
  rm -f -- "\$CHECK" "\$TRUST" 2>/dev/null
fi
exit 0
EOF
}

fm_quota_reset_poll_cleanup() {
  [ -z "$FM_QUOTA_RESET_POLL_CHECK_TMP" ] || rm -f -- "$FM_QUOTA_RESET_POLL_CHECK_TMP"
  [ -z "$FM_QUOTA_RESET_POLL_TRUST_TMP" ] || rm -f -- "$FM_QUOTA_RESET_POLL_TRUST_TMP"
  FM_QUOTA_RESET_POLL_CHECK_TMP=
  FM_QUOTA_RESET_POLL_TRUST_TMP=
}

fm_quota_reset_poll_revoke_final() {
  local failed=0
  if [ -e "$FM_QUOTA_RESET_POLL_CHECK_DEST" ] || [ -L "$FM_QUOTA_RESET_POLL_CHECK_DEST" ]; then
    rm -f -- "$FM_QUOTA_RESET_POLL_CHECK_DEST" || failed=1
  fi
  if [ -e "$FM_QUOTA_RESET_POLL_TRUST_DEST" ] || [ -L "$FM_QUOTA_RESET_POLL_TRUST_DEST" ]; then
    rm -f -- "$FM_QUOTA_RESET_POLL_TRUST_DEST" || failed=1
  fi
  return "$failed"
}

fm_quota_reset_poll_prepare() {
  local state=$1 hash
  [ ! -L "$state" ] || return 1
  mkdir -p "$state" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  umask 077
  FM_QUOTA_RESET_POLL_STATE=$state
  FM_QUOTA_RESET_POLL_CHECK_DEST="$state/$FM_QUOTA_RESET_POLL_ID.check.sh"
  FM_QUOTA_RESET_POLL_TRUST_DEST="$state/$FM_QUOTA_RESET_POLL_ID.check-trust"
  FM_QUOTA_RESET_POLL_STATE_DEVICE=$(fm_pr_file_device "$state") || return 1
  [ -n "$FM_QUOTA_RESET_POLL_STATE_DEVICE" ] || return 1

  FM_QUOTA_RESET_POLL_CHECK_TMP=$(mktemp "$state/.fm-quota-reset-check.XXXXXX") || return 1
  FM_QUOTA_RESET_POLL_TRUST_TMP=$(mktemp "$state/.fm-quota-reset-trust.XXXXXX") || {
    fm_quota_reset_poll_cleanup
    return 1
  }
  if ! fm_quota_reset_poll_render "$state" > "$FM_QUOTA_RESET_POLL_CHECK_TMP" \
    || ! chmod 0700 "$FM_QUOTA_RESET_POLL_CHECK_TMP" \
    || ! fm_pr_private_file_valid "$FM_QUOTA_RESET_POLL_CHECK_TMP" 700 "$FM_QUOTA_RESET_POLL_STATE_DEVICE" \
    || ! bash -n "$FM_QUOTA_RESET_POLL_CHECK_TMP"; then
    fm_quota_reset_poll_cleanup
    return 1
  fi
  hash=$(fm_custom_check_sha256 "$FM_QUOTA_RESET_POLL_CHECK_TMP") || {
    fm_quota_reset_poll_cleanup
    return 1
  }
  if ! printf '%s\n%s\n' fm-custom-check-v1 "$hash" > "$FM_QUOTA_RESET_POLL_TRUST_TMP" \
    || ! chmod 0600 "$FM_QUOTA_RESET_POLL_TRUST_TMP" \
    || ! fm_pr_private_file_valid "$FM_QUOTA_RESET_POLL_TRUST_TMP" 600 "$FM_QUOTA_RESET_POLL_STATE_DEVICE"; then
    fm_quota_reset_poll_cleanup
    return 1
  fi
}

fm_quota_reset_poll_publish_prepared() {
  [ -n "$FM_QUOTA_RESET_POLL_CHECK_TMP" ] && [ -n "$FM_QUOTA_RESET_POLL_TRUST_TMP" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_QUOTA_RESET_POLL_TRUST_DEST" "$FM_QUOTA_RESET_POLL_STATE_DEVICE" || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_QUOTA_RESET_POLL_CHECK_DEST" "$FM_QUOTA_RESET_POLL_STATE_DEVICE" || return 1

  if ! mv -f -- "$FM_QUOTA_RESET_POLL_TRUST_TMP" "$FM_QUOTA_RESET_POLL_TRUST_DEST"; then
    fm_quota_reset_poll_revoke_final || true
    return 1
  fi
  FM_QUOTA_RESET_POLL_TRUST_TMP=
  if ! fm_pr_regular_destination_on_device_or_absent "$FM_QUOTA_RESET_POLL_CHECK_DEST" "$FM_QUOTA_RESET_POLL_STATE_DEVICE" \
    || ! mv -f -- "$FM_QUOTA_RESET_POLL_CHECK_TMP" "$FM_QUOTA_RESET_POLL_CHECK_DEST"; then
    fm_quota_reset_poll_revoke_final || true
    return 1
  fi
  FM_QUOTA_RESET_POLL_CHECK_TMP=
  if ! fm_custom_check_registered "$FM_QUOTA_RESET_POLL_STATE" "$FM_QUOTA_RESET_POLL_ID"; then
    fm_quota_reset_poll_revoke_final || true
    return 1
  fi
}

fm_quota_reset_poll_armed() {
  local state=$1
  fm_custom_check_registered "$state" "$FM_QUOTA_RESET_POLL_ID"
}

# Retire the poll, but only when the armed check is byte-identical to what this
# version renders for this state directory. The check slot is shared with every
# other custom check, so a slot some other owner has taken keeps its artifacts.
fm_quota_reset_poll_retire() {
  local state=$1 check trust
  check="$state/$FM_QUOTA_RESET_POLL_ID.check.sh"
  trust="$state/$FM_QUOTA_RESET_POLL_ID.check-trust"
  if [ ! -e "$check" ] && [ ! -L "$check" ]; then
    rm -f -- "$trust" || return 1
    return 0
  fi
  [ -f "$check" ] && [ ! -L "$check" ] || return 1
  fm_quota_reset_poll_render "$state" | cmp -s - "$check" || return 1
  rm -f -- "$check" "$trust" || return 1
  [ ! -e "$check" ] && [ ! -L "$check" ]
}
