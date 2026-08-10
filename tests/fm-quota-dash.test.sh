#!/usr/bin/env bash
# Behavior tests for the dispatch-focused quota dashboard presentation.
#
# quota-axi remains the source of all quota data. The dashboard must show only
# the account windows that affect Firstmate's dispatch decisions and must make
# Grok's unmeasured weekly cap visible alongside its prepaid credits number.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-quota-dash-tests)

test_dispatch_windows_and_grok_caveat() {
  local case_dir fakebin real_jq out
  case_dir="$TMP_ROOT/dispatch-windows"
  fakebin=$(fm_fakebin "$case_dir")
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for quota dashboard tests"

  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[
  {"provider":"claude","plan":"max","windows":[
    {"id":"five_hour","label":"session","percentRemaining":80,"resetsAt":"2030-01-01T01:00:00Z","pace":{"status":"on_pace"}},
    {"id":"seven_day","label":"week","percentRemaining":70,"resetsAt":"2030-01-07T01:00:00Z","pace":{"status":"on_pace"}},
    {"id":"model:fable","label":"Fable week","percentRemaining":60,"resetsAt":"2030-01-07T01:00:00Z","pace":{"status":"on_pace"}}]},
  {"provider":"codex","plan":"plus","windows":[
    {"id":"weekly","label":"week","percentRemaining":50,"resetsAt":"2030-01-07T01:00:00Z","pace":{"status":"on_pace"}}]},
  {"provider":"grok","windows":[
    {"id":"credits","label":"credits","percentRemaining":42,"resetsAt":"2030-01-07T01:00:00Z","pace":{"status":"on_pace"}},
    {"id":"product:imagine","label":"Imagine","percentRemaining":26,"resetsAt":"2030-01-07T01:00:00Z","pace":{"status":"on_pace"}},
    {"id":"product:grok_build","label":"Grok Build","percentRemaining":74,"resetsAt":"2030-01-07T01:00:00Z","pace":{"status":"on_pace"}}]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider claude,codex,grok --once)
  assert_contains "$out" "claude (session)" "Claude's five-hour dispatch window must be shown"
  assert_contains "$out" "claude (week)" "Claude's seven-day dispatch window must be shown"
  assert_contains "$out" "codex (week)" "Codex's weekly dispatch window must be shown"
  assert_contains "$out" "grok (credits; weekly cap unmeasured)" "Grok credits must disclose the unmeasured weekly cap"
  assert_not_contains "$out" "Fable week" "model-specific Claude noise must stay out of the dashboard"
  assert_not_contains "$out" "Imagine" "Grok Imagine product credits must stay out of the dashboard"
  assert_not_contains "$out" "Grok Build" "Grok Build product credits must stay out of the dashboard"
  pass "fm-quota-dash: dispatch windows remain visible and Grok's weekly cap is explicit"
}

test_default_providers_include_grok() {
  local case_dir fakebin real_jq out asked
  case_dir="$TMP_ROOT/default-providers"
  fakebin=$(fm_fakebin "$case_dir")
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for quota dashboard tests"
  mkdir -p "$case_dir"

  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do
  case "\$1" in --provider) printf '%s' "\$2" > '$case_dir/asked'; shift 2 ;; *) shift ;; esac
