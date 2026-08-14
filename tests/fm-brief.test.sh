#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issues
# #166, #958, #1069). Building a variable with `VAR=$(cat <<EOF ... EOF)` is
# unsafe on Bash 3.2 (macOS /bin/bash): the lexer scans for the matching `)` of
# the command substitution textually and tracks quote state through the heredoc
# body, so a single apostrophe, unbalanced quote, or unbalanced paren anywhere
# in that body breaks parsing of the *entire rest of the script* - `bash -n`
# fails, not just the generated brief. The DOD and Herdr-section builders now
# use `IFS= read -r -d '' VAR <<EOF || true` instead, which removes the `$(...)`
# wrapper and eliminates the whole defect class regardless of future prose.
# test_no_heredoc_in_command_substitution guards that structure directly.
# Ambient `bash -n` here is Bash 5 and cannot see the bug, so the real
# cross-version enforcement lives in the macos-stock-bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse under the ambient bash. That is Bash 5 in
# CI and locally, where the issue #958/#1069 parser bug does not fire, so this
# is a weak guard on its own; test_no_heredoc_in_command_substitution and the
# macos-stock-bash CI job carry the real cross-version enforcement.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

# Structural class guard (issues #166, #958, #1069): never build a variable by
# wrapping a heredoc in a command substitution (`VAR=$(cat <<EOF ... EOF)`).
# That construct is what breaks Bash 3.2 parsing, and pinning one historical
# apostrophe phrase (as the old test did) missed the #945 reintroduction. This
# guards the *shape* directly against the whole file, so any future DOD or
# section builder that reintroduces the class fails here regardless of prose.
test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/fm-brief.sh" \
    || fail "fm-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode. fm-brief.sh no longer reads it -
