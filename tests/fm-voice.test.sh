#!/usr/bin/env bash
# tests/fm-voice.test.sh - behavior tests for bin/fm-voice.sh, the hold-to-talk
# voice input for Herdr agent panes, and bootstrap's config/voice gating.
#
# Everything is hermetic: whisper-cli, herdr, afplay, pbcopy, swiftc, and curl
# are fakebin stubs that log their calls (pbcopy exists only so a clipboard
# write would show up in a log), test WAVs are generated with python3's
# wave module, and every home lives under the test tmproot. The real microphone,
# hot key, and permission dialog cannot be exercised here; the specification's
# manual verifications MV-1..MV-6 own those.
#
# Two guarantees carry the most weight:
#   - INERT BY DEFAULT: without config/voice nothing runs, and bootstrap prints
#     and writes nothing for voice (firstmate is a shared template).
#   - NEVER ENTER: delivery is exactly one `herdr pane send-text`; no
#     `agent prompt`, `pane run`, or `send-keys` ever appears in the herdr log.
#   - NEVER DELETE, NEVER PBCOPY: submit deletes no recording, however it is
#     invoked, and never writes the clipboard; the daemon that made a recording
#     directory is its only deleter, and start sweeps only the daemon's own
#     fm-voice.* namespace under TMPDIR.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VOICE="$ROOT/bin/fm-voice.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-voice-tests)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
PY_DIR=$(command -v python3 2>/dev/null) && PY_DIR=$(dirname "$PY_DIR") || PY_DIR=
[ -n "$PY_DIR" ] && BASE_PATH="$PY_DIR:$BASE_PATH"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# --- fixtures ----------------------------------------------------------------

# make_home <name> [config-body]: a fresh FM_HOME with config/voice when a body
# (possibly "") is given; no config/voice when the second argument is omitted.
make_home() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/config" "$d/state" "$d/data" "$d/projects"
  if [ $# -ge 2 ]; then printf '%s\n' "$2" > "$d/config/voice"; fi
  printf '%s\n' "$d"
}

# make_wav <path> <seconds> <amplitude 0..32767>: 16 kHz mono 16-bit PCM
make_wav() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, wave, struct, math
path, secs, amp = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
n = int(16000 * secs)
frames = b"".join(struct.pack("<h", int(amp * math.sin(2 * math.pi * 440 * i / 16000))) for i in range(n))
with wave.open(path, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(frames)
PY
}

# minimal_path <home>: a PATH holding only the shell utilities fm-voice.sh needs,
# so whisper-cli, swiftc, jq, python3, and herdr are genuinely absent whatever
# the host has installed (swiftc and python3 live in /usr/bin on macOS).
minimal_path() {
  local d="$1/minbin" t src
  mkdir -p "$d"
  for t in bash sh env sed cut basename dirname wc tr grep cat mktemp uname kill \
           mkdir rm head tail sort ls sleep find rmdir; do
    src=$(command -v "$t" 2>/dev/null) || continue
    ln -sf "$src" "$d/$t"
  done
  printf '%s\n' "$d"
}

# rec_dir <home>: a fresh daemon-style recording directory under the home's TMPDIR
rec_dir() {
  mkdir -p "$1/tmp"
  mktemp -d "$1/tmp/fm-voice.XXXXXX"
}

# make_fakes <home>: fakebin with logging herdr/whisper-cli/afplay/pbcopy.
# Behavior is steered by env: FAKE_PANES (herdr pane list JSON), FAKE_HERDR_LIST_RC,
# FAKE_WHISPER_OUT, FAKE_WHISPER_RC, FAKE_WHISPER_SLEEP.
make_fakes() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_HERDR_LOG"
case "$1 $2" in
  "pane list")
    [ "${FAKE_HERDR_LIST_RC:-0}" = 0 ] || exit "$FAKE_HERDR_LIST_RC"
    printf '%s\n' "$FAKE_PANES" ;;
  "pane send-text") exit "${FAKE_SEND_RC:-0}" ;;
  "notification show") echo '{"reason":"disabled","shown":false}' ;;
  "status") exit "${FAKE_HERDR_STATUS_RC:-0}" ;;
esac
exit 0
SH
  cat > "$fakebin/whisper-cli" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_WHISPER_LOG"
[ -z "${FAKE_WHISPER_SLEEP:-}" ] || sleep "$FAKE_WHISPER_SLEEP"
printf '%s' "${FAKE_WHISPER_OUT-}"
exit "${FAKE_WHISPER_RC:-0}"
SH
  cat > "$fakebin/afplay" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_AFPLAY_LOG"
SH
  cat > "$fakebin/pbcopy" <<'SH'
#!/usr/bin/env bash
cat >> "$FAKE_PBCOPY_LOG"
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

panes_json() {  # <pane_id> <agent or ""> <status> [title]
  local agent_field=""
  [ -z "$2" ] || agent_field="\"agent\":\"$2\","
  printf '{"result":{"panes":[{"pane_id":"%s","focused":true,%s"agent_status":"%s","terminal_title_stripped":"%s"},{"pane_id":"w1:p9","focused":false,"agent":"codex","agent_status":"idle","terminal_title_stripped":"other"}]}}' \
    "$1" "$agent_field" "$3" "${4:-Parlino webhook settings screen}"
}

