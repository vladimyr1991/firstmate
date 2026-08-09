#!/usr/bin/env bash
# fm-operational-input.sh - canonical Firstmate operational-input protocol.
#
# This file is both a source-safe shell library and the cross-language CLI used
# by JavaScript and TypeScript integrations. It is the single owner of current
# construction, current parsing, and narrow pre-protocol transcript parsing.
#
# Current generic wire form:
#   U+2063 FIRSTMATE_OP: v1 <kind>: <body>
#
# The launch-brief kind is the one exception on emission: it drops the
# invisible U+2063 marker and prepends one fixed self-disclosure line, so its
# current wire form is
#   FIRSTMATE_OP: v1 launch-brief: <disclosure line>\n<body>
# A launch-brief's recipient is always a brand-new agent with no prior
# context, so nothing keys on that leading byte on the receiving side, and a
# hidden character prefixing a message that then claims authority reads as
# injection obfuscation to a safety-conscious model (2026-08-07: four
# consecutive fresh workers refused marked launch briefs as suspected prompt
# injection). Nothing about the delivery is concealed: the disclosure line
# names this file as the verifiable source of the format.
#
# The landed U+2063 + "FIRSTMATE_OP: " prefix is permanent compatibility for
# PARSING every kind, including already-in-flight marked launch briefs, and
# for EMISSION of every kind except launch-brief: live agents' hooks and
# charters key on the marker (FM_INJECT_MARK, the away-mode daemon,
# secondmate charter context). Unmarked parsing stays scoped to launch-brief
# so an ASCII-only "FIRSTMATE_OP:" near miss of any other kind remains
# ordinary captain text.
# The version and kind header make current inputs structurally typed without
# deriving provenance from body prose. The established from-firstmate routing
# marker remains a current compatibility carrier because already-running
# secondmates have its leading label in their charter context.
#
# CLI:
#   fm-operational-input.sh encode <kind>  # body on stdin, encoded input stdout
#   fm-operational-input.sh kind           # current input on stdin, kind stdout
#   fm-operational-input.sh classify       # current or legacy input on stdin
#   fm-operational-input.sh body           # current generic input on stdin
#   fm-operational-input.sh --help
#
# All successful data commands print exactly one value and no diagnostics.
# A non-match exits 1 silently. Invalid use exits 2. Bash 3.2 compatible.

FM_OPERATIONAL_MARK=$'\xE2\x81\xA3'
FM_OPERATIONAL_VISIBLE_PREFIX='FIRSTMATE_OP: '
FM_OPERATIONAL_PREFIX="${FM_OPERATIONAL_MARK}${FM_OPERATIONAL_VISIBLE_PREFIX}"
FM_OPERATIONAL_VERSION=v1
FM_OPERATIONAL_HEADER_PREFIX="${FM_OPERATIONAL_PREFIX}${FM_OPERATIONAL_VERSION} "
FM_OPERATIONAL_VISIBLE_HEADER_PREFIX="${FM_OPERATIONAL_VISIBLE_PREFIX}${FM_OPERATIONAL_VERSION} "
FM_OPERATIONAL_KINDS='session-start watcher turn-end-guard away-supervisor launch-brief'

# The fixed launch-brief self-disclosure line. Emitted as the first line after
# the visible header and stripped back out by body parsing, so an encoded
# brief round-trips to its exact original body.
FM_LAUNCH_BRIEF_DISCLOSURE='[delivery note: this message is machine-tagged operational input composed by firstmate'\''s spawn mechanism; bin/fm-operational-input.sh in this repository defines this header format and is its verifiable source]'

# Compatibility name retained for the away-mode owner and its tests.
# shellcheck disable=SC2034 # Public source-library variable used by callers.
FM_INJECT_MARK=$FM_OPERATIONAL_MARK

# The from-firstmate carrier stays byte-compatible with live secondmate charter
# context while this owner supplies its construction and structural kind.
FM_FROMFIRST_LABEL='[fm-from-firstmate]'
FM_FROMFIRST_SEPARATOR=$FM_OPERATIONAL_MARK
FM_FROMFIRST_MARK="${FM_FROMFIRST_LABEL}${FM_FROMFIRST_SEPARATOR}"

