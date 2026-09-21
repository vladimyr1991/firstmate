#!/usr/bin/env bash
# Regression tests for cleanup endpoint identity validation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-endpoint-safety)
REAL_TMUX=$(command -v tmux || true)

make_case() {  # <name>
  local dir=$1
  mkdir -p "$TMP_ROOT/$dir/home/state" "$TMP_ROOT/$dir/home/data" \
    "$TMP_ROOT/$dir/home/config" "$TMP_ROOT/$dir/fakebin" \
    "$TMP_ROOT/$dir/worktree" "$TMP_ROOT/$dir/project"
  : > "$TMP_ROOT/$dir/worktree/sentinel"
  : > "$TMP_ROOT/$dir/runtime.log"
  cat > "$TMP_ROOT/$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  cat > "$TMP_ROOT/$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$TMP_ROOT/$dir/fakebin/tmux" "$TMP_ROOT/$dir/fakebin/treehouse"
  printf '%s\n' "$TMP_ROOT/$dir"
}

run_case() {  # <case> <id>
  local dir=$1 id=$2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force
}

assert_refused_without_mutation() {  # <case> <id> <description>
  local dir=$1 id=$2 description=$3 rc
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: teardown unexpectedly succeeded"
  assert_present "$dir/home/state/$id.meta" "$description: metadata changed before refusal"
  assert_present "$dir/worktree/sentinel" "$description: worktree changed before refusal"
  [ ! -s "$dir/runtime.log" ] || fail "$description: runtime command ran before refusal: $(cat "$dir/runtime.log")"
}

test_invalid_endpoint_records_refuse_before_mutation() {
  local dir id=endpoint-a

  dir=$(make_case missing)
  fm_write_meta "$dir/home/state/$id.meta" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "missing endpoint"

  dir=$(make_case empty)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty endpoint"

  dir=$(make_case malformed)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=ambient-current-window" "worktree=$dir/worktree" \
    "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "malformed endpoint"

  dir=$(make_case mismatched)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-other-task" "endpoint_task_id=other-task" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "task-mismatched endpoint"

  dir=$(make_case empty-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty task binding"

  dir=$(make_case duplicate-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "duplicate task binding"

  pass "fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call"
}

test_supported_backend_endpoint_records_validate() {
  local dir id backend target
  dir=$(make_case valid-backends)
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"

  id=tmux-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid tmux endpoint refused"
  [ "$FM_BACKEND_VALIDATED_BACKEND:$FM_BACKEND_VALIDATED_TARGET" = "tmux:firstmate:fm-$id" ] || fail "tmux endpoint validation returned wrong identity"

  id=tmux-spaced-session
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=team work:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid tmux endpoint with a spaced session name refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = "team work:fm-$id" ] || fail "tmux validation changed the spaced session identity"

  id=herdr-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:w1:p2" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Herdr endpoint refused"

  id=zellij-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:7" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=zellij" "zellij_session=lab" "zellij_tab_id=3" "zellij_pane_id=7"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Zellij endpoint refused"

  id=orca-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-7" \
    "worktree=$dir/worktree" "project=$dir/project" "backend=orca" "orca_worktree_id=worktree-9"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Orca endpoint refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = term-7 ] || fail "Orca validation did not select its terminal"

  id=cmux-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=workspace-1:surface-2" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=cmux" "cmux_workspace_id=workspace-1" "cmux_surface_id=surface-2"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid cmux endpoint refused"

  for backend in tmux herdr zellij orca cmux; do
    set +e
    fm_backend_kill "$backend" "" >/dev/null 2>&1
    target=$?
    set -e
    [ "$target" -ne 0 ] || fail "$backend generic kill accepted an empty target"
  done
  pass "cleanup identity: valid tmux, Herdr, Zellij, Orca, and cmux records validate while every empty backend target refuses"
}

test_tmux_empty_target_refuses_without_invocation() {
  local dir rc
  dir=$(make_case direct-empty)
  set +e
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill ""' _ "$ROOT" \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "direct empty tmux target unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "direct empty tmux target invoked tmux"
  pass "tmux backend: direct empty target returns nonzero without invoking tmux"
}

test_recorded_process_identity_cleanup_is_exact() {
  local dir target_pid control_pid target_record control_record live_command
  dir=$(make_case recorded-process)
  sleep 30 &
  control_pid=$!
  sleep 30 &
  target_pid=$!
  printf '%s\n' "$control_pid" > "$dir/control.pid"
  printf '%s\n' "$target_pid" > "$dir/target.pid"
  target_record=$(cat "$dir/target.pid")
  control_record=$(cat "$dir/control.pid")
  [ "$target_record" = "$target_pid" ] && [ "$control_record" = "$control_pid" ] \
    || fail "recorded process identity changed before cleanup"
  live_command=$(ps -p "$target_record" -o comm= 2>/dev/null | tr -d '[:space:]')
  case "$live_command" in sleep) ;; *) fail "recorded target pid no longer belongs to the expected child" ;; esac
  kill -TERM "$target_record"
  wait "$target_record" 2>/dev/null || true
  kill -0 "$target_record" 2>/dev/null && fail "exact target pid survived cleanup"
  kill -0 "$control_record" 2>/dev/null || fail "independent control process was disturbed"
  kill -TERM "$control_record"
  wait "$control_record" 2>/dev/null || true
  pass "process cleanup: creation-time PID identity removes only the exact child and preserves the control child"
}

