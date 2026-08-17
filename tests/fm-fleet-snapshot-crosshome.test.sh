#!/usr/bin/env bash
# Behavior tests for fm-fleet-snapshot --home-summary / --cross-home and
# additive links exposure (FR-1..FR-5, AC-2/3/5/7/13).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-crosshome)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fakebin() {
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/tmux" "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

# A minimal firstmate home usable as a --home-summary / --cross-home target.
make_readable_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$home/bin"
  # Regular non-symlink AGENTS.md required by validate_readable_home.
  printf '# firstmate home\n' > "$home/AGENTS.md"
  printf '%s\n' "$home"
}

write_task_meta() {  # <home> <id> [extra meta lines...]
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "$@"
}

test_home_summary_reads_non_secondmate_home() {
  local observer target target_real out fakebin
  observer=$(make_readable_home observer-hs)
  target=$(make_readable_home target-hs)
  target_real=$(cd "$target" && pwd -P)
  write_task_meta "$target" t1
  fakebin=$(make_fakebin "$TMP_ROOT/fakebin-hs")
  out=$(
    PATH="$fakebin:$PATH" \
      FM_HOME="$observer" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$observer/state" FM_DATA_OVERRIDE="$observer/data" \
      FM_CONFIG_OVERRIDE="$observer/config" FM_PROJECTS_OVERRIDE="$observer/projects" \
      "$SNAPSHOT" --home-summary "$target"
  ) || fail "home-summary of a non-secondmate home should exit 0: $out"
  printf '%s' "$out" | jq -e --arg home "$target_real" '
    .schema == "fm-secondmate-home-summary.v1"
    and .home == $home
  ' >/dev/null || fail "home-summary schema/home wrong: $out"
  pass "AC-2: --home-summary reads a non-secondmate home"
}

test_home_summary_refuses_unsafe_targets() {
  local observer target err rc fakebin
  observer=$(make_readable_home observer-refuse)
  target=$(make_readable_home target-refuse)
  fakebin=$(make_fakebin "$TMP_ROOT/fakebin-refuse")

  # Active FM_HOME
  err=$(
    PATH="$fakebin:$PATH" \
      FM_HOME="$observer" FM_ROOT_OVERRIDE="$ROOT" \
      "$SNAPSHOT" --home-summary "$observer" 2>&1 >/dev/null
  ); rc=$?
  [ "$rc" -eq 2 ] || fail "self home-summary should exit 2, got $rc: $err"
  assert_contains "$err" "active firstmate home" "self-home refusal must name the reason"

  # Missing AGENTS.md
  rm -f "$target/AGENTS.md"
  err=$(
    PATH="$fakebin:$PATH" \
      FM_HOME="$observer" FM_ROOT_OVERRIDE="$ROOT" \
      "$SNAPSHOT" --home-summary "$target" 2>&1 >/dev/null
  ); rc=$?
  [ "$rc" -eq 2 ] || fail "missing AGENTS.md should exit 2, got $rc: $err"
  assert_contains "$err" "missing AGENTS.md" "missing AGENTS.md refusal must name the reason"

  # state/ is a symlink
  target=$(make_readable_home target-symlink)
  rm -rf "$target/state"
  mkdir -p "$TMP_ROOT/outside-state"
  ln -s "$TMP_ROOT/outside-state" "$target/state"
  err=$(
    PATH="$fakebin:$PATH" \
      FM_HOME="$observer" FM_ROOT_OVERRIDE="$ROOT" \
      "$SNAPSHOT" --home-summary "$target" 2>&1 >/dev/null
  ); rc=$?
  [ "$rc" -eq 2 ] || fail "symlink state/ should exit 2, got $rc: $err"
  [ -z "$(
    PATH="$fakebin:$PATH" \
      FM_HOME="$observer" FM_ROOT_OVERRIDE="$ROOT" \
      "$SNAPSHOT" --home-summary "$target" 2>/dev/null
  )" ] || fail "refused home-summary must print nothing on stdout"

  # Relative path
  err=$(
    PATH="$fakebin:$PATH" \
      FM_HOME="$observer" FM_ROOT_OVERRIDE="$ROOT" \
      "$SNAPSHOT" --home-summary relative/path 2>&1 >/dev/null
  ); rc=$?
  [ "$rc" -eq 2 ] || fail "relative path should exit 2, got $rc: $err"
  assert_contains "$err" "not absolute" "relative path refusal must name the reason"

  pass "AC-3: --home-summary refuses unsafe targets"
}

