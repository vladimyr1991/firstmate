#!/usr/bin/env bash
# Canonical current and isolated legacy operational-input protocol matrices.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/fm-operational-input.sh"
# shellcheck source=/dev/null
. "$OWNER"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

classify_cli() {
  printf '%s' "$1" | "$OWNER" classify 2>/dev/null
}

kind_cli() {
  printf '%s' "$1" | "$OWNER" kind 2>/dev/null
}

test_current_generic_matrix() {
  local kind body encoded parsed stripped prefix_hex
  prefix_hex=$(printf '%s' "$FM_OPERATIONAL_PREFIX" | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a346495253544d4154455f4f503a20 ] \
    || fail "current operational prefix lost the landed U+2063 FIRSTMATE_OP bytes: $prefix_hex"

  for kind in session-start watcher turn-end-guard away-supervisor launch-brief; do
    body="CURRENT_BODY_FOR_${kind}"
    fm_operational_input_encode "$kind" "$body" encoded \
      || fail "could not encode current $kind fixture"
    if [ "$kind" = launch-brief ]; then
      [ "${encoded#'FIRSTMATE_OP: '}" != "$encoded" ] \
        || fail "launch-brief emission did not begin with the visible FIRSTMATE_OP: header"
      case "$encoded" in
        *"$FM_OPERATIONAL_MARK"*) fail "launch-brief emission still carries the invisible U+2063 marker" ;;
      esac
      [ "$encoded" = "FIRSTMATE_OP: v1 launch-brief: ${FM_LAUNCH_BRIEF_DISCLOSURE}"$'\n'"$body" ] \
        || fail "launch-brief emission lost its header/disclosure/body shape"
    else
      [ "${encoded#"$FM_OPERATIONAL_HEADER_PREFIX"}" != "$encoded" ] \
        || fail "current $kind emission lost the landed marked header"
      [ "$encoded" = "${FM_OPERATIONAL_HEADER_PREFIX}${kind}: ${body}" ] \
        || fail "current $kind emission is no longer byte-identical to the landed form"
    fi
    fm_operational_input_kind "$encoded" parsed \
      || fail "could not parse current $kind fixture"
    [ "$parsed" = "$kind" ] \
      || fail "current $kind fixture became $parsed"
    [ "$(kind_cli "$encoded")" = "$kind" ] \
      || fail "cross-language CLI lost current $kind"
    [ "$(classify_cli "$encoded")" = "$kind" ] \
      || fail "classifier lost current $kind"
    fm_operational_input_body "$encoded" stripped \
      || fail "could not recover current $kind body"
    [ "$stripped" = "$body" ] \
      || fail "current $kind body changed during encode/parse"
  done
  pass "operational input: every current generic envelope retains its exact structured kind"
}

test_launch_brief_dual_forms() {
  local marked parsed stripped
  marked="${FM_OPERATIONAL_HEADER_PREFIX}launch-brief: IN_FLIGHT_MARKED_BRIEF"
  fm_operational_input_kind "$marked" parsed \
    || fail "the marked in-flight launch-brief form no longer parses"
  [ "$parsed" = launch-brief ] \
    || fail "marked launch-brief became $parsed"
  [ "$(kind_cli "$marked")" = launch-brief ] \
    || fail "CLI lost the marked launch-brief form"
  [ "$(classify_cli "$marked")" = launch-brief ] \
    || fail "classifier lost the marked launch-brief form"
  fm_operational_input_body "$marked" stripped \
    || fail "could not recover the marked launch-brief body"
  [ "$stripped" = IN_FLIGHT_MARKED_BRIEF ] \
    || fail "marked launch-brief body changed during parse"

  # An unmarked launch-brief without the disclosure line (a hand-fed or
  # foreign producer) still parses, with its body intact.
  fm_operational_input_body "FIRSTMATE_OP: v1 launch-brief: BARE_UNMARKED_BRIEF" stripped \
    || fail "the unmarked disclosure-free launch-brief form no longer parses"
  [ "$stripped" = BARE_UNMARKED_BRIEF ] \
    || fail "unmarked disclosure-free launch-brief body changed during parse"
  pass "operational input: launch-brief parses in both its marked in-flight and unmarked current forms"
}

test_current_from_firstmate_carrier() {
  local encoded parsed separator
  separator=$(printf '\342\201\243')
  fm_message_mark_from_firstmate "corr=0123456789abcdef inspect the report" encoded
  [ "${encoded#"[fm-from-firstmate]$separator"}" != "$encoded" ] \
    || fail "from-firstmate lost its live-charter-compatible leading carrier"
  fm_operational_input_kind "$encoded" parsed \
    || fail "from-firstmate current carrier did not parse"
  [ "$parsed" = from-firstmate ] \
    || fail "from-firstmate current carrier became $parsed"
  [ "$(classify_cli "$encoded")" = from-firstmate ] \
    || fail "cross-language classifier lost from-firstmate"
  pass "operational input: the established from-firstmate carrier remains structurally typed and byte-compatible"
}

