#!/usr/bin/env bash
# Hold-to-talk voice input for Herdr agent panes: hold a chord, speak, release,
# and a LOCAL whisper.cpp transcription is TYPED into the composer of the
# focused agent pane - never submitted. The operator reads it and presses Enter.
#
# This script is the single owner of every policy decision in the feature -
# the config keys, the focus rule, the silence gates, the hallucination list,
# the state cues, and the exit codes - so the ordinary shell test suite covers
# them with fake whisper-cli/herdr/afplay/pbcopy binaries
# (tests/fm-voice.test.sh). The compiled daemon (bin/fm-voice-hotkey.swift) only
# observes the chord and records audio while it is held; it knows nothing about
# Herdr and hands every recording to `fm-voice.sh submit`.
#
# OFF BY DEFAULT, like X mode: nothing here runs, installs, downloads, or prints
# unless $FM_HOME/config/voice exists. Without it every subcommand except
# --help and status exits 2, status prints "off", and bootstrap's voice step is
# a hard no-op. config/voice is LOCAL, gitignored, and NOT inherited by
# secondmate homes (a secondmate never runs the daemon).
#
# Configuration - config/voice, KEY=VALUE lines, every key optional
# (an empty file enables the feature with these defaults):
#   hotkey       modifier chord, default ctrl+alt+space. Grammar: one or more of
#                ctrl, alt, shift, cmd joined by "+", then "+", then exactly one
#                key: space, a-z, 0-9, f1-f19, esc, tab, return, ` - = [ ] ; ' , . /
#                A bare modifier or the Fn key is impossible without Input
#                Monitoring, so it is refused rather than approximated.
#   model        whisper ggml weights path, default
#                ${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/voice/ggml-large-v3-turbo-q5_0.bin
#   language     whisper language code or "auto", default ru
#   max_seconds  recording cap per press, integer 5..600, default 120
#   min_dbfs     peak level below which a recording is silence, integer -90..0,
#                default -45
#   sounds       on (default) or off - the afplay state cues
#
# Subcommands (all but --help/status exit 2 when config/voice is absent):
#   status         prints off | not ready | ready | running (pid N); exit 0
#   doctor         MISSING:/MISSING_MANUAL: lines for whisper-cpp, swiftc, jq,
#                  python3, then exactly one VOICE: summary line; exit 0 ready/running/
#                  macOS-only, 1 not ready
#   build          compile the daemon with swiftc -O into the voice cache,
#                  content-addressed by the source hash; exit 7 on failure
#   install-model [--full] [--yes]
#                  download the pinned weights (q5_0 by default, --full for the
#                  full-precision file) after printing URL, size, destination
#                  and reading "yes" from the terminal (--yes skips the prompt);
#                  exit 6 checksum/download failure, 8 declined
#   start          validate config, refuse a second instance, sweep leftovers,
#                  warm the model once, then exec the daemon in the foreground;
#                  exit 2 invalid config or not ready, 3 microphone denied,
#                  4 hot key registration failed, 5 already running
#   stop           SIGTERM the recorded daemon; exit 1 when none runs
#   submit <wav>   gate, transcribe, deliver; prints exactly one line
#                  (typed into ... | nothing heard | refused: ... | failed: ...
#                  | busy: ...); exit 0 typed, 3 refused, 4 nothing heard,
#                  5 failed (including an invalid config/voice, re-read on
#                  every submit), 9 another submit holds the lock
#   cue <state>    play the afplay cue for a state (used by the daemon)
#
# Silence protection is DOUBLE and both halves are mandatory: whisper invents
# text on silence ("Продолжение следует...") and no whisper-cli flag stops it.
#   1. BEFORE whisper: duration < 0.5 s or peak below min_dbfs => nothing heard.
#   2. AFTER whisper: the collapsed transcript is compared, case-insensitively
#      and ignoring trailing . ! …, against FM_VOICE_HALLUCINATIONS, the
#      list assigned right below this header.
# The list matches the WHOLE transcript only. No phrase is ever removed from a
# longer transcript, because a trimmed transcript would silently lose speech.
#
# Delivery rule: `herdr pane list` must show exactly one focused pane, it must
# carry a non-empty agent, and agent_status must be idle, working, or done.
# blocked (an approval or question dialog) and unknown are refused, because
# typing into a dialog can answer it. The only delivery command ever used is
# `herdr pane send-text` - never `herdr agent prompt`, `herdr pane run`, or
# `send-keys enter`. A refusal copies the transcript to the clipboard (pbcopy)
# and types nowhere; another pane is never picked.
#
# Audio at rest: the daemon records into a fresh 0700 directory
# $TMPDIR/fm-voice.XXXXXX; submit deletes that directory on every exit path
# (EXIT/INT/TERM/HUP trap) and start sweeps any leftover fm-voice.* directory.
# No audio is ever written under data/, state/, projects/, or the repository,
# and no audio path is printed.
#
# State cues (sounds=on), each via afplay /System/Library/Sounds/<name>.aiff in
# the background: recording Tink, transcribing Pop, typed Glass, nothing heard/
# refused/busy Basso, failed Sosumi. submit also tries
# `herdr notification show` best-effort and ignores a disabled toast.
#
# Environment:
#   FM_HOME, FM_CONFIG_OVERRIDE, FM_STATE_OVERRIDE  the usual home resolution
#   TMPDIR              where recordings live (default /tmp)
#   FM_VOICE_DEBUG=1    pass whisper-cli stderr through instead of discarding it
#   FM_VOICE_OS_OVERRIDE  test seam: pretend uname printed this value so the
#                       macOS-only doctor/start paths are testable on Linux CI
#   FM_VOICE_SOURCE_HASH_OVERRIDE  test seam: daemon source hash used by
#                       build/start, so a fake daemon binary can be planted
#   FM_VOICE_MODEL_SHA256_OVERRIDE  test seam: pinned checksum for install-model
#   FM_VOICE_NO_WARMUP=1  test seam: start skips the whisper warm-up run
#
# Model pins (re-verified 2026-09-09 against huggingface x-linked-etag):
#   ggml-large-v3-turbo-q5_0.bin 574041195 B
#     394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2
#   ggml-large-v3-turbo.bin      1624555275 B
#     1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69
set -u

