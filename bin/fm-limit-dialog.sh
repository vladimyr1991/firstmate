#!/usr/bin/env bash
# Answer a worker's usage-limit dialog by choosing "wait", never "upgrade", and
# record the resulting freeze so the fleet resumes itself when the window comes
# back.
# Usage: fm-limit-dialog.sh <task-id> [--provider <p>] [--action <a>]
#                          [--detect-only] [--from-capture <file>] [--lines <n>]
#
# A worker that exhausts its own window parks on an interactive choice - one
# option waits for the reset, another buys more capacity - and stays parked
# until a human answers it. Answering it is mechanical; what makes it dangerous
# to automate is that the wrong option spends the captain's money. So the
# selection here is never positional and never guessed: the options are read
# out of the pane, exactly one must identify itself as the waiting option, and
# anything ambiguous is refused with no keystroke sent at all. The upgrade
# option is never selected by this script under any circumstance - that is the
# captain's decision, not an automation's.
#
# Choosing "wait" only unblocks the pane; it does not make the work resume when
# the limit lifts. The freeze registry (bin/fm-quota-freeze.sh) is what does
# that, which is why arming it is part of answering the dialog rather than a
# separate step someone has to remember.
#
# The dialog shape is matched by option TEXT, not by a per-harness template:
# firstmate supports seven harnesses and the wording differs between them and
# across their versions, so a positional or vendor-specific matcher would be
# both unverifiable and unsafe. Refusing on anything ambiguous is what keeps an
# unrecognized variant harmless.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# Sourced for fm_quota_freeze_provider_valid alone: the provider this script
# accepts and the provider the registry accepts must be one definition, or a
# provider fm-quota-freeze.sh would take gets refused here before any keystroke.
# shellcheck source=bin/fm-quota-freeze-lib.sh
. "$SCRIPT_DIR/fm-quota-freeze-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-limit-dialog.sh <task-id> [--provider <p>] [--action <a>]
                          [--detect-only] [--from-capture <file>] [--lines <n>]

Detects a worker parked on a usage-limit dialog, answers it by selecting the
option that waits for the reset, and records the freeze that makes the work
resume by itself once the window recovers.

  <task-id>        the parked task, resolved through state/<task-id>.meta
  --provider       the quota-axi provider whose window is exhausted (claude,
                   codex, grok, ...). With it, the resume is armed immediately;
                   without it the dialog is still answered and the command
                   exits 4 so the freeze can be recorded separately. The
                   provider is never inferred from the harness or model name
  --action         what the resume must cause (nudge, respawn, repeat);
                   defaults to nudge, since a worker that waited is still alive
                   and only needs one steer
  --detect-only    report what was found and send nothing
  --from-capture   read pane text from a file instead of capturing it live
  --lines          how many pane lines to capture (default 60)

Exit codes:
  0  the dialog was answered and, when a provider was given, the resume armed
  1  no dialog detected, or answering it failed
  2  usage error
  3  a dialog was found but its options are ambiguous; nothing was sent
  4  the dialog was answered but no resume was armed

The upgrade option is never selected. If exactly one option does not identify
itself as the waiting option, this refuses with exit 3 and sends no keystroke.
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

ID=
PROVIDER=
ACTION=nudge
DETECT_ONLY=0
FROM_CAPTURE=
LINES=60

if [ "$#" -eq 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
  usage
  exit 0
fi
[ "$#" -ge 1 ] || { usage >&2; exit 2; }
ID=$1
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --provider) [ "$#" -ge 2 ] || usage_error "--provider requires a value"; PROVIDER=$2; shift 2 ;;
    --action) [ "$#" -ge 2 ] || usage_error "--action requires a value"; ACTION=$2; shift 2 ;;
    --detect-only) DETECT_ONLY=1; shift ;;
    --from-capture) [ "$#" -ge 2 ] || usage_error "--from-capture requires a path"; FROM_CAPTURE=$2; shift 2 ;;
    --lines)
      [ "$#" -ge 2 ] || usage_error "--lines requires a count"
      case "$2" in ''|*[!0-9]*|0) usage_error "--lines must be a positive integer" ;; esac
      LINES=$2; shift 2 ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done
case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) usage_error "invalid task id: $ID" ;;
esac
case "$ACTION" in
  nudge|respawn|repeat) ;;
  *) usage_error "invalid action: $ACTION" ;;
esac
# Validated here rather than left to fm-quota-freeze.sh, which only sees it
# after the keystroke has already been sent: a usage error discovered then would
# leave an answered dialog with no resume armed. The check itself is the
# registry's own, called rather than copied.
if [ -n "$PROVIDER" ]; then
  fm_quota_freeze_provider_valid "$PROVIDER" || usage_error "invalid provider: $PROVIDER"
fi