test_landed_untyped_prefix_is_explicitly_legacy() {
  local untyped parsed
  untyped="${FM_OPERATIONAL_PREFIX}body whose historical subtype is unknowable"
  fm_legacy_operational_input_kind "$untyped" parsed \
    || fail "landed untyped FIRSTMATE_OP input was not retained"
  [ "$parsed" = legacy-operational ] \
    || fail "landed untyped FIRSTMATE_OP input falsely became $parsed"
  ! fm_operational_input_kind "$untyped" parsed \
    || fail "untyped FIRSTMATE_OP input passed the current typed parser"
  [ "$(classify_cli "$untyped")" = legacy-operational ] \
    || fail "CLI did not expose the untyped prefix as legacy-operational"
  pass "operational input: untyped landed FIRSTMATE_OP transcripts are explicit legacy-operational input"
}

test_isolated_legacy_matrix() {
  local watcher turnend away parsed
  watcher="${FM_LEGACY_WATCHER_PREFIX}signal: legacy${FM_LEGACY_WATCHER_SUFFIX}"
  turnend="${FM_LEGACY_TURNEND_PREFIX}watcher: FAILED - legacy"
  away="${FM_LEGACY_AWAY_PREFIX}1 event(s)): done: legacy"

  for fixture in \
    "session-start|$FM_LEGACY_SESSIONSTART" \
    "watcher|$watcher" \
    "turn-end-guard|$turnend" \
    "away-supervisor|$away"
  do
    expected=${fixture%%|*}
    message=${fixture#*|}
    ! fm_operational_input_kind "$message" parsed \
      || fail "legacy $expected fixture leaked into the current parser"
    fm_legacy_operational_input_kind "$message" parsed \
      || fail "legacy $expected fixture was not recognized"
    [ "$parsed" = "$expected" ] \
      || fail "legacy $expected fixture became $parsed"
  done
  pass "operational input: historical prose compatibility is isolated from current parsing"
}

test_genuine_near_misses_remain_unclassified() {
  local marker fixture parsed
  marker=$FM_OPERATIONAL_MARK
  while IFS= read -r fixture || [ -n "$fixture" ]; do
    [ -n "$fixture" ] || continue
    ! fm_operational_input_classify "$fixture" parsed \
      || fail "genuine near miss was classified as $parsed: $fixture"
    [ -z "$(classify_cli "$fixture" || true)" ] \
      || fail "CLI classified a genuine near miss: $fixture"
  done <<EOF
Captain quote: ${FM_OPERATIONAL_PREFIX}v1 watcher
FIRSTMATE_OP: v1 watcher
FIRSTMATE_OP: v1 watcher: UNMARKED_NON_LAUNCH_KIND_STAYS_CAPTAIN_TEXT
FIRSTMATE_OP: v1 launch-brief
Captain quote: FIRSTMATE_OP: v1 launch-brief: QUOTED_UNMARKED_LAUNCH_BRIEF
$marker arbitrary captain text
Captain quote: $FM_LEGACY_SESSIONSTART
${FM_LEGACY_SESSIONSTART} Please explain this sentence.
FIRSTMATE WATCHER WAKE: can you explain this phrase?
TURN WOULD END BLIND - can you make this warning friendlier?
Supervisor escalate (1 event(s)): is this wording clear?
[fm-from-firstmate] inspect this visible label
EOF
  pass "operational input: quoted, ASCII-only, arbitrary-U+2063, altered-legacy, and label-only near misses stay genuine"
}

test_cross_language_adapter_uses_the_owner() {
  local encoded parsed
  encoded=$(FM_TEST_ROOT="$ROOT" HELPER="$ROOT/.opencode/plugins/lib/fm-operational-input.js" \
    node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";
const { encodeFirstmateOperationalInput } = await import(pathToFileURL(process.env.HELPER).href);
process.stdout.write(await encodeFirstmateOperationalInput(process.env.FM_TEST_ROOT, "watcher", "CROSS_LANGUAGE_BODY"));
JS
  ) || fail "OpenCode cross-language adapter could not invoke the canonical owner"
  fm_operational_input_kind "$encoded" parsed \
    || fail "OpenCode cross-language adapter returned an invalid current envelope"
  [ "$parsed" = watcher ] \
    || fail "OpenCode cross-language adapter changed watcher to $parsed"
  pass "operational input: the OpenCode adapter constructs through the canonical owner"
}

test_invalid_current_encodings_are_rejected() {
  local output
  output=$(printf 'body' | "$OWNER" encode legacy-operational 2>/dev/null) \
    && fail "legacy-operational was accepted as a current producer kind"
  [ -z "$output" ] || fail "invalid current kind printed protocol data"
  output=$(printf '' | "$OWNER" encode watcher 2>/dev/null) \
    && fail "empty current operational body was accepted"
  [ -z "$output" ] || fail "empty current body printed protocol data"
  pass "operational input: current construction rejects legacy kinds and empty bodies"
}

test_current_generic_matrix
test_launch_brief_dual_forms
test_current_from_firstmate_carrier
test_landed_untyped_prefix_is_explicitly_legacy
test_isolated_legacy_matrix
test_genuine_near_misses_remain_unclassified
test_cross_language_adapter_uses_the_owner
test_invalid_current_encodings_are_rejected
