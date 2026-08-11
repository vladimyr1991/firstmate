#!/usr/bin/env bash
# Behavior tests for the dispatch-focused quota dashboard presentation.
#
# quota-axi remains the source of all quota data. The dashboard must show only
# the account windows that affect Firstmate's dispatch decisions, group them
# by cycle, and make Grok's unmeasured weekly cap visible beside its credits.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-quota-dash-tests)

# The dashboard picks its layout from the terminal width, so every case states
# the width it is asserting about. Without this the runner's own COLUMNS/TERM
# decided whether the wide table existed at all, and a narrow pane failed
# assertions that have nothing to do with the code under test.
WIDE=100
NARROW=68

test_dispatch_windows_and_grok_caveat() {
  local case_dir fakebin real_jq out weekly_block grok_reset
  case_dir="$TMP_ROOT/dispatch-windows"
  fakebin=$(fm_fakebin "$case_dir")
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for quota dashboard tests"
  # An hour short of four days: a reset exactly N days out renders as "Nd 0h"
  # or "(N-1)d 23h" depending on which second the dashboard starts in, and a
  # test must not depend on that.
  grok_reset=$(date -u -v+4d -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d '+4 days -1 hour' +%Y-%m-%dT%H:%M:%SZ)

  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  cat > "$fakebin/quota-axi" <<SH
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
    {"id":"credits","kind":"credits","label":"credits","percentRemaining":42,"resetsAt":"$grok_reset","pace":{"status":"on_pace"}},
    {"id":"product:imagine","kind":"credits","label":"Imagine","percentRemaining":26,"resetsAt":"2030-01-07T01:00:00Z","pace":{"status":"on_pace"}},
    {"id":"product:grok_build","kind":"credits","label":"Grok Build","percentRemaining":74,"resetsAt":"2030-01-07T01:00:00Z","pace":{"status":"on_pace"}}]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider claude,codex,grok --once)
  assert_contains "$out" "claude (session)" "Claude's five-hour dispatch window must be shown"
  assert_contains "$out" "claude (week)" "Claude's seven-day dispatch window must be shown"
  assert_contains "$out" "codex (week)" "Codex's weekly dispatch window must be shown"
  weekly_block=$(printf '%s\n' "$out" | sed -n '/WEEKLY LIMIT/,/DAILY LIMIT/p')
  assert_contains "$weekly_block" "grok (credits)" "Grok credits with a reset must appear in WEEKLY LIMIT"
  assert_contains "$out" "weekly cap unmeasured" "Grok credits must disclose the unmeasured weekly cap"
  assert_contains "$out" "3d" "the Grok reset about four days away must render as about three days remaining"
  assert_not_contains "$out" "Fable week" "model-specific Claude noise must stay out of the dashboard"
  assert_not_contains "$out" "Imagine" "Grok Imagine product credits must stay out of the dashboard"
  assert_not_contains "$out" "Grok Build" "Grok Build product credits must stay out of the dashboard"
  pass "fm-quota-dash: dispatch windows are filtered and Grok credits are weekly"
}

test_credits_near_reset_stay_weekly() {
  local case_dir fakebin real_jq out weekly_block reset
  case_dir="$TMP_ROOT/credits-near-reset"
  fakebin=$(fm_fakebin "$case_dir")
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for quota dashboard tests"
  reset=$(date -u -v+1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)

  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[
  {"provider":"grok","plan":"heavy","windows":[
    {"id":"credits","kind":"credits","label":"credits","percentRemaining":42,"resetsAt":"$reset"}]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider grok --once)
  weekly_block=$(printf '%s\n' "$out" | sed -n '/WEEKLY LIMIT/,/DAILY LIMIT/p')
  assert_contains "$weekly_block" "grok (credits)" \
    "a credit balance with one day left must not move to DAILY LIMIT"
  pass "fm-quota-dash: reset time is never mistaken for a credit cycle length"
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

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --once)
  asked=$(cat "$case_dir/asked" 2>/dev/null || printf '')
  [ "$asked" = "claude,codex,grok" ] \
    || fail "the default dashboard must query claude,codex,grok - quota-axi was asked for: ${asked:-<nothing>}"
  assert_contains "$out" "grok (credits)" "Grok's credits must appear without an explicit --provider"
  assert_contains "$out" "weekly cap unmeasured" "Grok's weekly cap warning must appear without an explicit --provider"
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

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider kimi,grok,codex --once)
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
  local case_dir fakebin real_jq out header_col note_col row weekly_block
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

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --once)
  assert_contains "$out" "grok (credits)" \
    "prepaid credits with no reset timestamp must remain visible"
  weekly_block=$(printf '%s\n' "$out" | sed -n '/WEEKLY LIMIT/,/DAILY LIMIT/p')
  assert_contains "$weekly_block" "grok (credits)" \
    "a credit balance stays weekly whether or not quota-axi carried a resetsAt"
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

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --once)
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

