#!/usr/bin/env bash
# fm-send refuses a text message over FM_SEND_MAX_BYTES (default 1000).
#
# The Claude Code composer keeps only the bytes after the last full 1022-byte
# chunk of typed text, so a longer steer silently loses its head.
# fm-send therefore refuses such a message before any backend call, instead of
# reporting a send that arrived truncated.
# These tests pin that behavior hermetically (stubbed tmux + sleep, no real agent):
#   1. 1001 ASCII bytes are refused with exit 1, the count and limit on stderr,
#      and no send-keys call.
#   2. The limit counts bytes, not characters (501 x 2-byte letter = 1002 bytes).
#   3. Exactly 1000 bytes are sent whole, once.
#   4. FM_SEND_MAX_BYTES tunes the limit.
#   5. A refused secondmate send leaves no pending-reply record behind.
#   6. The --key path is unaffected.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-length)

# A fake tmux that logs every send-keys call to FM_SEND_LOG as one line,
# "send-keys literal=<0|1> <text>", and lets fm-send's submit path reach a clean
# "empty" verdict (numeric cursor_y, empty bordered composer).
make_stubs() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys literal=%s %s\n' "$literal" "${1:-}" >> "$FM_SEND_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

FB=$(make_stubs "$TMP_ROOT")

setup_home() {  # <name> -> echoes a fresh home dir with an empty state/
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# run_send <home> [env-assignments...] -- <fm-send args...>
# Stderr goes to $home/err and send-keys calls to $home/log; returns fm-send's exit code.
run_send() {
  local home=$1; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$home/log"
  env ${envs[@]+"${envs[@]}"} PATH="$FB:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$home/log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>"$home/err"
}

repeat() {  # <string> <count>
  local out='' i
  for ((i = 0; i < $2; i++)); do out+=$1; done
  printf '%s' "$out"
}

test_over_limit_refused() {
  local home rc
  home=$(setup_home over)
  run_send "$home" -- sess:win "$(repeat a 1001)"; rc=$?
  expect_code 1 "$rc" "a 1001-byte message should be refused"
  grep -q '1001 bytes' "$home/err" || fail "stderr should name the byte count"$'\n'"$(cat "$home/err")"
  grep -q '1000-byte limit' "$home/err" || fail "stderr should name the limit"$'\n'"$(cat "$home/err")"
  grep -q 'send its path' "$home/err" || fail "stderr should name the file-path workaround"$'\n'"$(cat "$home/err")"
  grep -q 'send-keys' "$home/log" && fail "a refused message must not reach tmux"$'\n'"$(cat "$home/log")"
  pass "fm-send: a 1001-byte message is refused before any send"
}

test_limit_counts_bytes() {
  local home rc
  home=$(setup_home bytes)
  run_send "$home" -- sess:win "$(repeat 'Ж' 501)"; rc=$?
  expect_code 1 "$rc" "501 two-byte letters (1002 bytes) should be refused"
  grep -q '1002 bytes' "$home/err" || fail "stderr should count bytes"$'\n'"$(cat "$home/err")"
  grep -q 'send-keys' "$home/log" && fail "a refused message must not reach tmux"
  pass "fm-send: the limit counts bytes, not characters"
}

test_boundary_sent() {
  local home rc msg n
  home=$(setup_home boundary)
  msg=$(repeat a 1000)
  run_send "$home" -- sess:win "$msg"; rc=$?
  expect_code 0 "$rc" "a 1000-byte message should be sent"
  n=$(grep -c "^send-keys literal=1 $msg\$" "$home/log")
  [ "$n" = 1 ] || fail "expected exactly one literal send of the full 1000 bytes, got $n"$'\n'"$(cut -c1-80 "$home/log")"
  pass "fm-send: a 1000-byte message is sent whole"
}

test_limit_tunable() {
  local home rc
  home=$(setup_home tunable)
  run_send "$home" FM_SEND_MAX_BYTES=10 -- sess:win "hello worl!"; rc=$?
  expect_code 1 "$rc" "an 11-byte message over FM_SEND_MAX_BYTES=10 should be refused"
  grep -q '10-byte limit' "$home/err" || fail "stderr should name the tuned limit"
  run_send "$home" FM_SEND_MAX_BYTES=junk -- sess:win "$(repeat a 1000)"; rc=$?
  expect_code 0 "$rc" "a non-numeric FM_SEND_MAX_BYTES should fall back to 1000"
  run_send "$home" FM_SEND_MAX_BYTES=0 -- sess:win "$(repeat a 1001)"; rc=$?
  expect_code 1 "$rc" "a zero FM_SEND_MAX_BYTES should fall back to 1000"
  pass "fm-send: FM_SEND_MAX_BYTES tunes the limit, and a bad value falls back to 1000"
}

test_secondmate_no_stranded_record() {
  local home rc
  home=$(setup_home secondmate)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  run_send "$home" -- domain "$(repeat a 1001)"; rc=$?
  expect_code 1 "$rc" "an over-limit secondmate send should be refused"
  grep -q 'send-keys' "$home/log" && fail "a refused secondmate send must not reach tmux"
  if [ -d "$home/state/pending-replies" ] && [ -n "$(ls -A "$home/state/pending-replies")" ]; then
    fail "a refused secondmate send left a pending-reply record"$'\n'"$(ls -A "$home/state/pending-replies")"
  fi
  pass "fm-send: a refused secondmate send leaves no pending-reply record"
}

test_key_unaffected() {
  local home rc
  home=$(setup_home key)
  run_send "$home" FM_SEND_MAX_BYTES=1 -- sess:win --key Enter; rc=$?
  expect_code 0 "$rc" "the --key path should ignore the length limit"
  grep -q '^send-keys literal=0 Enter$' "$home/log" || fail "--key Enter should reach tmux"$'\n'"$(cat "$home/log")"
  pass "fm-send: the --key path is unaffected"
}

test_over_limit_refused
test_limit_counts_bytes
test_boundary_sent
test_limit_tunable
test_secondmate_no_stranded_record
test_key_unaffected