isolated_tmux_window_exists() {  # <dir> <socket> <session> <window>
  ( cd "$1" && "$REAL_TMUX" -S "$2" list-windows -t "$3" -F '#{window_name}' 2>/dev/null ) \
    | grep -Fqx "$4"
}

test_isolated_tmux_invalid_and_valid_cleanup() {
  local dir socket socket_id session='endpoint safety' target_id=target control=control target=fm-target
  local prefix_target=fm-prefix prefix_survivor=fm-prefix2 rc
  [ -n "$REAL_TMUX" ] || { echo "skip - tmux not installed"; return 0; }
  dir=$(make_case isolated-real)
  socket=dedicated.sock
  socket_id="$dir/$socket"
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-session -d -s "$session" -n "$control" )
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "$session:" -n "$target" )
  printf '%s\n' "$socket_id" > "$dir/socket.identity"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
set -eu
[ -z "\${TMUX:-}" ] && [ -z "\${TMUX_PANE:-}" ] || exit 91
[ "\${FM_TEST_TMUX_SOCKET:-}" = '$socket_id' ] || exit 92
[ "\$(cat '$dir/socket.identity')" = '$socket_id' ] || exit 93
printf 'tmux' >> "\${FM_RUNTIME_LOG:?}"
printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"
printf '\n' >> "\${FM_RUNTIME_LOG:?}"
cd '$dir'
exec '$REAL_TMUX' -S '$socket' "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  fm_write_meta "$dir/home/state/invalid.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  set +e
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" invalid --force \
    > "$dir/invalid.out" 2> "$dir/invalid.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "isolated invalid endpoint unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "isolated invalid endpoint reached tmux"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" || fail "invalid cleanup removed control window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" || fail "invalid cleanup removed target window"

  set +e
  # shellcheck disable=SC2016 # $1 expands inside the isolated child shell.
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill ""' _ "$ROOT" \
    > "$dir/empty.out" 2> "$dir/empty.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "isolated direct empty target unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "isolated direct empty target reached tmux"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" || fail "direct empty cleanup removed control window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" || fail "direct empty cleanup removed target window"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "=$session:" -n "$prefix_survivor" )
  # shellcheck disable=SC2016 # $1 and $2 expand inside the isolated child shell.
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill "$2"' _ "$ROOT" "$session:$prefix_target"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$prefix_survivor" \
    || fail "missing exact target cleanup removed its prefix-matched neighbor"

  fm_write_meta "$dir/home/state/$target_id.meta" \
    "window=$session:$target" "endpoint_task_id=$target_id" \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "kind=scout" "mode=no-mistakes"
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$target_id" --force \
    > "$dir/valid.out" 2> "$dir/valid.err" \
    || fail "isolated valid endpoint teardown failed: $(cat "$dir/valid.err")"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" \
    && fail "valid cleanup did not remove the exact target window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" \
    || fail "valid cleanup removed the independent control window"
  grep -Fqx "tmux <kill-window> <-t> <=$session:=$target>" "$dir/runtime.log" \
    || fail "valid cleanup did not invoke exactly the recorded target: $(cat "$dir/runtime.log")"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null ) || true
  pass "fm-teardown: exact tmux cleanup preserves invalid and prefix-matched neighbors while removing only the recorded target"
}