test_links_exposure_on_json_and_summary() {
  local home out fakebin
  home=$(make_readable_home links-home)
  write_task_meta "$home" linked \
    "notion_page=https://www.notion.so/card-linked" \
    "notion_linked_ts=2026-08-01T00:00:00Z"
  write_task_meta "$home" archived \
    "notion_page_archived=https://www.notion.so/card-archived"
  write_task_meta "$home" bare
  fakebin=$(make_fakebin "$TMP_ROOT/fakebin-links")

  out=$(
    PATH="$fakebin:$PATH" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
      "$SNAPSHOT" --json
  ) || fail "--json should exit 0"
  printf '%s' "$out" | jq -e '
    (.tasks[] | select(.id=="linked") | .links.notion_page)
      == "https://www.notion.so/card-linked"
    and (.tasks[] | select(.id=="linked") | .links.notion_page_archived) == null
    and (.tasks[] | select(.id=="archived") | .links.notion_page) == null
    and (.tasks[] | select(.id=="archived") | .links.notion_page_archived)
      == "https://www.notion.so/card-archived"
    and (.tasks[] | select(.id=="bare") | .links.notion_page) == null
  ' >/dev/null || fail "tasks[].links wrong: $out"

  out=$(
    PATH="$fakebin:$PATH" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
      "$SNAPSHOT" --secondmate-home-summary
  ) || fail "--secondmate-home-summary should exit 0"
  printf '%s' "$out" | jq -e '
    (.endpoints[] | select(.id=="linked") | .links.notion_page)
      == "https://www.notion.so/card-linked"
    and (.endpoints[] | select(.id=="bare") | .links.notion_page) == null
  ' >/dev/null || fail "endpoints[].links wrong: $out"

  pass "FR-4: links exposed on tasks[] and endpoints[]"
}

test_cross_home_shape_and_disclosure() {
  local observer parent sibling gone out rc fakebin
  local parent_real observer_real sibling_real gone_real
  observer=$(make_readable_home observer-ch)
  parent=$(make_readable_home parent-ch)
  sibling=$(make_readable_home sibling-ch)
  gone=$(make_readable_home gone-ch)
  parent_real=$(cd "$parent" && pwd -P)
  observer_real=$(cd "$observer" && pwd -P)
  sibling_real=$(cd "$sibling" && pwd -P)
  gone_real=$(cd "$gone" && pwd -P)
  write_task_meta "$parent" p-task \
    "notion_page=https://www.notion.so/parent-card"
  write_task_meta "$sibling" s-task \
    "notion_page_archived=https://www.notion.so/archived-card"
  # Registry: sibling (readable), gone (will be removed), observer (must be skipped)
  cat > "$parent/data/secondmates.md" <<EOF
- sibling - Sibling scope (home: $sibling_real; scope: sibling domain work; projects: ; added 2026-08-01)
- gone - Gone scope (home: $gone_real; scope: missing home work; projects: ; added 2026-08-01)
- observer - Observer scope (home: $observer_real; scope: self skip; projects: ; added 2026-08-01)
EOF
  rm -rf "$gone"

  fakebin=$(make_fakebin "$TMP_ROOT/fakebin-ch")
  out=$(
    PATH="$fakebin:$PATH" \
      FM_HOME="$observer_real" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$observer/state" FM_DATA_OVERRIDE="$observer/data" \
      FM_CONFIG_OVERRIDE="$observer/config" FM_PROJECTS_OVERRIDE="$observer/projects" \
      FM_SNAPSHOT_CROSS_HOME_TIMEOUT=20 \
      "$SNAPSHOT" --cross-home "$parent_real"
  ); rc=$?
  [ "$rc" -eq 0 ] || fail "cross-home with readable parent should exit 0, got $rc: $out"

  printf '%s' "$out" | jq -e --arg parent "$parent_real" --arg observer "$observer_real" '
    .schema == "fm-cross-home-fleet.v1"
    and .parent_home == $parent
    and .observer_home == $observer
    and .registry.present == true
    and .truncated == false
    and (.homes | map(select(.id=="observer")) | length) == 0
    and (.homes[] | select(.role=="parent") | .available) == true
    and (.homes[] | select(.id=="sibling") | .available) == true
    and (.homes[] | select(.id=="gone") | .available) == false
    and (.unavailable | map(select(.id=="gone")) | length) == 1
    and (.unavailable[] | select(.id=="gone") | .reason) != null
    and .counts.unavailable >= 1
    and ([.homes[] | select(.role=="parent") | .summary.endpoints[]?
         | select(.links.notion_page == "https://www.notion.so/parent-card")] | length) == 1
    and ([.homes[] | select(.id=="sibling") | .summary.endpoints[]?
         | select(.links.notion_page_archived == "https://www.notion.so/archived-card")] | length) == 1
    and ([.homes[] | select(.id=="sibling") | .summary.endpoints[]?
         | select(.links.notion_page == "https://www.notion.so/archived-card")] | length) == 0
  ' >/dev/null || fail "cross-home shape wrong: $out"

  pass "AC-5/AC-7: --cross-home shape, skip-self, unavailable disclosure, links"
}