FM_VOICE_HALLUCINATIONS='Продолжение следует
Субтитры сделал DimaTorzok
Субтитры делал DimaTorzok
Редактор субтитров А.Семкин Корректор А.Егорова
Спасибо за просмотр
you
Thank you
Thanks for watching
[BLANK_AUDIO]
(music)
[Music]'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONF="$CONFIG/voice"
SELF="$SCRIPT_DIR/fm-voice.sh"
DAEMON_SRC="$SCRIPT_DIR/fm-voice-hotkey.swift"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/voice"
PID_FILE="$STATE/voice.pid"
LOCK_DIR="$STATE/voice.submit.lock"
SOUND_DIR=/System/Library/Sounds

MODEL_Q5_FILE=ggml-large-v3-turbo-q5_0.bin
MODEL_Q5_SIZE=574041195
MODEL_Q5_SHA=394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2
MODEL_FULL_FILE=ggml-large-v3-turbo.bin
MODEL_FULL_SIZE=1624555275
MODEL_FULL_SHA=1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69
MODEL_URL_BASE=https://huggingface.co/ggerganov/whisper.cpp/resolve/main
MODEL_MAX_BYTES=1700000000

# shellcheck source=bin/fm-x-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-x-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//'
}

os_name() {
  if [ -n "${FM_VOICE_OS_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_VOICE_OS_OVERRIDE"
  else
    uname
  fi
}

is_darwin() { [ "$(os_name)" = Darwin ]; }

# --- config -------------------------------------------------------------------

conf_get() {  # <key> <default>
  local v
  v=$(fmx_env_get "$1" "$CONF")
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"
}

load_config() {
  HOTKEY=$(conf_get hotkey ctrl+alt+space)
  MODEL=$(conf_get model "$CACHE_DIR/$MODEL_Q5_FILE")
  LANGUAGE=$(conf_get language ru)
  MAX_SECONDS=$(conf_get max_seconds 120)
  MIN_DBFS=$(conf_get min_dbfs -45)
  SOUNDS=$(conf_get sounds on)
}

is_int() {
  local digits=${1#-}
  case "$digits" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# Prints the first invalid-config reason, or nothing when the config is valid.
config_error() {
  if ! hotkey_valid "$HOTKEY"; then
    printf 'invalid hotkey: %s (expected <ctrl|alt|shift|cmd>[+...]+<key>)\n' "$HOTKEY"
    return
  fi
  if ! is_int "$MAX_SECONDS" || [ "$MAX_SECONDS" -lt 5 ] || [ "$MAX_SECONDS" -gt 600 ]; then
    printf 'invalid max_seconds: %s (expected an integer 5..600)\n' "$MAX_SECONDS"
    return
  fi
  if ! is_int "$MIN_DBFS" || [ "$MIN_DBFS" -lt -90 ] || [ "$MIN_DBFS" -gt 0 ]; then
    printf 'invalid min_dbfs: %s (expected an integer -90..0)\n' "$MIN_DBFS"
    return
  fi
  case "$SOUNDS" in
    on|off) ;;
    *) printf 'invalid sounds: %s (expected on or off)\n' "$SOUNDS"; return ;;
  esac
  case "$LANGUAGE" in
    ''|*[!a-z]*) printf 'invalid language: %s (expected a whisper language code or auto)\n' "$LANGUAGE"; return ;;
  esac
}

