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
make_recorder() { local home=$1 log=$2; local recorder="$home/recorder"
  # shellcheck disable=SC2016 # $1/$2 belong to the generated recorder.
  printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" "$1" "$2" >> "%s"\n' "$log" > "$recorder"; chmod +x "$recorder"; printf '%s' "$recorder"
}
test_unnotified_episode_marker_retries_alert() {
  local home log recorder ep out; home=$(make_home retry); log="$home/alerts"; recorder=$(make_recorder "$home" "$log"); : > "$home/state/task.meta"
  ep="$home/state/.watcher-outside-guard-episode"
  printf 'version=fm-watcher-outside-guard-v1\nepisode=stale-1\ndetected_at_utc=2026-01-01T00:00:00Z\nnotified=0\nevent_log=%s\n' "$home/state/.watcher-outside-guard-events.log" > "$ep"
  out=$(FM_WEDGE_ALARM_EXEC="$recorder" FM_WEDGE_ALARM_CHANNEL=osascript "$GUARD" --home "$home") || fail "retry guard failed"
  [ "$out" = 'watcher outside guard: lost' ] || fail "unnotified episode did not report lost: $out"
  [ "$(wc -l < "$log" | tr -d ' ')" = 1 ] || fail "unnotified episode marker suppressed the alert"
  grep -qx 'notified=1' "$ep" || fail "marker was not promoted to notified after the alert"
  grep -qx 'episode=stale-1' "$ep" || fail "retry replaced the in-progress episode identity"
  out=$(FM_WEDGE_ALARM_EXEC="$recorder" FM_WEDGE_ALARM_CHANNEL=osascript "$GUARD" --home "$home") || fail "post-retry guard failed"
  [ -z "$out" ] || fail "an already-notified episode printed: $out"
  [ "$(wc -l < "$log" | tr -d ' ')" = 1 ] || fail "notified episode alerted again"
  pass "an episode marker left at notified=0 retries the alert once, then stays quiet"
}
test_steady_state_runs_print_nothing() {
  local home log recorder out; home=$(make_home quiet); log="$home/alerts"; recorder=$(make_recorder "$home" "$log")
  out=$(FM_WEDGE_ALARM_EXEC=discard "$GUARD" --home "$home"; FM_WEDGE_ALARM_EXEC=discard "$GUARD" --home "$home") || fail "idle guard failed"
  [ -z "$out" ] || fail "idle runs printed: $out"
  : > "$home/state/task.meta"
  out=$(FM_WEDGE_ALARM_EXEC="$recorder" FM_WEDGE_ALARM_CHANNEL=osascript "$GUARD" --home "$home") || fail "lost guard failed"
  [ "$out" = 'watcher outside guard: lost' ] || fail "loss transition did not print once: $out"
  out=$(FM_WEDGE_ALARM_EXEC="$recorder" FM_WEDGE_ALARM_CHANNEL=osascript "$GUARD" --home "$home") || fail "repeat guard failed"
  [ -z "$out" ] || fail "repeated lost run printed: $out"
  rm "$home/state/task.meta"
  out=$(FM_WEDGE_ALARM_EXEC=discard "$GUARD" --home "$home") || fail "recovery guard failed"
  [ "$out" = 'watcher outside guard: recovered' ] || fail "recovery transition did not print once: $out"
  [ ! -e "$home/state/.watcher-outside-guard-episode" ] || fail "recovery left the episode marker"
  out=$(FM_WEDGE_ALARM_EXEC=discard "$GUARD" --home "$home") || fail "post-recovery guard failed"
  [ -z "$out" ] || fail "post-recovery idle run printed: $out"
  pass "the guard prints only on loss and recovery transitions, never on steady-state runs"
}
test_idle_home_stays_silent
test_dead_required_home_alerts_once
test_quota_freeze_requires_supervision
test_unnotified_episode_marker_retries_alert
test_steady_state_runs_print_nothing
