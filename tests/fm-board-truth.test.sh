#!/usr/bin/env bash
# Tests for the board reconciliation truth source: bin/fm-board-truth.sh and the
# durable card index bin/fm-notion-link.sh writes through bin/fm-notion-index-lib.sh.
#
# The defect these guard: a Notion card's Status used to move only on a status
# EVENT from its worker, and tearing the task down erased the one record
# (state/<id>.meta notion_page=) that tied the card to its work, so a card whose
# event was missed stayed "В работе" forever. Reconciliation replaces the event:
# the PM compares the board with what is true in git and the deploy run on every
# cycle. For that, a card must stay resolvable to its branch after the task is
# gone, however it went - which is what the index is for.
#
# Matrix:
#   (a) link appends a live index line; archive appends an archive line; the
#       card then has no live link and --all-index skips it
#   (b) index append refused (unwritable data dir) -> meta untouched, exit 1
#   (c) branch in staging + deploy run success       -> landed-on-stand
#   (d) branch in staging + deploy run failure       -> landed-not-deployed
#   (e) branch exists, not in staging (in develop)   -> in-flight, in_develop=yes
#   (f) branch absent, artifact pattern misses       -> not-started
#   (g) branch absent, artifact pattern hits staging -> landed-on-stand (squash-merged)
#   (h) branch absent, no artifact pattern           -> unresolved (never guessed)
#   (i) --deploy none / no gh-axi on PATH            -> deploy=unknown, landed-not-deployed
#   (j) REVERSE HALF: the task is torn down with --force (records erased) -
#       without the index the card is unresolved; with the index it is still
#       landed-on-stand. The index is the only difference between the two runs.
#   (k) unsafe inputs are refused: bad url, bad branch name, missing --repo
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TRUTH="$ROOT/bin/fm-board-truth.sh"
LINK="$ROOT/bin/fm-notion-link.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-board-truth-tests)

gitc() { git -c user.email=t@t -c user.name=t "$@"; }

# Build one sandbox: a bare origin with main, develop, staging; fm/landed merged
# into staging; fm/wip only on develop; a clone at $case/repo; a fake gh-axi whose
# deploy conclusion is $2 (default success). Echoes the case dir.
build_case() {
  local name=$1 conclusion=${2:-success} case_dir seed
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/fakebin"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  seed="$case_dir/seed"
  git clone -q "$case_dir/origin.git" "$seed" 2>/dev/null
  git -C "$seed" checkout -q -b main 2>/dev/null || git -C "$seed" checkout -q main
  printf 'base\n' > "$seed/README"
  git -C "$seed" add README
  gitc -C "$seed" commit -q -m base
  git -C "$seed" push -q origin main
  git -C "$seed" checkout -q -b develop main
  git -C "$seed" push -q origin develop
  git -C "$seed" checkout -q -b staging main
  git -C "$seed" push -q origin staging
  git -C "$seed" checkout -q -b fm/landed main
  printf 'route /api/subject_requests/search\n' > "$seed/feature.py"
  git -C "$seed" add feature.py
  gitc -C "$seed" commit -q -m "feature"
  git -C "$seed" push -q origin fm/landed
  git -C "$seed" checkout -q staging
  gitc -C "$seed" merge -q --no-ff fm/landed -m "merge landed"
  git -C "$seed" push -q origin staging
  git -C "$seed" checkout -q -b fm/wip main
  gitc -C "$seed" commit -q --allow-empty -m "wip"
  git -C "$seed" push -q origin fm/wip
  git -C "$seed" checkout -q develop
  gitc -C "$seed" merge -q --no-ff fm/wip -m "merge wip into develop"
  git -C "$seed" push -q origin develop
  git clone -q "$case_dir/origin.git" "$case_dir/repo"
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "run list")
    case " \$* " in
      *" --workflow deploy.yml"*" --branch staging"*)
        printf 'count: 1 (showing first 1)\nruns[1]{id,status,conclusion}:\n  1,completed,$conclusion\n' ;;
      *) printf 'count: 0 (showing first 0)\nruns[]: []\n' ;;
    esac
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  printf '%s\n' "$case_dir"
}

run_truth() {  # <case> <args...> -> stdout, sets RC
  local case_dir=$1; shift
  OUT=$(PATH="$case_dir/fakebin:$PATH" FM_HOME="$case_dir" "$TRUTH" --repo "$case_dir/repo" "$@" 2>&1)
  RC=$?
}
field() { printf '%s\n' "$1" | tr '\t' '\n' | sed -n "s/^$2=//p"; }