hotkey_key_valid() {
  case "$1" in
    space|esc|tab|return|'`'|-|=|'['|']'|';'|"'"|,|.|/) return 0 ;;
    [a-z]|[0-9]) return 0 ;;
    f[1-9]|f1[0-9]) return 0 ;;
  esac
  return 1
}

hotkey_valid() {
  local spec=$1 part rest mods=0
  case "$spec" in
    *+*) ;;
    *) return 1 ;;
  esac
  rest=$spec
  while :; do
    case "$rest" in
      *+*) part=${rest%%+*}; rest=${rest#*+} ;;
      *) break ;;
    esac
    case "$part" in
      ctrl|alt|shift|cmd) mods=$((mods + 1)) ;;
      *) return 1 ;;
    esac
  done
  [ "$mods" -ge 1 ] || return 1
  hotkey_key_valid "$rest"
}

# --- gate ---------------------------------------------------------------------

require_enabled() {
  if [ ! -f "$CONF" ]; then
    echo "voice input is off (create config/voice to enable)"
    exit 2
  fi
}

require_darwin() {
  if ! is_darwin; then
    echo "voice input is macOS only (config/voice ignored on $(os_name))"
    exit 2
  fi
}

# --- cues ---------------------------------------------------------------------

cue_sound_for() {
  case "$1" in
    recording) echo Tink ;;
    transcribing) echo Pop ;;
    typed) echo Glass ;;
    nothing|refused|busy) echo Basso ;;
    failed) echo Sosumi ;;
    *) return 1 ;;
  esac
}

play_cue() {  # <state>
  local sound
  [ "${SOUNDS:-on}" = on ] || return 0
  sound=$(cue_sound_for "$1") || return 0
  command -v afplay >/dev/null 2>&1 || return 0
  afplay "$SOUND_DIR/$sound.aiff" >/dev/null 2>&1 &
}

notify() {  # <title> <body>
  command -v herdr >/dev/null 2>&1 || return 0
  herdr notification show "$1" --body "$2" --sound none >/dev/null 2>&1 || true
}

# --- readiness ----------------------------------------------------------------

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    return 1
  fi
}

file_size() {
  wc -c < "$1" | tr -d '[:space:]'
}

source_hash() {
  if [ -n "${FM_VOICE_SOURCE_HASH_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_VOICE_SOURCE_HASH_OVERRIDE"
  else
    sha256_of "$DAEMON_SRC" | cut -c1-12
  fi
}

daemon_binary() {
  printf '%s/fm-voice-hotkey-%s\n' "$CACHE_DIR" "$(source_hash)"
}

pinned_sha_for_model() {  # prints the pin for a known basename, nothing otherwise
  case "$(basename "$1")" in
    "$MODEL_Q5_FILE") printf '%s %s\n' "$MODEL_Q5_SHA" "$MODEL_Q5_SIZE" ;;
    "$MODEL_FULL_FILE") printf '%s %s\n' "$MODEL_FULL_SHA" "$MODEL_FULL_SIZE" ;;
  esac
}