# voice_env <home> <fakebin> [env...] <command...>: runs <command> under the
# exact environment submit gets from the daemon - the fakes first on PATH, the
# home's overrides, and every fake's log wired up. run_submit and the pbcopy
# tripwire below share it so the wiring the tripwire proves is the wiring
# every submit runs under.
voice_env() {
  local home=$1 fakebin=$2
  shift 2
  env PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" TMPDIR="$home/tmp" \
    FAKE_HERDR_LOG="$home/herdr.log" FAKE_WHISPER_LOG="$home/whisper.log" \
    FAKE_AFPLAY_LOG="$home/afplay.log" FAKE_PBCOPY_LOG="$home/pbcopy.log" \
    "$@"
}

# run_submit <home> <fakebin> <wav> [env...]: runs submit the way the daemon
# does, with only the WAV path and the logs wired up; prints stdout, exit code
# in RC. SUBMIT_ARGS prepends extra submit arguments before the WAV.
run_submit() {
  local home=$1 fakebin=$2 wav=$3
  shift 3
  : > "$home/herdr.log"; : > "$home/whisper.log"; : > "$home/afplay.log"; : > "$home/pbcopy.log"
  # shellcheck disable=SC2086
  set -- "$@" "$VOICE" submit ${SUBMIT_ARGS-} "$wav"
  OUT=$(voice_env "$home" "$fakebin" "$@" 2>"$home/stderr")
  RC=$?
}

# assert_kept <wav> <label>: the recording and its directory are still there
# after a submit, whatever the outcome - submit never deletes what it was handed.
assert_kept() {
  assert_present "$1" "$2: the recording is left for the daemon that made it"
}

# assert_clipboard_untouched <home> <label>: the fake pbcopy was never invoked.
assert_clipboard_untouched() {
  [ ! -s "$1/pbcopy.log" ] || fail "$2: pbcopy must never be called, clipboard got: $(cat "$1/pbcopy.log")"
}

# afplay runs in the background; give its log a moment before asserting on it.
wait_afplay() {
  local i=0
  while [ ! -s "$1/afplay.log" ] && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
}

run_bootstrap() {  # <home> <fakebin> [env...]
  local home=$1 fakebin=$2
  shift 2
  env "$@" PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_BOOTSTRAP_DETECT_ONLY=1 bash "$BOOTSTRAP" 2>/dev/null
}

# --- tripwire: the fake pbcopy is proven to fire -------------------------------
# Every assert_clipboard_untouched below passes on an EMPTY pbcopy log, so
# together they prove nothing unless the fake is the pbcopy on submit's PATH
# and its log is wired: a fake with no FAKE_PBCOPY_LOG exits 1 with an empty
# log, and submit would call it as `pbcopy 2>/dev/null || true`. This is the
# one positive call. The resolution check comes first so a broken fake can
# never send the probe text to the real clipboard.

test_pbcopy_tripwire_fires() {
  local home fakebin resolved
  home=$(make_home tripwire "")
  fakebin=$(make_fakes "$home")
  : > "$home/pbcopy.log"
  resolved=$(voice_env "$home" "$fakebin" bash -c 'command -v pbcopy')
  [ "$resolved" = "$fakebin/pbcopy" ] || fail "tripwire: pbcopy must resolve to the fake, got: $resolved"
  voice_env "$home" "$fakebin" bash -c 'printf %s "tripwire text" | pbcopy 2>/dev/null || true'
  [ "$(cat "$home/pbcopy.log")" = "tripwire text" ] \
    || fail "tripwire: the fake pbcopy must log what it was fed, log: $(cat "$home/pbcopy.log")"
  ( assert_clipboard_untouched "$home" tripwire ) 2>/dev/null \
    && fail "tripwire: assert_clipboard_untouched must fail once the clipboard was written"
  pass "tripwire: a clipboard write under submit's own environment reaches the fake's log and fails the untouched assertion"
}

# --- AC-1 / AC-2: inert without config -----------------------------------------

test_inert_without_config() {
  local home fakebin out rc
  home=$(make_home inert)
  fakebin=$(fm_fakebin "$home")
  out=$(run_bootstrap "$home" "$fakebin"); rc=$?
  assert_not_contains "$out" "VOICE:" "AC-1: bootstrap must print no VOICE line without config/voice"
  assert_not_contains "$out" "MISSING: whisper-cpp" "AC-1: bootstrap must not demand whisper-cpp without config/voice"
  [ -z "$(find "$home/state" "$home/config" -name 'voice*' 2>/dev/null)" ] \
    || fail "AC-1: no voice* file may exist under state/ or config/ without opt-in"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" "$VOICE" submit /dev/null); rc=$?
  expect_code 2 "$rc" "AC-2: submit without config"
  [ "$out" = "voice input is off (create config/voice to enable)" ] || fail "AC-2: off message, got: $out"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" "$VOICE" status); rc=$?
  expect_code 0 "$rc" "AC-2: status without config"
  [ "$out" = off ] || fail "AC-2: status must print off, got: $out"
  for sub in doctor build start stop install-model; do
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
      FM_STATE_OVERRIDE="$home/state" "$VOICE" "$sub" 2>/dev/null); rc=$?
    expect_code 2 "$rc" "AC-2: $sub without config"
  done
  assert_absent "$home/state/voice.pid" "AC-2: nothing may be written without config"
  pass "AC-1/AC-2: voice input is inert without config/voice"
}

# --- AC-3 / AC-4: doctor names each missing piece; bootstrap relays it ---------

