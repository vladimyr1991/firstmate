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
# assertions that have nothing to do with the code under test. Cases about the
# narrow layout derive their width from the table's own rendered size instead,
# so retuning a column cannot turn them into tests of nothing.
WIDE=100

test_dispatch_windows_and_grok_caveat() {
  local case_dir fakebin real_jq out weekly_block grok_reset grok_row
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
  # Anchored on the Grok row: the fixture's other resets are years out, and a
  # bare "3d" would also be satisfied by any day count ending in 3 (1243d).
  grok_row=$(printf '%s\n' "$out" | awk '/^ *[0-9]+ grok /  { print; exit }')
  assert_contains "$grok_row" "3d " \
    "the Grok reset about four days away must render as about three days remaining"
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

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider claude,grok --once)
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
  local case_dir fakebin real_jq out claude_bar grok_bar distinct longest table_header narrow
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

  # One column short of what the table's own header costs: narrow enough to
  # force the compact layout however the columns are later retuned.
  narrow=$(PATH="$fakebin:$BASE_PATH" COLUMNS=200 FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider claude,grok --once \
    | awk '/AVAILABILITY/ { print length - 1; exit }')
  [ "${narrow:-0}" -gt 0 ] || fail "could not measure the full table's header width"

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$narrow" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider claude,grok --once)
  assert_contains "$out" "weekly cap unmeasured" \
    "a narrow pane must still disclose Grok's unmeasured weekly cap"
  table_header=$(printf '%s\n' "$out" | awk '/ ID +MODEL/ { print; exit }')
  assert_not_contains "$table_header" "AVAILABILITY" \
    "a narrow pane drops the wide table, which is why the caveat cannot live there alone"
  claude_bar=$(printf '%s\n' "$out" | awk -F'[][]' '/ claude \(/ { print $2; exit }')
  grok_bar=$(printf '%s\n' "$out" | awk -F'[][]' '/ grok \(/ { print $2; exit }')
  [ -n "$claude_bar" ] && [ "$claude_bar" = "$grok_bar" ] \
    || fail "two rows at 80% must draw the same bar: claude '$claude_bar' vs grok '$grok_bar'"
  distinct=$(printf '%s\n' "$out" | awk -F'[][]' '/^ *[0-9]+ \[/ { print length($2) }' | sort -u | wc -l | tr -d ' ')
  [ "$distinct" = 1 ] || fail "every gauge in the stack must share one bar width, found $distinct widths in: $out"
  longest=$(printf '%s\n' "$out" | awk '{ if (length > m) m = length } END { print m + 0 }')
  [ "$longest" -le "$narrow" ] \
    || fail "no line may exceed the $narrow-column pane, longest was $longest in: $out"
  pass "fm-quota-dash: a narrow pane keeps the caveat, one bar width, and its margins"
}