# A verified sidecar (<model>.verified holding "<size> <sha>") lets doctor skip
# rehashing 574 MB at every session start; the hash runs once per install.
model_status() {  # prints "" when fine, else the not-ready reason
  local pin sha size actual
  if [ ! -f "$MODEL" ]; then
    printf 'model missing at %s (run bin/fm-voice.sh install-model)\n' "$MODEL"
    return
  fi
  pin=$(pinned_sha_for_model "$MODEL")
  [ -n "$pin" ] || return 0
  sha=${pin%% *}; size=${pin##* }
  actual=$(file_size "$MODEL")
  if [ "$actual" != "$size" ]; then
    echo "model checksum mismatch"
    return
  fi
  if [ -f "$MODEL.verified" ] && [ "$(cat "$MODEL.verified")" = "$size $sha" ]; then
    return 0
  fi
  if [ "$(sha256_of "$MODEL")" = "$sha" ]; then
    printf '%s %s\n' "$size" "$sha" > "$MODEL.verified" 2>/dev/null || true
    return 0
  fi
  echo "model checksum mismatch"
}

pid_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

running_pid() {  # prints the live daemon pid, or nothing
  local pid
  [ -f "$PID_FILE" ] || return 0
  pid=$(tr -d '[:space:]' < "$PID_FILE")
  if pid_alive "$pid"; then
    printf '%s\n' "$pid"
  fi
}

# The submit lock is a directory holding the owner's pid, so a holder that died
# without running its trap (SIGKILL, a closed pane, power loss) never wedges
# later submits: a lock whose pid is dead is stale and reclaimed. A lock with no
# pid yet is stale only once it is older than LOCK_GRACE_SECONDS, so a holder
# that has just created the directory and not written its pid is never evicted.
LOCK_GRACE_SECONDS=5

mtime_of() {
  case "$(uname)" in
    Darwin|*BSD) stat -f %m "$1" 2>/dev/null ;;
    *) stat -c %Y "$1" 2>/dev/null ;;
  esac
}

lock_is_stale() {
  local pid mtime now
  [ -d "$LOCK_DIR" ] || return 1
  if [ -f "$LOCK_DIR/pid" ]; then
    pid=$(tr -d '[:space:]' < "$LOCK_DIR/pid" 2>/dev/null) || pid=
    ! pid_alive "$pid"
    return
  fi
  mtime=$(mtime_of "$LOCK_DIR") || return 1
  now=$(date +%s)
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  [ $((now - mtime)) -gt "$LOCK_GRACE_SECONDS" ]
}

clear_stale_lock() {
  lock_is_stale && rm -rf -- "$LOCK_DIR"
  return 0
}

acquire_submit_lock() {  # succeeds once the lock is held with our pid inside
  local attempt
  for attempt in 1 2; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo $$ > "$LOCK_DIR/pid"
      return 0
    fi
    [ "$attempt" -eq 1 ] && lock_is_stale && rm -rf -- "$LOCK_DIR"
  done
  return 1
}