# FR-1..FR-5, FR-7: a worktree another live record in the same home still
# claims refuses before any runtime command, even under --force; the sibling's
# claim is compared canonically (a symlink alias spells the same path), while a
# record naming a different directory, including a string-prefix neighbour, is
# not a claim and the return is invoked with exactly the recorded path.
test_worktree_claimed_by_another_live_record_refuses_before_mutation() {
  local dir
  dir=$(make_case claimed)
  ln -s "$dir/worktree" "$dir/worktree-alias"
  fm_write_meta "$dir/home/state/victim.meta" \
    "window=firstmate:fm-victim" "worktree=$dir/worktree" \
    "project=$dir/project" "kind=scout" "mode=no-mistakes"
  fm_write_meta "$dir/home/state/stale.meta" \
    "window=firstmate:fm-stale" "worktree=$dir/worktree-alias" \
    "project=$dir/project" "kind=scout" "mode=no-mistakes"
  assert_refused_without_mutation "$dir" stale "claimed worktree"
  assert_grep "REFUSED: task stale records worktree $dir/worktree-alias" "$dir/stderr" \
    "claimed worktree refusal did not name this task and its recorded path: $(cat "$dir/stderr")"
  assert_grep "live task victim" "$dir/stderr" \
    "claimed worktree refusal did not name the live claimant: $(cat "$dir/stderr")"
  assert_grep "preserving task state" "$dir/stderr" \
    "claimed worktree refusal did not state that task state is preserved: $(cat "$dir/stderr")"
  assert_present "$dir/home/state/victim.meta" "claimed worktree refusal changed the claimant's record"

  # Positive control: the same records once stale names a directory no other
  # record claims. A prefix neighbour (worktree-extra) and a sibling with no
  # worktree= line must not count as claims either.
  mkdir "$dir/other-worktree" "$dir/other-worktree-extra"
  fm_write_meta "$dir/home/state/stale.meta" \
    "window=firstmate:fm-stale" "worktree=$dir/other-worktree" \
    "project=$dir/project" "kind=scout" "mode=no-mistakes"
  fm_write_meta "$dir/home/state/prefix.meta" \
    "window=firstmate:fm-prefix" "worktree=$dir/other-worktree-extra" \
    "project=$dir/project" "kind=scout" "mode=no-mistakes"
  fm_write_meta "$dir/home/state/bare.meta" \
    "window=firstmate:fm-bare" "project=$dir/project" "kind=scout" "mode=no-mistakes"
  run_case "$dir" stale > "$dir/control.out" 2> "$dir/control.err" \
    || fail "unclaimed worktree teardown failed: $(cat "$dir/control.err")"
  assert_no_grep "REFUSED:" "$dir/control.err" \
    "unclaimed worktree teardown printed a refusal: $(cat "$dir/control.err")"
  grep -Fqx "treehouse <return> <--force> <$dir/other-worktree>" "$dir/runtime.log" \
    || fail "unclaimed worktree teardown did not return exactly the recorded path: $(cat "$dir/runtime.log")"
  ! grep -F "<$dir/worktree>" "$dir/runtime.log" >/dev/null \
    || fail "unclaimed worktree teardown touched the claimant's worktree: $(cat "$dir/runtime.log")"
  ! grep -F "<$dir/other-worktree-extra>" "$dir/runtime.log" >/dev/null \
    || fail "unclaimed worktree teardown touched the prefix neighbour: $(cat "$dir/runtime.log")"
  assert_present "$dir/home/state/victim.meta" "unclaimed worktree teardown removed the claimant's record"
  assert_present "$dir/home/state/prefix.meta" "unclaimed worktree teardown removed the prefix neighbour's record"
  assert_present "$dir/worktree/sentinel" "unclaimed worktree teardown changed the claimant's worktree"
  assert_absent "$dir/home/state/stale.meta" "unclaimed worktree teardown left its own record behind"
  pass "fm-teardown: a worktree another live record claims refuses before every runtime call, while an unclaimed or prefix-neighbour path returns exactly the recorded worktree"
}

REAL_TREEHOUSE=$(command -v treehouse || true)
REAL_TREEHOUSE_PIDS=()
REAL_TREEHOUSE_REPO=
REAL_TREEHOUSE_SLOTS=()

kill_real_treehouse_pids() {
  local pid
  for pid in "${REAL_TREEHOUSE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  REAL_TREEHOUSE_PIDS=()
}

# EXIT trap for the real-tool test: kill every sleep it started and return every
# slot it leased, on the failure path too, then run the library cleanup. Its
# last command must succeed so the trap never rewrites the suite's exit status.
real_treehouse_cleanup() {
  local slot
  kill_real_treehouse_pids
  for slot in "${REAL_TREEHOUSE_SLOTS[@]:-}"; do
    [ -n "$slot" ] && [ -d "$slot" ] || continue
    ( cd "$REAL_TREEHOUSE_REPO" && "$REAL_TREEHOUSE" return --force "$slot" ) >/dev/null 2>&1 || true
  done
  REAL_TREEHOUSE_SLOTS=()
  # The suite runs under set -e by the time this fires, so the library's
  # own loop status must not become this trap's.
  fm_test_cleanup || true
  return 0
}