done
cat <<'JSON'
{"providers":[
  {"provider":"grok","plan":"heavy","windows":[
    {"id":"credits","label":"credits","percentRemaining":42,"resetsAt":"2030-01-07T01:00:00Z","pace":{"status":"on_pace"}}]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --once)
  asked=$(cat "$case_dir/asked" 2>/dev/null || printf '')
  [ "$asked" = "claude,codex,grok" ] \
    || fail "the default dashboard must query claude,codex,grok - quota-axi was asked for: ${asked:-<nothing>}"
  assert_contains "$out" "grok (credits; weekly cap unmeasured)" "Grok's weekly cap warning must appear without an explicit --provider"
  pass "fm-quota-dash: Grok is part of the default dispatch view"
}

test_other_providers_keep_reported_windows() {
  local case_dir fakebin real_jq out
  case_dir="$TMP_ROOT/other-providers"
  fakebin=$(fm_fakebin "$case_dir")
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for quota dashboard tests"

  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[
  {"provider":"kimi","plan":"pro","windows":[
    {"id":"weekly","label":"week","percentRemaining":90,"resetsAt":"2030-01-07T01:00:00Z","pace":{"status":"on_pace"}}]},
  {"provider":"grok","plan":"heavy","windows":[
    {"id":"prepaid_credits","label":"credits","percentRemaining":42,"resetsAt":"2030-01-07T01:00:00Z","pace":{"status":"on_pace"}}]},
  {"provider":"codex","plan":"plus","windows":[]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider kimi,grok,codex --once)
  assert_contains "$out" "kimi (week)" "a readable window from another provider must be shown, not hidden"
  assert_contains "$out" " 90.0%" "a readable percentage must survive the dispatch filter"
  assert_not_contains "$out" "UNREADABLE - run: quota-axi --allow-keychain-prompt] kimi" \
    "quota that WAS read must never be reported as unreadable"
  assert_contains "$out" "UNKNOWN - dispatch limit not reported] grok" \
    "a Grok window that is not credits must not stand in for the dispatch limit"
  assert_not_contains "$out" "42.0%" "a non-dispatch Grok window's number must not be shown as headroom"
  assert_contains "$out" "UNREADABLE" "a provider reporting no windows at all is still unreadable"
  pass "fm-quota-dash: unfiltered providers keep the windows quota-axi reported"
}

test_missing_reset_keeps_columns_aligned() {
  local case_dir fakebin real_jq out header_col note_col row
  case_dir="$TMP_ROOT/missing-reset"
  fakebin=$(fm_fakebin "$case_dir")
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for quota dashboard tests"

  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[
  {"provider":"grok","plan":"heavy","windows":[
    {"id":"credits","label":"credits","percentRemaining":42}]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --once)
  assert_contains "$out" "grok (credits; weekly cap unmeasured)" \
    "prepaid credits with no reset timestamp must still disclose the weekly cap"
  header_col=$(printf '%s\n' "$out" | awk '/AVAILABILITY/ { print index($0, "AVAILABILITY"); exit }')
  row=$(printf '%s\n' "$out" | awk '/^ *[0-9]+ grok /  { print; exit }')
  note_col=$(printf '%s\n' "$row" | awk '{ print index($0, "weekly cap unmeasured") }')
  [ -n "$header_col" ] && [ "$note_col" = "$header_col" ] \
    || fail "the note must sit under AVAILABILITY (header col $header_col, note col $note_col) in: $row"
  pass "fm-quota-dash: a missing reset timestamp does not shift the table columns"
}

test_noise_only_provider_reports_unknown_headroom() {
  local case_dir fakebin real_jq out
  case_dir="$TMP_ROOT/noise-only"
  fakebin=$(fm_fakebin "$case_dir")
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for quota dashboard tests"

  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[
  {"provider":"claude","plan":"max","windows":[
    {"id":"model:fable","label":"Fable week","percentRemaining":60,"resetsAt":"2030-01-07T01:00:00Z","pace":{"status":"on_pace"}}]},
  {"provider":"grok","plan":"heavy","windows":[
    {"id":"product:imagine","label":"Imagine","percentRemaining":26,"resetsAt":"2030-01-07T01:00:00Z","pace":{"status":"on_pace"}},
    {"id":"product:grok_build","label":"Grok Build","percentRemaining":74,"resetsAt":"2030-01-07T01:00:00Z","pace":{"status":"on_pace"}}]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --once)
  assert_not_contains "$out" "Imagine" "Grok product windows must never reach the dashboard, even as a fallback"
  assert_not_contains "$out" "Grok Build" "Grok product windows must never reach the dashboard, even as a fallback"
  assert_not_contains "$out" "Fable week" "Claude model windows must never reach the dashboard, even as a fallback"
  assert_not_contains "$out" "UNREADABLE" "quota that WAS read must not be reported as unreadable"
  assert_not_contains "$out" "26.0%" "a filtered product window's number must not surface anywhere"
  assert_not_contains "$out" "60.0%" "a filtered model window's number must not surface anywhere"
  assert_contains "$out" "UNKNOWN - dispatch limit not reported] claude" \
    "Claude without a dispatch window must disclose unknown headroom"
  assert_contains "$out" "UNKNOWN - dispatch limit not reported] grok" \
    "Grok without a credits window must disclose unknown headroom"
  assert_contains "$out" "dispatch limit not reported; weekly cap unmeasured" \
    "the Grok weekly cap stays visible on the unknown-headroom row"
  assert_contains "$out" "unknown" "the table must show a non-numeric remaining value"
  pass "fm-quota-dash: noise-only providers disclose unknown headroom, not noise or 0%"
}

test_help_prints_the_whole_header() {
  local out
  out=$("$ROOT/bin/fm-quota-dash.sh" --help)
  assert_contains "$out" "Usage:" "--help must print the usage line"
  assert_contains "$out" "Keys: r = refresh now, q = quit." "--help must print the key bar"
  assert_not_contains "$out" "set -u" "--help must stop at the end of the header comment"
  pass "fm-quota-dash: --help prints the whole header, however long it grows"
}

test_dispatch_windows_and_grok_caveat
test_default_providers_include_grok
test_missing_reset_keeps_columns_aligned
test_noise_only_provider_reports_unknown_headroom
test_help_prints_the_whole_header
test_other_providers_keep_reported_windows