# Fills NOT_READY (comma-separated reasons) and prints the MISSING lines.
collect_readiness() {
  local reasons='' r bin
  if ! command -v whisper-cli >/dev/null 2>&1; then
    echo "MISSING: whisper-cpp (install: brew install whisper-cpp)"
    reasons="$reasons, whisper-cli missing"
  fi
  if ! command -v swiftc >/dev/null 2>&1; then
    echo "MISSING_MANUAL: swiftc (instructions: xcode-select --install)"
    reasons="$reasons, swiftc missing"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "MISSING: jq (install: brew install jq)"
    reasons="$reasons, jq missing"
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "MISSING_MANUAL: python3 (instructions: xcode-select --install)"
    reasons="$reasons, python3 missing"
  fi
  r=$(config_error)
  [ -z "$r" ] || reasons="$reasons, $r"
  r=$(model_status)
  [ -z "$r" ] || reasons="$reasons, $r"
  bin=$(daemon_binary)
  if [ ! -x "$bin" ]; then
    reasons="$reasons, daemon not built (run bin/fm-voice.sh build)"
  elif [ "$("$bin" --probe-mic 2>/dev/null)" = denied ]; then
    reasons="$reasons, microphone denied for the hosting terminal app"
  fi
  if ! command -v herdr >/dev/null 2>&1 || ! herdr status >/dev/null 2>&1; then
    reasons="$reasons, herdr not running"
  fi
  NOT_READY=${reasons#, }
}

cmd_status() {
  local pid
  [ -f "$CONF" ] || { echo off; return 0; }
  is_darwin || { echo "not ready"; return 0; }
  load_config
  pid=$(running_pid)
  if [ -n "$pid" ]; then echo "running (pid $pid)"; return 0; fi
  collect_readiness >/dev/null
  if [ -z "$NOT_READY" ]; then echo ready; else echo "not ready"; fi
}

cmd_doctor() {
  local pid
  require_enabled
  if ! is_darwin; then
    echo "VOICE: macOS only - config/voice ignored on $(os_name)"
    return 0
  fi
  load_config
  pid=$(running_pid)
  if [ -n "$pid" ]; then
    echo "VOICE: running (pid $pid)"
    return 0
  fi
  collect_readiness
  if [ -n "$NOT_READY" ]; then
    echo "VOICE: not ready - $NOT_READY"
    return 1
  fi
  echo "VOICE: ready - start it with bin/fm-voice.sh start"
}

# --- build --------------------------------------------------------------------

cmd_build() {
  local bin out
  require_enabled
  require_darwin
  command -v swiftc >/dev/null 2>&1 || {
    echo "MISSING_MANUAL: swiftc (instructions: xcode-select --install)"
    exit 2
  }
  mkdir -p "$CACHE_DIR"
  bin=$(daemon_binary)
  if [ -x "$bin" ]; then
    echo "daemon already built: $bin"
    return 0
  fi
  echo "compiling $DAEMON_SRC (about a minute the first time)"
  if ! out=$(swiftc -O -o "$bin.tmp" "$DAEMON_SRC" 2>&1); then
    printf '%s\n' "$out"
    rm -f "$bin.tmp"
    echo "compile failed"
    exit 7
  fi
  mv -f "$bin.tmp" "$bin"
  echo "daemon built: $bin"
}

# --- model --------------------------------------------------------------------

cmd_install_model() {
  local full=0 yes=0 file size sha dest url answer actual
  while [ $# -gt 0 ]; do
    case "$1" in
      --full) full=1 ;;
      --yes) yes=1 ;;
      *) echo "install-model: unknown option $1"; exit 2 ;;
    esac
    shift
  done
  require_enabled
  if [ "$full" -eq 1 ]; then
    file=$MODEL_FULL_FILE; size=$MODEL_FULL_SIZE; sha=$MODEL_FULL_SHA
  else
    file=$MODEL_Q5_FILE; size=$MODEL_Q5_SIZE; sha=$MODEL_Q5_SHA
  fi
  sha=${FM_VOICE_MODEL_SHA256_OVERRIDE:-$sha}
  dest="$CACHE_DIR/$file"
  url="$MODEL_URL_BASE/$file"
  if [ -f "$dest" ] && [ "$(file_size "$dest")" = "$size" ] \
    && [ "$(sha256_of "$dest")" = "$sha" ]; then
    printf '%s %s\n' "$size" "$sha" > "$dest.verified"
    echo "model already installed at $dest"
    return 0
  fi
  echo "model: $url"
  echo "size: $size bytes"
  echo "destination: $dest"
  if [ "$yes" -ne 1 ]; then
    if [ ! -r /dev/tty ]; then
      echo "declined: no terminal to confirm on (pass --yes to skip the prompt)"
      exit 8
    fi
    printf 'download it? type yes to continue: '
    read -r answer < /dev/tty || answer=
    if [ "$answer" != yes ]; then
      echo "declined"
      exit 8
    fi
  fi
  command -v curl >/dev/null 2>&1 || { echo "MISSING: curl (install: brew install curl)"; exit 6; }
  mkdir -p "$CACHE_DIR"
  rm -f "$dest.part" "$dest.verified"
  if ! curl -fL --max-filesize "$MODEL_MAX_BYTES" -o "$dest.part" "$url"; then
    rm -f "$dest.part"
    echo "download failed"
    exit 6
  fi
  actual=$(sha256_of "$dest.part") || actual=
  if [ "$actual" != "$sha" ]; then
    rm -f "$dest.part"
    echo "checksum mismatch: expected $sha, got ${actual:-nothing}"
    exit 6
  fi
  mv -f "$dest.part" "$dest"
  printf '%s %s\n' "$size" "$sha" > "$dest.verified"
  echo "model installed at $dest"
}