# --- (a) index lifecycle -----------------------------------------------------
C=$(build_case a)
fm_write_meta "$C/state/t1.meta" "window=firstmate:fm-t1" "project=$C/repo"
fm_write_meta "$C/state/t2.meta" "window=firstmate:fm-t2" "project=$C/repo"
FM_HOME="$C" FM_NOW_OVERRIDE=100 "$LINK" t1 https://www.notion.so/card-1 >/dev/null || fail "(a) link t1"
FM_HOME="$C" FM_NOW_OVERRIDE=101 "$LINK" t2 https://www.notion.so/card-2 >/dev/null || fail "(a) link t2"
assert_grep $'100\tlink\tt1\thttps://www.notion.so/card-1\tfm/t1\t'"$C/repo" "$C/data/notion-cards.tsv" "(a) link line recorded"
FM_HOME="$C" FM_NOW_OVERRIDE=102 "$LINK" --archive t2 >/dev/null || fail "(a) archive t2"
assert_grep $'102\tarchive\tt2\thttps://www.notion.so/card-2\tfm/t2' "$C/data/notion-cards.tsv" "(a) archive line recorded"
assert_grep 'notion_page_archived=https://www.notion.so/card-2' "$C/state/t2.meta" "(a) meta archived"
run_truth "$C" --all-index --no-fetch
expect_code 0 "$RC" "(a) all-index"
assert_contains "$OUT" 'card=https://www.notion.so/card-1' "(a) live card listed"
assert_not_contains "$OUT" 'card-2' "(a) archived card not listed"
run_truth "$C" --card https://www.notion.so/card-2 --no-fetch
assert_contains "$OUT" 'truth=unresolved' "(a) archived card resolves to nothing"
pass "(a) index lifecycle"

# --- (b) index append refused -> meta untouched ---------------------------------
C=$(build_case b)
fm_write_meta "$C/state/t1.meta" "window=firstmate:fm-t1" "project=$C/repo"
chmod 500 "$C/data"
FM_HOME="$C" "$LINK" t1 https://www.notion.so/card-1 >/dev/null 2>"$C/err"; rc=$?
chmod 700 "$C/data"
expect_code 1 "$rc" "(b) link refused"
assert_grep 'failed to record the link' "$C/err" "(b) names the index failure"
assert_no_grep 'notion_page=' "$C/state/t1.meta" "(b) meta untouched"
assert_absent "$C/data/notion-cards.tsv" "(b) no partial index"
pass "(b) index append refused leaves meta untouched"

# --- (c)..(i) verdicts ------------------------------------------------------------
C=$(build_case c)
run_truth "$C" --branch fm/landed
expect_code 0 "$RC" "(c) exit"
[ "$(field "$OUT" truth)" = landed-on-stand ] || fail "(c) expected landed-on-stand: $OUT"
[ "$(field "$OUT" in_staging)" = yes ] || fail "(c) in_staging"
[ "$(field "$OUT" in_develop)" = no ] || fail "(c) in_develop"
[ "$(field "$OUT" deploy)" = alive ] || fail "(c) deploy alive"
pass "(c) branch in staging with live deploy -> landed-on-stand"

D=$(build_case d failure)
run_truth "$D" --branch fm/landed
[ "$(field "$OUT" truth)" = landed-not-deployed ] || fail "(d) expected landed-not-deployed: $OUT"
[ "$(field "$OUT" deploy)" = dead ] || fail "(d) deploy dead"
pass "(d) failed deploy run -> landed-not-deployed"

run_truth "$C" --branch fm/wip
[ "$(field "$OUT" truth)" = in-flight ] || fail "(e) expected in-flight: $OUT"
[ "$(field "$OUT" in_develop)" = yes ] || fail "(e) in_develop"
pass "(e) branch outside staging -> in-flight"

run_truth "$C" --branch fm/never --artifact 'webhook-test|webhook_test'
[ "$(field "$OUT" truth)" = not-started ] || fail "(f) expected not-started: $OUT"
[ "$(field "$OUT" branch_exists)" = no ] || fail "(f) branch_exists"
pass "(f) absent branch and missing artifact -> not-started"