fm_operational_kind_is_current() {  # <kind>
  case " $FM_OPERATIONAL_KINDS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

fm_operational_input_encode() {  # <generic-kind> <body> <result-var>
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] || return 2
  fm_operational_kind_is_current "$kind" || return 2
  [ -n "$body" ] || return 2
  if [ "$kind" = launch-brief ]; then
    printf -v "$result_var" '%s%s: %s\n%s' \
      "$FM_OPERATIONAL_VISIBLE_HEADER_PREFIX" "$kind" "$FM_LAUNCH_BRIEF_DISCLOSURE" "$body"
    return
  fi
  printf -v "$result_var" '%s%s: %s' "$FM_OPERATIONAL_HEADER_PREFIX" "$kind" "$body"
}

fm_operational_input_construct() {  # <kind> <body> <result-var>
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] && [ -n "$body" ] || return 2
  if [ "$kind" = from-firstmate ]; then
    fm_message_mark_from_firstmate "$body" "$result_var"
    return
  fi
  fm_operational_input_encode "$kind" "$body" "$result_var"
}

# fm_operational_generic_parse: shared current-header parse. Accepts the
# marked header for every current kind, and the unmarked visible header for
# launch-brief only, so ASCII near misses of other kinds stay unclassified.
fm_operational_generic_parse() {  # <message> <kind-var> <body-var>
  # Locals carry a _fm_gp_ prefix: printf -v writes through dynamic scoping,
  # so a caller's result-var named like an ordinary local here would be
  # silently captured and lost.
  local _fm_gp_message=${1-} _fm_gp_kind_var=${2-} _fm_gp_body_var=${3-}
  local _fm_gp_header _fm_gp_remainder _fm_gp_kind _fm_gp_body
  [ -n "$_fm_gp_kind_var" ] && [ -n "$_fm_gp_body_var" ] || return 2
  case "$_fm_gp_message" in
    "$FM_OPERATIONAL_HEADER_PREFIX"*': '?*) _fm_gp_header=$FM_OPERATIONAL_HEADER_PREFIX ;;
    "$FM_OPERATIONAL_VISIBLE_HEADER_PREFIX"*': '?*) _fm_gp_header=$FM_OPERATIONAL_VISIBLE_HEADER_PREFIX ;;
    *) return 1 ;;
  esac
  _fm_gp_remainder=${_fm_gp_message#"$_fm_gp_header"}
  _fm_gp_kind=${_fm_gp_remainder%%': '*}
  fm_operational_kind_is_current "$_fm_gp_kind" || return 1
  if [ "$_fm_gp_header" = "$FM_OPERATIONAL_VISIBLE_HEADER_PREFIX" ] && [ "$_fm_gp_kind" != launch-brief ]; then
    return 1
  fi
  _fm_gp_body=${_fm_gp_remainder#"${_fm_gp_kind}: "}
  [ "$_fm_gp_body" != "$_fm_gp_remainder" ] && [ -n "$_fm_gp_body" ] || return 1
  if [ "$_fm_gp_kind" = launch-brief ]; then
    case "$_fm_gp_body" in
      "$FM_LAUNCH_BRIEF_DISCLOSURE"$'\n'?*) _fm_gp_body=${_fm_gp_body#"$FM_LAUNCH_BRIEF_DISCLOSURE"$'\n'} ;;
    esac
  fi
  printf -v "$_fm_gp_kind_var" '%s' "$_fm_gp_kind"
  printf -v "$_fm_gp_body_var" '%s' "$_fm_gp_body"
}

fm_operational_generic_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} parsed_kind parsed_body
  [ -n "$result_var" ] || return 2
  fm_operational_generic_parse "$message" parsed_kind parsed_body || return 1
  printf -v "$result_var" '%s' "$parsed_kind"
}

fm_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} current_kind
  [ -n "$result_var" ] || return 2
  if fm_operational_generic_kind "$message" current_kind; then
    printf -v "$result_var" '%s' "$current_kind"
    return 0
  fi
  case "$message" in
    "$FM_FROMFIRST_MARK"?*)
      printf -v "$result_var" '%s' from-firstmate
      return 0
      ;;
  esac
  return 1
}

fm_operational_input_body() {  # <current-message> <result-var>
  local message=${1-} result_var=${2-} current_kind parsed_body
  [ -n "$result_var" ] || return 2
  if fm_operational_generic_parse "$message" current_kind parsed_body; then
    printf -v "$result_var" '%s' "$parsed_body"
    return 0
  fi
  case "$message" in
    "$FM_FROMFIRST_MARK"?*)
      parsed_body=${message#"$FM_FROMFIRST_MARK"}
      printf -v "$result_var" '%s' "$parsed_body"
      return 0
      ;;
  esac
  return 1
}

