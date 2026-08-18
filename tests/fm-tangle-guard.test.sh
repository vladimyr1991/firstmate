#!/usr/bin/env bash
# Behavior tests for the worktree-tangle guards.
#
# Firstmate is a treehouse-pooled git repo of itself: disposable crewmate
# worktrees and leased secondmate homes are all linked worktrees of the same
# repo. The "tangle" is a crewmate branching/committing in the OPERATING
# checkout - the one its session runs its home from - instead of its own
# disposable worktree, stranding that checkout on a feature branch. A crewmate
# on the fm/<id> branch its brief mandates, inside its own linked worktree, is
# correct work and must stay silent. Two guards cover it:
#   GUARD 1 (prevention) - the brief asserts isolation before its branch step, and
#            fm-spawn refuses to launch unless the resolved worktree is isolated.
#   GUARD 2 (detection)  - fm-guard and fm-bootstrap resolve the operating
#            checkout (fm_tangle_checkout), then alarm when THAT checkout is on a
#            named non-default branch. The default branch, a detached HEAD, and a
#            disposable worktree the script merely runs from stay silent.
# These cases pin: the shared lib's path-local branch classification, the
# operating-checkout resolver, the fm-guard banner, the fm-bootstrap problem
# line, the brief assertion ordering, and the fm-spawn abort - all hermetic over
# temp git repos and fakebins.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tangle-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tangle-guard)
fm_git_identity fmtest fmtest@example.invalid

# A fresh git repo on `main` with one commit. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# --- shared lib: branch classification --------------------------------------

# fm_primary_tangle_branch is the path-local half of the decision: given ONE
# directory, a NAMED non-default branch is the tangle; the default branch and
# detached HEAD are healthy. Which directory it is handed is fm_tangle_checkout's
# job, covered separately below.
test_lib_classification() {
  local repo n=0 label state branch expect out
  repo=$(make_repo "$TMP_ROOT/lib-repo")
  while IFS='|' read -r label state branch expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case "$state" in
      default)  git -C "$repo" checkout -q main ;;
      feature)  git -C "$repo" checkout -q -B "$branch" ;;
      detached) git -C "$repo" checkout -q main; git -C "$repo" checkout -q --detach ;;
    esac
    out=$(fm_primary_tangle_branch "$repo" || true)
    [ "$out" = "$expect" ] || fail "$label: expected tangle='$expect', got '$out'"
  done <<'ROWS'
on the default branch is healthy|default||
on a feature branch is the tangle|feature|fm/readme-restructure-d3|fm/readme-restructure-d3
detached HEAD on default is healthy (worktrees, secondmate homes)|detached||
ROWS
  # A non-git directory is not a tangle and must not error.
  out=$(fm_primary_tangle_branch "$TMP_ROOT" || true)
  [ -z "$out" ] || fail "non-git dir wrongly reported a tangle: '$out'"
  pass "fm_primary_tangle_branch: feature branch alarms; default/detached/non-git stay silent"
}

# --- GUARD 2a: fm-guard banner ----------------------------------------------

run_guard() {
  # Scope the guard to a temp repo as the primary checkout; state lives under it.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-guard.sh" 2>&1
}