run_truth "$C" --card https://www.notion.so/squashed --branch fm/deleted-after-squash --artifact 'subject_requests/search'
[ "$(field "$OUT" truth)" = landed-on-stand ] || fail "(g) expected landed-on-stand: $OUT"
[ "$(field "$OUT" artifact_in_staging)" = yes ] || fail "(g) artifact"
pass "(g) absent branch but artifact in staging -> landed-on-stand"

run_truth "$C" --branch fm/never
[ "$(field "$OUT" truth)" = unresolved ] || fail "(h) expected unresolved: $OUT"
pass "(h) absent branch with no artifact pattern -> unresolved"

run_truth "$C" --branch fm/landed --deploy none
[ "$(field "$OUT" deploy)" = unknown ] || fail "(i) deploy none"
[ "$(field "$OUT" truth)" = landed-not-deployed ] || fail "(i) unknown deploy never counts as on the stand"
OUT=$(PATH="/usr/bin:/bin" FM_HOME="$C" "$TRUTH" --repo "$C/repo" --branch fm/landed --no-fetch 2>&1)
[ "$(field "$OUT" deploy)" = unknown ] || fail "(i) no gh-axi -> unknown: $OUT"
pass "(i) unreadable deploy -> unknown, never alive"

# --- (j) reverse half: task torn down by force -------------------------------------
# Same scenario twice. The only difference between the two runs is whether the
# durable index exists. Both tear the task down with --force, the harshest exit a
# task can have, which erases state/<id>.meta and its notion_page= line.
J=$(build_case j)
fm_fake_exit0 "$J/fakebin" treehouse tmux
touch "$J/state/.last-watcher-beat"
fm_write_meta "$J/state/t1.meta" "window=firstmate:fm-t1" "endpoint_task_id=t1" \
  "worktree=$J/no-such-worktree" "project=$J/repo" "kind=ship" "mode=no-mistakes"
FM_HOME="$J" "$LINK" t1 https://www.notion.so/card-j >/dev/null || fail "(j) link"
assert_grep 'notion_page=https://www.notion.so/card-j' "$J/state/t1.meta" "(j) meta linked"
# Pre-fix world: the binding lived only in meta. Remove the index to model it.
mv "$J/data/notion-cards.tsv" "$J/index.saved"
PATH="$J/fakebin:$PATH" FM_HOME="$J" FM_STATE_OVERRIDE="$J/state" FM_DATA_OVERRIDE="$J/data" \
  "$TEARDOWN" t1 --force >/dev/null 2>&1 || fail "(j) forced teardown"
assert_absent "$J/state/t1.meta" "(j) meta erased by teardown"
run_truth "$J" --card https://www.notion.so/card-j --no-fetch
[ "$(field "$OUT" truth)" = unresolved ] || fail "(j) without the index the card is lost: $OUT"
[ "$(field "$OUT" task)" = - ] || fail "(j) no task resolvable without index"
# Fixed world: the index is back; nothing else changed and the task is still gone.
mv "$J/index.saved" "$J/data/notion-cards.tsv"
# Rename the recorded branch to the one that landed, so the index resolves to real work.
sed -i.bak 's#\tfm/t1\t#\tfm/landed\t#' "$J/data/notion-cards.tsv" && rm -f "$J/data/notion-cards.tsv.bak"
run_truth "$J" --card https://www.notion.so/card-j --no-fetch
[ "$(field "$OUT" truth)" = landed-on-stand ] || fail "(j) with the index the card still reconciles: $OUT"
[ "$(field "$OUT" task)" = t1 ] || fail "(j) task resolved from index after teardown"
pass "(j) forced teardown: card lost without the index, reconciled with it"

# --- (k) refusals ---------------------------------------------------------------------
run_truth "$C" --card 'http://www.notion.so/x'
expect_code 2 "$RC" "(k) non-https url"
run_truth "$C" --card 'https://www.notion.so/x y'
expect_code 2 "$RC" "(k) whitespace url"
run_truth "$C" --branch '--upload-pack=x'
expect_code 2 "$RC" "(k) option-shaped branch"
OUT=$("$TRUTH" --branch fm/landed 2>&1); RC=$?
expect_code 2 "$RC" "(k) missing --repo"
run_truth "$C"
expect_code 2 "$RC" "(k) no subject"
FM_HOME="$C" "$LINK" t9 https://www.notion.so/x >/dev/null 2>&1 && fail "(k) link without meta must fail"
pass "(k) unsafe inputs refused"

echo "all fm-board-truth tests passed"