# Normalize one captured pane into plain text: drop terminal escape sequences
# and the right-hand frame glyph harnesses draw their dialogs with, so option
# matching sees the words rather than the chrome. Left-hand decoration is
# handled by the option pattern itself rather than by a character-class sweep,
# which is not portable across sed implementations for multibyte glyphs.
normalize() {
  sed $'s/\033\\[[0-9;?]*[a-zA-Z]//g' \
    | sed -E 's/[[:space:]]*(│|┃|║|\|)[[:space:]]*$//' \
    | sed 's/[[:space:]]*$//'
}

# A limit dialog must announce a limit somewhere in the pane. Requiring this
# context line keeps an ordinary numbered menu ("1. yes / 2. no") from ever
# being treated as a limit dialog.
has_limit_context() {
  grep -qiE 'limit' "$1" \
    && grep -qiE 'limit[^.]*(reset|reach|exceed)|(reach|hit|exceed)[^.]*limit' "$1"
}

# Emit "<number>\t<text>" for each numbered option in the pane.
options_of() {
  sed -nE 's/^[^A-Za-z0-9]*([0-9]{1,2})[.)][[:space:]]+([^[:space:]].*)$/\1\t\2/p' "$1"
}

is_wait_option() {
  printf '%s' "$1" | grep -qiE 'wait' \
    && printf '%s' "$1" | grep -qiE 'reset|limit'
}

# Anything that could cost money. An option matching this is never selected,
# even if it also mentions waiting.
is_paid_option() {
  printf '%s' "$1" | grep -qiE 'upgrade|buy|purchase|subscribe|billing|payment|checkout|credit card|add (funds|credits)'
}

CAPTURE=$(mktemp "${TMPDIR:-/tmp}/fm-limit-dialog.XXXXXX")
CAPTURE2=$(mktemp "${TMPDIR:-/tmp}/fm-limit-dialog.XXXXXX")
trap 'rm -f -- "$CAPTURE" "$CAPTURE2"' EXIT
trap 'exit 1' HUP INT TERM

# How much recent output the post-answer confirmation looks at. There is NO
# portable "visible pane only" bound across the five backends: tmux reads it as
# scrollback depth above the live pane, herdr/zellij/cmux end their capture in
# `tail -n "$lines"`, and orca forwards the number as `--limit`. A count of 0
# would therefore mean "visible pane" on tmux and "nothing at all" on three of
# the others, so this is a small POSITIVE bound every backend honours - a sample
# of recent output, not a statement about what is on screen. That is why the
# confirmation below is strictly advisory and never decides an exit code.
CONFIRM_LINES=12

# Returns non-zero instead of dying when <required> is not "required", for the
# one caller that runs after the durable work is committed and therefore may not
# turn a capture failure into a failed-answer verdict.
capture_pane() {  # <destination> [lines] [required|optional]
  local dest=$1 lines=${2:-$LINES} required=${3:-required} target backend label raw
  if [ -n "$FROM_CAPTURE" ]; then
    [ -f "$FROM_CAPTURE" ] || die "capture file does not exist: $FROM_CAPTURE"
    normalize < "$FROM_CAPTURE" > "$dest"
    return 0
  fi
  if ! target=$(fm_backend_resolve_selector "$ID" "$STATE"); then
    [ "$required" = required ] || return 1
    die "could not resolve the worker's endpoint for $ID"
  fi
  backend=$(fm_backend_of_selector "$ID" "$target" "$STATE")
  label=$(fm_backend_expected_label_of_selector "$ID" "$STATE")
  if ! raw=$(fm_backend_capture "$backend" "$target" "$lines" "$label" 2>/dev/null); then
    [ "$required" = required ] || return 1
    die "could not read the worker's screen for $ID"
  fi
  printf '%s\n' "$raw" | normalize > "$dest"
}

# Fills WAIT_NUMBER/WAIT_TEXT/OTHER_OPTIONS. Returns 0 when exactly one option
# unambiguously waits, 1 when there is no dialog, 2 when a dialog is present but
# its options cannot be told apart safely.
WAIT_NUMBER=
WAIT_TEXT=
OTHER_OPTIONS=
scan() {  # <capture>
  local file=$1 number text matches=0 seen='' key
  WAIT_NUMBER=
  WAIT_TEXT=
  OTHER_OPTIONS=
  has_limit_context "$file" || return 1
  while IFS=$(printf '\t') read -r number text; do
    [ -n "$number" ] || continue
    # The capture is scrollback, so a dialog redrawn (a resize, a repaint)
    # appears more than once. An identical option is the same option, not a
    # second one; without this a repainted pane would read as ambiguous and
    # refuse every time. Two DIFFERENT wait-shaped options still refuse.
    key="|$number=$text|"
    case "$seen" in
      *"$key"*) continue ;;
    esac
    seen="$seen$key"
    if is_wait_option "$text" && ! is_paid_option "$text"; then
      matches=$((matches + 1))
      WAIT_NUMBER=$number
      WAIT_TEXT=$text
    else
      OTHER_OPTIONS="$OTHER_OPTIONS $number=$text"
    fi
  done < <(options_of "$file")
  [ -n "$OTHER_OPTIONS" ] || [ "$matches" -gt 0 ] || return 1
  [ "$matches" -eq 1 ] || return 2
  return 0
}