# --- daemon lifecycle ---------------------------------------------------------

sweep_leftovers() {
  local d
  for d in "${TMPDIR:-/tmp}"/fm-voice.* "${TMPDIR:-/tmp}"/fm-voice-submit.*; do
    [ -d "$d" ] && rm -rf -- "$d"
  done
  return 0
}

warm_up() {
  local dir wav
  [ "${FM_VOICE_NO_WARMUP:-0}" = 1 ] && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-voice.XXXXXX") || return 0
  wav="$dir/warm.wav"
  python3 - "$wav" <<'PY' 2>/dev/null || { rm -rf -- "$dir"; return 0; }
import sys, wave
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(b"\x00\x00" * 16000)
PY
  whisper-cli -m "$MODEL" -f "$wav" -l "$LANGUAGE" -nt -np >/dev/null 2>&1 || true
  rm -rf -- "$dir"
}

cmd_start() {
  local err pid bin
  require_enabled
  require_darwin
  load_config
  err=$(config_error)
  if [ -n "$err" ]; then
    echo "$err"
    exit 2
  fi
  pid=$(running_pid)
  if [ -n "$pid" ]; then
    echo "already running (pid $pid)"
    exit 5
  fi
  rm -f "$PID_FILE"
  clear_stale_lock
  bin=$(daemon_binary)
  if [ ! -x "$bin" ]; then
    echo "daemon not built (run bin/fm-voice.sh build)"
    exit 2
  fi
  collect_readiness >/dev/null
  if [ -n "$NOT_READY" ]; then
    echo "not ready - $NOT_READY"
    exit 2
  fi
  sweep_leftovers
  echo "warming up the model"
  warm_up
  mkdir -p "$STATE"
  echo $$ > "$PID_FILE"
  exec "$bin" --hotkey "$HOTKEY" --max-seconds "$MAX_SECONDS" \
    --submit "$SELF" --sounds "$SOUNDS" --tmpdir "${TMPDIR:-/tmp}"
}

cmd_stop() {
  local pid
  require_enabled
  pid=$(running_pid)
  if [ -z "$pid" ]; then
    rm -f "$PID_FILE"
    echo "not running"
    exit 1
  fi
  kill -TERM "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  echo "stopped (pid $pid)"
}

# --- submit -------------------------------------------------------------------

SUBMIT_DIR=
SUBMIT_WORK=
SUBMIT_CHILD=
SUBMIT_LOCKED=0

# Runs on every exit path, including SIGTERM/SIGINT/SIGHUP: the recording's directory
# (only when it is one the daemon made - a WAV handed in from anywhere else is
# left untouched), the private work directory, and the lock all go, and a
# still-running whisper-cli child is killed first.
submit_cleanup() {
  [ -n "$SUBMIT_CHILD" ] && kill "$SUBMIT_CHILD" 2>/dev/null
  if [ -n "$SUBMIT_DIR" ]; then
    case "$(basename "$SUBMIT_DIR")" in
      fm-voice.*) rm -rf -- "$SUBMIT_DIR" ;;
    esac
  fi
  [ -n "$SUBMIT_WORK" ] && rm -rf -- "$SUBMIT_WORK"
  [ "$SUBMIT_LOCKED" -eq 1 ] && rm -rf -- "$LOCK_DIR"
  return 0
}