# the ship mode arrives as an explicit flag - so this fixture exists to prove the
# scaffold ignores the registered posture (test_ship_mode_is_explicit_not_registry).
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id mode brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_mode in "brief-nomistakes-a1:no-mistakes" "brief-directpr-a2:direct-PR" "brief-localonly-a3:local-only"; do
    id=${id_mode%%:*}
    mode=${id_mode##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id --mode $mode should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    grep -qx "Delivery contract: mode=$mode" "$brief" \
      || fail "$id: brief did not record its machine-readable delivery contract line"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# A ship task's delivery mode is firstmate's per-task decision, so a missing or
# unusable value must stop the scaffold instead of silently defaulting. The
# no-mistakes-prod-only row is the conditional registry policy: it is never a task
# mode, and its refusal must say to classify the task's surface first.
test_ship_mode_is_required_and_closed_set() {
  local home id out status label flag expect
  home="$TMP_ROOT/mode-required-home"
  mkdir -p "$home/data"
  id=0
  while IFS='|' read -r label flag expect; do
    [ -n "$label" ] || continue
    id=$((id + 1))
    # shellcheck disable=SC2086  # flag is an intentional word-split arg list (may be empty)
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "brief-required-$id" some-proj $flag 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/data/brief-required-$id/brief.md" "$label: refused scaffold still wrote a brief"
  done <<'ROWS'
missing --mode||ship briefs require --mode
empty --mode value|--mode|requires a value
unknown mode value|--mode nope|must be one of no-mistakes, direct-PR, local-only
conditional policy is not a task mode|--mode no-mistakes-prod-only|classify this task's surface
ROWS
  pass "fm-brief.sh: ship --mode is required and closed-set validated"
}

# The registry is the captain's standing posture, not this task's answer: the
# scaffold must follow the explicit flag even when the project is registered
# with a different mode, and must not consult the registry at all.
test_ship_mode_is_explicit_not_registry() {
  local home brief
  home="$TMP_ROOT/explicit-over-registry-home"
  write_registry "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a5 direct-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "explicit no-mistakes brief on a direct-PR project should scaffold"
  brief="$home/data/brief-explicit-a5/brief.md"
  grep -qx "Delivery contract: mode=no-mistakes" "$brief" \
    || fail "registered direct-PR posture overrode the explicit --mode"
  assert_grep "Firstmate will then instruct you to run /no-mistakes" "$brief" \
    "explicit no-mistakes brief did not render the pipeline definition of done"

  # An unregistered project is not a blocker either, because nothing is looked up.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a6 never-registered --mode local-only >/dev/null 2>&1 \
    || fail "unregistered project should still scaffold from the explicit mode"
  grep -qx "Delivery contract: mode=local-only" "$home/data/brief-explicit-a6/brief.md" \
    || fail "unregistered project did not honour the explicit --mode"
  pass "fm-brief.sh: the explicit ship mode wins over the registered posture"
}

# yolo is firstmate's approval authority and never reaches the worker, and a scout
# or charter carries no delivery contract. Each must refuse rather than accept and
# discard the flag, which would look recorded but change nothing.
test_delivery_flags_are_refused_where_they_do_not_apply() {
  local home out status label args expect
  home="$TMP_ROOT/refused-flags-home"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
  done <<'ROWS'
yolo on a ship brief|brief-refused-b1 some-proj --mode direct-PR --yolo on|--yolo is not a brief input
yolo=value form on a ship brief|brief-refused-b2 some-proj --mode direct-PR --yolo=off|--yolo is not a brief input
mode on a scout brief|brief-refused-b3 some-proj --scout --mode direct-PR|--mode applies only to ship briefs
mode on a secondmate charter|brief-refused-b4 --secondmate --no-projects --mode no-mistakes|--mode applies only to ship briefs
ROWS
  pass "fm-brief.sh: --yolo and scout/secondmate --mode are refused, never silently dropped"
}

# --sync-base guards branch creation for projects served from a shared worktree
# pool, whose local base branch does not refresh between tasks. The sync step must
# come BEFORE the branch step in every ship mode, and the remaining steps must stay
# correctly numbered; a sync step buried after `git checkout -b` would arrive too
# late to change the base the task is cut from.
test_sync_base_step_precedes_branch_creation() {
  local home id mode brief sync_line branch_line
  home="$TMP_ROOT/sync-base-home"
  mkdir -p "$home/data"
  for id_mode in "brief-sync-nm:no-mistakes" "brief-sync-pr:direct-PR" "brief-sync-lo:local-only"; do
    id=${id_mode%%:*}
    mode=${id_mode##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" pooled-proj --mode "$mode" --sync-base develop >/dev/null 2>&1 \
      || fail "$id: --sync-base brief should scaffold"
    brief="$home/data/$id/brief.md"
    assert_grep 'git fetch origin && git log --oneline HEAD..origin/develop' "$brief" \
      "$id: Setup lost the base-drift check against origin/develop"
    assert_grep "git checkout -b fm/$id origin/develop" "$brief" \
      "$id: Setup never tells the worker to branch from the remote when the base is stale"
    sync_line=$(grep -n 'sync the base branch' "$brief" | head -1 | cut -d: -f1)
    branch_line=$(grep -n "git checkout -b fm/$id\`" "$brief" | head -1 | cut -d: -f1)
    [ -n "$sync_line" ] && [ -n "$branch_line" ] \
      || fail "$id: could not locate both the sync step and the branch step"
    [ "$sync_line" -lt "$branch_line" ] \
      || fail "$id: the base-sync step must precede branch creation (sync at $sync_line, branch at $branch_line)"
    grep -qx "1\. \*\*First action: sync the base branch, before creating any branch.\*\* .*" "$brief" \
      || fail "$id: the base-sync step is not the numbered first Setup action"
    grep -q "^2\. Create your branch: " "$brief" \
      || fail "$id: branch creation was not renumbered to step 2 behind the sync step"
  done
  # shellcheck disable=SC2016 # Literal generated-brief text, not a shell expansion.
  grep -q '^3\. Run `no-mistakes doctor`' "$home/data/brief-sync-nm/brief.md" \
    || fail "no-mistakes doctor step was not renumbered to step 3 behind the sync step"

  # Without the flag the Setup keeps its original two steps: ordinary
  # single-checkout projects must not inherit a pooled-worktree ritual.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-nosync-nm plain-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "plain brief should scaffold"
  brief="$home/data/brief-nosync-nm/brief.md"
  assert_no_grep "sync the base branch" "$brief" \
    "a brief without --sync-base emitted the pooled-base sync step anyway"
  # shellcheck disable=SC2016 # Literal generated-brief text, not a shell expansion.
  grep -q '^1\. First action: create your branch: `git checkout -b fm/brief-nosync-nm`$' "$brief" \
    || fail "default Setup lost its original first branch step"
  # shellcheck disable=SC2016 # Literal generated-brief text, not a shell expansion.
  grep -q '^2\. Run `no-mistakes doctor`' "$brief" \
    || fail "default no-mistakes Setup lost its original doctor step numbering"
  pass "fm-brief.sh: --sync-base puts a base-drift check ahead of branch creation"
}

# A --sync-base that is accepted and then dropped would produce a brief that looks
# guarded and is not - the exact failure the flag exists to prevent - so both an
# inapplicable scaffold kind and an empty branch name must refuse loudly.
test_sync_base_is_refused_where_it_does_not_apply() {
  local home out status label args expect
  home="$TMP_ROOT/sync-base-refused-home"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
    assert_absent "$home/data/${args%% *}/brief.md" "$label: refused scaffold still wrote a brief"
  done <<'ROWS'
sync-base on a secondmate charter|brief-syncref-c2 --secondmate --no-projects --sync-base develop|--sync-base applies only to ship and scout briefs
empty sync-base value|brief-syncref-c3 some-proj --mode local-only --sync-base=|--sync-base requires a branch name
missing sync-base value|brief-syncref-c4 some-proj --mode local-only --sync-base|--sync-base requires a value
empty sync-base value on a scout brief|brief-syncref-c5 some-proj --scout --sync-base=|--sync-base requires a branch name
missing sync-base value on a scout brief|brief-syncref-c6 some-proj --scout --sync-base|--sync-base requires a value
ROWS
  pass "fm-brief.sh: --sync-base is refused where it cannot apply, never silently dropped"
}

# A scout cuts no branch, but it reads the pooled base to reach a conclusion, so a
# stale base makes it report a fix as missing when the fix is already live on the
# remote (observed twice on 2026-08-13). The scout step must therefore land in Setup
# ahead of the investigation, and a scout without the flag must keep the original
# unguarded Setup so ordinary single-checkout projects gain no pooled-worktree ritual.
test_sync_base_guards_a_scout_investigation_base() {
  local home brief sync_line rules_line ship_brief
  home="$TMP_ROOT/sync-base-scout-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-sync-scout pooled-proj --scout --sync-base develop >/dev/null 2>&1 \
    || fail "--scout --sync-base brief should scaffold"
  brief="$home/data/brief-sync-scout/brief.md"
  assert_grep 'git fetch origin && git log --oneline HEAD..origin/develop' "$brief" \
    "scout Setup lost the base-drift check against origin/develop"
  assert_grep 'git checkout --detach origin/develop' "$brief" \
    "scout Setup never tells the worker to move onto the remote base when it is stale"
  assert_grep 'blocked: pooled base diverged from origin/develop' "$brief" \
    "scout Setup lost the diverged-base stop"
  assert_no_grep 'git checkout -b fm/brief-sync-scout' "$brief" \
    "scout Setup told a report-only task to cut a delivery branch"
  grep -qx "1\. \*\*First action: sync the base branch, before investigating anything.\*\* .*" "$brief" \
    || fail "the scout base-sync step is not the numbered first Setup action"
  sync_line=$(grep -n 'sync the base branch' "$brief" | head -1 | cut -d: -f1)
  rules_line=$(grep -n '^# Rules$' "$brief" | head -1 | cut -d: -f1)
  [ -n "$sync_line" ] && [ -n "$rules_line" ] \
    || fail "could not locate both the scout sync step and the Rules heading"
  [ "$sync_line" -lt "$rules_line" ] \
    || fail "the scout base-sync step must sit inside Setup, ahead of the investigation (sync at $sync_line, Rules at $rules_line)"

  # No flag: the scout Setup keeps its original prose, with no sync step at all.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-nosync-scout plain-proj --scout >/dev/null 2>&1 \
    || fail "plain scout brief should scaffold"
  brief="$home/data/brief-nosync-scout/brief.md"
  assert_no_grep "sync the base branch" "$brief" \
    "a scout brief without --sync-base emitted the pooled-base sync step anyway"
  assert_no_grep "git fetch origin" "$brief" \
    "a scout brief without --sync-base emitted a base fetch anyway"
  assert_grep "The report is the only thing that survives, so anything worth keeping must be in it." "$brief" \
    "plain scout Setup lost its original closing line"

  # The ship path keeps its own branch-cutting remedy: the two paths share the check,
  # not the remedy, and a scout's detached checkout must never leak into a ship brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-sync-ship pooled-proj --mode local-only --sync-base develop >/dev/null 2>&1 \
    || fail "ship --sync-base brief should scaffold"
  ship_brief="$home/data/brief-sync-ship/brief.md"
  assert_grep "git checkout -b fm/brief-sync-ship origin/develop" "$ship_brief" \
    "ship --sync-base lost its branch-from-remote remedy"
  assert_no_grep "git checkout --detach origin/develop" "$ship_brief" \
    "the scout remedy leaked into a ship brief"
  grep -qx "1\. \*\*First action: sync the base branch, before creating any branch.\*\* .*" "$ship_brief" \
    || fail "ship --sync-base lost its own branch-creation framing"
  pass "fm-brief.sh: --scout --sync-base guards the investigated base without inventing a branch"
}

# End-to-end proof against the real defect: a pooled worktree sitting on a local
# base that origin has moved past. The commands the generated brief prints are
# extracted from the brief and executed against that fixture, so this asserts the
# instruction actually catches the drift and lands the branch on current code -
# not merely that some prose about syncing exists.
test_sync_base_instruction_catches_a_stale_pooled_base() {
  local home brief fixture upstream pool drift_cmd branch_cmd out
  home="$TMP_ROOT/sync-base-fixture-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-sync-fixture pooled-proj --mode local-only --sync-base develop >/dev/null 2>&1 \
    || fail "fixture brief should scaffold"
  brief="$home/data/brief-sync-fixture/brief.md"
  # shellcheck disable=SC2016 # Backticks delimit the brief's own code spans.
  drift_cmd=$(sed -n 's/^ *Run `\([^`]*\)`.*/\1/p' "$brief" | head -1)
  # shellcheck disable=SC2016 # Backticks delimit the brief's own code spans.
  branch_cmd=$(sed -n 's/.*instead, with `\([^`]*\)`.*/\1/p' "$brief" | head -1)
  [ -n "$drift_cmd" ] || fail "could not extract the drift-check command from the generated brief"
  [ -n "$branch_cmd" ] || fail "could not extract the stale-base branch command from the generated brief"

  fixture="$TMP_ROOT/sync-base-fixture"
  upstream="$fixture/upstream"
  pool="$fixture/pool"
  mkdir -p "$upstream"
  git -C "$upstream" init -q
  git -C "$upstream" symbolic-ref HEAD refs/heads/develop
  printf 'old caption\n' > "$upstream/feature.txt"
  git -C "$upstream" add feature.txt
  git -C "$upstream" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm v1
  git clone --quiet "$upstream" "$pool"
  git -C "$pool" checkout -q --detach develop

  # A current pool must stay silent, so the check does not cry drift every task.
  out=$( cd "$pool" && eval "$drift_cmd" 2>&1 ) \
    || fail "drift check failed on a current pooled base: $out"
  [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] \
    || fail "drift check reported drift on an already-current pooled base: $out"

  # origin moves on; the pool's local develop does not, exactly as between tasks.
  printf 'new three-line demo frame\n' > "$upstream/feature.txt"
  git -C "$upstream" add feature.txt
  git -C "$upstream" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm v2
  out=$( cd "$pool" && eval "$drift_cmd" 2>&1 ) \
    || fail "drift check failed against a moved origin: $out"
  printf '%s' "$out" | grep -q v2 \
    || fail "drift check did not surface the commit the pooled base is missing: $out"

  # Following the brief's stale-base instruction must land on current code.
  ( cd "$pool" && eval "$branch_cmd" >/dev/null 2>&1 ) \
    || fail "the brief's stale-base branch command failed in the fixture"
  grep -q 'new three-line demo frame' "$pool/feature.txt" \
    || fail "branching per the brief still left the task on the stale base"

  # The scout remedy must reach current code too, or the report is drawn on the
  # stale base the flag exists to catch. Same fixture, a second pooled clone.
  local scout_brief scout_drift scout_remedy scout_pool
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-sync-scout-fixture pooled-proj --scout --sync-base develop >/dev/null 2>&1 \
    || fail "fixture scout brief should scaffold"
  scout_brief="$home/data/brief-sync-scout-fixture/brief.md"
  # shellcheck disable=SC2016 # Backticks delimit the brief's own code spans.
  scout_drift=$(sed -n 's/^ *Run `\([^`]*\)`.*/\1/p' "$scout_brief" | head -1)
  # shellcheck disable=SC2016 # Backticks delimit the brief's own code spans.
  scout_remedy=$(sed -n 's/.*instead, with `\([^`]*\)`.*/\1/p' "$scout_brief" | head -1)
  [ -n "$scout_drift" ] || fail "could not extract the drift-check command from the scout brief"
  [ -n "$scout_remedy" ] || fail "could not extract the stale-base remedy from the scout brief"
  scout_pool="$fixture/scout-pool"
  git clone --quiet "$upstream" "$scout_pool"
  # Park it on v1, exactly like a pooled worktree left behind by the previous task.
  git -C "$scout_pool" checkout -q --detach "$(git -C "$upstream" rev-parse HEAD~1)"
  grep -q 'old caption' "$scout_pool/feature.txt" \
    || fail "scout fixture pool did not start on the stale base"
  out=$( cd "$scout_pool" && eval "$scout_drift" 2>&1 ) \
    || fail "scout drift check failed against a moved origin: $out"
  printf '%s' "$out" | grep -q v2 \
    || fail "scout drift check did not surface the commit the pooled base is missing: $out"
  ( cd "$scout_pool" && eval "$scout_remedy" >/dev/null 2>&1 ) \
    || fail "the scout brief's stale-base remedy failed in the fixture"
  grep -q 'new three-line demo frame' "$scout_pool/feature.txt" \
    || fail "following the scout remedy still left the investigation on the stale base"
  pass "fm-brief.sh: the generated sync step detects a stale pooled base and reaches current code on ship and scout paths"
}

# The divergence stop must fire on a base that carries work outside the sync base's
# own published lineage, and stay silent on a base that is merely a different
# published lineage. A raw `origin/<base>..HEAD` ahead-count cannot tell those apart,
# so a default branch holding a hotfix that was never back-merged into the sync base
# - an ordinary git-flow shape - was blocked before it could start, producing no work
# at all. Excluding everything on the remote instead is too coarse the other way: a
# pooled worktree left parked on a finished task's published tip would read as
# compatible. Excluding the remote's default branch alone is the line that separates
# them. The commands are extracted from the generated brief and executed against
# fixtures, so this asserts the instruction's real behavior rather than the presence
# of prose.
test_sync_base_divergence_stop_spares_only_the_default_branch() {
  local home brief fixture upstream diverge_cmd drift_cmd branch_cmd pool out
  home="$TMP_ROOT/sync-base-diverge-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-sync-diverge pooled-proj --mode local-only --sync-base develop >/dev/null 2>&1 \
    || fail "divergence fixture brief should scaffold"
  brief="$home/data/brief-sync-diverge/brief.md"
  # shellcheck disable=SC2016 # Backticks delimit the brief's own code spans.
  drift_cmd=$(sed -n 's/^ *Run `\([^`]*\)`.*/\1/p' "$brief" | head -1)
  # shellcheck disable=SC2016 # Backticks delimit the brief's own code spans.
  diverge_cmd=$(sed -n 's/.*rule out a genuinely divergent base with `\([^`]*\)`.*/\1/p' "$brief" | head -1)
  # shellcheck disable=SC2016 # Backticks delimit the brief's own code spans.
  branch_cmd=$(sed -n 's/.*instead, with `\([^`]*\)`.*/\1/p' "$brief" | head -1)
  [ -n "$drift_cmd" ] || fail "could not extract the drift-check command from the generated brief"
  [ -n "$diverge_cmd" ] || fail "could not extract the divergence-check command from the generated brief"
  [ -n "$branch_cmd" ] || fail "could not extract the stale-base branch command from the generated brief"

  fixture="$TMP_ROOT/sync-base-diverge-fixture"
  upstream="$fixture/upstream"
  mkdir -p "$upstream"
  git -C "$upstream" init -q
  git -C "$upstream" symbolic-ref HEAD refs/heads/develop
  printf 'shared\n' > "$upstream/feature.txt"
  git -C "$upstream" add feature.txt
  git -C "$upstream" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm shared-base
  # `main` forks here and takes a hotfix that is never back-merged into develop.
  git -C "$upstream" branch main
  printf 'develop moved on\n' > "$upstream/feature.txt"
  git -C "$upstream" add feature.txt
  git -C "$upstream" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm dev2
  # A finished task's branch, published on the remote and never merged anywhere.
  git -C "$upstream" checkout -q -b fm/prev-task
  printf 'the previous task\n' > "$upstream/prev.txt"
  git -C "$upstream" add prev.txt
  git -C "$upstream" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm prev-task-work
  git -C "$upstream" checkout -q main
  printf 'hotfix\n' > "$upstream/hotfix.txt"
  git -C "$upstream" add hotfix.txt
  git -C "$upstream" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm hotfix-on-main
  # The pooled repo's default branch is `main`, so clones resolve origin/HEAD to it.

  # Genuinely behind: a pure ancestor of the remote base must not read as diverged.
  pool="$fixture/behind"
  git clone --quiet "$upstream" "$pool"
  git -C "$pool" checkout -q --detach refs/remotes/origin/develop~1
  out=$( cd "$pool" && eval "$drift_cmd" 2>&1 ) || fail "drift check failed on the behind pool: $out"
  printf '%s' "$out" | grep -q dev2 || fail "the behind pool did not read as stale: $out"
  out=$( cd "$pool" && eval "$diverge_cmd" 2>&1 ) || fail "divergence check failed on the behind pool: $out"
  [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] \
    || fail "the divergence stop fired on a base that is merely behind: $out"

  # A current pool is silent too, so the stop never fires on the common case.
  git -C "$pool" checkout -q --detach refs/remotes/origin/develop
  out=$( cd "$pool" && eval "$diverge_cmd" 2>&1 ) || fail "divergence check failed on the current pool: $out"
  [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] \
    || fail "the divergence stop fired on an already-current base: $out"

  # The regression: a default branch holding a published commit the sync base never
  # took. The old raw ahead-count sees it and blocks; excluding the remote's default
  # branch must not, and the stale remedy must still carry the task onto current
  # sync-base code.
  pool="$fixture/lineage"
  git clone --quiet "$upstream" "$pool"
  git -C "$pool" checkout -q --detach refs/remotes/origin/main
  out=$( cd "$pool" && git log --oneline origin/develop..HEAD 2>&1 )
  printf '%s' "$out" | grep -q hotfix-on-main \
    || fail "the lineage fixture does not reproduce the raw ahead-count false positive: $out"
  out=$( cd "$pool" && eval "$diverge_cmd" 2>&1 ) || fail "divergence check failed on the lineage pool: $out"
  [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] \
    || fail "the divergence stop still blocks a default branch whose extra commit is on the remote's default branch: $out"
  out=$( cd "$pool" && eval "$drift_cmd" 2>&1 ) || fail "drift check failed on the lineage pool: $out"
  printf '%s' "$out" | grep -q dev2 \
    || fail "the lineage pool did not read as stale, so it would never take the remedy: $out"
  ( cd "$pool" && eval "$branch_cmd" >/dev/null 2>&1 ) \
    || fail "the brief's stale-base branch command failed on the lineage pool"
  grep -q 'develop moved on' "$pool/feature.txt" \
    || fail "the lineage pool followed the remedy and still did not reach current sync-base code"

  # A pooled worktree left parked on a finished task's tip. Teardown detaches the
  # pool there and drops only the local branch name, so the leftover commits survive
  # on origin/fm/<id> while origin/develop has not moved: the drift check is silent,
  # and only the divergence stop keeps the next task off the previous one's work.
  pool="$fixture/prev-task-tip"
  git clone --quiet "$upstream" "$pool"
  git -C "$pool" checkout -q --detach refs/remotes/origin/fm/prev-task
  out=$( cd "$pool" && eval "$drift_cmd" 2>&1 ) || fail "drift check failed on the previous-task pool: $out"
  [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] \
    || fail "the previous-task fixture is stale as well, so the divergence stop is not what is under test: $out"
  out=$( cd "$pool" && eval "$diverge_cmd" 2>&1 ) || fail "divergence check failed on the previous-task pool: $out"
  printf '%s' "$out" | grep -q prev-task-work \
    || fail "the divergence stop missed a base parked on a previous task's published tip: $out"

  # Genuinely diverged: unpushed work on the pooled base must still stop.
  pool="$fixture/diverged"
  git clone --quiet "$upstream" "$pool"
  git -C "$pool" checkout -q --detach refs/remotes/origin/develop~1
  printf 'left behind by the previous task\n' > "$pool/scratch.txt"
  git -C "$pool" add scratch.txt
  git -C "$pool" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm local-scratch
  out=$( cd "$pool" && eval "$diverge_cmd" 2>&1 ) || fail "divergence check failed on the diverged pool: $out"
  printf '%s' "$out" | grep -q local-scratch \
    || fail "the divergence stop no longer catches unpublished work on the pooled base: $out"

  # A pool re-initialised onto a history the remote shares nothing with. The check
  # needs no special clause for it: every commit HEAD holds is one origin/develop
  # does not, so the range prints them all and the base blocks on its own.
  pool="$fixture/unrelated"
  git clone --quiet "$upstream" "$pool"
  git -C "$pool" checkout -q --orphan unrelated-history
  git -C "$pool" rm -rq --cached .
  rm -f "$pool/feature.txt" "$pool/hotfix.txt" "$pool/prev.txt"
  printf 'a history of its own\n' > "$pool/reinit.txt"
  git -C "$pool" add reinit.txt
  git -C "$pool" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm unrelated-root
  git -C "$pool" checkout -q --detach HEAD
  out=$( cd "$pool" && eval "$diverge_cmd" 2>&1 ) || fail "divergence check failed on the unrelated-history pool: $out"
  printf '%s' "$out" | grep -q unrelated-root \
    || fail "a base sharing no history with the remote read as compatible instead of blocking: $out"

  # And the brief still carries the stop the checks feed.
  assert_grep 'blocked: pooled base diverged from origin/develop' "$brief" \
    "the generated Setup lost the diverged-base stop"
  pass "fm-brief.sh: the divergence stop spares the remote's default branch and blocks everything else off the sync base"
}

# The divergence check names the remote's default branch, and a pool can easily have
# no usable refs/remotes/origin/HEAD: `git init` + `git remote add` + fetch never
# writes one, and an upstream default-branch rename leaves the existing symref
# dangling because nothing runs `git remote set-head origin -a` afterwards. Naming
# that ref outright made the check exit non-zero in both states, so every task on such
# a pool blocked before starting - the same produced-no-work outcome --sync-base's
# divergence fix set out to remove. The emitted command resolves the default branch
# with the fallback the rest of the repo uses, and verifies the name origin/HEAD gives
# before using it, since a dangling symref reports success and a stale name.
test_sync_base_divergence_check_survives_a_missing_origin_head() {
  local home brief fixture upstream diverge_cmd pool out
  home="$TMP_ROOT/sync-base-no-origin-head-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-sync-no-head pooled-proj --mode local-only --sync-base develop >/dev/null 2>&1 \
    || fail "missing-origin-HEAD fixture brief should scaffold"
  brief="$home/data/brief-sync-no-head/brief.md"
  # shellcheck disable=SC2016 # Backticks delimit the brief's own code spans.
  diverge_cmd=$(sed -n 's/.*rule out a genuinely divergent base with `\([^`]*\)`.*/\1/p' "$brief" | head -1)
  [ -n "$diverge_cmd" ] || fail "could not extract the divergence-check command from the generated brief"

  fixture="$TMP_ROOT/sync-base-no-origin-head-fixture"
  upstream="$fixture/upstream"
  mkdir -p "$upstream"
  git -C "$upstream" init -q
  git -C "$upstream" symbolic-ref HEAD refs/heads/develop
  printf 'shared\n' > "$upstream/feature.txt"
  git -C "$upstream" add feature.txt
  git -C "$upstream" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm shared-base
  git -C "$upstream" branch main
  printf 'develop moved on\n' > "$upstream/feature.txt"
  git -C "$upstream" add feature.txt
  git -C "$upstream" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm dev2
  git -C "$upstream" checkout -q main
  printf 'hotfix\n' > "$upstream/hotfix.txt"
  git -C "$upstream" add hotfix.txt
  git -C "$upstream" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm hotfix-on-main

  # A pool with no origin/HEAD, parked on the lineage variant that must not block.
  pool="$fixture/no-origin-head"
  git clone --quiet "$upstream" "$pool"
  git -C "$pool" remote set-head origin --delete
  [ -z "$(git -C "$pool" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" ] \
    || fail "the fixture still has an origin/HEAD, so it does not exercise the missing-ref path"
  out=$( cd "$pool" && eval "$diverge_cmd" 2>&1 ) \
    || fail "the divergence check errored on a pool with no origin/HEAD, blocking a task that should proceed: $out"
  [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] \
    || fail "the divergence stop fired on a published lineage variant once origin/HEAD was missing: $out"

  # The fallback must not swallow a real divergence: unpushed work still blocks.
  printf 'never pushed\n' > "$pool/scratch.txt"
  git -C "$pool" add scratch.txt
  git -C "$pool" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm local-scratch
  out=$( cd "$pool" && eval "$diverge_cmd" 2>&1 ) \
    || fail "the divergence check errored on the diverged no-origin/HEAD pool: $out"
  printf '%s' "$out" | grep -q local-scratch \
    || fail "the default-branch fallback swallowed genuine divergence: $out"

  # A dangling origin/HEAD, the state an upstream master-to-main rename leaves behind.
  # symbolic-ref reports success and the stale name here, so a fallback that only
  # checks its exit status never fires and the check dies on an unknown revision.
  local rename_upstream
  rename_upstream="$fixture/renamed-default"
  mkdir -p "$rename_upstream"
  git -C "$rename_upstream" init -q
  git -C "$rename_upstream" symbolic-ref HEAD refs/heads/master
  printf 'shared\n' > "$rename_upstream/feature.txt"
  git -C "$rename_upstream" add feature.txt
  git -C "$rename_upstream" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm shared-base
  git -C "$rename_upstream" branch develop
  printf 'released\n' > "$rename_upstream/release.txt"
  git -C "$rename_upstream" add release.txt
  git -C "$rename_upstream" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm release-on-default
  pool="$fixture/dangling-origin-head"
  git clone --quiet "$rename_upstream" "$pool"
  git -C "$rename_upstream" branch -m master main
  git -C "$pool" fetch -q --prune origin
  [ "$(git -C "$pool" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" = origin/master ] \
    || fail "the fixture's origin/HEAD is not dangling, so it does not exercise the stale-symref path"
  git -C "$pool" checkout -q --detach refs/remotes/origin/main
  out=$( cd "$pool" && eval "$diverge_cmd" 2>&1 ) \
    || fail "the divergence check errored on a pool whose origin/HEAD dangles, blocking a task that should proceed: $out"
  [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] \
    || fail "the divergence stop fired on a published lineage variant once origin/HEAD dangled: $out"

  # A remote with no main or master either: the exclusion set collapses to the sync
  # base alone, and the command must still run rather than error on an empty ref.
  local bare_upstream
  bare_upstream="$fixture/develop-only"
  mkdir -p "$bare_upstream"
  git -C "$bare_upstream" init -q
  git -C "$bare_upstream" symbolic-ref HEAD refs/heads/develop
  printf 'only develop here\n' > "$bare_upstream/feature.txt"
  git -C "$bare_upstream" add feature.txt
  git -C "$bare_upstream" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm develop-only
  pool="$fixture/develop-only-pool"
  git clone --quiet "$bare_upstream" "$pool"
  git -C "$pool" remote set-head origin --delete
  git -C "$pool" checkout -q --detach refs/remotes/origin/develop
  out=$( cd "$pool" && eval "$diverge_cmd" 2>&1 ) \
    || fail "the divergence check errored when no default branch could be resolved at all: $out"
  [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] \
    || fail "the divergence stop fired on a base that is exactly the sync base: $out"
  pass "fm-brief.sh: the divergence check resolves the default branch with a verified fallback instead of blocking on a missing or dangling origin/HEAD"
}

# A pooled default branch can strictly contain the sync base - main right after a
# release merge, say - which leaves the drift check silent and the divergence check
# silent too, since the extra commits are on the remote's default branch. Read on the
# drift check alone that base looks current, and a branch cut from it carries the
# extra commits into a PR aimed at the sync base. The step must route it to the same
# remedy a stale base takes instead.
test_sync_base_step_routes_a_default_branch_that_contains_the_base() {
  local home brief fixture upstream variant_cmd diverge_cmd drift_cmd branch_cmd pool out
  local branch_step branch_condition plain_branch_cmd
  home="$TMP_ROOT/sync-base-superset-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-sync-superset pooled-proj --mode local-only --sync-base develop >/dev/null 2>&1 \
    || fail "superset fixture brief should scaffold"
  brief="$home/data/brief-sync-superset/brief.md"
  # shellcheck disable=SC2016 # Backticks delimit the brief's own code spans.
  drift_cmd=$(sed -n 's/^ *Run `\([^`]*\)`.*/\1/p' "$brief" | head -1)
  # shellcheck disable=SC2016 # Backticks delimit the brief's own code spans.
  variant_cmd=$(sed -n 's/.*not a lineage variant with `\([^`]*\)`.*/\1/p' "$brief" | head -1)
  # shellcheck disable=SC2016 # Backticks delimit the brief's own code spans.
  diverge_cmd=$(sed -n 's/.*rule out a genuinely divergent base with `\([^`]*\)`.*/\1/p' "$brief" | head -1)
  # shellcheck disable=SC2016 # Backticks delimit the brief's own code spans.
  branch_cmd=$(sed -n 's/.*instead, with `\([^`]*\)`.*/\1/p' "$brief" | head -1)
  [ -n "$drift_cmd" ] || fail "could not extract the drift-check command from the generated brief"
  [ -n "$variant_cmd" ] || fail "could not extract the lineage-variant command from the generated brief"
  [ -n "$diverge_cmd" ] || fail "could not extract the divergence-check command from the generated brief"
  [ -n "$branch_cmd" ] || fail "could not extract the stale-base branch command from the generated brief"

  fixture="$TMP_ROOT/sync-base-superset-fixture"
  upstream="$fixture/upstream"
  mkdir -p "$upstream"
  git -C "$upstream" init -q
  git -C "$upstream" symbolic-ref HEAD refs/heads/develop
  printf 'shared\n' > "$upstream/feature.txt"
  git -C "$upstream" add feature.txt
  git -C "$upstream" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm shared-base
  # `main` carries everything develop has plus a release commit of its own.
  git -C "$upstream" checkout -q -b main
  printf 'release only\n' > "$upstream/release.txt"
  git -C "$upstream" add release.txt
  git -C "$upstream" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm release-on-main

  pool="$fixture/superset"
  git clone --quiet "$upstream" "$pool"
  git -C "$pool" checkout -q --detach refs/remotes/origin/main
  out=$( cd "$pool" && eval "$drift_cmd" 2>&1 ) || fail "drift check failed on the superset pool: $out"
  [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] \
    || fail "the superset fixture is stale, so the drift check alone would already route it: $out"
  out=$( cd "$pool" && eval "$diverge_cmd" 2>&1 ) || fail "divergence check failed on the superset pool: $out"
  [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] \
    || fail "the divergence stop blocked a default branch that merely contains the sync base: $out"
  out=$( cd "$pool" && eval "$variant_cmd" 2>&1 ) || fail "lineage-variant check failed on the superset pool: $out"
  printf '%s' "$out" | grep -q release-on-main \
    || fail "the step reads a base that strictly contains the sync base as current, so the task branches off the variant: $out"
  # The branch step decides which command the worker actually runs, and on this path
  # step 1 routes to the remote base with no drift to show for it. Conditioning that
  # alternative on the drift check sends the worker to the plain branch cut instead,
  # so read the condition the generated Setup - this script's output contract - puts
  # on the remote-base command and reject one the drift check alone can satisfy.
  branch_step=$(grep -F "or \`git checkout -b fm/brief-sync-superset origin/develop\`" "$brief" | head -1)
  [ -n "$branch_step" ] || fail "could not find the branch step's remote-base alternative in the generated brief"
  branch_condition=${branch_step#*origin/develop\`}
  case $branch_condition in
    *"sent you to the remote base"*) : ;;
    *) fail "the branch step's remote-base alternative is not conditioned on step 1's routing, so a lineage variant with no drift takes the plain branch cut: $branch_condition" ;;
  esac

  # That condition has to be load-bearing: the plain branch command really does keep
  # the variant's extra commit, which is what makes taking the wrong fork a defect.
  # shellcheck disable=SC2016 # Backticks delimit the brief's own code spans.
  plain_branch_cmd=$(sed -n 's/.*Create your branch: `\([^`]*\)`.*/\1/p' "$brief" | head -1)
  [ -n "$plain_branch_cmd" ] || fail "could not extract the plain branch command from the generated brief"
  ( cd "$pool" && eval "$plain_branch_cmd" >/dev/null 2>&1 ) \
    || fail "the brief's plain branch command failed on the superset pool"
  [ -e "$pool/release.txt" ] \
    || fail "the plain branch command does not carry the variant's extra commit, so this fixture cannot show the wrong fork is wrong"
  git -C "$pool" checkout -q --detach refs/remotes/origin/main
  git -C "$pool" branch -D fm/brief-sync-superset >/dev/null 2>&1 \
    || fail "could not reset the superset pool between the two branch commands"

  # Following the remedy the variant is routed to must land on the sync base itself.
  ( cd "$pool" && eval "$branch_cmd" >/dev/null 2>&1 ) \
    || fail "the brief's remedy command failed on the superset pool"
  [ ! -e "$pool/release.txt" ] \
    || fail "the remedy left the task on the variant, still carrying its extra commit"

  # A base that really is current must stay current: the extra check is silent there.
  pool="$fixture/current"
  git clone --quiet "$upstream" "$pool"
  git -C "$pool" checkout -q --detach refs/remotes/origin/develop
  out=$( cd "$pool" && eval "$variant_cmd" 2>&1 ) || fail "lineage-variant check failed on the current pool: $out"
  [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] \
    || fail "the lineage-variant check fired on a base that is exactly the sync base: $out"
  pass "fm-brief.sh: a pooled base that already contains the sync base takes the remedy instead of reading as current"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "local-only brief must not include the no-mistakes --intent contract"
  id="brief-direct-intent-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "direct-PR brief must not include the no-mistakes --intent contract"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_grep "make \`--intent\` preserve all relevant content from this brief" "$brief" \
    "no-mistakes DOD must require --intent to retain the accepted task contract"
  assert_grep "carrying only each requirement's current accepted form" "$brief" \
    "no-mistakes DOD must replace superseded requirements with their current accepted form"
  assert_grep "retain direct requirements instead of substituting a diff summary" "$brief" \
    "no-mistakes DOD must keep direct requirements and exclude generic scaffold boilerplate from --intent"
  assert_grep "exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific" "$brief" \
    "no-mistakes DOD must exclude non-task-specific scaffold boilerplate from --intent"
  # The apostrophe in "firstmate's authority check" is now structurally safe
  # (no `$(...)` wrapper around the heredoc), so it renders verbatim instead of
  # being reworded or escaped away. test_no_heredoc_in_command_substitution
  # guards the structure that makes it safe.
  assert_grep "firstmate's authority check" "$brief" \
    "no-mistakes DOD lost the apostrophe prose that the structural fix makes parse-safe"
  pass "fm-brief.sh: no-mistakes DOD keeps its apostrophe prose, now parse-safe"
}

# The recurring failure this guards: a no-mistakes worker commits locally,
# re-runs its own lint and tests, and reports `done:` naming only a commit,
# having never invoked the pipeline, pushed, or opened a PR. The brief used to
# invite exactly that, asserting completion at the commit in the same breath as
# it introduced the word `done:`. So the definition of done must now open by
# stating what `done:` requires, must define the CI-cannot-run exception in the
# same section that cites it, and must name its two report points as two
# distinct things. Everything here reads generated brief text, never the
# script's source bytes.
test_no_mistakes_dod_states_what_done_requires() {
  local home id brief dod other statement exception
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks and braces must stay literal
  statement='**`done:` on a no-mistakes ship task means a real PR exists with checks green (or the CI-cannot-run exception below) - a local commit plus local lint/test checks is NOT done, even if every local check passes.**'
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks and braces must stay literal
  exception='CI-cannot-run exception: when the forge reports that no CI checks are configured for this PR, say so explicitly and name the local gate you re-ran green against the pushed head, as `done: PR {url} - no CI checks configured; {gate} re-run green on the pushed head`. Never report absent checks as green checks.'
  home="$TMP_ROOT/done-clarity-home"
  mkdir -p "$home/data"
  id="brief-done-clarity-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "no-mistakes brief was not scaffolded"

  # AC-1/AC-2: present verbatim, and exactly once.
  assert_grep "$statement" "$brief" \
    "no-mistakes DOD must state that done: requires a real PR, not a local commit"
  [ "$(grep -F -c -- "$statement" "$brief")" = "1" ] \
    || fail "the done: requirement statement must appear exactly once in the brief"

  # AC-3/AC-6/AC-8: the definition of done opens with the spawn-side contract
  # line, then the statement, then the exception that the statement cites, and
  # the statement is the first done: mention inside the section. The earlier
  # mention in the shared Rules block points at this section rather than making
  # a competing completion claim, so the section is the meaningful boundary.
  dod="$TMP_ROOT/done-clarity-dod.txt"
  awk '/^# Definition of done$/,0' "$brief" > "$dod"
  [ "$(sed -n '2p' "$dod")" = "Delivery contract: mode=no-mistakes" ] \
    || fail "the delivery contract line must stay the first line after the definition of done header"
  [ "$(sed -n '3p' "$dod")" = "$statement" ] \
    || fail "the done: requirement statement must sit immediately after the delivery contract line"
  [ "$(sed -n '4p' "$dod")" = "$exception" ] \
    || fail "the CI-cannot-run exception must be defined on the line that follows the statement citing it"
  [ "$(grep -n -- 'done:' "$dod" | head -1 | cut -d: -f1)" = "3" ] \
    || fail "the done: requirement statement must be the first done: mention in the definition of done"

  # AC-9: two report points, named as two, with the handoff verb unchanged.
  assert_grep "You report twice on this task, and only the second report is completion." "$brief" \
    "the definition of done must name its two report points as two distinct things"
  assert_grep "The first is a HANDOFF, not a finish" "$brief" \
    "the first report must be labelled a handoff rather than a finish"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`done: implemented and committed; ready for /no-mistakes`' "$brief" \
    "the handoff must keep the done: verb that triggers validation"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`done: PR {url} checks green`' "$brief" \
    "the terminal report format must remain the only stated terminal signal"

  # AC-4: the contradicting completion sentence is gone from this mode, and
  # still present in direct-PR, where it is correct - that mode genuinely does
  # complete at the commit, before its own push-and-PR step. A global
  # replacement would have stripped both copies.
  assert_no_grep "The task is complete only when committed on your branch." "$brief" \
    "no-mistakes DOD must not still claim the task completes at the commit"

  # AC-5: the statement stays out of every other scaffold.
  id="brief-done-clarity-c2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode direct-PR >/dev/null 2>&1
  other="$home/data/$id/brief.md"
  assert_grep "The task is complete only when committed on your branch." "$other" \
    "direct-PR lost its own correct completion sentence to a global replacement"
  assert_no_grep "$statement" "$other" \
    "the no-mistakes done: statement leaked into the direct-PR brief"
  id="brief-done-clarity-c3"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode local-only >/dev/null 2>&1
  assert_no_grep "$statement" "$home/data/$id/brief.md" \
    "the no-mistakes done: statement leaked into the local-only brief"
  id="brief-done-clarity-c4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1
  assert_no_grep "$statement" "$home/data/$id/brief.md" \
    "the no-mistakes done: statement leaked into the scout brief"
  id="brief-done-clarity-c5"
  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" --secondmate alpha >/dev/null 2>&1
  assert_no_grep "$statement" "$home/data/$id/brief.md" \
    "the no-mistakes done: statement leaked into the secondmate charter"
  pass "fm-brief.sh: no-mistakes DOD states what done: requires and owns its exception"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

# Two universal contract additions that must survive in EVERY ship mode, because
# both defend against failures that a green gate does not catch: shipping a
# rendered-but-inert element, and mistaking inherited breakage for your own.
# They live in the shared heredoc precisely so no mode can drift out of them,
# so assert across all three rather than on one sample.
test_ship_baseline_and_no_placeholder_contract() {
  local home id mode brief
  home="$TMP_ROOT/baseline-placeholder-home"
  write_registry "$home"

  for id_mode in "brief-base-d1:no-mistakes" "brief-base-d2:direct-PR" "brief-base-d3:local-only"; do
    id=${id_mode%%:*}
    mode=${id_mode##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "Establish a test baseline before your first edit." "$brief" \
      "$id ($mode): brief lost the baseline-before-editing contract"
    assert_grep "treat that as inherited breakage" "$brief" \
      "$id ($mode): baseline contract lost the inherited-breakage stop condition"
    assert_grep "Leave behind no placeholder or unimplemented code" "$brief" \
      "$id ($mode): brief lost the no-placeholder rule"
    assert_grep "an element a user can click and get nothing from is not done" "$brief" \
      "$id ($mode): no-placeholder rule lost its works-not-compiles bar"
  done
  pass "fm-brief.sh: every ship mode carries the baseline and no-placeholder contracts"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, or work ready for review' "$brief" \
    "secondmate charter lost decisions, blockers, failures, or ready outcomes"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_secondmate_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_HOME changed charter bytes compared with the same absolute home"
  assert_grep ">> '$home/state/relative-home.status'" "$brief" \
    "relative FM_HOME did not render an absolute secondmate status path"

  brief="$home/data/relative-state/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_STATE_OVERRIDE=state-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep ">> '$state_override/relative-state.status'" "$brief" \
    "relative FM_STATE_OVERRIDE did not render an absolute secondmate status path"

  brief="$data_override/relative-data/brief.md"
  FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_DATA_OVERRIDE=data-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep ">> '$home/state/relative-data.status'" "$brief" \
    "relative FM_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    FM_HOME=missing-home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-home --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_HOME must fail"
  assert_grep "FM_HOME directory cannot be resolved: missing-home" "$err" \
    "unresolved relative FM_HOME did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_STATE_OVERRIDE=missing-state FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-state --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_STATE_OVERRIDE must fail"
  assert_grep "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative FM_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_DATA_OVERRIDE=missing-data FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-data --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_DATA_OVERRIDE must fail"
  assert_grep "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative FM_DATA_OVERRIDE did not fail loudly"

  pass "fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# A verification that writes into a real outward-facing surface leaves noise in a
# surface the captain reads unless the test itself removes it, so both worker
# scaffolds must carry the full delete-after-test discipline: evidence first,
# delete, re-probe, cleanup in the test's own teardown including the failure path,
# and a non-writing probe preferred. Asserted through generated briefs.
test_outward_write_cleanup_rule_reaches_both_scaffolds() {
  local home brief label
  home="$TMP_ROOT/outward-cleanup-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-cleanup-s1 some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "ship scaffold for the outward-write cleanup rule exited non-zero"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-cleanup-s2 some-proj --scout >/dev/null 2>&1 \
    || fail "scout scaffold for the outward-write cleanup rule exited non-zero"
  for label in brief-cleanup-s1 brief-cleanup-s2; do
    brief="$home/data/$label/brief.md"
    assert_grep "writes into a real outward-facing surface must delete what it wrote" "$brief" \
      "$label: brief lost the delete-after-test rule"
    assert_grep "then delete, then re-probe to confirm it is gone" "$brief" \
      "$label: brief lost the capture-delete-reprobe order"
    assert_grep "A consumed id is fine" "$brief" \
      "$label: brief lost the consumed-id-is-fine point"
    assert_grep "own teardown, including the" "$brief" \
      "$label: brief lost the teardown-including-failure-path point"
    assert_grep "Prefer a non-writing probe when the surface offers one." "$brief" \
      "$label: brief lost the non-writing-probe preference"
    assert_no_grep "only Telegram" "$brief" \
      "$label: brief scoped the cleanup rule to one specific channel"
  done
  pass "fm-brief.sh: ship and scout scaffolds carry the outward-write cleanup rule"
}

# A no-mistakes worker's most common legitimate idle is its own pipeline gate or a
# CI run, and leaving `working:` as the last event during that wait produced false
# wedge escalations. Both scaffolds must name those two waits as pause examples.
test_pause_examples_name_pipeline_and_ci_waits() {
  local home brief label
  home="$TMP_ROOT/pause-examples-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-pause-s1 some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "ship scaffold for the pause examples exited non-zero"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-pause-s2 some-proj --scout >/dev/null 2>&1 \
    || fail "scout scaffold for the pause examples exited non-zero"
  for label in brief-pause-s1 brief-pause-s2; do
    brief="$home/data/$label/brief.md"
    assert_grep "waiting for a pipeline gate to return" "$brief" \
      "$label: pause examples omitted the pipeline-gate return"
    assert_grep "run to finish" "$brief" \
      "$label: pause examples omitted a CI run"
    assert_grep "an upstream release, a rate-limit reset" "$brief" \
      "$label: pause examples lost their original external waits"
  done
  pass "fm-brief.sh: pause examples name the pipeline-gate and CI waits in both scaffolds"
}

# Hard rule 4 lives only in firstmate's own AGENTS.md, which no worker reads, so
# workers addressed the captain directly. Both worker scaffolds must state the
# single-channel rule themselves.
test_workers_report_to_firstmate_only() {
  local home brief label
  home="$TMP_ROOT/single-channel-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-channel-s1 some-proj --mode direct-PR >/dev/null 2>&1 \
    || fail "ship scaffold for the single-channel rule exited non-zero"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-channel-s2 some-proj --scout >/dev/null 2>&1 \
    || fail "scout scaffold for the single-channel rule exited non-zero"
  for label in brief-channel-s1 brief-channel-s2; do
    brief="$home/data/$label/brief.md"
    assert_grep "Report status and findings to firstmate only." "$brief" \
      "$label: brief lost the report-to-firstmate-only rule"
    assert_grep "firstmate is the sole channel to the captain" "$brief" \
      "$label: brief did not state that firstmate is the only channel to the captain"
  done
  pass "fm-brief.sh: both worker scaffolds route all reporting through firstmate only"
}

# A project whose registered posture grants standing staging-inclusive landing
# autonomy needs that contract GENERATED: the plain local-only "stop and wait"
# boilerplate otherwise contradicts the task section granting the autonomy.
test_staging_autonomy_generates_the_landing_contract() {
  local home brief plain
  home="$TMP_ROOT/staging-autonomy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-staging-s1 some-proj --mode local-only --staging-autonomy >/dev/null 2>&1 \
    || fail "local-only --staging-autonomy scaffold exited non-zero"
  brief="$home/data/brief-staging-s1/brief.md"

  # bin/fm-spawn.sh matches the delivery contract line exactly, so autonomy must
  # ride alongside local-only rather than inventing a fourth mode value.
  grep -qx "Delivery contract: mode=local-only" "$brief" \
    || fail "staging-autonomy brief lost the machine-readable local-only contract line"
  grep -qx "Delivery autonomy: staging-inclusive" "$brief" \
    || fail "staging-autonomy brief did not record its autonomy line"

  assert_grep "git fetch origin && git checkout -b fm/brief-staging-s1 origin/develop" "$brief" \
    "staging-autonomy brief did not branch explicitly from origin/develop"
  assert_grep "merge \`fm/brief-staging-s1\` -> \`develop\` -> \`staging\`, push both branches" "$brief" \
    "staging-autonomy brief did not state the git-flow landing sequence"
  assert_grep "watch CI to a final result" "$brief" \
    "staging-autonomy brief did not require watching CI to a final result"
  assert_grep "fast-forward this worktree's own local \`develop\`" "$brief" \
    "staging-autonomy brief did not close the stale-base loop after landing"
  assert_grep "done [key=staging]: staging=<sha> ci=<run-id> result=green" "$brief" \
    "staging-autonomy brief did not require the keyed staging close line"
  assert_grep "blocked [key=evaluation]: test gate green, UI touched, awaiting browser evaluation before merge" "$brief" \
    "staging-autonomy brief did not stop UI work at the browser evaluation gate"
  assert_grep "never land red or failing work" "$brief" \
    "staging-autonomy brief dropped the never-land-red limit"
  assert_grep "Tagging or releasing \`main\` is never yours" "$brief" \
    "staging-autonomy brief did not keep release out of the standing authority"

  # The contradicted boilerplate must be gone, not merely followed by a correction.
  assert_no_grep "Do NOT push, do NOT open a PR, do NOT merge." "$brief" \
    "staging-autonomy brief still carries the stop-and-wait local-only boilerplate"
  assert_no_grep "Never push to any remote and never open a PR." "$brief" \
    "staging-autonomy brief still forbids the pushes its own landing sequence requires"
  assert_no_grep "done: ready in branch" "$brief" \
    "staging-autonomy brief still closes on a ready branch instead of the staging line"

  # Plain local-only is unchanged and stays the conservative default.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-staging-s2 some-proj --mode local-only >/dev/null 2>&1 \
    || fail "plain local-only scaffold exited non-zero"
  plain="$home/data/brief-staging-s2/brief.md"
  assert_grep "Do NOT push, do NOT open a PR, do NOT merge." "$plain" \
    "plain local-only brief lost its stop-and-wait contract"
  assert_no_grep "Delivery autonomy: staging-inclusive" "$plain" \
    "plain local-only brief claimed staging autonomy nobody asked for"
  assert_no_grep "origin/develop" "$plain" \
    "plain local-only brief adopted the git-flow branch base"
  pass "fm-brief.sh: --staging-autonomy generates the captain's staging landing contract"
}

# Autonomy that does not apply must be refused, never accepted and discarded:
# a silently dropped flag reads as recorded and reproduces the exact
# contradiction this mechanism exists to remove.
test_staging_autonomy_is_refused_where_it_does_not_apply() {
  local home out status label args expect
  home="$TMP_ROOT/staging-refused-home"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
  done <<'ROWS'
staging autonomy on a no-mistakes ship|brief-staging-r1 some-proj --mode no-mistakes --staging-autonomy|--staging-autonomy applies only to --mode local-only
staging autonomy on a direct-PR ship|brief-staging-r2 some-proj --mode direct-PR --staging-autonomy|--staging-autonomy applies only to --mode local-only
staging autonomy on a scout|brief-staging-r3 some-proj --scout --staging-autonomy|--staging-autonomy applies only to ship briefs
staging autonomy on a secondmate charter|brief-staging-r4 --secondmate --no-projects --staging-autonomy|--staging-autonomy applies only to ship briefs
ROWS
  assert_absent "$home/data/brief-staging-r1/brief.md" "refused staging-autonomy scaffold still wrote a brief"
  pass "fm-brief.sh: --staging-autonomy is refused outside local-only ship briefs"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

test_script_parses
test_no_heredoc_in_command_substitution
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_ship_mode_is_required_and_closed_set
test_ship_mode_is_explicit_not_registry
test_delivery_flags_are_refused_where_they_do_not_apply
test_sync_base_step_precedes_branch_creation
test_sync_base_is_refused_where_it_does_not_apply
test_sync_base_guards_a_scout_investigation_base
test_sync_base_instruction_catches_a_stale_pooled_base
test_sync_base_divergence_stop_spares_only_the_default_branch
test_sync_base_step_routes_a_default_branch_that_contains_the_base
test_sync_base_divergence_check_survives_a_missing_origin_head
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_no_mistakes_dod_states_what_done_requires
test_ship_project_memory_wording
test_ship_baseline_and_no_placeholder_contract
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_secondmate_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_outward_write_cleanup_rule_reaches_both_scaffolds
test_pause_examples_name_pipeline_and_ci_waits
test_workers_report_to_firstmate_only
test_staging_autonomy_generates_the_landing_contract
test_staging_autonomy_is_refused_where_it_does_not_apply
test_scout_and_secondmate_scaffold