test_doctor_and_bootstrap_relay() {
  local home fakebin out rc expected
  local minbin direct
  home=$(make_home doctor "")
  fakebin=$(fm_fakebin "$home")
  minbin=$(minimal_path "$home")
  # PATH holds only core utilities: no whisper-cli, swiftc, jq, python3, herdr.
  out=$(PATH="$minbin" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_VOICE_OS_OVERRIDE=Darwin XDG_CACHE_HOME="$home/cache" "$VOICE" doctor); rc=$?
  expect_code 1 "$rc" "AC-3: doctor not ready"
  expected='MISSING: whisper-cpp (install: brew install whisper-cpp)
MISSING_MANUAL: swiftc (instructions: xcode-select --install)
MISSING: jq (install: brew install jq)
MISSING_MANUAL: python3 (instructions: xcode-select --install)'
  [ "$(printf '%s\n' "$out" | head -4)" = "$expected" ] || fail "AC-3: MISSING lines in order, got:"$'\n'"$out"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 5 ] || fail "AC-3: exactly five lines, got:"$'\n'"$out"
  case "$(printf '%s\n' "$out" | sed -n 5p)" in
    "VOICE: not ready - "*) ;;
    *) fail "AC-3: fifth line must be the VOICE summary, got:"$'\n'"$out" ;;
  esac
  assert_contains "$out" "python3 missing" "AC-3: python3 reason"
  assert_contains "$out" "model missing at $home/cache/firstmate/voice/ggml-large-v3-turbo-q5_0.bin (run bin/fm-voice.sh install-model)" "AC-3: model reason"
  assert_contains "$out" "daemon not built (run bin/fm-voice.sh build)" "AC-3: daemon reason"
  assert_contains "$out" "herdr not running" "AC-3: herdr reason"

  # bootstrap itself needs the base PATH (git, gh, ...), so the host may supply
  # some of the voice tools; AC-4 is that whatever doctor prints under that PATH,
  # bootstrap relays as one contiguous block, unchanged and in order.
  direct=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_VOICE_OS_OVERRIDE=Darwin XDG_CACHE_HOME="$home/cache" "$VOICE" doctor)
  assert_contains "$direct" "MISSING: whisper-cpp (install: brew install whisper-cpp)" "AC-4: whisper-cli is absent under the base PATH"
  out=$(run_bootstrap "$home" "$fakebin" FM_VOICE_OS_OVERRIDE=Darwin XDG_CACHE_HOME="$home/cache")
  assert_contains "$out"$'\n' "$direct"$'\n' "AC-4: bootstrap relays doctor's lines unchanged and in order"
  [ "$(printf '%s\n' "$out" | grep -c '^VOICE:')" = 1 ] || fail "AC-4: exactly one VOICE line"

  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_VOICE_OS_OVERRIDE=Linux "$VOICE" doctor); rc=$?
  expect_code 0 "$rc" "doctor on Linux"
  [ "$out" = "VOICE: macOS only - config/voice ignored on Linux" ] || fail "non-Darwin doctor line, got: $out"
  pass "AC-3/AC-4: doctor names each missing piece and bootstrap relays it unchanged"
}

# --- AC-5: invalid hotkey refused before any daemon starts --------------------

test_invalid_hotkey() {
  local home fakebin out rc spec
  for spec in option ctrl+alt+space+x 'ctrl+' fn+space; do
    home=$(make_home "hotkey-$RANDOM" "hotkey=$spec")
    fakebin=$(fm_fakebin "$home")
    out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
      FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
      FM_VOICE_OS_OVERRIDE=Darwin "$VOICE" start); rc=$?
    expect_code 2 "$rc" "AC-5: start with hotkey=$spec"
    assert_contains "$out" "invalid hotkey: $spec" "AC-5: message names the hotkey"
    assert_absent "$home/state/voice.pid" "AC-5: no pid file for hotkey=$spec"
  done
  home=$(make_home hotkey-bad-int "max_seconds=4-5")
  out=$(PATH="$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" FM_VOICE_OS_OVERRIDE=Darwin "$VOICE" start); rc=$?
  expect_code 2 "$rc" "invalid max_seconds"
  assert_contains "$out" "invalid max_seconds: 4-5" "invalid integer names the key"
  pass "AC-5: invalid hotkey and config values are refused at start"
}

# --- AC-6: happy path types without Enter --------------------------------------

test_happy_path_types_without_enter() {
  local home fakebin dir wav
  home=$(make_home happy "")
  fakebin=$(make_fakes "$home")
  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
  run_submit "$home" "$fakebin" "$wav" \
    FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_OUT=$'Почини тест\nи запусти линтер\n'
  expect_code 0 "$RC" "AC-6: submit exit"
  [ "$OUT" = 'typed into claude "Parlino webhook settings screen" (wA2:p2): Почини тест и запусти линтер' ] \
    || fail "AC-6: stdout, got: $OUT"
  [ "$(grep -c '^pane send-text wA2:p2 Почини тест и запусти линтер$' "$home/herdr.log")" = 1 ] \
    || fail "AC-6: exactly one send-text with the collapsed text, log:"$'\n'"$(cat "$home/herdr.log")"
  assert_no_grep "agent prompt" "$home/herdr.log" "AC-6: never agent prompt"
  assert_no_grep "pane run" "$home/herdr.log" "AC-6: never pane run"
  assert_no_grep "send-keys" "$home/herdr.log" "AC-6: never send-keys"
  assert_kept "$wav" "AC-6"
  wait_afplay "$home"
  assert_grep "Glass.aiff" "$home/afplay.log" "AC-6: Glass cue"
  assert_clipboard_untouched "$home" "AC-6"
  assert_grep "-l ru" "$home/whisper.log" "AC-6: default language ru"
  pass "AC-6: happy path types the transcript with send-text only, no Enter"
}