wait_pid_gone() {  # <pid> <seconds>
  local pid=$1 deadline=$(( $(date +%s) + $2 ))
  while kill -0 "$pid" 2>/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.2
  done
  return 0
}

# FR-8: pin the contract the claim refusal rests on against the real tool.
# Returning one pool slot terminates only processes whose cwd is that slot or a
# descendant of it; a process in a sibling slot of the same pool survives, and
# returning that sibling slot itself then terminates it.
test_real_treehouse_return_terminates_only_the_returned_worktrees_processes() {
  local dir repo a b pid pid_a_root pid_a_sub pid_b
  [ -n "$REAL_TREEHOUSE" ] || { echo "skip - treehouse not installed"; return 0; }
  dir="$TMP_ROOT/real-treehouse"
  repo="$dir/repo"
  mkdir -p "$dir/pool"
  fm_git_init_commit "$repo"
  printf 'max_trees = 4\nroot = "%s"\n' "$dir/pool" > "$repo/treehouse.toml"
  git -C "$repo" add treehouse.toml
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'pool config'
  export TREEHOUSE_NO_UPDATE_CHECK=1
  REAL_TREEHOUSE_REPO=$repo
  trap real_treehouse_cleanup EXIT
  a=$(cd "$repo" && "$REAL_TREEHOUSE" get --lease --lease-holder a 2>"$dir/get-a.err") \
    || fail "treehouse get for slot a failed: $(cat "$dir/get-a.err")"
  REAL_TREEHOUSE_SLOTS=("$a")
  b=$(cd "$repo" && "$REAL_TREEHOUSE" get --lease --lease-holder b 2>"$dir/get-b.err") \
    || fail "treehouse get for slot b failed: $(cat "$dir/get-b.err")"
  REAL_TREEHOUSE_SLOTS=("$a" "$b")
  [ -d "$a" ] && [ -d "$b" ] && [ "$a" != "$b" ] || fail "treehouse did not hand out two distinct slots: a=$a b=$b"
  case "$(cd "$a" && pwd -P)" in "$(cd "$dir/pool" && pwd -P)"/*) ;; *) fail "slot a is not under the hermetic pool root: $a" ;; esac
  [ "$(dirname "$(dirname "$a")")" = "$(dirname "$(dirname "$b")")" ] \
    || fail "slots are not siblings of one pool: a=$a b=$b"
  mkdir "$a/sub"
  ( cd "$a" && exec sleep 60 ) &
  pid_a_root=$!
  ( cd "$a/sub" && exec sleep 60 ) &
  pid_a_sub=$!
  ( cd "$b" && exec sleep 60 ) &
  pid_b=$!
  REAL_TREEHOUSE_PIDS=("$pid_a_root" "$pid_a_sub" "$pid_b")
  sleep 1
  for pid in "$pid_a_root" "$pid_a_sub" "$pid_b"; do
    kill -0 "$pid" 2>/dev/null || fail "sleep $pid died before the return"
  done

  ( cd "$repo" && "$REAL_TREEHOUSE" return --force "$b" ) > "$dir/return-b.out" 2>&1 \
    || fail "treehouse return of slot b failed: $(cat "$dir/return-b.out")"
  wait_pid_gone "$pid_b" 3 || fail "returning slot b left its own process alive"
  kill -0 "$pid_a_root" 2>/dev/null || fail "returning slot b terminated the sibling slot's root process"
  kill -0 "$pid_a_sub" 2>/dev/null || fail "returning slot b terminated the sibling slot's subdirectory process"
  grep -q "Terminated lingering processes" "$dir/return-b.out" \
    || fail "treehouse return of slot b did not report terminating its process: $(cat "$dir/return-b.out")"

  ( cd "$repo" && "$REAL_TREEHOUSE" return --force "$a" ) > "$dir/return-a.out" 2>&1 \
    || fail "treehouse return of slot a failed: $(cat "$dir/return-a.out")"
  wait_pid_gone "$pid_a_root" 3 || fail "returning slot a left its root process alive"
  wait_pid_gone "$pid_a_sub" 3 || fail "returning slot a left its subdirectory process alive"
  kill_real_treehouse_pids
  REAL_TREEHOUSE_SLOTS=()
  pass "treehouse return: returning one pool slot terminates only that slot's processes and leaves the sibling slot's alive"
}

test_invalid_endpoint_records_refuse_before_mutation
test_supported_backend_endpoint_records_validate
test_tmux_empty_target_refuses_without_invocation
test_recorded_process_identity_cleanup_is_exact
test_isolated_tmux_invalid_and_valid_cleanup
test_worktree_claimed_by_another_live_record_refuses_before_mutation
test_real_treehouse_return_terminates_only_the_returned_worktrees_processes