test_cross_home_parent_unreadable_exits_1() {
  local observer parent out rc fakebin
  observer=$(make_readable_home observer-bad)
  parent="$TMP_ROOT/no-such-parent-$$"
  fakebin=$(make_fakebin "$TMP_ROOT/fakebin-bad")
  out=$(
    PATH="$fakebin:$PATH" \
      FM_HOME="$observer" FM_ROOT_OVERRIDE="$ROOT" \
      "$SNAPSHOT" --cross-home "$parent" 2>/dev/null
  ); rc=$?
  [ "$rc" -eq 1 ] || fail "unreadable parent should exit 1, got $rc: $out"
  printf '%s' "$out" | jq -e '
    .schema == "fm-cross-home-fleet.v1"
    and (.homes[0].available == false)
    and (.homes[0].summary == null)
    and (.unavailable | length) >= 1
  ' >/dev/null || fail "parent-unreadable object wrong: $out"
  pass "SNAP-2: parent unreadable exits 1 with disclosed object"
}

test_cross_home_writes_nothing() {
  local observer parent sibling fakebin before after marker parent_real observer_real sibling_real
  observer=$(make_readable_home observer-nfr2)
  parent=$(make_readable_home parent-nfr2)
  sibling=$(make_readable_home sibling-nfr2)
  parent_real=$(cd "$parent" && pwd -P)
  observer_real=$(cd "$observer" && pwd -P)
  sibling_real=$(cd "$sibling" && pwd -P)
  cat > "$parent/data/secondmates.md" <<EOF
- sibling - Sibling (home: $sibling_real; scope: sibling work; projects: ; added 2026-08-01)
EOF
  write_task_meta "$parent" p1
  write_task_meta "$sibling" s1
  fakebin=$(make_fakebin "$TMP_ROOT/fakebin-nfr2")

  marker="$TMP_ROOT/nfr2-marker"
  : > "$marker"
  # Snapshot every path under parent with mtime+mode before the read.
  before=$(find "$parent_real" \( -type f -o -type d -o -type l \) -print \
    | LC_ALL=C sort \
    | while IFS= read -r p; do
        if [ "$(uname)" = Darwin ]; then
          stat -f '%N %m %Lp' "$p" 2>/dev/null || true
        else
          stat -c '%n %Y %a' "$p" 2>/dev/null || true
        fi
      done)

  PATH="$fakebin:$PATH" \
    FM_HOME="$observer_real" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$observer/state" FM_DATA_OVERRIDE="$observer/data" \
    FM_CONFIG_OVERRIDE="$observer/config" FM_PROJECTS_OVERRIDE="$observer/projects" \
    FM_SNAPSHOT_CROSS_HOME_TIMEOUT=20 \
    "$SNAPSHOT" --cross-home "$parent_real" >/dev/null \
    || fail "cross-home for write-probe should succeed"

  after=$(find "$parent_real" \( -type f -o -type d -o -type l \) -print \
    | LC_ALL=C sort \
    | while IFS= read -r p; do
        if [ "$(uname)" = Darwin ]; then
          stat -f '%N %m %Lp' "$p" 2>/dev/null || true
        else
          stat -c '%n %Y %a' "$p" 2>/dev/null || true
        fi
      done)

  [ "$before" = "$after" ] || fail "AC-13: cross-home mutated parent home
BEFORE:
$before
AFTER:
$after"
  # Also ensure no files newer than the marker appeared under parent.
  if find "$parent_real" -newer "$marker" 2>/dev/null | grep -q .; then
    fail "AC-13: files newer than marker under parent: $(find "$parent_real" -newer "$marker")"
  fi
  pass "AC-13: --cross-home writes nothing into another home"
}