# --- AC-7 / AC-8 / AC-9: refusals -----------------------------------------------

test_refusals() {
  local home fakebin dir wav
  home=$(make_home refuse "")
  fakebin=$(make_fakes "$home")

  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
  run_submit "$home" "$fakebin" "$wav" \
    FAKE_PANES="$(panes_json wA7:p3 '' unknown)" FAKE_WHISPER_OUT=$'Почини тест\nи запусти линтер\n'
  expect_code 3 "$RC" "AC-7: non-agent pane"
  [ "$OUT" = "refused: focused pane wA7:p3 is not an agent pane; not typed, transcript: Почини тест и запусти линтер" ] || fail "AC-7: stdout, got: $OUT"
  assert_no_grep "send-text" "$home/herdr.log" "AC-7: nothing typed"
  assert_clipboard_untouched "$home" "AC-7"
  assert_kept "$wav" "AC-7"
  wait_afplay "$home"
  assert_grep "Basso.aiff" "$home/afplay.log" "AC-7: Basso cue"

  for st in blocked unknown; do
    dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
    run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude "$st")" FAKE_WHISPER_OUT="Привет"
    expect_code 3 "$RC" "AC-8: $st agent"
    assert_contains "$OUT" "wA2:p2" "AC-8: names the pane for $st"
    case "$st" in
      blocked) assert_contains "$OUT" "waiting on a dialog" "AC-8: blocked wording" ;;
      unknown) assert_contains "$OUT" "agent state unknown" "AC-8: unknown wording" ;;
    esac
    assert_no_grep "send-text" "$home/herdr.log" "AC-8: nothing typed for $st"
    assert_contains "$OUT" "; not typed, transcript: Привет" "AC-8: transcript shown for $st"
    assert_clipboard_untouched "$home" "AC-8 $st"
    assert_kept "$wav" "AC-8 $st"
  done

  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES='{"result":{"panes":[{"pane_id":"w1:p1","focused":false,"agent":"claude","agent_status":"idle"}]}}' FAKE_WHISPER_OUT="Привет"
  expect_code 3 "$RC" "AC-9: no focused pane"
  [ "$OUT" = "refused: no single focused pane; not typed, transcript: Привет" ] || fail "AC-9: stdout, got: $OUT"
  assert_no_grep "send-text" "$home/herdr.log" "AC-9: nothing typed"
  assert_clipboard_untouched "$home" "AC-9"
  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES='{"result":{"panes":[{"pane_id":"w1:p1","focused":true,"agent":"claude","agent_status":"idle"},{"pane_id":"w1:p2","focused":true,"agent":"claude","agent_status":"idle"}]}}' FAKE_WHISPER_OUT="Привет"
  expect_code 3 "$RC" "AC-9: two focused panes"
  [ "$OUT" = "refused: no single focused pane; not typed, transcript: Привет" ] || fail "AC-9: two-pane stdout, got: $OUT"
  assert_no_grep "send-text" "$home/herdr.log" "AC-9: nothing typed with two panes"

  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude working)" FAKE_WHISPER_OUT="Привет" FAKE_SEND_RC=1
  expect_code 3 "$RC" "send-text failure is a refusal"
  [ "$OUT" = "refused: send-text to wA2:p2 failed; not typed, transcript: Привет" ] || fail "send-text failure wording, got: $OUT"
  assert_clipboard_untouched "$home" "send-text failure"

  # Dictated text can be a password or token; a refusal shows it only on the
  # daemon pane line and never hands it to pbcopy, so what the operator copied
  # before is still on the clipboard.
  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude blocked)" FAKE_WHISPER_OUT="секретный токен"
  expect_code 3 "$RC" "refusal with a secret in the transcript"
  assert_clipboard_untouched "$home" "secret transcript"
  assert_contains "$OUT" "секретный токен" "the transcript is shown in the daemon pane line instead"
  pass "AC-7/AC-8/AC-9: non-agent, blocked, unknown, and unfocused panes are refused with the transcript on the output line and the clipboard untouched"
}

# --- AC-10: silence gate runs before whisper -------------------------------------

test_silence_gate() {
  local home fakebin dir wav
  home=$(make_home silence "")
  fakebin=$(make_fakes "$home")
  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 0.3 20000
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_OUT="Привет"
  expect_code 4 "$RC" "AC-10: short recording"
  [ "$OUT" = "nothing heard" ] || fail "AC-10: stdout, got: $OUT"
  [ ! -s "$home/whisper.log" ] || fail "AC-10: whisper must not run on a 0.3 s recording"
  assert_kept "$wav" "AC-10 short"

  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 0
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_OUT="Продолжение следует..."
  expect_code 4 "$RC" "AC-10: digital silence"
  [ "$OUT" = "nothing heard" ] || fail "AC-10: silence stdout, got: $OUT"
  [ ! -s "$home/whisper.log" ] || fail "AC-10: whisper must not run on digital silence"
  assert_no_grep "send-text" "$home/herdr.log" "AC-10: nothing typed"
  assert_kept "$wav" "AC-10 silence"

  # A quiet-but-audible recording just above the threshold does reach whisper.
  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 400
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_OUT="Привет"
  expect_code 0 "$RC" "quiet speech above min_dbfs is transcribed"

  # submit re-reads config/voice on every call; a threshold the gate cannot
  # evaluate is a failure, never a pass-through to whisper on silence.
  printf 'min_dbfs=-45dB\n' > "$home/config/voice"
  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 0
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_OUT="Продолжение следует..."
  expect_code 5 "$RC" "invalid min_dbfs"
  [ "$OUT" = "failed: invalid min_dbfs: -45dB (expected an integer -90..0)" ] || fail "invalid min_dbfs stdout, got: $OUT"
  [ ! -s "$home/whisper.log" ] || fail "whisper must not run when min_dbfs is invalid"
  assert_no_grep "send-text" "$home/herdr.log" "invalid min_dbfs: nothing typed"
  assert_kept "$wav" "invalid min_dbfs"
  assert_absent "$home/state/voice.submit.lock" "invalid min_dbfs: lock released"
  wait_afplay "$home"
  assert_grep "Sosumi.aiff" "$home/afplay.log" "invalid min_dbfs: Sosumi cue"
  pass "AC-10: recordings shorter than 0.5 s or below min_dbfs never reach whisper, and a bad threshold fails closed"
}

