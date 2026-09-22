#!/usr/bin/env bash
# Home-scoped, outside-session watcher-loss detector.  It never restarts work.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { printf 'usage: %s --home <absolute-FM_HOME>\n' "${0##*/}" >&2; }
HOME_ARG=
while [ "$#" -gt 0 ]; do case "$1" in --home) [ "$#" -gt 1 ] || { usage; exit 2; }; HOME_ARG=$2; shift 2;; --help|-h) usage; exit 0;; *) usage; exit 2;; esac; done
case "$HOME_ARG" in /*) ;; *) printf 'outside guard: --home must be an absolute directory\n' >&2; exit 2;; esac
[ -d "$HOME_ARG" ] && [ ! -L "$HOME_ARG" ] || { printf 'outside guard: unsafe home\n' >&2; exit 2; }
FM_HOME=$(cd "$HOME_ARG" && pwd -P) || exit 2
[ "$FM_HOME" = "$HOME_ARG" ] || { printf 'outside guard: symlinked home\n' >&2; exit 2; }
STATE="$FM_HOME/state"; [ -d "$STATE" ] && [ ! -L "$STATE" ] || { printf 'outside guard: unsafe state\n' >&2; exit 2; }
log() { printf 'watcher outside guard: %s\n' "$*" >&2; }
# shellcheck source=bin/fm-supervision-lib.sh
. "$DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
FM_STATE_OVERRIDE="$STATE" . "$DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-wedge-alarm-lib.sh
. "$DIR/fm-wedge-alarm-lib.sh"
LOCK="$STATE/.watcher-outside-guard.lock"; EP="$STATE/.watcher-outside-guard-episode"; EVENTS="$STATE/.watcher-outside-guard-events.log"; WATCH="$DIR/fm-watch.sh"; GRACE=${FM_GUARD_GRACE:-300}
fm_lock_try_acquire "$LOCK" || exit 0
trap 'fm_lock_release "$LOCK"' EXIT
fm_supervision_status "$STATE" "$GRACE"
if [ "$FM_SUP_NEEDED" = false ] || fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then [ -e "$EP" ] && { rm -f "$EP"; printf 'watcher outside guard: recovered\n'; }; exit 0; fi
if [ -e "$EP" ] && grep -qx 'notified=1' "$EP" 2>/dev/null; then exit 0; fi
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ ! -e "$EP" ]; then
  episode="$(date +%s)-${BASHPID:-$$}"; tmp=$(mktemp "$STATE/.watcher-outside-guard-episode.XXXXXX") || exit 1
  if ! printf 'version=fm-watcher-outside-guard-v1\nepisode=%s\ndetected_at_utc=%s\nnotified=0\nevent_log=%s\n' "$episode" "$now" "$EVENTS" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$EP"; then rm -f "$tmp"; exit 1; fi
fi
wpid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || printf unavailable); wid=unavailable; fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$wpid" "$FM_HOME" && wid=matched || true
fm_session_lock_read "$STATE" || true
if [ -z "${FM_LOCK_PID:-}" ]; then alive=unavailable; elif fm_harness_pid_alive "$FM_LOCK_PID"; then alive=true; else alive=false; fi
up=$(uptime 2>/dev/null | tr '\t\n' ' ' || printf unavailable); pm=$(pmset -g log 2>/dev/null | grep -E 'Wake|Sleep|DarkWake' | tail -5 | tr '\t\n' ' ' || printf unavailable)
line=$(printf '%s\thome=%s\tin_flight=%s\tsources=%s\tquota_frozen=%s\tx=%s\tsprint=%s\tbeacon=%s\twatcher_pid=%s\twatcher_identity=%s\tsession_form=%s\tsession_pid=%s\tsession_harness=%s\tsession=%s\tsession_alive=%s\tuptime=%s\tpmset=%s' "$now" "$FM_HOME" "$FM_SUP_IN_FLIGHT" "$FM_SUP_SOURCES" "$FM_SUP_QUOTA_FROZEN" "$([ -f "$STATE/x-watch.check.sh" ] && echo present || echo absent)" "$([ -f "$STATE/sprint-watch.check.sh" ] && echo present || echo absent)" "$FM_SUP_BEACON_DESC" "$wpid" "$wid" "$FM_LOCK_FORM" "${FM_LOCK_PID:-unavailable}" "${FM_LOCK_HARNESS:-unavailable}" "${FM_LOCK_SESSION:-unavailable}" "$alive" "$up" "$pm")
if ! { [ -f "$EVENTS" ] && tail -n 999 "$EVENTS"; printf '%s\n' "$line"; } > "$EVENTS.tmp" || ! chmod 600 "$EVENTS.tmp" || ! mv -f "$EVENTS.tmp" "$EVENTS"; then exit 1; fi
wedge_alarm_notify "watcher supervision LOST $(basename "$FM_HOME"): in-flight=$FM_SUP_IN_FLIGHT sources=$FM_SUP_SOURCES quota=$FM_SUP_QUOTA_FROZEN beacon=$FM_SUP_BEACON_DESC - see $EVENTS" "$EP" || true
if ! { grep -v '^notified=' "$EP"; printf 'notified=1\nnotified_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$EP.tmp" || ! chmod 600 "$EP.tmp" || ! mv -f "$EP.tmp" "$EP"; then rm -f "$EP.tmp"; exit 1; fi
printf 'watcher outside guard: lost\n'