# Prints "<duration seconds> <peak dBFS>" for a PCM WAV; fails on a bad file.
wav_probe() {
  python3 - "$1" <<'PY'
import sys, wave, array, math
with wave.open(sys.argv[1], "rb") as w:
    n = w.getnframes(); rate = w.getframerate(); width = w.getsampwidth()
    ch = w.getnchannels(); raw = w.readframes(n)
dur = n / float(rate) if rate else 0.0
if width == 2:
    samples = array.array("h", raw); full = 32768.0
elif width == 1:
    samples = array.array("B", raw); samples = [s - 128 for s in samples]; full = 128.0
elif width == 4:
    samples = array.array("i", raw); full = 2147483648.0
else:
    sys.exit("unsupported sample width %d" % width)
peak = max((abs(s) for s in samples), default=0)
dbfs = 20 * math.log10(peak / full) if peak else -999.0
print("%.3f %.1f" % (dur, dbfs))
PY
}

# Takes the raw whisper stdout as $1; prints three lines: "empty",
# "hallucination", or "speech", then the collapsed text, then its first 80 chars.
classify_transcript() {
  FM_VOICE_HALLUCINATIONS="$FM_VOICE_HALLUCINATIONS" FM_VOICE_TEXT="$1" python3 - <<'PY'
import os, sys
text = " ".join(os.environ["FM_VOICE_TEXT"].split())
def norm(s):
    return s.strip().rstrip(".!…").strip().casefold()
known = [norm(l) for l in os.environ["FM_VOICE_HALLUCINATIONS"].splitlines() if l.strip()]
if not text:
    print("empty")
elif norm(text) in known:
    print("hallucination")
else:
    print("speech")
print(text)
print(text[:80])
PY
}