# --- recording ownership: submit deletes nothing, however it is pointed ----------
#
# The security finding of 2026-09-14: three editions in a row let submit delete
# a directory it did not create, each by a better path check than the last.
# The fix is subtraction, not a fourth check: submit has no deletion at all,
# and the daemon that made a recording directory is its only deleter.

test_recording_dir_ownership() {
  local home fakebin hand own wav
  home=$(make_home ownership "")
  fakebin=$(make_fakes "$home")
  mkdir -p "$home/tmp"

  # Reverse test from the finding: a directory the daemon did NOT create, holding
  # a WAV, named through the old --recording-dir option. Before the fix this
  # deleted the directory wholesale. It must be in place afterwards, untouched,
  # and the option itself is refused rather than silently ignored.
  hand="$home/tmp/fm-voice.hand"; mkdir -p "$hand"
  wav="$hand/take1.wav"; make_wav "$wav" 2 20000; : > "$hand/take2.wav"
  SUBMIT_ARGS="--recording-dir $hand" run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_OUT="Привет"
  expect_code 5 "$RC" "--recording-dir is refused"
  [ "$OUT" = "failed: unknown submit option --recording-dir" ] || fail "--recording-dir stdout, got: $OUT"
  [ ! -s "$home/whisper.log" ] || fail "--recording-dir: whisper must not run on a refused option"
  assert_no_grep "send-text" "$home/herdr.log" "--recording-dir: nothing typed"
  assert_present "$hand" "--recording-dir: the named directory is in place"
  assert_present "$wav" "--recording-dir: its WAV is in place"
  assert_present "$hand/take2.wav" "--recording-dir: its sibling file is in place"

  # The same directory as an ordinary submit target, through every outcome:
  # typed, refused, failed. Nothing is deleted on any of them.
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_OUT="Привет"
  expect_code 0 "$RC" "hand submit typed"
  assert_grep "pane send-text wA2:p2 Привет" "$home/herdr.log" "hand submit still types"
  assert_present "$wav" "hand submit keeps the WAV after typing"
  assert_present "$hand/take2.wav" "hand submit keeps sibling files after typing"
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude blocked)" FAKE_WHISPER_OUT="Привет"
  expect_code 3 "$RC" "hand submit refused"
  assert_present "$wav" "hand submit keeps the WAV after a refusal"
  assert_present "$hand" "hand submit keeps the directory after a refusal"
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_RC=1
  expect_code 5 "$RC" "hand submit failed"
  assert_present "$wav" "hand submit keeps the WAV after a failure"

  # A daemon-shaped directory (fresh mktemp fm-voice.XXXXXX under TMPDIR, one
  # rec.wav inside, exactly what the daemon hands over) is kept by submit too:
  # the shape of the path grants no deletion right, only provenance does, and
  # submit has none.
  own=$(rec_dir "$home"); wav="$own/rec.wav"; make_wav "$wav" 2 20000
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_OUT="Привет"
  expect_code 0 "$RC" "daemon-shaped submit typed"
  assert_present "$own" "daemon-shaped directory is kept by submit"
  assert_present "$wav" "daemon-shaped WAV is kept by submit"
  assert_present "$hand" "the neighbouring directory is untouched"

  # Only submit's own scratch (fm-voice-submit.*) ever comes and goes.
  [ "$(find "$home/tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 2 ] || fail "exactly the two recording directories remain under TMPDIR: $(find "$home/tmp" -mindepth 1 -maxdepth 1)"
  pass "submit deletes nothing it was handed, and --recording-dir no longer exists to aim it"
}

# --- AC-11 / AC-12: hallucination list, whole-text only --------------------------

test_hallucinations() {
  local home fakebin dir wav phrase
  home=$(make_home halluc "")
  fakebin=$(make_fakes "$home")
  for phrase in 'Продолжение следует...' 'you' '' 'Thank you.' 'СПАСИБО ЗА ПРОСМОТР' '[BLANK_AUDIO]'; do
    dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
    run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_OUT="$phrase"
    expect_code 4 "$RC" "AC-11: '$phrase'"
    [ "$OUT" = "nothing heard" ] || fail "AC-11: stdout for '$phrase', got: $OUT"
    assert_no_grep "send-text" "$home/herdr.log" "AC-11: nothing typed for '$phrase'"
    assert_kept "$wav" "AC-11 '$phrase'"
  done
  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude idle)" \
    FAKE_WHISPER_OUT="Спасибо за просмотр логов, и почини тест"
  expect_code 0 "$RC" "AC-12: real text containing a listed phrase"
  assert_grep "pane send-text wA2:p2 Спасибо за просмотр логов, и почини тест" "$home/herdr.log" \
    "AC-12: the full sentence reaches send-text unchanged"
  pass "AC-11/AC-12: known hallucinations are nothing heard; the list never trims real text"
}