capture_pane "$CAPTURE"
set +e
scan "$CAPTURE"
SCAN_RC=$?
set -e

case "$SCAN_RC" in
  1)
    printf 'limit-dialog: not detected\n'
    exit 1 ;;
  2)
    printf 'limit-dialog: detected but ambiguous; no key was sent\n' >&2
    printf 'options:%s\n' "$OTHER_OPTIONS" >&2
    exit 3 ;;
esac

# Belt and braces before any keystroke leaves this script: the selection must
# still read as the waiting option and must not read as a paid one. This is the
# last gate before money can be spent, so it does not trust the scan above.
case "$WAIT_NUMBER" in
  ''|*[!0-9]*) die "the selected option is not a plain number" ;;
esac
[ "${#WAIT_NUMBER}" -le 2 ] || die "the selected option number is out of range"
is_wait_option "$WAIT_TEXT" || die "the selected option no longer reads as the waiting option"
! is_paid_option "$WAIT_TEXT" || die "refusing to select an option that could spend money"

printf 'limit-dialog: detected\n'
printf 'wait-option: %s\n' "$WAIT_NUMBER"
printf 'wait-text: %s\n' "$WAIT_TEXT"
[ -z "$OTHER_OPTIONS" ] || printf 'other-options:%s\n' "$OTHER_OPTIONS"

if [ "$DETECT_ONLY" -eq 1 ]; then
  exit 0
fi
if [ -n "$FROM_CAPTURE" ]; then
  die "--from-capture reads a saved screen and cannot answer a live dialog; add --detect-only"
fi

SEND_RC=0
FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$ID" "$WAIT_NUMBER" >/dev/null 2>&1 || SEND_RC=$?
if [ "$SEND_RC" -eq 0 ]; then
  printf 'selected: %s (%s)\n' "$WAIT_NUMBER" "$WAIT_TEXT"
else
  printf 'warning: the wait selection was not confirmed by the worker runtime\n' >&2
fi

# The obligation is recorded whether or not the keystroke confirmed: the work is
# frozen either way, and an unrecorded freeze is the failure this whole path
# exists to prevent.
FREEZE_RC=0
if [ -n "$PROVIDER" ]; then
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-quota-freeze.sh" add \
    --subject "$ID" --kind task --provider "$PROVIDER" --action "$ACTION" \
    --note "waited on a usage-limit dialog" || FREEZE_RC=$?
fi

if [ "$SEND_RC" -ne 0 ]; then
  exit 1
fi

# Only now, after the durable part is done, look at whether the dialog cleared -
# over a much smaller slice of recent output than detection reads, because the
# full scrollback still holds the pre-answer render of the very dialog just
# answered (which is why scan() dedupes repaints at all) and would answer "still
# there" every time.
#
# Everything from here on is ADVISORY. The key was sent, the submit was
# confirmed by the worker runtime, and the freeze is recorded; per the commit
# invariant in bin/fm-quota-freeze-lib.sh's header, no step after that may
# report the answer as having failed. A pane that has not repainted yet, a
# closed window, and a backend that cannot be read are all warnings: telling the
# caller to re-answer an answered dialog types a second selection into a live
# composer, which is the worse outcome by far.
CLEARED_RC=1
set +e
capture_pane "$CAPTURE2" "$CONFIRM_LINES" optional
CONFIRM_CAPTURE_RC=$?
if [ "$CONFIRM_CAPTURE_RC" -eq 0 ]; then
  scan "$CAPTURE2"
  CLEARED_RC=$?
fi
set -e
if [ "$CONFIRM_CAPTURE_RC" -ne 0 ]; then
  printf 'warning: could not re-read the pane for %s to confirm the dialog cleared; the selection was sent and the freeze recorded regardless\n' \
    "$ID" >&2
elif [ "$CLEARED_RC" -ne 1 ]; then
  printf 'warning: the limit dialog is still in the pane output; the selection was sent and the freeze recorded, so verify the pane rather than re-answering it\n' >&2
fi

if [ -z "$PROVIDER" ]; then
  printf 'note: no resume was armed; record the freeze with fm-quota-freeze.sh add once the exhausted provider is established\n' >&2
  exit 4
fi
# The freeze script has its own exit table (a contested check slot is 3 there,
# an ambiguous dialog is 3 here), so its code is never propagated verbatim: a
# caller reading 3 would believe no keystroke was sent. Every failure to arm is
# reported as the one thing that actually happened - the dialog was answered and
# no resume was armed - with the child's own error already on stderr.
if [ "$FREEZE_RC" -ne 0 ]; then
  printf 'note: the dialog was answered but recording the freeze failed (fm-quota-freeze.sh add exited %s); no resume was armed\n' \
    "$FREEZE_RC" >&2
  exit 4
fi
exit 0