test_unmeasured_rows_group_under_unknown_limit() {
  local case_dir fakebin real_jq out weekly_block daily_block unknown_block order fallbacks
  case_dir="$TMP_ROOT/unknown-section"
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
    {"id":"model:fable","label":"Fable week","percentRemaining":60,"resetsAt":"2030-01-07T01:00:00Z"}]},
  {"provider":"codex","plan":"plus","windows":[]},
  {"provider":"grok","plan":"heavy","windows":[
    {"id":"credits","kind":"credits","label":"credits","percentRemaining":42,"resetsAt":"2030-01-07T01:00:00Z"}]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --once)
  weekly_block=$(printf '%s\n' "$out" | sed -n '/WEEKLY LIMIT/,/DAILY LIMIT/p')
  daily_block=$(printf '%s\n' "$out" | sed -n '/DAILY LIMIT/,/UNKNOWN LIMIT/p')
  unknown_block=$(printf '%s\n' "$out" | sed -n '/UNKNOWN LIMIT/,$p')

  assert_contains "$unknown_block" "UNKNOWN - dispatch limit not reported] claude" \
    "a provider with no dispatch window belongs under UNKNOWN LIMIT"
  assert_contains "$unknown_block" "UNREADABLE - run: quota-axi --allow-keychain-prompt] codex" \
    "a provider whose quota could not be read belongs under UNKNOWN LIMIT"
  assert_not_contains "$daily_block" "dispatch limit not reported] claude" \
    "an unmeasured row must not be filed as today's limit"
  assert_not_contains "$daily_block" "UNREADABLE - run: quota-axi --allow-keychain-prompt] codex" \
    "codex's only dispatch window is weekly, so an unreadable codex row is not a daily limit"
  assert_not_contains "$weekly_block" "dispatch limit not reported] claude" \
    "an unmeasured row must not be filed as this week's limit either"
  assert_contains "$weekly_block" "grok (credits)" \
    "a measured window still lands in the section whose claim is true of it"

  order=$(printf '%s\n' "$out" | awk '/WEEKLY LIMIT/ { print "W" } /DAILY LIMIT/ { print "D" } /UNKNOWN LIMIT/ { print "U" }' | tr -d '\n')
  [ "$order" = "WDU" ] \
    || fail "sections must read WEEKLY, then DAILY, then UNKNOWN last, got '$order' in: $out"

  fallbacks=$(printf '%s\n' "$out" | grep -c 'dispatch limit not reported\] claude')
  [ "$fallbacks" = 1 ] || fail "a provider gets exactly one fallback gauge row, got $fallbacks in: $out"
  pass "fm-quota-dash: unmeasured rows group under a trailing UNKNOWN LIMIT section"
}

test_unknown_section_is_absent_when_every_cycle_is_known() {
  local case_dir fakebin real_jq out
  case_dir="$TMP_ROOT/no-unknown-section"
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
    {"id":"five_hour","label":"session","percentRemaining":80,"resetsAt":"2030-01-01T01:00:00Z"},
    {"id":"seven_day","label":"week","percentRemaining":70,"resetsAt":"2030-01-07T01:00:00Z"}]},
  {"provider":"codex","plan":"plus","windows":[
    {"id":"weekly","kind":"weekly","label":"week","percentRemaining":50,"resetsAt":"2030-01-07T01:00:00Z"}]},
  {"provider":"grok","plan":"heavy","windows":[
    {"id":"credits","kind":"credits","label":"credits","percentRemaining":42,"resetsAt":"2030-01-07T01:00:00Z"}]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --once)
  assert_not_contains "$out" "UNKNOWN LIMIT" \
    "a fleet whose windows all state a cycle must not carry an empty UNKNOWN heading"
  assert_not_contains "$out" "(none)" "every section must have rows in this fixture"
  assert_contains "$out" "claude (session)" "a session window is a daily-cycle claim"
  assert_contains "$out" "claude (week)" "a seven-day window is a weekly-cycle claim"
  pass "fm-quota-dash: UNKNOWN LIMIT appears only when something is unmeasured"
}

test_window_without_a_stated_cycle_is_not_claimed_as_daily() {
  local case_dir fakebin real_jq out daily_block unknown_block
  case_dir="$TMP_ROOT/no-stated-cycle"
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
    {"id":"widgets","label":"widgets","percentRemaining":55},
    {"id":"five_hour","label":"session","percentRemaining":80,"resetsAt":"2030-01-01T01:00:00Z"}]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider kimi --once)
  daily_block=$(printf '%s\n' "$out" | sed -n '/DAILY LIMIT/,/UNKNOWN LIMIT/p')
  unknown_block=$(printf '%s\n' "$out" | sed -n '/UNKNOWN LIMIT/,$p')
  assert_contains "$unknown_block" "kimi (widgets)" \
    "a window that states no cycle length must not be claimed by a cycle section"
  assert_not_contains "$daily_block" "kimi (widgets)" \
    "the nearest plausible section is not evidence of a cycle"
  assert_contains "$daily_block" "kimi (session)" \
    "a session window in the same payload still lands in DAILY LIMIT"
  assert_contains "$out" " 55.0%" "an unmeasured cycle does not hide a measured percentage"
  pass "fm-quota-dash: a window with no stated cycle is grouped as unknown, not daily"
}