# --- AC-13 / AC-14: failures ---------------------------------------------------

test_failures() {
  local home fakebin dir wav
  home=$(make_home failures "")
  fakebin=$(make_fakes "$home")
  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_RC=1
  expect_code 5 "$RC" "AC-13: whisper failure"
  [ "$OUT" = "failed: whisper-cli exited 1" ] || fail "AC-13: stdout, got: $OUT"
  assert_kept "$wav" "AC-13"
  wait_afplay "$home"
  assert_grep "Sosumi.aiff" "$home/afplay.log" "AC-13: Sosumi cue"
  assert_clipboard_untouched "$home" "AC-13"

  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
  run_submit "$home" "$fakebin" "$wav" FAKE_HERDR_LIST_RC=1 FAKE_WHISPER_OUT="Почини тест"
  expect_code 5 "$RC" "AC-14: herdr unreachable"
  [ "$OUT" = "failed: herdr not running; not typed, transcript: Почини тест" ] || fail "AC-14: stdout, got: $OUT"
  assert_clipboard_untouched "$home" "AC-14"
  assert_kept "$wav" "AC-14"
  assert_no_grep "send-text" "$home/herdr.log" "AC-14: nothing typed"

  # The third undelivered branch: herdr answers but with JSON jq cannot read.
  # Same line shape, same rules - transcript on the line, clipboard untouched,
  # recording left alone.
  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES='{not json at all' FAKE_WHISPER_OUT="Почини тест"
  expect_code 5 "$RC" "unreadable pane JSON"
  [ "$OUT" = "failed: herdr pane list returned unreadable JSON; not typed, transcript: Почини тест" ] || fail "unreadable pane JSON stdout, got: $OUT"
  assert_clipboard_untouched "$home" "unreadable pane JSON"
  assert_kept "$wav" "unreadable pane JSON"
  assert_no_grep "send-text" "$home/herdr.log" "unreadable pane JSON: nothing typed"

  dir=$(rec_dir "$home")
  run_submit "$home" "$fakebin" "$dir/rec.wav"
  expect_code 5 "$RC" "missing recording"
  [ "$OUT" = "failed: no recording" ] || fail "missing recording must not print the path, got: $OUT"

  # No scratch directory means no transcription: submit fails closed instead of
  # running whisper with its output pointed at the filesystem root.
  dir=$(mktemp -d "$home/fm-voice.XXXXXX"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
  chmod 0500 "$home/tmp"
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_OUT="Привет"
  chmod 0700 "$home/tmp"
  expect_code 5 "$RC" "unusable TMPDIR"
  [ "$OUT" = "failed: cannot create a scratch directory under TMPDIR" ] || fail "unusable TMPDIR stdout, got: $OUT"
  [ ! -s "$home/whisper.log" ] || fail "whisper must not run without a scratch directory"
  assert_kept "$wav" "unusable TMPDIR"
  assert_absent "$home/state/voice.submit.lock" "unusable TMPDIR: lock released"
  pass "AC-13/AC-14: whisper and herdr failures report, release the lock, and show the transcript when there is one"
}

# --- AC-15: deletion survives a signal -----------------------------------------

test_signal_cleanup() {
  local home fakebin dir wav pid i
  home=$(make_home signal "")
  fakebin=$(make_fakes "$home")
  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
  : > "$home/herdr.log"; : > "$home/whisper.log"; : > "$home/afplay.log"; : > "$home/pbcopy.log"
  env PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" TMPDIR="$home/tmp" \
    FAKE_HERDR_LOG="$home/herdr.log" FAKE_WHISPER_LOG="$home/whisper.log" \
    FAKE_AFPLAY_LOG="$home/afplay.log" FAKE_PBCOPY_LOG="$home/pbcopy.log" \
    FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_SLEEP=5 FAKE_WHISPER_OUT="Привет" \
    "$VOICE" submit "$wav" >/dev/null 2>&1 &
  pid=$!
  sleep 1
  kill -TERM "$pid" 2>/dev/null
  i=0
  while { [ -d "$home/state/voice.submit.lock" ] || ls -d "$home/tmp"/fm-voice-submit.* >/dev/null 2>&1; } && [ "$i" -lt 20 ]; do
    sleep 0.1; i=$((i + 1))
  done
  wait "$pid" 2>/dev/null
  assert_absent "$home/state/voice.submit.lock" "AC-15: lock directory gone within 2 s of SIGTERM"
  [ "$(ls "$home/tmp" 2>/dev/null)" = "$(basename "$dir")" ] || fail "AC-15: only the recording remains under TMPDIR, no scratch: $(ls "$home/tmp")"
  assert_present "$wav" "AC-15: the recording is left for the daemon that made it"
  pass "AC-15: SIGTERM mid-transcription still releases the lock and the scratch, and leaves the recording alone"
}

# --- AC-16: concurrent submit refused -----------------------------------------

test_concurrent_submit() {
  local home fakebin dir wav holder
  home=$(make_home concurrent "")
  fakebin=$(make_fakes "$home")
  sleep 30 & holder=$!
  mkdir -p "$home/state/voice.submit.lock"
  echo "$holder" > "$home/state/voice.submit.lock/pid"
  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_OUT="Привет"
  expect_code 9 "$RC" "AC-16: second submit"
  [ "$OUT" = "busy: another transcription is running" ] || fail "AC-16: stdout, got: $OUT"
  assert_kept "$wav" "AC-16"
  assert_present "$home/state/voice.submit.lock" "AC-16: the other submit's lock is left alone"
  [ "$(cat "$home/state/voice.submit.lock/pid")" = "$holder" ] || fail "AC-16: the live holder's pid is kept"
  [ ! -s "$home/whisper.log" ] || fail "AC-16: whisper must not run"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  pass "AC-16: a concurrent submit is refused and touches neither the lock nor the recording"
}

# --- stale lock: a holder that died without its trap never wedges submit ------

test_stale_lock_reclaimed() {
  local home fakebin dir wav dead
  home=$(make_home stale-lock "")
  fakebin=$(make_fakes "$home")
  sleep 30 & dead=$!; kill "$dead"; wait "$dead" 2>/dev/null
  mkdir -p "$home/state/voice.submit.lock"
  echo "$dead" > "$home/state/voice.submit.lock/pid"
  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_OUT="Привет"
  expect_code 0 "$RC" "stale lock (dead pid): submit proceeds"
  case "$OUT" in "typed into claude "*"(wA2:p2): Привет") ;; *) fail "stale lock: stdout, got: $OUT" ;; esac
  assert_grep "pane send-text wA2:p2 Привет" "$home/herdr.log" "stale lock: transcript typed"
  assert_absent "$home/state/voice.submit.lock" "stale lock: released after the submit"
  assert_kept "$wav" "stale lock"

  mkdir -p "$home/state/voice.submit.lock"
  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_OUT="Привет"
  expect_code 9 "$RC" "fresh lock without a pid yet: a holder mid-acquire is not evicted"
  assert_present "$home/state/voice.submit.lock" "fresh lock without a pid: left alone"
  [ ! -s "$home/whisper.log" ] || fail "fresh lock without a pid: whisper must not run"

  python3 -c 'import os, sys, time; t = time.time() - 60; os.utime(sys.argv[1], (t, t))' "$home/state/voice.submit.lock"
  dir=$(rec_dir "$home"); wav="$dir/rec.wav"; make_wav "$wav" 2 20000
  run_submit "$home" "$fakebin" "$wav" FAKE_PANES="$(panes_json wA2:p2 claude idle)" FAKE_WHISPER_OUT="Привет"
  expect_code 0 "$RC" "old lock without a pid: submit proceeds"
  assert_absent "$home/state/voice.submit.lock" "old lock without a pid: released after the submit"
  pass "stale lock: a dead holder or an old unrecorded lock is reclaimed; a fresh unrecorded lock is not"
}