test_absent_registry_is_parent_only() {
  local observer parent out fakebin parent_real observer_real
  observer=$(make_readable_home observer-noreg)
  parent=$(make_readable_home parent-noreg)
  parent_real=$(cd "$parent" && pwd -P)
  observer_real=$(cd "$observer" && pwd -P)
  # No secondmates.md
  fakebin=$(make_fakebin "$TMP_ROOT/fakebin-noreg")
  out=$(
    PATH="$fakebin:$PATH" \
      FM_HOME="$observer_real" FM_ROOT_OVERRIDE="$ROOT" \
      "$SNAPSHOT" --cross-home "$parent_real"
  ) || fail "absent registry should still exit 0"
  printf '%s' "$out" | jq -e '
    .registry.present == false
    and .registry.available == true
    and (.homes | length) == 1
    and .homes[0].role == "parent"
    and .homes[0].available == true
  ' >/dev/null || fail "absent registry shape wrong: $out"
  pass "absent secondmates.md yields parent-only fleet"
}

# A registry file that exists but cannot be opened must not read as an empty
# fleet: enumerating zero secondmates from an unreadable roster would make a
# standing PM call every sibling-owned card orphaned.
test_cross_home_unreadable_registry_is_disclosed() {
  local observer parent sibling out rc fakebin parent_real observer_real sibling_real
  if [ "$(id -u)" = 0 ]; then
    pass "skip: root reads mode-000 files, unreadable-registry case not reproducible"
    return 0
  fi
  observer=$(make_readable_home observer-regperm)
  parent=$(make_readable_home parent-regperm)
  sibling=$(make_readable_home sibling-regperm)
  parent_real=$(cd "$parent" && pwd -P)
  observer_real=$(cd "$observer" && pwd -P)
  sibling_real=$(cd "$sibling" && pwd -P)
  cat > "$parent/data/secondmates.md" <<EOF
- sibling - Sibling (home: $sibling_real; scope: sibling work; projects: ; added 2026-08-01)
EOF
  chmod 000 "$parent/data/secondmates.md"
  fakebin=$(make_fakebin "$TMP_ROOT/fakebin-regperm")
  out=$(
    PATH="$fakebin:$PATH" \
      FM_HOME="$observer_real" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$observer/state" FM_DATA_OVERRIDE="$observer/data" \
      FM_CONFIG_OVERRIDE="$observer/config" FM_PROJECTS_OVERRIDE="$observer/projects" \
      FM_SNAPSHOT_CROSS_HOME_TIMEOUT=20 \
      "$SNAPSHOT" --cross-home "$parent_real" 2>/dev/null
  ); rc=$?
  chmod 644 "$parent/data/secondmates.md"
  [ "$rc" -eq 0 ] || fail "readable parent with unreadable registry should exit 0, got $rc: $out"
  printf '%s' "$out" | jq -e '
    .registry.present == true
    and .registry.available == false
    and .registry.complete == false
    and (.registry.reason | type) == "string"
    and (.homes | map(select(.id == "sibling")) | length) == 0
  ' >/dev/null || fail "unreadable registry must not report an enumerated fleet: $out"
  pass "SNAP-2: an unreadable secondmates.md is disclosed, not read as an empty fleet"
}