test_guard_banner() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/guard-repo")

  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed while primary was on main"

  git -C "$repo" checkout -q --detach
  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed on a detached HEAD (legitimate worktree state)"

  git -C "$repo" checkout -q -B fm/tangle-aa1
  out=$(run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "guard did not alarm on a feature branch in the primary"
  assert_contains "$out" "fm/tangle-aa1" "guard banner did not name the offending branch"
  assert_contains "$out" "checkout main" "guard banner did not print the restore remediation"
  out=$(FM_GUARD_READ_ONLY=1 run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "read-only guard did not keep the tangle alarm"
  assert_contains "$out" "read-only session must leave restore work" "read-only guard did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "read-only guard printed a state-changing restore command"
  pass "fm-guard: bordered tangle banner fires only for a feature branch and suppresses repair commands in read-only mode"
}

# --- GUARD 2b: fm-bootstrap problem line ------------------------------------

run_bootstrap() {
  # No projects/ under the home keeps fleet sync inert; grep isolates the line.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_line() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/bootstrap-repo")

  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line while on main: $out"

  git -C "$repo" checkout -q --detach
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line on a detached HEAD: $out"

  git -C "$repo" checkout -q -B fm/tangle-bb2
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "bootstrap did not report the tangled branch"
  assert_contains "$out" "checkout main" "bootstrap TANGLE line lacked the restore remediation"
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "detect-only bootstrap did not report the tangled branch"
  assert_contains "$out" "$repo" "detect-only bootstrap did not name the stranded checkout"
  assert_contains "$out" "read-only session must leave restore work" "detect-only bootstrap did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "detect-only bootstrap printed a state-changing restore command"
  pass "fm-bootstrap: TANGLE problem line fires only for a feature branch and suppresses repair commands in detect-only mode"
}

# --- GUARD 2c: operating-checkout resolution --------------------------------

# Install the real scripts into <dir>/bin so a guard/bootstrap run from there
# resolves its script-relative FM_ROOT to <dir> - the ordinary crewmate shape,
# where neither FM_ROOT_OVERRIDE nor FM_HOME is set and the executed copy lives
# inside the disposable worktree.
install_bin() {
  local dir=$1
  mkdir -p "$dir/bin/backends"
  cp "$ROOT"/bin/*.sh "$dir/bin/"
  cp "$ROOT"/bin/backends/*.sh "$dir/bin/backends/"
}

# Physical path of <dir>, which is what git reports back to the resolver.
real_path() {
  (cd "$1" && pwd -P)
}

# Run the copy of fm-guard.sh under <script_root>/bin with the crewmate
# environment: FM_ROOT_OVERRIDE unset, FM_HOME unset unless given, and home
# state pointed at scratch so no sweep depends on the fixture layout.
run_guard_from() {
  local script_root=$1 scratch=$2 home=${3:-}
  if [ -n "$home" ]; then
    env -u FM_ROOT_OVERRIDE FM_HOME="$home" \
      FM_STATE_OVERRIDE="$scratch/state" FM_CONFIG_OVERRIDE="$scratch/config" \
      "$script_root/bin/fm-guard.sh" 2>&1
  else
    env -u FM_ROOT_OVERRIDE -u FM_HOME \
      FM_STATE_OVERRIDE="$scratch/state" FM_CONFIG_OVERRIDE="$scratch/config" \
      "$script_root/bin/fm-guard.sh" 2>&1
  fi
}

# Same for fm-bootstrap.sh, with every home path pointed at scratch so its
# sweeps stay inert (no projects/, no secondmates).
run_bootstrap_from() {
  local script_root=$1 scratch=$2 home=${3:-}
  if [ -n "$home" ]; then
    env -u FM_ROOT_OVERRIDE FM_HOME="$home" \
      FM_STATE_OVERRIDE="$scratch/state" FM_CONFIG_OVERRIDE="$scratch/config" \
      FM_DATA_OVERRIDE="$scratch/data" FM_PROJECTS_OVERRIDE="$scratch/projects" \
      "$script_root/bin/fm-bootstrap.sh" 2>/dev/null
  else
    env -u FM_ROOT_OVERRIDE -u FM_HOME \
      FM_STATE_OVERRIDE="$scratch/state" FM_CONFIG_OVERRIDE="$scratch/config" \
      FM_DATA_OVERRIDE="$scratch/data" FM_PROJECTS_OVERRIDE="$scratch/projects" \
      "$script_root/bin/fm-bootstrap.sh" 2>/dev/null
  fi
}

# AC-1 / AC-6: a ship worker that did exactly what its brief mandates - a named
# fm/<id> branch inside its own linked worktree - is healthy, and so is a scout
# worktree left detached. This is the false fire the resolver exists to stop.
test_isolated_worktree_is_healthy() {
  local repo ship scout scratch out
  repo=$(make_repo "$TMP_ROOT/iso-repo")
  ship="$TMP_ROOT/iso-ship"
  scout="$TMP_ROOT/iso-scout"
  scratch="$TMP_ROOT/iso-scratch"
  mkdir -p "$scratch"
  git -C "$repo" worktree add -q -b fm/ship-ac1 "$ship" >/dev/null 2>&1
  git -C "$repo" worktree add -q --detach "$scout" >/dev/null 2>&1
  install_bin "$ship"
  install_bin "$scout"

  out=$(fm_primary_tangle_branch "$(fm_tangle_checkout "$ship" "" 0)" || true)
  [ -z "$out" ] || fail "resolver+classifier reported a tangle for an isolated ship worktree: '$out'"

  out=$(run_guard_from "$ship" "$scratch")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed on a crewmate's own fm/<id> worktree"
  out=$(run_bootstrap_from "$ship" "$scratch" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line for a crewmate's own worktree: $out"

  out=$(run_guard_from "$scout" "$scratch")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed from a detached scout worktree"
  pass "operating-checkout resolution: an isolated fm/<id> worktree and a detached scout never alarm"
}

# AC-3: the genuine case a crewmate must still see - the repo's main worktree is
# itself stranded on a feature branch. Running from a linked worktree must still
# fire, and must name the main worktree and ITS branch, not the caller's.
test_primary_tangle_from_linked_worktree() {
  local repo ship scratch main_path out
  repo=$(make_repo "$TMP_ROOT/gen-repo")
  ship="$TMP_ROOT/gen-ship"
  scratch="$TMP_ROOT/gen-scratch"
  mkdir -p "$scratch"
  git -C "$repo" worktree add -q -b fm/ship-ac3 "$ship" >/dev/null 2>&1
  install_bin "$ship"
  git -C "$repo" checkout -q -B fm/primary-tangled
  main_path=$(real_path "$repo")

  out=$(fm_tangle_checkout "$ship" "" 0 || true)
  [ "$out" = "$main_path" ] || fail "resolver picked '$out', expected the main worktree '$main_path'"

  out=$(run_guard_from "$ship" "$scratch")
  assert_contains "$out" "WORKTREE TANGLE" "guard missed a stranded main worktree when run from a linked worktree"
  assert_contains "$out" "fm/primary-tangled" "guard banner did not name the stranded branch"
  assert_contains "$out" "$main_path" "guard banner did not name the stranded main worktree path"
  assert_not_contains "$out" "fm/ship-ac3" "guard banner named the caller's own worktree branch"
  assert_contains "$out" "git -C $main_path checkout main" "guard banner did not target the main worktree for repair"

  out=$(run_bootstrap_from "$ship" "$scratch" | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/primary-tangled" "bootstrap missed the stranded main worktree"
  assert_contains "$out" "git -C $main_path checkout main" "bootstrap TANGLE line did not target the main worktree"
  assert_not_contains "$out" "fm/ship-ac3" "bootstrap TANGLE line named the caller's own worktree branch"
  pass "operating-checkout resolution: a stranded main worktree still alarms from a crewmate pane and names the main path"
}

# AC-4: a secondmate home is a leased LINKED worktree and is the operating
# checkout for its own session, so a feature branch there is a real tangle. The
# session carries FM_HOME; that wins over the script-relative worktree.
test_secondmate_home_tangle() {
  local repo home ship scratch home_path out
  repo=$(make_repo "$TMP_ROOT/sm-repo")
  home="$TMP_ROOT/sm-home"
  ship="$TMP_ROOT/sm-ship"
  scratch="$TMP_ROOT/sm-scratch"
  mkdir -p "$scratch"
  git -C "$repo" worktree add -q -b fm/secondmate-home "$home" >/dev/null 2>&1
  git -C "$repo" worktree add -q -b fm/ship-ac4 "$ship" >/dev/null 2>&1
  install_bin "$ship"
  home_path=$(real_path "$home")

  out=$(fm_tangle_checkout "$ship" "$home" 0 || true)
  [ "$out" = "$home_path" ] || fail "resolver picked '$out', expected the FM_HOME work tree '$home_path'"

  out=$(run_guard_from "$ship" "$scratch" "$home")
  assert_contains "$out" "WORKTREE TANGLE" "guard missed a secondmate home stranded on a feature branch"
  assert_contains "$out" "fm/secondmate-home" "guard banner did not name the secondmate home branch"
  assert_contains "$out" "$home_path" "guard banner did not name the secondmate home path"
  assert_not_contains "$out" "fm/ship-ac4" "guard banner named the caller's worktree instead of the home"

  out=$(run_bootstrap_from "$ship" "$scratch" "$home" | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/secondmate-home" "bootstrap missed the stranded secondmate home"
  assert_contains "$out" "git -C $home_path checkout main" "bootstrap TANGLE line did not target the secondmate home"
  pass "operating-checkout resolution: a secondmate home on a feature branch still alarms and names the home"
}

# AC-5 / AC-7: the two contracts the fix must not quietly relax - an explicit
# FM_ROOT_OVERRIDE still wins over any FM_HOME (the wake-helper test seam), and
# the path-local classifier still reports a named branch in a linked worktree
# when asked about that path directly. The false-fire fix lives in resolution,
# not in "a named branch in a linked worktree is healthy".
test_override_and_path_local_contracts() {
  local repo ship notgit out
  repo=$(make_repo "$TMP_ROOT/ctr-repo")
  ship="$TMP_ROOT/ctr-ship"
  notgit="$TMP_ROOT/ctr-notgit"
  mkdir -p "$notgit"
  git -C "$repo" worktree add -q -b fm/ship-ac7 "$ship" >/dev/null 2>&1

  out=$(fm_primary_tangle_branch "$ship" || true)
  [ "$out" = "fm/ship-ac7" ] || fail "path-local classifier no longer reports a named branch in a linked worktree: '$out'"

  out=$(fm_tangle_checkout "$notgit" "$ship" 1 || true)
  [ "$out" = "$notgit" ] || fail "FM_ROOT_OVERRIDE did not win over FM_HOME: got '$out'"

  git -C "$repo" checkout -q -B fm/should-not-matter
  out=$(FM_ROOT_OVERRIDE="$notgit" FM_HOME="$repo" "$ROOT/bin/fm-guard.sh" 2>&1)
  assert_not_contains "$out" "WORKTREE TANGLE" "a non-git FM_ROOT_OVERRIDE no longer suppresses the tangle check"
  pass "operating-checkout resolution: FM_ROOT_OVERRIDE still wins and the path-local classifier is unchanged"
}

# A BARE-repository-backed layout has no operating primary checkout at all: the
# first porcelain record is the bare repo itself and every other record is a
# linked worktree. A bare repo's HEAD is routinely a named branch that is not
# the default, and `git rev-parse --is-inside-work-tree` prints `false` while
# still exiting 0 there, so both the resolver and the path-local classifier must
# reject it on the printed value. Otherwise a crewmate on its mandated fm/<id>
# branch is told a bare directory is stranded, with a repair command that cannot
# run - the same false fire on correct work the resolver exists to stop.
test_bare_backed_layout_stays_silent() {
  local src bare ship scratch out
  src=$(make_repo "$TMP_ROOT/bare-src")
  bare="$TMP_ROOT/bare-repo.git"
  ship="$TMP_ROOT/bare-ship"
  scratch="$TMP_ROOT/bare-scratch"
  mkdir -p "$scratch"
  git clone -q --bare "$src" "$bare"
  git -C "$bare" branch -q develop main
  git -C "$bare" symbolic-ref HEAD refs/heads/develop
  git -C "$bare" worktree add -q -b fm/ship-bare "$ship" >/dev/null 2>&1
  install_bin "$ship"

  # The bare repo still has a resolvable default branch, so nothing but the
  # work-tree check keeps the classifier off it.
  out=$(fm_default_branch "$bare" || true)
  [ "$out" = main ] || fail "fixture is not exercising the bare case: default branch resolved to '$out'"
  out=$(fm_primary_tangle_branch "$bare" || true)
  [ -z "$out" ] || fail "path-local classifier called a bare repository tangled: '$out'"

  out=$(fm_tangle_checkout "$ship" "" 0 || true)
  [ -z "$out" ] || fail "resolver picked a bare repository as the operating checkout: '$out'"
  out=$(fm_tangle_checkout "$ship" "$bare" 0 || true)
  [ -z "$out" ] || fail "a bare FM_HOME was accepted as the operating checkout: '$out'"

  out=$(run_guard_from "$ship" "$scratch")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed on a bare-backed layout with no primary checkout"
  out=$(run_bootstrap_from "$ship" "$scratch" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line for a bare-backed layout: $out"
  pass "operating-checkout resolution: a bare-backed repo layout resolves to no checkout and stays silent"
}

# --- GUARD 1a: brief isolation assertion ------------------------------------

# The generated ship brief must carry the isolation assertion AHEAD of the
# `git checkout -b` step, so the crewmate verifies its worktree before branching.
test_brief_assertion_precedes_branch() {
  local home brief iso br
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tangle-brief-cc3 alpha --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/tangle-brief-cc3/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "blocked [key=primary-checkout]: launched in primary checkout, not an isolated worktree" "$brief" \
    "brief is missing the isolation blocked-status contract"
  assert_grep "The path check is authoritative" "$brief" \
    "brief must make the path check authoritative"
  assert_no_grep "A reliable test that you are in a linked worktree" "$brief" \
    "brief must not present git-dir/common-dir as decisive"
  assert_no_grep "they are identical in the primary checkout" "$brief" \
    "brief must not claim the primary checkout has identical git dirs"
  iso=$(grep -n 'launched in primary checkout, not an isolated worktree' "$brief" | head -1 | cut -d: -f1)
  br=$(grep -n 'git checkout -b fm/' "$brief" | head -1 | cut -d: -f1)
  if [ -z "$iso" ] || [ -z "$br" ]; then
    fail "brief missing assertion ($iso) or branch step ($br)"
  fi
  [ "$iso" -lt "$br" ] || fail "isolation assertion (line $iso) must precede the branch step (line $br)"
  pass "fm-brief: ship brief asserts worktree isolation before the branch step"
}

# --- GUARD 1b: fm-spawn isolation abort -------------------------------------

# A fake tmux that reports FM_FAKE_PANE_PATH as the post-`treehouse get` pane cwd
# (so the spawn's worktree-resolution loop resolves to a path we control), names
# the session on '#S', and swallows window ops. Echoes the fakebin dir.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex --mode no-mistakes --yolo off 2>&1
}

test_spawn_isolation_abort() {
  local home proj fakebin out status
  home="$TMP_ROOT/spawn-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake")
  # A genuine isolated linked worktree of the project, detached on the default.
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-wt" >/dev/null 2>&1
  mkdir -p "$TMP_ROOT/spawn-notgit" "$proj/sub"

  # Abort: the pane resolves to a plain non-git directory (not a worktree at all).
  out=$(run_spawn "$home" abort-notgit-dd4 "$proj" "$TMP_ROOT/spawn-notgit" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn into a non-worktree dir should abort"
  assert_contains "$out" "did not yield an isolated worktree" "non-worktree spawn lacked the isolation error"
  assert_absent "$home/state/abort-notgit-dd4.meta" "aborted spawn must not record meta"

  # Abort: the pane resolves INTO the primary checkout (a subdir of PROJ_ABS).
  out=$(run_spawn "$home" abort-primary-ee5 "$proj" "$proj/sub" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn landing inside the primary checkout should abort"
  assert_contains "$out" "did not yield an isolated worktree" "primary-checkout spawn lacked the isolation error"

  # Proceed: the pane resolves to a genuine, isolated worktree.
  out=$(run_spawn "$home" ok-isolated-ff6 "$proj" "$TMP_ROOT/spawn-wt" "$fakebin"); status=$?
  expect_code 0 "$status" "spawn into a genuine isolated worktree should succeed"
  assert_contains "$out" "spawned ok-isolated-ff6" "isolated spawn did not report success"
  assert_not_contains "$out" "did not yield an isolated worktree" "isolated spawn wrongly tripped the guard"
  pass "fm-spawn: aborts unless the resolved worktree is a genuine, isolated worktree"
}

# --- GUARD 1c: fm-spawn tmux window construction ----------------------------

# The prevention guard also depends on fm-spawn building robust tmux commands
# under a non-default tmux config (base-index 1, automatic-rename on). A RECORDING
# fake tmux logs every invocation and returns a sentinel window id, so these
# assertions pin the command construction deterministically, with no live tmux:
#   - window creation targets the session with a trailing colon (append form), so
#     tmux appends at the next free index instead of the active window index, which
#     collides under base-index 1;
#   - the window id is captured (-P -F #{window_id}) and automatic-rename/allow-rename
#     are disabled so the fm-<id> name survives treehouse cd'ing into the worktree;
#   - the treehouse-get send-keys and the worktree wait loop target that stable
#     window id, never the (possibly-renamed) name - a lost name would let
#     display-message fall back to the active client's window and misread firstmate's
#     OWN pane as the worktree, tangling a hook into the primary checkout.
make_spawn_record_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '%s\n' "@spawnwid"; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn_record() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5 rec=$6
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    FM_TMUX_REC="$rec" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex --mode no-mistakes --yolo off 2>&1
}

test_spawn_tmux_window_construction() {
  local home proj fakebin rec wt out status
  home="$TMP_ROOT/spawn-rec-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-rec-proj")
  fakebin=$(make_spawn_record_fakebin "$TMP_ROOT/spawn-rec-fake")
  rec="$TMP_ROOT/spawn-rec.log"
  : > "$rec"
  wt="$TMP_ROOT/spawn-rec-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1

  out=$(run_spawn_record "$home" rec-win-gg7 "$proj" "$wt" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "spawn into a genuine worktree should succeed"
  assert_contains "$out" "spawned rec-win-gg7" "recording spawn did not report success"

  # Bug 1 fix: append-form window creation (trailing colon on the session target).
  assert_grep "new-window -dP -F #{window_id} -t firstmate: -n fm-rec-win-gg7" "$rec" \
    "new-window must append at the session (trailing colon) and capture the window id"
  assert_no_grep "new-window -dP -F #{window_id} -t firstmate -n" "$rec" \
    "new-window must not target the bare session name (collides under base-index 1)"

  # Bug 2 fix (a): pin the window name against automatic-rename / allow-rename.
  assert_grep "set-window-option -t @spawnwid automatic-rename off" "$rec" \
    "must disable automatic-rename on the spawned window"
  assert_grep "set-window-option -t @spawnwid allow-rename off" "$rec" \
    "must disable allow-rename on the spawned window"

  # Bug 2 fix (b): treehouse-get and the worktree wait loop target the stable id.
  assert_grep "send-keys -t @spawnwid treehouse get Enter" "$rec" \
    "treehouse get must be sent to the stable window id"
  assert_grep "display-message -p -t @spawnwid #{pane_current_path}" "$rec" \
    "the worktree wait loop must query the stable window id, not the name"

  pass "fm-spawn: appends windows by session-colon, pins the name, and targets the window id"
}

test_lib_classification
test_guard_banner
test_bootstrap_line
test_isolated_worktree_is_healthy
test_primary_tangle_from_linked_worktree
test_secondmate_home_tangle
test_override_and_path_local_contracts
test_bare_backed_layout_stays_silent
test_brief_assertion_precedes_branch
test_spawn_isolation_abort
test_spawn_tmux_window_construction