test_full_table_is_used_exactly_when_it_fits() {
  local case_dir fakebin real_jq wide_out needed grid fit_out spill_out tight_out restored longest header
  case_dir="$TMP_ROOT/table-boundary"
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
    {"id":"five_hour","label":"session","percentRemaining":80,"resetsAt":"2030-01-01T01:00:00Z"},
    {"id":"seven_day","label":"week","percentRemaining":70,"resetsAt":"2030-01-07T01:00:00Z"}]},
  {"provider":"codex","plan":"plus","windows":[
    {"id":"weekly","kind":"weekly","label":"week","percentRemaining":50,"resetsAt":"2030-01-07T01:00:00Z"}]},
  {"provider":"grok","plan":"heavy","windows":[
    {"id":"credits","kind":"credits","label":"credits","percentRemaining":42,"resetsAt":"2030-01-07T01:00:00Z"}]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  # Both boundaries are read off the rendered table rather than restated here:
  # its longest row is what the full table needs, and its header line - whose
  # last cell is the AVAILABILITY label - is what the grid alone costs.
  wide_out=$(PATH="$fakebin:$BASE_PATH" COLUMNS=200 FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --once)
  needed=$(printf '%s\n' "$wide_out" \
    | awk '/AVAILABILITY/ || /^ *[0-9]+ [a-z]/ { if (length > m) m = length } END { print m + 0 }')
  grid=$(printf '%s\n' "$wide_out" | awk '/AVAILABILITY/ { print length; exit }')
  [ "${needed:-0}" -gt 0 ] && [ "${grid:-0}" -gt 0 ] \
    || fail "could not measure the full table in: $wide_out"
  [ "$needed" -le 80 ] \
    || fail "the full table must fit an ordinary 80-column terminal, it needs $needed"
  assert_not_contains "$wide_out" "full table needs" \
    "a pane wider than the table has nothing to report"

  fit_out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$needed" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --once)
  assert_contains "$fit_out" "AVAILABILITY" \
    "at exactly the width it measures, the full table must be the one drawn"
  assert_contains "$fit_out" "weekly cap unmeasured" "the caveat survives at the boundary width"
  longest=$(printf '%s\n' "$fit_out" | awk '{ if (length > m) m = length } END { print m + 0 }')
  [ "$longest" -le "$needed" ] \
    || fail "the full table must not wrap at the width it asked for, longest was $longest in: $fit_out"

  # One column short of the widest row: the grid still fits, so the columns
  # stay and only the measurement is reported.
  spill_out=$(PATH="$fakebin:$BASE_PATH" COLUMNS=$(( needed - 1 )) FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --once)
  header=$(printf '%s\n' "$spill_out" | awk '/ ID +MODEL/ { print; exit }')
  assert_contains "$header" "AVAILABILITY" \
    "a pane that can still hold the grid must keep PLAN, RESETS and AVAILABILITY"
  assert_contains "$spill_out" "full table needs $needed cols" \
    "a pane short of the full table must be told what it would cost"

  # One column short of the grid: compact is the honest fallback, and it still
  # reports the requirement and keeps the caveat.
  tight_out=$(PATH="$fakebin:$BASE_PATH" COLUMNS=$(( grid - 1 )) FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --once)
  header=$(printf '%s\n' "$tight_out" | awk '/ ID +MODEL/ { print; exit }')
  assert_not_contains "$header" "AVAILABILITY" \
    "a pane too narrow for the grid must fall back to the compact table"
  # The width the captain is sent looking for must be the one that actually
  # brings the dropped columns back, measured by widening the pane to it.
  assert_contains "$tight_out" "PLAN/RESETS/AVAILABILITY return at $grid cols" \
    "the compact fallback must state the grid width that restores the columns"
  assert_contains "$tight_out" "full table needs $needed cols" \
    "the wider spill-free measurement stays disclosed, on its own line"
  restored=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$grid" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --once)
  header=$(printf '%s\n' "$restored" | awk '/ ID +MODEL/ { print; exit }')
  assert_contains "$header" "PLAN" "the stated width must restore PLAN"
  assert_contains "$header" "RESETS" "the stated width must restore RESETS"
  assert_contains "$header" "AVAILABILITY" "the stated width must restore AVAILABILITY"
  assert_contains "$tight_out" "weekly cap unmeasured" \
    "falling back to compact must not drop Grok's caveat"
  longest=$(printf '%s\n' "$tight_out" | awk '{ if (length > m) m = length } END { print m + 0 }')
  [ "$longest" -le $(( grid - 1 )) ] \
    || fail "the compact fallback must fit the pane, longest was $longest in: $tight_out"
  pass "fm-quota-dash: the table's own measured width decides full vs compact"
}