# The observer is not a fleet member, so its registry line must never consume a
# record-limit slot nor surface as an unavailable home.
test_cross_home_self_skip_precedes_record_limit() {
  local observer parent sibling extra out rc fakebin
  local parent_real observer_real sibling_real extra_real
  observer=$(make_readable_home observer-limit)
  parent=$(make_readable_home parent-limit)
  sibling=$(make_readable_home sibling-limit)
  extra=$(make_readable_home extra-limit)
  parent_real=$(cd "$parent" && pwd -P)
  observer_real=$(cd "$observer" && pwd -P)
  sibling_real=$(cd "$sibling" && pwd -P)
  extra_real=$(cd "$extra" && pwd -P)
  cat > "$parent/data/secondmates.md" <<EOF
- sibling - Sibling (home: $sibling_real; scope: sibling work; projects: ; added 2026-08-01)
- observer - Observer (home: $observer_real; scope: self skip; projects: ; added 2026-08-01)
- extra - Extra (home: $extra_real; scope: past the bound; projects: ; added 2026-08-01)
EOF
  fakebin=$(make_fakebin "$TMP_ROOT/fakebin-limit")
  out=$(
    PATH="$fakebin:$PATH" \
      FM_HOME="$observer_real" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$observer/state" FM_DATA_OVERRIDE="$observer/data" \
      FM_CONFIG_OVERRIDE="$observer/config" FM_PROJECTS_OVERRIDE="$observer/projects" \
      FM_SNAPSHOT_CROSS_HOME_TIMEOUT=20 FM_SNAPSHOT_SECONDMATES=1 \
      "$SNAPSHOT" --cross-home "$parent_real"
  ); rc=$?
  [ "$rc" -eq 0 ] || fail "bounded cross-home should exit 0, got $rc: $out"
  printf '%s' "$out" | jq -e '
    (.homes | map(select(.id == "observer")) | length) == 0
    and (.unavailable | map(select(.id == "observer")) | length) == 0
    and (.homes[] | select(.id == "sibling") | .available) == true
    and (.homes[] | select(.id == "extra") | .available) == false
    and (.unavailable[] | select(.id == "extra") | .reason) == "record limit"
    and .truncated == true
    and .registry.complete == false
    and (.registry.reason | type) == "string"
  ' >/dev/null || fail "self-skip/record-limit disclosure wrong: $out"
  pass "SNAP-2: the observer is skipped before the record bound and truncation marks the registry incomplete"
}

# The bounded read applies to --home-summary too, so a summary the observer
# refuses can never have already reached stdout.
test_home_summary_refuses_over_byte_limit_without_output() {
  local observer target out err rc fakebin
  observer=$(make_readable_home observer-bytes)
  target=$(make_readable_home target-bytes)
  write_task_meta "$target" t1
  fakebin=$(make_fakebin "$TMP_ROOT/fakebin-bytes")
  out=$(
    PATH="$fakebin:$PATH" \
      FM_HOME="$observer" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$observer/state" FM_DATA_OVERRIDE="$observer/data" \
      FM_CONFIG_OVERRIDE="$observer/config" FM_PROJECTS_OVERRIDE="$observer/projects" \
      FM_SNAPSHOT_SECONDMATE_MAX_BYTES=32 \
      "$SNAPSHOT" --home-summary "$target" 2>"$TMP_ROOT/bytes.err"
  ); rc=$?
  err=$(cat "$TMP_ROOT/bytes.err")
  [ "$rc" -eq 1 ] || fail "over-limit home-summary should exit 1, got $rc: $out"
  [ -z "$out" ] || fail "over-limit home-summary must print nothing on stdout: $out"
  assert_contains "$err" "byte limit" "over-limit home-summary must name the reason"
  pass "FR-2: --home-summary enforces the summary byte bound before writing stdout"
}

