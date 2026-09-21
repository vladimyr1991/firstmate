#!/usr/bin/env bash
# Regression test for fm-spawn.sh's task-metadata publication (bin/fm-spawn.sh,
# the record written to state/<id>.meta.tmp and renamed into place just before
# the launch command is sent to the pane).
#
# A spawn that cannot record state/<id>.meta must not report success and must
# not launch an agent: a task with a live agent and no record is invisible to
# supervision, capacity accounting, idle detection, and cleanup.
#
# The defect this guards lives in bash 3.2 (stock macOS /bin/bash): a failed
# redirection of a COMPOUND command is not a `set -e` error there, so the
# script used to carry on past the failed write and print `spawned <id>` with
# exit 0. bash 4+ exits at that point on its own, which is why every spawn is
# driven under each distinct bash on the machine - the runner's `bash` plus
# /bin/bash when it is a different binary - so the proof runs on the
# interpreter where the defect actually lives rather than only on the one
# where it cannot happen.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-meta-write)

# Every distinct bash binary to drive the spawn under, deduplicated by
# resolved path so a machine whose `bash` IS /bin/bash runs each case once.
list_interpreters() {
  local cand seen="" real
  for cand in "$(command -v bash)" /bin/bash; do
    [ -x "$cand" ] || continue
    real=$(cd "$(dirname "$cand")" && pwd -P)/$(basename "$cand")
    case "$seen" in
      *"|$real|"*) continue ;;
    esac
    seen="$seen|$real|"
    printf '%s\n' "$cand"
  done
}

# A fake tmux that reports the pane already sitting in the worktree and logs
# every invocation, so the test can prove that no launch command was ever sent.
make_meta_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?FM_FAKE_TMUX_LOG unset}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_meta_case <name> <id> builds a home and a project with a real worktree.
make_meta_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_meta_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_meta_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_meta_spawn() {  # <interpreter> <id>
  local interp=$1 id=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_TMUX_LOG="$CASE_DIR/tmux.log" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$interp" "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A directory squatting on state/<id>.meta makes the metadata write fail. The
# spawn must exit non-zero, must not print the success line, must not publish
# a regular metadata file, must leave no temporary metadata behind, and must
# never send the launch command (which carries the brief path) to the pane.
test_metadata_write_failure_is_not_success() {
  local interp rec id out status n=0
  for interp in $(list_interpreters); do
    n=$((n + 1))
    id="metafail-z$n"
    rec=$(make_meta_case "metafail-$n" "$id")
    read_meta_record "$rec"
    mkdir -p "$HOME_DIR/state/$id.meta"

    out=$(run_meta_spawn "$interp" "$id")
    status=$?
    [ "$status" -ne 0 ] || fail "[$interp] spawn reported success (exit 0) although metadata could not be written"$'\n'"--- output ---"$'\n'"$out"
    assert_not_contains "$out" "spawned $id" "[$interp] spawn printed the success line although metadata could not be written"
    assert_contains "$out" "metadata" "[$interp] spawn did not name the metadata write as the failure"
    assert_contains "$out" "Is a directory" "[$interp] spawn did not report why the metadata write failed"
    [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "[$interp] a regular metadata file was published despite the failure"
    [ -z "$(find "$HOME_DIR/state" -name "$id.meta.*" -print 2>/dev/null)" ] \
      || fail "[$interp] temporary metadata was left behind: $(find "$HOME_DIR/state" -name "$id.meta.*")"
    assert_no_grep "brief.md" "$CASE_DIR/tmux.log" "[$interp] the launch command was sent to the pane although no metadata was recorded"
    pass "[$interp] metadata write failure exits non-zero, publishes nothing, and launches no agent"
  done
  [ "$n" -ge 1 ] || fail "no bash interpreter found to drive the spawn"
}

# The ordinary path still publishes the record and leaves no temporary file.
test_metadata_write_success_publishes_record() {
  local interp rec id out status n=0
  for interp in $(list_interpreters); do
    n=$((n + 1))
    id="metaok-z$n"
    rec=$(make_meta_case "metaok-$n" "$id")
    read_meta_record "$rec"

    out=$(run_meta_spawn "$interp" "$id")
    status=$?
    expect_code 0 "$status" "[$interp] spawn should succeed when metadata can be written"
    assert_contains "$out" "spawned $id" "[$interp] spawn did not report success"
    assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "[$interp] metadata did not record the worktree"
    assert_grep "backend=tmux" "$HOME_DIR/state/$id.meta" "[$interp] metadata did not record the backend"
    [ -z "$(find "$HOME_DIR/state" -name "$id.meta.*" -print 2>/dev/null)" ] \
      || fail "[$interp] temporary metadata was left behind after a successful publish"
    assert_grep "brief.md" "$CASE_DIR/tmux.log" "[$interp] the launch command was never sent to the pane"
    pass "[$interp] successful metadata publish records the task and launches the agent"
  done
}

# A directory squatting on the temporary sibling state/<id>.meta.tmp, with the
# final record path free, gets past the up-front directory refusal and makes
# the write itself fail with the OS's own "Is a directory": this is the case
# that exercises the write guard rather than the pre-check. The squatting
# directory is the test's own fixture, so it is the one thing allowed to
# remain in state/ afterwards.
test_metadata_temporary_write_failure_is_not_success() {
  local interp rec id out status n=0
  for interp in $(list_interpreters); do
    n=$((n + 1))
    id="metatmp-z$n"
    rec=$(make_meta_case "metatmp-$n" "$id")
    read_meta_record "$rec"
    mkdir -p "$HOME_DIR/state/$id.meta.tmp"

    out=$(run_meta_spawn "$interp" "$id")
    status=$?
    [ "$status" -ne 0 ] || fail "[$interp] spawn reported success (exit 0) although the temporary metadata could not be written"$'\n'"--- output ---"$'\n'"$out"
    assert_not_contains "$out" "spawned $id" "[$interp] spawn printed the success line although the temporary metadata could not be written"
    assert_contains "$out" "metadata" "[$interp] spawn did not name the metadata write as the failure"
    assert_contains "$out" "Is a directory" "[$interp] spawn did not report the OS reason the temporary metadata write failed"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "[$interp] a metadata record was published despite the failed write"
    [ -d "$HOME_DIR/state/$id.meta.tmp" ] || fail "[$interp] the squatting directory at the temporary path was removed"
    [ -z "$(find "$HOME_DIR/state" -name "$id.meta.*" ! -path "$HOME_DIR/state/$id.meta.tmp" -print 2>/dev/null)" ] \
      || fail "[$interp] temporary metadata was left behind: $(find "$HOME_DIR/state" -name "$id.meta.*" ! -path "$HOME_DIR/state/$id.meta.tmp")"
    assert_no_grep "brief.md" "$CASE_DIR/tmux.log" "[$interp] the launch command was sent to the pane although no metadata was recorded"
    pass "[$interp] temporary metadata write failure exits non-zero, publishes nothing, and launches no agent"
  done
  [ "$n" -ge 1 ] || fail "no bash interpreter found to drive the spawn"
}

test_metadata_write_failure_is_not_success
test_metadata_temporary_write_failure_is_not_success
test_metadata_write_success_publishes_record

echo "# all fm-spawn-meta-write tests passed"