# Every configured provider owes the captain a row. These cases assert the
# shape an unread provider takes: exactly one gauge, under UNKNOWN LIMIT, and
# counted among the resources - never a provider that simply is not on screen.
assert_unread_provider() {  # <out> <provider> <label>
  local out=$1 prov=$2 label=$3 unknown_block gauges
  unknown_block=$(printf '%s\n' "$out" | sed -n '/UNKNOWN LIMIT/,$p')
  assert_contains "$unknown_block" "UNREADABLE - run: quota-axi --allow-keychain-prompt] $prov" \
    "$label: $prov must render once as unreadable under UNKNOWN LIMIT"
  gauges=$(printf '%s\n' "$out" | grep -c "UNREADABLE - run: quota-axi --allow-keychain-prompt] $prov")
  [ "$gauges" = 1 ] \
    || fail "$label: $prov must get exactly one gauge row, got $gauges in: $out"
}

test_a_failed_quota_read_never_hides_a_provider() {
  local case_dir fakebin real_jq out prov
  case_dir="$TMP_ROOT/failed-read"
  fakebin=$(fm_fakebin "$case_dir")
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for quota dashboard tests"

  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
echo 'quota-axi: could not reach any provider' >&2
exit 1
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider claude,codex,grok --once)
  for prov in claude codex grok; do
    assert_unread_provider "$out" "$prov" "a quota-axi that fails outright"
  done
  assert_contains "$out" "weekly cap unmeasured" \
    "Grok's unmeasured weekly cap survives a failed quota read"
  assert_contains "$out" "Resources: 4" \
    "three unread providers plus the image row are four resources, not one"
  pass "fm-quota-dash: a failed quota-axi run shows every provider as unread, not as nothing"
}

test_unparseable_quota_output_never_hides_a_provider() {
  local case_dir fakebin real_jq out prov
  case_dir="$TMP_ROOT/unparseable"
  fakebin=$(fm_fakebin "$case_dir")
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for quota dashboard tests"

  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  # Exit 0 with prose instead of JSON: a successful run whose output cannot be
  # read is still no report at all.
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
echo 'no accounts configured'
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider claude,codex,grok --once)
  for prov in claude codex grok; do
    assert_unread_provider "$out" "$prov" "output that is not JSON"
  done
  pass "fm-quota-dash: output that is not JSON leaves every provider disclosed as unread"
}

test_provider_missing_from_the_payload_still_gets_a_row() {
  local case_dir fakebin real_jq out weekly_block prov
  case_dir="$TMP_ROOT/partial-payload"
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
    {"id":"credits","kind":"credits","label":"credits","percentRemaining":42,"resetsAt":"2030-01-07T01:00:00Z"}]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider claude,codex,grok --once)
  for prov in claude codex; do
    assert_unread_provider "$out" "$prov" "a payload that omits a configured provider"
  done
  weekly_block=$(printf '%s\n' "$out" | sed -n '/WEEKLY LIMIT/,/DAILY LIMIT/p')
  assert_contains "$weekly_block" "grok (credits)" \
    "the provider the payload did report keeps its measured window"
  assert_contains "$out" " 42.0%" "a missing neighbour must not cost a reported provider its number"
  pass "fm-quota-dash: a provider the payload omits is disclosed, not dropped"
}

