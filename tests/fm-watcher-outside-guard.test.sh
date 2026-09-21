#!/usr/bin/env bash
# Behavior tests for the home-scoped outside-session watcher guard.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-watcher-outside-guard)
GUARD="$ROOT/bin/fm-watcher-outside-guard.sh"

make_home() { local d="$TMP_ROOT/$1"; mkdir -p "$d/state"; (cd "$d" && pwd -P); }
test_idle_home_stays_silent() {
  local home; home=$(make_home idle)
  FM_WEDGE_ALARM_EXEC=discard "$GUARD" --home "$home" >/dev/null || fail "idle guard failed"
  [ ! -e "$home/state/.watcher-outside-guard-episode" ] || fail "idle home made episode"
  [ ! -e "$home/state/.watcher-outside-guard-events.log" ] || fail "idle home made event"
  pass "idle home with stale or absent beacon does not alert"
}
test_dead_required_home_alerts_once() {
  local home log recorder; home=$(make_home dead); log="$home/alerts"; recorder="$home/recorder"; : > "$home/state/task.meta"
  # shellcheck disable=SC2016 # $1/$2 belong to the generated recorder.
  printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" "$1" "$2" >> "%s"\n' "$log" > "$recorder"; chmod +x "$recorder"
  FM_WEDGE_ALARM_EXEC="$recorder" FM_WEDGE_ALARM_CHANNEL=osascript "$GUARD" --home "$home" || fail "first guard failed"
  FM_WEDGE_ALARM_EXEC="$recorder" FM_WEDGE_ALARM_CHANNEL=osascript "$GUARD" --home "$home" || fail "second guard failed"
  [ "$(wc -l < "$home/state/.watcher-outside-guard-events.log" | tr -d ' ')" = 1 ] || fail "expected one event"
  grep -F 'watcher supervision LOST' "$log" >/dev/null || fail "missing alert summary"
  [ "$(wc -l < "$log" | tr -d ' ')" = 1 ] || fail "expected one alert"
  pass "required dead supervision records and alerts exactly once"
}
test_quota_freeze_requires_supervision() {
  local home; home=$(make_home quota); mkdir "$home/state/quota-frozen"; : > "$home/state/quota-frozen/obligation"
  FM_WEDGE_ALARM_EXEC=discard "$GUARD" --home "$home" >/dev/null || fail "quota guard failed"
  grep -F 'quota_frozen=1' "$home/state/.watcher-outside-guard-events.log" >/dev/null || fail "quota obligation was not counted"
  pass "regular quota-freeze obligation requires supervision"
}
test_idle_home_stays_silent
test_dead_required_home_alerts_once
test_quota_freeze_requires_supervision