test_credit_balances_without_reset_are_weekly() {
  local case_dir fakebin real_jq out weekly_block daily_block
  case_dir="$TMP_ROOT/credits-no-reset"
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
    {"id":"credits","kind":"credits","label":"credits","percentRemaining":42}]},
  {"provider":"kimi","plan":"pro","windows":[
    {"id":"balance","kind":"credits","label":"balance","percentRemaining":33}]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider grok,kimi --once)
  weekly_block=$(printf '%s\n' "$out" | sed -n '/WEEKLY LIMIT/,/DAILY LIMIT/p')
  daily_block=$(printf '%s\n' "$out" | sed -n '/DAILY LIMIT/,$p')
  assert_contains "$weekly_block" "grok (credits)" \
    "a credit balance is a billing-cycle balance even with no resetsAt"
  assert_contains "$weekly_block" "kimi (balance)" \
    "kind=credits alone must place a balance in WEEKLY LIMIT"
  assert_not_contains "$daily_block" "grok (credits)" \
    "a nullable reset timestamp must not present prepaid credits as today's budget"
  assert_not_contains "$daily_block" "kimi (balance)" \
    "a nullable reset timestamp must not present prepaid credits as today's budget"
  pass "fm-quota-dash: credit balances are weekly with or without a reset timestamp"
}

test_nonzero_offset_reset_is_applied() {
  local case_dir fakebin real_jq out reset
  case_dir="$TMP_ROOT/offset-reset"
  fakebin=$(fm_fakebin "$case_dir")
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for quota dashboard tests"
  # An instant three days and 23 hours out, written in +02:00: its clock fields
  # read 4d1h ahead, so an offset that is stripped rather than applied shows up
  # as a reset a whole day further away.
  reset="$(date -u -v+4d -v+1H +%Y-%m-%dT%H:%M:%S 2>/dev/null \
    || date -u -d '+4 days 1 hour' +%Y-%m-%dT%H:%M:%S)+02:00"

  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[
  {"provider":"codex","plan":"plus","windows":[
    {"id":"weekly","label":"week","percentRemaining":50,"resetsAt":"$reset"}]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider codex --once)
  assert_contains "$out" "3d" "a +02:00 reset four days out must render as about three days remaining"
  assert_not_contains "$out" "4d" "a zone offset must be applied, never dropped"
  pass "fm-quota-dash: a non-zero zone offset moves the reset, it is not discarded"
}

test_narrow_terminal_keeps_caveat_and_bar_widths() {
  local case_dir fakebin real_jq out claude_bar grok_bar distinct longest
  case_dir="$TMP_ROOT/narrow"
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
    {"id":"five_hour","label":"session","percentRemaining":80,"resetsAt":"2030-01-07T01:00:00Z"}]},
  {"provider":"grok","plan":"heavy","windows":[
    {"id":"credits","kind":"credits","label":"credits","percentRemaining":80,"resetsAt":"2030-01-07T01:00:00Z"}]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$NARROW" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider claude,grok --once)
  assert_contains "$out" "weekly cap unmeasured" \
    "a narrow pane must still disclose Grok's unmeasured weekly cap"
  assert_not_contains "$out" "AVAILABILITY" \
    "a narrow pane drops the wide table, which is why the caveat cannot live there alone"
  claude_bar=$(printf '%s\n' "$out" | awk -F'[][]' '/ claude \(/ { print $2; exit }')
  grok_bar=$(printf '%s\n' "$out" | awk -F'[][]' '/ grok \(/ { print $2; exit }')
  [ -n "$claude_bar" ] && [ "$claude_bar" = "$grok_bar" ] \
    || fail "two rows at 80% must draw the same bar: claude '$claude_bar' vs grok '$grok_bar'"
  distinct=$(printf '%s\n' "$out" | awk -F'[][]' '/^ *[0-9]+ \[/ { print length($2) }' | sort -u | wc -l | tr -d ' ')
  [ "$distinct" = 1 ] || fail "every gauge in the stack must share one bar width, found $distinct widths in: $out"
  longest=$(printf '%s\n' "$out" | awk '{ if (length > m) m = length } END { print m + 0 }')
  [ "$longest" -le "$NARROW" ] \
    || fail "no line may exceed the $NARROW-column pane, longest was $longest in: $out"
  pass "fm-quota-dash: a narrow pane keeps the caveat, one bar width, and its margins"
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
test_credits_near_reset_stay_weekly
test_default_providers_include_grok
test_missing_reset_keeps_columns_aligned
test_credit_balances_without_reset_are_weekly
test_nonzero_offset_reset_is_applied
test_narrow_terminal_keeps_caveat_and_bar_widths
test_noise_only_provider_reports_unknown_headroom
test_help_prints_the_whole_header
test_other_providers_keep_reported_windows