test_failed_run_does_not_claim_a_provider_reported_no_limit() {
  local case_dir fakebin real_jq out
  case_dir="$TMP_ROOT/failed-partial"
  fakebin=$(fm_fakebin "$case_dir")
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for quota dashboard tests"

  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  # A run that printed a payload AND failed: "dispatch limit not reported" is a
  # claim about a complete answer, which a failed run never gave.
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[
  {"provider":"claude","plan":"max","windows":[
    {"id":"model:fable","label":"Fable week","percentRemaining":60,"resetsAt":"2030-01-07T01:00:00Z"}]}
]}
JSON
exit 1
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider claude --once)
  assert_unread_provider "$out" claude "a failed run that still printed a payload"
  assert_not_contains "$out" "dispatch limit not reported" \
    "a failed run is not evidence that the provider reported no dispatch limit"
  pass "fm-quota-dash: the quota-axi exit state survives into what the row claims"
}

test_a_payload_jq_cannot_walk_lists_every_provider() {
  local case_dir fakebin real_jq out prov
  case_dir="$TMP_ROOT/unwalkable-payload"
  fakebin=$(fm_fakebin "$case_dir")
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for quota dashboard tests"

  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  # Valid JSON, exit 0, but the provider entries are strings: the row program
  # cannot walk them, and the guarantee that every provider renders must not
  # depend on the program the bad payload breaks.
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
echo '{"providers":["claude","codex"]}'
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$WIDE" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider claude,codex,grok --once)
  for prov in claude codex grok; do
    assert_unread_provider "$out" "$prov" "a payload whose provider entries are not objects"
  done
  assert_contains "$out" "Resources: 4" \
    "a malformed payload must not shrink the fleet to the image row"
  pass "fm-quota-dash: a payload jq cannot walk still lists every configured provider"
}