# A registry far larger than the fleet must bound what the snapshot emits, not
# just how many homes it reads, and must say so instead of shortening silently.
test_cross_home_registry_window_bounds_emission() {
  local observer parent out rc fakebin parent_real observer_real i
  observer=$(make_readable_home observer-window)
  parent=$(make_readable_home parent-window)
  parent_real=$(cd "$parent" && pwd -P)
  observer_real=$(cd "$observer" && pwd -P)
  : > "$parent/data/secondmates.md"
  for i in 1 2 3 4 5 6 7 8; do
    printf -- '- mate%s - Mate %s (home: %s/absent-%s; scope: bulk; projects: ; added 2026-08-01)\n' \
      "$i" "$i" "$TMP_ROOT" "$i" >> "$parent/data/secondmates.md"
  done
  fakebin=$(make_fakebin "$TMP_ROOT/fakebin-window")

  # Record window: at most parent + FM_SNAPSHOT_REGISTRY_RECORDS emitted homes.
  out=$(
    PATH="$fakebin:$PATH" \
      FM_HOME="$observer_real" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$observer/state" FM_DATA_OVERRIDE="$observer/data" \
      FM_CONFIG_OVERRIDE="$observer/config" FM_PROJECTS_OVERRIDE="$observer/projects" \
      FM_SNAPSHOT_CROSS_HOME_TIMEOUT=20 FM_SNAPSHOT_SECONDMATES=0 \
      FM_SNAPSHOT_REGISTRY_RECORDS=3 \
      "$SNAPSHOT" --cross-home "$parent_real"
  ); rc=$?
  [ "$rc" -eq 0 ] || fail "windowed cross-home should exit 0, got $rc: $out"
  printf '%s' "$out" | jq -e '
    (.homes | length) == 4
    and .truncated == true
    and .registry.complete == false
    and (.registry.reason | test("record window"))
    and .counts.requested == (.homes | length)
    and .counts.unavailable == (.unavailable | length)
    and .counts.available == ([.homes[] | select(.available)] | length)
  ' >/dev/null || fail "record window disclosure wrong: $out"

  # Input window: a roster read past the line bound is equally incomplete.
  out=$(
    PATH="$fakebin:$PATH" \
      FM_HOME="$observer_real" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$observer/state" FM_DATA_OVERRIDE="$observer/data" \
      FM_CONFIG_OVERRIDE="$observer/config" FM_PROJECTS_OVERRIDE="$observer/projects" \
      FM_SNAPSHOT_CROSS_HOME_TIMEOUT=20 FM_SNAPSHOT_SECONDMATES=0 \
      FM_SNAPSHOT_REGISTRY_LINES=2 \
      "$SNAPSHOT" --cross-home "$parent_real"
  ); rc=$?
  [ "$rc" -eq 0 ] || fail "line-windowed cross-home should exit 0, got $rc: $out"
  printf '%s' "$out" | jq -e '
    (.homes | length) == 3
    and .truncated == true
    and .registry.complete == false
    and (.registry.reason | test("read window"))
  ' >/dev/null || fail "read window disclosure wrong: $out"

  pass "SNAP-2: an oversized parent registry bounds emitted records and discloses the window"
}

test_home_summary_reads_non_secondmate_home
test_home_summary_refuses_unsafe_targets
test_home_summary_refuses_over_byte_limit_without_output
test_cross_home_registry_window_bounds_emission
test_cross_home_unreadable_registry_is_disclosed
test_cross_home_self_skip_precedes_record_limit
test_links_exposure_on_json_and_summary
test_cross_home_shape_and_disclosure
test_cross_home_parent_unreadable_exits_1
test_cross_home_writes_nothing
test_absent_registry_is_parent_only
