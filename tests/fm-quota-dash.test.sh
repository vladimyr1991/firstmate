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

test_dispatch_windows_and_grok_caveat