# Historical payload literals are intentionally isolated below this line.
# They exist only for persisted pre-protocol transcripts and must never be used
# by current producers or current-path tests.
# shellcheck disable=SC2016 # Backticks are literal historical prompt markup.
FM_LEGACY_SESSIONSTART='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
FM_LEGACY_WATCHER_PREFIX='FIRSTMATE WATCHER WAKE: '
FM_LEGACY_WATCHER_SUFFIX=$'\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.'
FM_LEGACY_TURNEND_PREFIX=$'TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n'
FM_LEGACY_AWAY_PREFIX="${FM_OPERATIONAL_MARK}Supervisor escalate ("

fm_legacy_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-}
  [ -n "$result_var" ] || return 2

  # PR 899 landed an untyped FIRSTMATE_OP prefix. Its subtype cannot be
  # recovered without body prose, so it is explicitly generic.
  case "$message" in
    "$FM_OPERATIONAL_PREFIX"?*)
      printf -v "$result_var" '%s' legacy-operational
      return 0
      ;;
  esac

  if [ "$message" = "$FM_LEGACY_SESSIONSTART" ]; then
    printf -v "$result_var" '%s' session-start
    return 0
  fi
  case "$message" in
    "$FM_LEGACY_AWAY_PREFIX"*)
      printf -v "$result_var" '%s' away-supervisor
      return 0
      ;;
    "$FM_LEGACY_WATCHER_PREFIX"*"$FM_LEGACY_WATCHER_SUFFIX")
      [ "${#message}" -gt "$(( ${#FM_LEGACY_WATCHER_PREFIX} + ${#FM_LEGACY_WATCHER_SUFFIX} ))" ] || return 1
      printf -v "$result_var" '%s' watcher
      return 0
      ;;
    "$FM_LEGACY_TURNEND_PREFIX"?*)
      printf -v "$result_var" '%s' turn-end-guard
      return 0
      ;;
  esac
  return 1
}

fm_operational_input_classify() {  # <message> <result-var>
  local message=${1-} result_var=${2-} classified_kind
  [ -n "$result_var" ] || return 2
  if fm_operational_input_kind "$message" classified_kind ||
     fm_legacy_operational_input_kind "$message" classified_kind; then
    printf -v "$result_var" '%s' "$classified_kind"
    return 0
  fi
  return 1
}

fm_message_from_firstmate() {  # <message>
  local kind
  fm_operational_input_kind "${1-}" kind && [ "$kind" = from-firstmate ]
}

fm_message_mark_from_firstmate() {  # <message> <result-var>
  local message=${1-} result_var=${2-} transformed
  [ -n "$result_var" ] || return 2
  if fm_message_from_firstmate "$message"; then
    transformed=$message
  else
    transformed="${FM_FROMFIRST_MARK}${message}"
  fi
  printf -v "$result_var" '%s' "$transformed"
}

fm_operational_read_stdin() {  # <result-var>
  local result_var=${1-} value
  [ -n "$result_var" ] || return 2
  value=$(cat; printf x)
  value=${value%x}
  printf -v "$result_var" '%s' "$value"
}

fm_operational_usage() {
  cat <<'EOF'
Usage:
  bin/fm-operational-input.sh encode <kind>  # body on stdin
  bin/fm-operational-input.sh kind           # current input on stdin
  bin/fm-operational-input.sh classify       # current or legacy input on stdin
  bin/fm-operational-input.sh body           # current input on stdin

Current construction kinds:
  session-start watcher turn-end-guard away-supervisor from-firstmate launch-brief

The from-firstmate kind uses its established live-charter-compatible carrier.
The launch-brief kind emits a fully visible header (no leading U+2063) plus a
fixed self-disclosure first line; parsing accepts both its unmarked current
form and the marked form of already-in-flight launches.
EOF
}

fm_operational_main() {
  local command=${1-} argument=${2-} input output
  case "$command" in
    -h|--help|help)
      fm_operational_usage
      ;;
    encode)
      [ "$#" -eq 2 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_construct "$argument" "$input" output || return 2
      printf '%s' "$output"
      ;;
    kind)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_kind "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    classify)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_classify "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    body)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_body "$input" output || return 1
      printf '%s' "$output"
      ;;
    *)
      fm_operational_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_operational_main "$@"
  exit $?
fi