# --- AC-17: single daemon instance ---------------------------------------------

test_single_instance() {
  local home fakebin out rc sleeper
  home=$(make_home instance "")
  fakebin=$(make_fakes "$home")
  sleep 30 & sleeper=$!
  echo "$sleeper" > "$home/state/voice.pid"
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_VOICE_OS_OVERRIDE=Darwin XDG_CACHE_HOME="$home/cache" "$VOICE" start); rc=$?
  expect_code 5 "$rc" "AC-17: live pid"
  [ "$out" = "already running (pid $sleeper)" ] || fail "AC-17: stdout, got: $out"
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_VOICE_OS_OVERRIDE=Darwin "$VOICE" status)
  [ "$out" = "running (pid $sleeper)" ] || fail "AC-17: status while running, got: $out"
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" "$VOICE" stop); rc=$?
  expect_code 0 "$rc" "stop with a live pid"
  wait "$sleeper" 2>/dev/null
  assert_absent "$home/state/voice.pid" "stop removes the pid file"

  sleep 30 & sleeper=$!; kill "$sleeper"; wait "$sleeper" 2>/dev/null
  echo "$sleeper" > "$home/state/voice.pid"
  mkdir -p "$home/state/voice.submit.lock"
  echo "$sleeper" > "$home/state/voice.submit.lock/pid"
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_VOICE_OS_OVERRIDE=Darwin XDG_CACHE_HOME="$home/cache" "$VOICE" start); rc=$?
  expect_code 2 "$rc" "AC-17: dead pid proceeds to the build check"
  [ "$out" = "daemon not built (run bin/fm-voice.sh build)" ] || fail "AC-17: stale pid message, got: $out"
  assert_absent "$home/state/voice.pid" "AC-17: stale pid file replaced"
  assert_absent "$home/state/voice.submit.lock" "AC-17: a dead holder's submit lock is cleared by start"
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" "$VOICE" stop); rc=$?
  expect_code 1 "$rc" "stop with nothing running"
  pass "AC-17: a live pid refuses a second daemon; a dead pid is replaced"
}

# --- AC-18: model checksum enforced ---------------------------------------------

