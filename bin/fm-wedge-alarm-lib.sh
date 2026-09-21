#!/usr/bin/env bash
# Shared wedge-alarm notification owner.
# Source only; callers provide log() (or receive quiet best-effort logging).

: "${WEDGE_ALARM_TIMEOUT_SECS_DEFAULT:=10}"
: "${WEDGE_ALARM_NOTIFIER_PID:=}"
wedge_alarm_log() { if declare -F log >/dev/null 2>&1; then log "$@"; fi; }
wedge_alarm_configured_channels() {
  local cfg line found=
  if [ -n "${FM_WEDGE_ALARM_CHANNEL:-}" ]; then printf '%s\n' "$FM_WEDGE_ALARM_CHANNEL"; return; fi
  cfg="${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}/wedge-alarm"
  if [ -f "$cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] || continue; case "$line" in \#*) continue;; esac
      printf '%s\n' "$line"; found=1
    done < "$cfg"
  fi
  [ -n "$found" ] || printf 'auto\n'
}
wedge_alarm_platform_default() { case "$(uname)" in Darwin) command -v osascript >/dev/null 2>&1 && printf osascript;; esac; }
wedge_alarm_stop_active_notifier() { local pid=${WEDGE_ALARM_NOTIFIER_PID:-}; [ -n "$pid" ] || return 0; WEDGE_ALARM_NOTIFIER_PID=; kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true; sleep 0.2; kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
wedge_alarm_run_bounded() {
  local channel=$1 timeout monitor=0 pid start elapsed rc; shift
  timeout=${FM_WEDGE_ALARM_TIMEOUT_SECS:-$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT}; case "$timeout" in ''|*[!0-9]*) timeout=$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT;; *) [ "$timeout" -gt 0 ] 2>/dev/null || timeout=$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT;; esac
  case $- in *m*) monitor=1;; esac; set -m 2>/dev/null || true; case $- in *m*);; *) wedge_alarm_log "wedge alarm: ${channel} notifier skipped because its watchdog could not start"; return 125;; esac
  "$@" & pid=$!; WEDGE_ALARM_NOTIFIER_PID=$pid; start=$SECONDS
  while kill -0 "-$pid" 2>/dev/null; do elapsed=$((SECONDS-start)); if [ "$elapsed" -ge "$timeout" ]; then wedge_alarm_stop_active_notifier; [ "$monitor" -eq 1 ] || set +m 2>/dev/null || true; wedge_alarm_log "wedge alarm: ${channel} notifier timed out after ${elapsed}s (limit ${timeout}s)"; return 124; fi; sleep 0.1; done
  if wait "$pid"; then rc=0; else rc=$?; fi; WEDGE_ALARM_NOTIFIER_PID=; [ "$monitor" -eq 1 ] || set +m 2>/dev/null || true; return "$rc"
}
wedge_alarm_emit() {
  local channel=$1 summary=$2 cmd=${3:-} rc override=${FM_WEDGE_ALARM_EXEC:-}
  case "$override" in discard) return 0;; '') ;; *) wedge_alarm_run_bounded "$channel" "$override" "$channel" "$summary" >/dev/null 2>&1; return $?;; esac
  case "$channel" in
    osascript) command -v osascript >/dev/null 2>&1 && wedge_alarm_run_bounded osascript osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "firstmate: away-mode escalations WEDGED" sound name "Basso"' -e 'end run' "$summary" >/dev/null 2>&1 ;;
    herdr) command -v herdr >/dev/null 2>&1 && wedge_alarm_run_bounded herdr herdr notification show "firstmate: away-mode escalations WEDGED" --body "$summary" --sound request >/dev/null 2>&1 ;;
    command) [ -n "$cmd" ] && wedge_alarm_run_bounded command sh -c "$cmd" fm-wedge-alarm "$summary" <<< "$summary" >/dev/null 2>&1 ;;
  esac
}
wedge_alarm_notify() {
  local summary=$1 marker=$2 ch; local -a channels=()
  while IFS= read -r ch; do [ -n "$ch" ] && channels+=("$ch"); done < <(wedge_alarm_configured_channels)
  for ch in "${channels[@]}"; do [ "$ch" = off ] && return 0; done
  for ch in "${channels[@]}"; do case "$ch" in auto|default) ch=$(wedge_alarm_platform_default);; esac; case "$ch" in '') wedge_alarm_log "wedge alarm: no OS-level alert channel; durable marker $marker is the only signal";; osascript|herdr) wedge_alarm_emit "$ch" "$summary" || true;; command:*) wedge_alarm_emit command "$summary" "${ch#command:}" || true;; *) wedge_alarm_log 'wedge alarm: unrecognized active-alert channel directive (redacted); marker still written';; esac; done
  return 0
}