test_status_rows_are_measured_against_the_pane() {
  local case_dir fakebin real_jq wide_out fit_out tight_out helpwide longest
  case_dir="$TMP_ROOT/status-width"
  fakebin=$(fm_fakebin "$case_dir")
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for quota dashboard tests"

  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  # One of each status row in a single payload: claude answers with no dispatch
  # window (UNKNOWN), codex answers with one (a gauge), and grok is left out
  # entirely (UNREADABLE, and the only row carrying a caveat).
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[
  {"provider":"claude","plan":"max","windows":[
    {"id":"model:fable","label":"Fable week","percentRemaining":60,"resetsAt":"2030-01-07T01:00:00Z"}]},
  {"provider":"codex","plan":"plus","windows":[
    {"id":"weekly","kind":"weekly","label":"week","percentRemaining":50,"resetsAt":"2030-01-07T01:00:00Z"}]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  # The boundary is the longest status row the dashboard actually printed, not
  # a width restated here: retuning the wording retunes the case with it.
  wide_out=$(PATH="$fakebin:$BASE_PATH" COLUMNS=200 FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider claude,codex,grok --once)
  helpwide=$(printf '%s\n' "$wide_out" \
    | awk '/UNREADABLE - run:/ { if (length > m) m = length } END { print m + 0 }')
  [ "${helpwide:-0}" -gt 0 ] || fail "could not measure an unreadable status row in: $wide_out"
  assert_not_contains "$wide_out" "  unreadable: run" \
    "a pane that fits the remedy inline must not repeat it at the bottom"

  fit_out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$helpwide" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider claude,codex,grok --once)
  assert_contains "$fit_out" "UNREADABLE - run: quota-axi --allow-keychain-prompt] grok" \
    "at exactly the width it measures, the status row keeps its remedy"
  longest=$(printf '%s\n' "$fit_out" | awk '{ if (length > m) m = length } END { print m + 0 }')
  [ "$longest" -le "$helpwide" ] \
    || fail "no line may exceed the $helpwide-column pane, longest was $longest in: $fit_out"

  # One column short: the remedy is the only thing that may give way, and it
  # moves to the bottom rather than disappearing.
  tight_out=$(PATH="$fakebin:$BASE_PATH" COLUMNS=$(( helpwide - 1 )) FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider claude,codex,grok --once)
  assert_not_contains "$tight_out" "UNREADABLE - run:" \
    "a pane too narrow for the remedy must not wrap the status row"
  assert_contains "$tight_out" "[UNREADABLE] grok" \
    "the unreadable fact itself is never dropped"
  assert_contains "$tight_out" "weekly cap unmeasured" \
    "the caveat survives a pane too narrow for the remedy"
  assert_contains "$tight_out" "UNKNOWN - dispatch limit not reported] claude" \
    "dispatch-limit-not-reported is a fact, so it is preserved at every width"
  assert_contains "$tight_out" "unreadable: run: quota-axi --allow-keychain-prompt" \
    "the remedy the row could not carry must still be stated once"
  longest=$(printf '%s\n' "$tight_out" | awk '{ if (length > m) m = length } END { print m + 0 }')
  [ "$longest" -le $(( helpwide - 1 )) ] \
    || fail "no line may exceed the $(( helpwide - 1 ))-column pane, longest was $longest in: $tight_out"
  pass "fm-quota-dash: status rows are measured against the pane like every other line"
}

test_gauge_lines_shrink_below_the_preferred_bar() {
  local case_dir fakebin real_jq wide_out overhead narrow out longest
  case_dir="$TMP_ROOT/gauge-shrink"
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
  {"provider":"codex","plan":"plus","windows":[
    {"id":"weekly","kind":"weekly","label":"week","percentRemaining":50,"resetsAt":"2030-01-07T01:00:00Z"}]}
]}
JSON
SH
  chmod +x "$fakebin/jq" "$fakebin/quota-axi"

  # Everything the widest gauge line spends outside its bar, measured from a
  # pane wide enough for the bar's 40-column ceiling.
  wide_out=$(PATH="$fakebin:$BASE_PATH" COLUMNS=200 FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider codex --once)
  overhead=$(printf '%s\n' "$wide_out" | awk '/^ *[0-9]+ \[/ { if (length > m) m = length } END { print m - 40 }')
  [ "${overhead:-0}" -gt 0 ] || fail "could not measure the gauge overhead in: $wide_out"

  # A pane that leaves room for only five bar columns: the bar is what gives
  # way, so the line still fits and the percentage is still there to read.
  narrow=$(( overhead + 5 ))
  out=$(PATH="$fakebin:$BASE_PATH" COLUMNS="$narrow" FM_HOME="$case_dir/home" "$ROOT/bin/fm-quota-dash.sh" --provider codex --once)
  longest=$(printf '%s\n' "$out" | awk '/^ *[0-9]+ \[/ { if (length > m) m = length } END { print m + 0 }')
  [ "$longest" -le "$narrow" ] \
    || fail "no gauge line may exceed the $narrow-column pane, longest was $longest in: $out"
  assert_contains "$out" " 50.0%" "the percentage is what the bar shrinks to protect"
  assert_contains "$out" "100.0%" "every gauge keeps its number at the narrow width"
  pass "fm-quota-dash: a gauge bar shrinks past its preferred width rather than wrapping"
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
test_unmeasured_rows_group_under_unknown_limit
test_unknown_section_is_absent_when_every_cycle_is_known
test_window_without_a_stated_cycle_is_not_claimed_as_daily
test_full_table_is_used_exactly_when_it_fits
test_a_failed_quota_read_never_hides_a_provider
test_unparseable_quota_output_never_hides_a_provider
test_provider_missing_from_the_payload_still_gets_a_row
test_failed_run_does_not_claim_a_provider_reported_no_limit
test_a_payload_jq_cannot_walk_lists_every_provider
test_status_rows_are_measured_against_the_pane
test_gauge_lines_shrink_below_the_preferred_bar
test_help_prints_the_whole_header
test_other_providers_keep_reported_windows