cmd_submit() {
  local wav err probe dur dbfs below raw rc verdict text short panes focused_json
  local count pane_id agent status title
  require_enabled
  wav=${1:-}
  if [ -z "$wav" ] || [ ! -f "$wav" ]; then
    echo "failed: no recording"
    exit 5
  fi
  load_config
  SUBMIT_DIR=$(cd "$(dirname "$wav")" && pwd)
  trap submit_cleanup EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP
  err=$(config_error)
  if [ -n "$err" ]; then
    play_cue failed
    echo "failed: $err"
    exit 5
  fi
  mkdir -p "$STATE"
  if ! acquire_submit_lock; then
    play_cue busy
    echo "busy: another transcription is running"
    exit 9
  fi
  SUBMIT_LOCKED=1

  if ! command -v python3 >/dev/null 2>&1; then
    play_cue failed
    echo "failed: python3 is required for the silence gate"
    exit 5
  fi
  if ! probe=$(wav_probe "$wav" 2>/dev/null); then
    play_cue failed
    echo "failed: cannot read the recording"
    exit 5
  fi
  dur=${probe%% *}; dbfs=${probe##* }
  below=$(python3 -c 'import sys; print(1 if float(sys.argv[1]) < 0.5 or float(sys.argv[2]) < float(sys.argv[3]) else 0)' "$dur" "$dbfs" "$MIN_DBFS" 2>/dev/null)
  case "$below" in
    1)
      play_cue nothing
      notify "Nothing heard" "recording too short or too quiet"
      echo "nothing heard"
      exit 4
      ;;
    0) ;;
    *)
      play_cue failed
      echo "failed: cannot evaluate the silence gate"
      exit 5
      ;;
  esac

  if ! command -v whisper-cli >/dev/null 2>&1; then
    play_cue failed
    echo "failed: whisper-cli not found (brew install whisper-cpp)"
    exit 5
  fi
  # whisper-cli runs as a background child under `wait` so a SIGTERM to submit
  # reaches the trap immediately instead of after the transcription finishes.
  if ! SUBMIT_WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-voice-submit.XXXXXX" 2>/dev/null); then
    SUBMIT_WORK=
    play_cue failed
    echo "failed: cannot create a scratch directory under TMPDIR"
    exit 5
  fi
  if [ "${FM_VOICE_DEBUG:-0}" = 1 ]; then
    whisper-cli -m "$MODEL" -f "$wav" -l "$LANGUAGE" -nt -np > "$SUBMIT_WORK/out" &
  else
    whisper-cli -m "$MODEL" -f "$wav" -l "$LANGUAGE" -nt -np > "$SUBMIT_WORK/out" 2>/dev/null &
  fi
  SUBMIT_CHILD=$!
  wait "$SUBMIT_CHILD"; rc=$?
  SUBMIT_CHILD=
  raw=$(cat "$SUBMIT_WORK/out")
  if [ "$rc" -ne 0 ]; then
    play_cue failed
    notify "Voice failed" "whisper-cli exited $rc"
    echo "failed: whisper-cli exited $rc"
    exit 5
  fi
  verdict=$(classify_transcript "$raw")
  text=$(printf '%s\n' "$verdict" | sed -n 2p)
  short=$(printf '%s\n' "$verdict" | sed -n 3p)
  case "$(printf '%s\n' "$verdict" | sed -n 1p)" in
    speech) ;;
    *)
      play_cue nothing
      notify "Nothing heard" "silence"
      echo "nothing heard"
      exit 4
      ;;
  esac

  if ! command -v jq >/dev/null 2>&1; then
    printf '%s' "$text" | pbcopy 2>/dev/null || true
    play_cue failed
    echo "failed: jq not found; text is on the clipboard"
    exit 5
  fi
  if ! panes=$(herdr pane list 2>/dev/null); then
    printf '%s' "$text" | pbcopy 2>/dev/null || true
    play_cue failed
    echo "failed: herdr not running; text is on the clipboard"
    exit 5
  fi
  if ! focused_json=$(printf '%s' "$panes" | jq -c '[.result.panes[]? | select(.focused == true)]' 2>/dev/null); then
    printf '%s' "$text" | pbcopy 2>/dev/null || true
    play_cue failed
    echo "failed: herdr pane list returned unreadable JSON; text is on the clipboard"
    exit 5
  fi
  count=$(printf '%s' "$focused_json" | jq 'length')
  if [ "$count" != 1 ]; then
    refuse "no single focused pane" "$text"
  fi
  pane_id=$(printf '%s' "$focused_json" | jq -r '.[0].pane_id // ""')
  agent=$(printf '%s' "$focused_json" | jq -r '.[0].agent // ""')
  status=$(printf '%s' "$focused_json" | jq -r '.[0].agent_status // ""')
  title=$(printf '%s' "$focused_json" | jq -r '.[0].terminal_title_stripped // ""')
  [ -n "$agent" ] || refuse "focused pane $pane_id is not an agent pane" "$text"
  case "$status" in
    idle|working|done) ;;
    blocked) refuse "agent in $pane_id is waiting on a dialog" "$text" ;;
    unknown|'') refuse "agent state unknown in $pane_id" "$text" ;;
    *) refuse "agent in $pane_id has status $status" "$text" ;;
  esac
  if ! herdr pane send-text "$pane_id" "$text" >/dev/null 2>&1; then
    refuse "send-text to $pane_id failed" "$text"
  fi
  play_cue typed
  notify "Typed into $agent" "$short"
  printf 'typed into %s "%s" (%s): %s\n' "$agent" "$title" "$pane_id" "$short"
  exit 0
}

refuse() {  # <reason> <text>
  printf '%s' "$2" | pbcopy 2>/dev/null || true
  play_cue refused
  notify "Refused" "$1"
  echo "refused: $1; text is on the clipboard"
  exit 3
}

cmd_cue() {
  require_enabled
  load_config
  play_cue "${1:-}"
}

# --- dispatch -----------------------------------------------------------------

case "${1:-}" in
  -h|--help|help|'') usage; exit 0 ;;
  status) cmd_status ;;
  doctor) cmd_doctor ;;
  build) cmd_build ;;
  install-model) shift; cmd_install_model "$@" ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  submit) shift; cmd_submit "$@" ;;
  cue) shift; cmd_cue "$@" ;;
  *) echo "fm-voice.sh: unknown subcommand '$1' (see --help)" >&2; exit 2 ;;
esac
