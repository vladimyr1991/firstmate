#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone.
# The optional session id is exported into the child only, so one case can
# never leak its identity into the next.
lib_eval() {  # <fakebin> <expression> [<session-id>]
  local fakebin=$1 expr=$2 session=${3:-}
  PATH="$fakebin:$PATH" CLAUDE_CODE_SESSION_ID="$session" bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB"
}

# A process table where pid 600 is a live claude session that is NOT anywhere in
# this process's ancestry: the shape a session leaves behind when it is moved
# into a background process tree, and the shape two sessions sharing one home
# have. Ownership can only be decided by the recorded session id here.
write_disjoint_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' claude ;;
  600:args=) printf '%s\n' claude ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$1/ps"
}

test_typed_record_survives_a_changed_process_tree() {
  local dir fakebin
  dir="$TMP_ROOT/typed-identity"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  write_disjoint_ps "$fakebin"
  printf 'pid=600 harness=claude session=70e62a49-6338-4383-9eb8-a58df9a3a006\n' > "$dir/state/.lock"

  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" 70e62a49-6338-4383-9eb8-a58df9a3a006 \
    || fail "a session lost ownership of its own home because its process tree changed"
  # The Stop payload carries the same id when the environment does not.
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state' 70e62a49-6338-4383-9eb8-a58df9a3a006" \
    || fail "the Stop payload's own session id did not establish ownership"
  pass "session-lock: a recorded session id keeps ownership when the recorded pid leaves the ancestry"
}

test_typed_record_refuses_a_different_live_session() {
  local dir fakebin
  dir="$TMP_ROOT/typed-foreign"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  write_disjoint_ps "$fakebin"
  printf 'pid=600 harness=claude session=session-one\n' > "$dir/state/.lock"

  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" session-two; then
    fail "a different live session claimed a home recorded to session-one"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "the recorded live owner was classified as a dead lock owner"
  pass "session-lock: a genuinely different live session is still refused a recorded home"
}

test_typed_record_pid_is_only_a_liveness_hint() {
  local dir fakebin
  dir="$TMP_ROOT/typed-ancestor-pid"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  write_disjoint_ps "$fakebin"
  # pid 650 IS this process's harness ancestor - the shape of a pooled host
  # process shared by several sessions. A recorded session id that does not
  # match must still refuse, or the two sessions sharing that host both claim
  # the home.
  printf 'pid=650 harness=claude session=session-one\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" session-two; then
    fail "a shared ancestor pid overrode a non-matching recorded session id"
  fi
  pass "session-lock: a shared ancestor pid never overrides a recorded session id"
}

test_unrecognized_records_fail_closed() {
  local dir fakebin record
  dir="$TMP_ROOT/malformed-records"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  write_disjoint_ps "$fakebin"
  for record in 'pid=650' 'pid=650 harness=claude' 'session=session-one' \
    'pid=abc harness=claude session=s1' 'pid=650 harness=claude session=s1 extra=1' \
    'pid=650 harness=claude session=bad;rm'; do
    printf '%s\n' "$record" > "$dir/state/.lock"
    if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" session-one; then
      fail "an unrecognized lock record was accepted as ownership: $record"
    fi
    lib_eval "$fakebin" "fm_session_lock_read '$dir/state'; [ \"\$FM_LOCK_FORM\" = malformed ]" \
      || fail "an unrecognized lock record did not parse as malformed: $record"
  done
  pass "session-lock: unrecognized lock records fail closed with no pid to act on"
}

test_legacy_record_is_read_exactly_as_before() {
  local dir fakebin
  dir="$TMP_ROOT/legacy-record"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  write_disjoint_ps "$fakebin"
  printf '650\n' > "$dir/state/.lock"
  # A legacy record is ancestry-decided even for a process that has its own
  # session id, so a home mid-upgrade behaves exactly as it does today.
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" session-one \
    || fail "a legacy record stopped resolving through harness ancestry"
  lib_eval "$fakebin" "fm_session_lock_read '$dir/state'; [ \"\$FM_LOCK_FORM\" = legacy ] && [ \"\$FM_LOCK_PID\" = 650 ]" \
    || fail "a bare-integer record did not parse as the legacy form"
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" session-one; then
    fail "a legacy record outside this ancestry was claimed as this session's own"
  fi
  pass "session-lock: legacy bare-pid records keep their exact ancestry semantics"
}