test_model_checksum() {
  local home fakebin out rc dest
  home=$(make_home model "")
  fakebin=$(make_fakes "$home")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
printf 'not the model' > "$out"
SH
  chmod +x "$fakebin/curl"
  dest="$home/cache/firstmate/voice/ggml-large-v3-turbo-q5_0.bin"
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    XDG_CACHE_HOME="$home/cache" "$VOICE" install-model --yes); rc=$?
  expect_code 6 "$rc" "AC-18: checksum mismatch exit"
  assert_contains "$out" "checksum mismatch" "AC-18: message"
  assert_absent "$dest" "AC-18: no .bin at the destination"
  assert_absent "$dest.part" "AC-18: no .part left behind"
  assert_contains "$out" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin" "AC-18: URL printed"
  assert_contains "$out" "574041195" "AC-18: size printed"

  # The matching hash installs and leaves a verified sidecar for doctor.
  local sha
  sha=$(printf 'not the model' | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    XDG_CACHE_HOME="$home/cache" FM_VOICE_MODEL_SHA256_OVERRIDE="$sha" "$VOICE" install-model --yes); rc=$?
  expect_code 0 "$rc" "install with the matching hash"
  assert_present "$dest" "installed model present"
  assert_absent "$dest.part" "no .part after install"
  pass "AC-18: install-model verifies the pinned checksum and deletes a bad download"
}

# --- doctor on a real model path with a checksum mismatch ------------------------

test_doctor_model_mismatch() {
  local home fakebin out dest
  home=$(make_home doctor-model "")
  fakebin=$(make_fakes "$home")
  fm_fake_exit0 "$fakebin" swiftc
  dest="$home/cache/firstmate/voice/ggml-large-v3-turbo-q5_0.bin"
  mkdir -p "$(dirname "$dest")"
  printf 'short' > "$dest"
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_VOICE_OS_OVERRIDE=Darwin XDG_CACHE_HOME="$home/cache" "$VOICE" doctor)
  assert_contains "$out" "model checksum mismatch" "doctor reports a wrong-size model as a checksum mismatch"
  assert_not_contains "$out" "MISSING" "doctor prints no MISSING line when every tool is present"
  pass "doctor: a model file with the wrong size is a checksum mismatch"
}

# --- start with a planted daemon: config validation order and the exec handoff ----

test_start_hands_off_to_daemon() {
  local home fakebin out rc bin
  home=$(make_home start-exec $'hotkey=cmd+shift+v\nsounds=off\nmax_seconds=30\nmodel=MODELPATH')
  sed -i.bak "s|MODELPATH|$home/custom-weights.bin|" "$home/config/voice" && rm -f "$home/config/voice.bak"
  printf 'weights' > "$home/custom-weights.bin"
  fakebin=$(make_fakes "$home")
  fm_fake_exit0 "$fakebin" swiftc
  mkdir -p "$home/cache/firstmate/voice"
  bin="$home/cache/firstmate/voice/fm-voice-hotkey-fakehash0001"
  cat > "$bin" <<'SH'
#!/usr/bin/env bash
echo "daemon args: $*"
SH
  chmod +x "$bin"
  # The leftover sweep is the recovery-path deleter for the daemon's own
  # namespace: a stale fm-voice.* directory goes, anything else under TMPDIR stays.
  mkdir -p "$home/tmp/fm-voice.stale" "$home/tmp/fm-voice-submit.stale" "$home/tmp/memos"
  : > "$home/tmp/fm-voice.stale/rec.wav"; : > "$home/tmp/memos/keep.wav"; : > "$home/tmp/fm-voice.txt"
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" TMPDIR="$home/tmp" \
    FM_VOICE_OS_OVERRIDE=Darwin XDG_CACHE_HOME="$home/cache" FM_VOICE_NO_WARMUP=1 \
    FM_VOICE_SOURCE_HASH_OVERRIDE=fakehash0001 "$VOICE" start); rc=$?
  expect_code 0 "$rc" "start execs the daemon"
  assert_absent "$home/tmp/fm-voice.stale" "start sweeps a leftover daemon recording directory"
  assert_absent "$home/tmp/fm-voice-submit.stale" "start sweeps a leftover submit scratch directory"
  assert_present "$home/tmp/memos/keep.wav" "start leaves a directory outside its namespace alone"
  assert_present "$home/tmp/fm-voice.txt" "start sweeps directories only, never a file"
  assert_contains "$out" "daemon args: --hotkey cmd+shift+v --max-seconds 30 --submit $VOICE --sounds off --tmpdir $home/tmp" \
    "start passes the resolved config to the daemon"
  assert_present "$home/state/voice.pid" "start records the daemon pid"
  pass "start: a built daemon receives the validated config and the submit path, after sweeping only fm-voice.* leftovers"
}

# --- cue subcommand: the daemon's only route to a sound ---------------------------

test_cue() {
  local home fakebin
  home=$(make_home cue "")
  fakebin=$(make_fakes "$home")
  : > "$home/afplay.log"
  PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" FAKE_AFPLAY_LOG="$home/afplay.log" "$VOICE" cue recording
  wait_afplay "$home"
  assert_grep "/System/Library/Sounds/Tink.aiff" "$home/afplay.log" "cue recording plays Tink"
  home=$(make_home cue-off "sounds=off")
  fakebin=$(make_fakes "$home")
  : > "$home/afplay.log"
  PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" FAKE_AFPLAY_LOG="$home/afplay.log" "$VOICE" cue recording
  sleep 0.2
  [ ! -s "$home/afplay.log" ] || fail "sounds=off must play nothing"
  pass "cue: sound cues follow the sounds key"
}

test_pbcopy_tripwire_fires
test_inert_without_config
test_doctor_and_bootstrap_relay
test_invalid_hotkey
test_happy_path_types_without_enter
test_refusals
test_silence_gate
test_recording_dir_ownership
test_hallucinations
test_failures
test_signal_cleanup
test_concurrent_submit
test_stale_lock_reclaimed
test_single_instance
test_model_checksum
test_doctor_model_mismatch
test_start_hands_off_to_daemon
test_cue