test_session_id_is_resolved_only_for_publishing_harnesses() {
  local dir fakebin got
  dir="$TMP_ROOT/session-id-source"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  write_disjoint_ps "$fakebin"
  got=$(lib_eval "$fakebin" 'fm_harness_session_id claude payload-id' env-id) \
    || fail "no session id was resolved for claude"
  [ "$got" = env-id ] || fail "the environment id must win over a payload id, got '$got'"
  got=$(lib_eval "$fakebin" 'fm_harness_session_id claude payload-id') \
    || fail "the payload id was not used when the environment carries none"
  [ "$got" = payload-id ] || fail "expected the payload id, got '$got'"
  if lib_eval "$fakebin" 'fm_harness_session_id kimi' env-id; then
    fail "a harness that publishes no session id resolved one anyway"
  fi
  if lib_eval "$fakebin" 'fm_harness_session_id claude "bad id"'; then
    fail "an unsafe session id was accepted"
  fi
  pass "session-lock: only a publishing harness resolves a session id, environment first"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

# --- end-to-end layer: a /clear inside one unchanged process tree ------------
#
# Clearing a Claude session publishes a new session id while its process tree is
# untouched, so the previous session's typed record still names a live ancestor
# pid. Every reader of state/.lock has to agree about that state, and the three
# real scripts are run here in one live harness process so nothing about the
# identity they resolve is simulated.

install_clear_sequence_scripts() {  # <dir>
  local dir=$1 script
  mkdir -p "$dir/bin" "$dir/docs"
  for script in fm-sessionstart-nudge.sh fm-turnend-guard.sh fm-lock.sh \
    fm-supervision-instructions.sh fm-operational-input.sh fm-harness.sh \
    fm-gate-refuse-lib.sh fm-primary-scope-lib.sh fm-supervision-lib.sh \
    fm-session-lock-lib.sh fm-wake-lib.sh; do
    cp "$ROOT/bin/$script" "$dir/bin/$script"
  done
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir/bin/fm-sessionstart-nudge.sh" "$dir/bin/fm-turnend-guard.sh" \
    "$dir/bin/fm-lock.sh" "$dir/bin/fm-supervision-instructions.sh" \
    "$dir/bin/fm-operational-input.sh" "$dir/bin/fm-harness.sh"
}

# A primary home holding the record of a session that has been cleared away,
# plus the sequence a cleared session actually runs: session-start nudge, one
# turn end, the session-start acquisition, then both readers again.
make_clear_sequence_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task1.meta"
  install_clear_sequence_scripts "$dir"
  cat > "$dir/sequence.sh" <<'SH'
#!/usr/bin/env bash
# Runs AS the harness-named session process, so $$ is the pid an unchanged
# process tree keeps handing every reader below.
state="$FM_HOME/state"
unset NO_MISTAKES_GATE
export CLAUDE_CODE_SESSION_ID="$FM_POST_CLEAR_ID"
export CLAUDECODE=1
export TMPDIR="$FM_HOME"
export FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100
printf 'pid=%s harness=claude session=%s\n' "$$" "$FM_PRE_CLEAR_ID" > "$state/.lock"

run_step() {  # <name> <command...>
  local name=$1
  shift
  "$@" > "$state/$name.out" 2>&1
  printf '%s\n' "$?" > "$state/$name.rc"
}

run_turn_end() {  # <name>
  local name=$1
  printf '{"stop_hook_active":true,"session_id":"%s"}' "$CLAUDE_CODE_SESSION_ID" \
    | "$FM_HOME/bin/fm-turnend-guard.sh" --claude > "$state/$name.out" 2>&1
  printf '%s\n' "$?" > "$state/$name.rc"
}

run_step nudge-before "$FM_HOME/bin/fm-sessionstart-nudge.sh"
run_turn_end guard-before
run_step reclaim "$FM_HOME/bin/fm-lock.sh"
run_step status-after "$FM_HOME/bin/fm-lock.sh" status
run_step nudge-after "$FM_HOME/bin/fm-sessionstart-nudge.sh"
run_turn_end guard-after
SH
  chmod +x "$dir/sequence.sh"
}

run_clear_sequence() {  # <dir>
  local dir=$1
  FM_HOME="$dir" FM_PRE_CLEAR_ID=sess-pre-clear FM_POST_CLEAR_ID=sess-post-clear \
    "$NAMED_CLAUDE" "$dir/sequence.sh"
}

step_rc() {  # <dir> <name>
  tr -d '[:space:]' < "$1/state/$2.rc"
}

step_out() {  # <dir> <name>
  cat "$1/state/$2.out"
}

test_e2e_cleared_session_is_told_to_claim_the_home_and_can() {
  local dir record
  dir="$TMP_ROOT/e2e-clear-sequence"
  make_clear_sequence_home "$dir"
  run_clear_sequence "$dir"

  expect_code 0 "$(step_rc "$dir" nudge-before)" "the session-start nudge must never block session init"
  assert_contains "$(step_out "$dir" nudge-before)" 'bin/fm-session-start.sh' \
    "a record left by the pre-clear session silenced the session-start instruction"

  expect_code 0 "$(step_rc "$dir" guard-before)" "a session that does not hold the home must not be blocked"
  assert_contains "$(step_out "$dir" guard-before)" 'systemMessage' \
    "the read-only allow was silent, so the session was left with no reason it stopped being blocked"
  assert_contains "$(step_out "$dir" guard-before)" 'sess-pre-clear' \
    "the read-only notice did not name the identity that holds the home"
  assert_contains "$(step_out "$dir" guard-before)" 'read-only' \
    "the read-only notice did not say this session cannot repair supervision"

  expect_code 0 "$(step_rc "$dir" reclaim)" \
    "the cleared session could not reclaim its own home: $(step_out "$dir" reclaim)"
  record=$(cat "$dir/state/.lock")
  case "$record" in
    *'session=sess-post-clear'*) : ;;
    *) fail "the reclaimed record does not carry the current session id: $record" ;;
  esac
  assert_contains "$(step_out "$dir" status-after)" 'sess-post-clear' \
    "fm-lock.sh status did not show the reclaimed session id"

  [ -z "$(step_out "$dir" nudge-after)" ] \
    || fail "the nudge still fired after the home was reclaimed: $(step_out "$dir" nudge-after)"
  expect_code 2 "$(step_rc "$dir" guard-after)" \
    "after the reclaim the guard must own the home again and block an unsupervised turn end"
  assert_contains "$(step_out "$dir" guard-after)" 'TURN WOULD END BLIND' \
    "the owning session's block lost its banner"
  pass "session-lock e2e: a cleared session is nudged to claim its home, ends its turns loudly until it does, and every reader agrees after it does"
}

test_version_named_session_is_identified_on_both_platforms
test_typed_record_survives_a_changed_process_tree
test_typed_record_refuses_a_different_live_session
test_typed_record_pid_is_only_a_liveness_hint
test_unrecognized_records_fail_closed
test_legacy_record_is_read_exactly_as_before
test_session_id_is_resolved_only_for_publishing_harnesses
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
test_e2e_cleared_session_is_told_to_claim_the_home_and_can
