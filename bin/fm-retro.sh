#!/usr/bin/env bash
# fm-retro.sh - deterministic mechanics for the lessons-learned pass that runs
# between confirmed landing and teardown.
#
# The semantic policy is owned once by
# .agents/skills/lessons-learned/SKILL.md. This script never reads report,
# brief, chat, or terminal prose to guess what a task taught. It collects
# COUNTABLE signals, records the agent's semantic attestation, and verifies that
# attestation for teardown. Judgment belongs to the agent and the skill.
#
# Every artifact lives under data/<id>/, never in task metadata: bin/fm-teardown.sh
# deletes state/<id>.status and state/<id>.meta, so a receipt written there would
# be erased by the very step this gate protects. data/<id>/ survives teardown.
#
# THE DURABLE-RECORD INVARIANT, which this script owns and every command below
# obeys: once a durable record is committed, no later step may destroy, degrade,
# or contradict it. Three consequences, none of them optional.
#
#   1. `unknown` and `0` are DIFFERENT FACTS. A status-derived count is `0` only
#      when the status log was read and genuinely held no such event; when the
#      log is gone it is `unknown`. Recording a torn-down task's five escalations
#      as `0` would not merely lose data, it would fail in the self-flattering
#      direction - the fleet would look like it was improving precisely because
#      the evidence of struggle had been erased.
#   2. A later read may never replace a known value with `unknown`, and may not
#      drop a known key either: known -> absent is the same degradation as
#      known -> unknown, only quieter. Both halves are enforced as one general
#      merge rule over a whole block rather than per key, so they also cover
#      degradations no reviewer named: a returned worktree turning `branch`,
#      `commit_base`, and `commits` unknown while state/<id>.meta still exists,
#      and a key this version never emits - a pass 2 struggle score, an
#      `audited_by` line from the cross-vendor audit, anything a human added -
#      being erased by the block rewrite. An unrecognized key is carried forward
#      verbatim instead, in the order it already had. This governs BOTH blocks,
#      because the hole belongs to rewriting a block from a fixed key list and
#      not to either block, so `collect` and `complete` share one helper.
#   3. When the volatile records are gone and a facts block already exists,
#      `collect` REFUSES instead of degrading. A refusal that names its reason is
#      strictly better than a quiet zero.
#
# The same invariant governs every other write path here: `complete` unions
# lesson keys and never drops one and carries forward attestation keys it does
# not recognize, the frame is seeded only when the file does not exist, and block
# rewrites leave every line outside their own markers untouched, so human
# narrative added to data/<id>/retro.md survives both commands. This invariant arrived independently from two unrelated tasks
# (fm-lessons-learned and fm-quota-autoresume), which is why it is stated here as
# a rule rather than patched at the one call site that exposed it.
#
# Usage:
#   fm-retro.sh collect <origin-id>
#   fm-retro.sh complete <origin-id> (--none | <lesson-key>...)
#   fm-retro.sh verify <origin-id>
#
# `collect` reads the still-present state/<id>.status and state/<id>.meta and
# writes a machine-readable facts block into data/<id>/retro.md. It applies no
# judgment, is idempotent, and never fails a task for a missing optional input:
# an unavailable fact is recorded as `unknown` rather than guessed. Status-line
# parsing is delegated to bin/fm-classify-lib.sh, the one owner of the
# status-fold contract; this script adds no second parser.
#
# Two facts are proxies and say so in the record rather than pretending to be
# exact. `commits` is counted against the first resolvable default-branch ref and
# publishes that ref as `commit_base`, so a project that ships from a branch the
# default ref lags behind reads as a large count with a visible reason instead of
# a wrong number. `elapsed_seconds` spans `dispatch_source` to `landing_source`,
# both named in the record, because no dispatch timestamp is recorded anywhere.
#
# `complete` is the semantic attestation, mirroring fm-decision-hold.sh complete.
# `--none` is an explicit "this task taught nothing durable", so silence is never
# mistaken for a clean sweep. Lesson keys are privacy-safe slugs, validated the
# same way decision keys are, and repeated runs union idempotently.
#
# `verify` is read-only and is called by ship teardown so cleanup cannot erase a
# task's evidence before the lessons-learned gate has succeeded.
#
# data/<id>/retro.md carries two delimited blocks. `collect` rewrites only the
# facts block and `complete` rewrites only the attestation block, so either
# command may run first, again, or after the other without losing the other's
# work. The facts block is deliberately an open key=value set: pass 2 struggle
# scoring can add keys without a format change. The attestation block carries a
# closed set of keys today, but it is rewritten under the same rule, so a key
# either block gains later - by a scorer, an auditor, or a hand - survives every
# re-run of the command that owns that block, unchanged and in place.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# fm-lock-lib.sh is a dependency-free leaf; sourced only for its portable
# fm_lock_path_mtime, so this script adds no fourth copy of the platform test.
# shellcheck source=bin/fm-lock-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-lock-lib.sh"

FACTS_OPEN='<!-- fm-retro:facts v1 -->'
FACTS_CLOSE='<!-- /fm-retro:facts -->'
ATTEST_OPEN='<!-- fm-retro:attestation v1 -->'
ATTEST_CLOSE='<!-- /fm-retro:attestation -->'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-retro: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

retro_path() {  # <origin-id>
  printf '%s/%s/retro.md\n' "$DATA" "$1"
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Epoch mtime of a file, or empty when unreadable. Delegates the platform test to
# fm_lock_path_mtime: a `stat -f %m || stat -c %Y` chain looks portable but is
# not, because GNU `stat -f` means --file-system and SUCCEEDS, so the fallback
# would never run on Linux and every timestamp would silently read unknown there.
file_epoch() {  # <path>
  local path=$1 value
  [ -f "$path" ] || return 0
  value=$(fm_lock_path_mtime "$path") || return 0
  case "$value" in
    ''|*[!0-9]*) return 0 ;;
    *) printf '%s' "$value" ;;
  esac
}

# Print the content of one delimited block, without its markers. Silent when the
# file or the block is absent, so a first run and a re-run share one code path.
read_block() {  # <file> <open-marker> <close-marker>
  local file=$1 open=$2 close=$3 line inside=0
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$inside" = 0 ]; then
      [ "$line" = "$open" ] && inside=1
      continue
    fi
    [ "$line" = "$close" ] && break
    printf '%s\n' "$line"
  done < "$file"
}

# Print one key's value from a block body of `key=value` lines.
block_value() {  # <block-body> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -1
}

# Rewrite one delimited block in place, creating the file and the block when
# absent and leaving every other line - including the sibling block - untouched.
write_block() {  # <file> <open-marker> <close-marker> <body>
  local file=$1 open=$2 close=$3 body=$4 tmp line inside=0 seen=0
  case "$body" in
    ''|*$'\n') : ;;
    *) body="$body"$'\n' ;;
  esac
  mkdir -p "$(dirname "$file")"
  tmp="$file.tmp.$$"
  : > "$tmp"
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$inside" = 1 ]; then
        [ "$line" = "$close" ] && inside=0
        continue
      fi
      if [ "$line" = "$open" ]; then
        inside=1
        seen=1
        printf '%s\n%s%s\n' "$open" "$body" "$close" >> "$tmp"
        continue
      fi
      printf '%s\n' "$line" >> "$tmp"
    done < "$file"
  fi
  if [ "$seen" = 0 ]; then
    printf '%s\n%s%s\n' "$open" "$body" "$close" >> "$tmp"
  fi
  mv "$tmp" "$file"
}

# Seed the human-readable frame exactly once so both commands can create the
# file and neither has to know the other's block order.
ensure_retro_frame() {  # <origin-id> <file>
  local id=$1 file=$2
  [ ! -f "$file" ] || return 0
  mkdir -p "$(dirname "$file")"
  {
    printf '# Retro: %s\n\n' "$id"
    cat <<'MD'
Countable signals collected by `bin/fm-retro.sh`, plus the landing worker's
semantic attestation.
The lessons themselves are proposals routed by
`.agents/skills/lessons-learned/SKILL.md`; this file records only what was
counted and what was attested.

## Facts

MD
    printf '%s\n%s\n\n' "$FACTS_OPEN" "$FACTS_CLOSE"
    printf '## Attestation\n\n'
    printf '%s\n%s\n' "$ATTEST_OPEN" "$ATTEST_CLOSE"
  } > "$file"
}

# Accumulate one `key=value` fact line into the block body being built.
#
# Consequence 2 of the durable-record invariant lives here, once, for every fact:
# a newly computed `unknown` never replaces a value the record already knows.
# Keeping it in the accumulator rather than at each call site is what makes the
# rule total - a fact added later inherits the protection without being
# remembered about.
FACTS_BODY=''
PREVIOUS_FACTS=''
EMITTED_KEYS=''
add_fact() {  # <key> <value>
  local key=$1 value=$2 previous
  if [ "$value" = unknown ] && [ -n "$PREVIOUS_FACTS" ]; then
    previous=$(block_value "$PREVIOUS_FACTS" "$key")
    if [ -n "$previous" ] && [ "$previous" != unknown ]; then
      value=$previous
    fi
  fi
  FACTS_BODY="${FACTS_BODY}${key}=${value}"$'\n'
  EMITTED_KEYS="${EMITTED_KEYS}${key} "
}

# The other half of consequence 2: a rewrite drops nothing it merely failed to
# recognize. Every line the previous block held whose key the rebuilt body does
# not itself emit is appended verbatim, after the known keys and in the order it
# already had, so an unchanged record rewrites byte-identically apart from its one
# timestamp key and a key added by a later pass survives a version of this script
# that predates it. One helper serves BOTH blocks: the hole this closes is a
# property of rewriting a whole block from a fixed key list, not of either block.
carry_unrecognized_lines() {  # <rebuilt-body> <previous-body> <emitted-keys>
  local body=$1 previous=$2 emitted=" $3 " line key
  case "$body" in
    ''|*$'\n') : ;;
    *) body="$body"$'\n' ;;
  esac
  printf '%s' "$body"
  [ -n "$previous" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      *=*)
        key=${line%%=*}
        case "$emitted" in
          *" $key "*) continue ;;
        esac
        ;;
    esac
    printf '%s\n' "$line"
  done <<EOF
$previous
EOF
}

sorted_key_union() {  # <comma-list> <space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

# Count status events by verb and collect the distinct decision keys they carry.
# Both the verb and the key come from bin/fm-classify-lib.sh so this script never
# becomes a second status-line parser.
#
# An ABSENT status log yields `unknown` for every count, never `0`: consequence 1
# of the durable-record invariant. `0` is the answer only when the log was read
# and held no such event, and `decision_keys=none` likewise means "read, and
# there were none" rather than "never read".
status_facts() {  # <status-file> -> "lines needs blocked resolved paused keys"
  local file=$1 line verb key lines=0 needs=0 blocked=0 resolved=0 paused=0 keys=''
  local resolve_verb pause_verb stripped
  resolve_verb=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  pause_verb=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  if [ ! -f "$file" ]; then
    printf 'unknown unknown unknown unknown unknown unknown'
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    lines=$((lines + 1))
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || key=''
    case "$verb" in
      needs-decision)
        needs=$((needs + 1))
        keys="${keys}${keys:+ }${key}"
        ;;
      blocked)
        blocked=$((blocked + 1))
        keys="${keys}${keys:+ }${key}"
        ;;
      "$resolve_verb") resolved=$((resolved + 1)) ;;
      "$pause_verb") paused=$((paused + 1)) ;;
    esac
  done < "$file"
  keys=$(sorted_key_union '' "$keys")
  printf '%s %s %s %s %s %s' "$lines" "$needs" "$blocked" "$resolved" "$paused" "${keys:-none}"
}

# Commits on the task branch that the default branch does not already contain.
# Read-only and best effort: an absent worktree, an unresolvable base, or any git
# failure yields `unknown` rather than a wrong number or a failed collect.
branch_facts() {  # <worktree> <task-id> -> "branch base commits"
  local wt=$1 id=$2 branch base candidate count
  if [ -z "$wt" ] || [ ! -d "$wt" ] || ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'unknown unknown unknown'
    return 0
  fi
  if git -C "$wt" rev-parse --verify --quiet "refs/heads/fm/$id" >/dev/null 2>&1; then
    branch="fm/$id"
  else
    branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=''
    [ -n "$branch" ] || branch=unknown
  fi
  base=''
  for candidate in origin/HEAD origin/main origin/master main master; do
    if git -C "$wt" rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
      base=$candidate
      break
    fi
  done
  if [ -z "$base" ] || [ "$branch" = unknown ]; then
    printf '%s %s unknown' "$branch" "${base:-unknown}"
    return 0
  fi
  count=$(git -C "$wt" rev-list --count "$branch" --not "$base" 2>/dev/null) || count=''
  case "$count" in
    ''|*[!0-9]*) count=unknown ;;
  esac
  printf '%s %s %s' "$branch" "$base" "$count"
}

command_collect() {
  local id=${1:-} file meta status_file open_count=0 eval_count=0
  local lines needs blocked resolved paused keys branch base commits
  local dispatch_epoch='' dispatch_source=unknown landing_epoch='' landing_source=unknown
  local elapsed=unknown now key value
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$id"
  meta="$STATE/$id.meta"
  status_file="$STATE/$id.status"
  file=$(retro_path "$id")
  [ -f "$meta" ] || [ -f "$status_file" ] || [ -d "$DATA/$id" ] \
    || fail "task $id is not owned by the active home $FM_HOME"

  PREVIOUS_FACTS=$(read_block "$file" "$FACTS_OPEN" "$FACTS_CLOSE")
  # Consequence 3 of the durable-record invariant: past teardown there is nothing
  # left to read, so a re-collect could only overwrite real evidence with
  # absence. Refuse and say so rather than degrade the record silently.
  if [ ! -f "$meta" ] && [ ! -f "$status_file" ] && [ -n "$PREVIOUS_FACTS" ]; then
    fail "task $id has no volatile records left and $file already holds collected facts; refusing to re-collect over them (the existing record was collected while state/$id.status and state/$id.meta still existed)"
  fi

  read -r lines needs blocked resolved paused keys <<EOF
$(status_facts "$status_file")
EOF
  if [ -f "$status_file" ]; then
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      open_count=$((open_count + 1))
    done <<EOF
$(status_open_decisions "$status_file")
EOF
  else
    open_count=unknown
  fi
  for value in "$DATA/$id"/evaluation-*.md; do
    [ -e "$value" ] || continue
    eval_count=$((eval_count + 1))
  done

  read -r branch base commits <<EOF
$(branch_facts "$(meta_value "$meta" worktree)" "$id")
EOF

  for value in "$DATA/$id/brief.md" "$meta"; do
    dispatch_epoch=$(file_epoch "$value")
    if [ -n "$dispatch_epoch" ]; then
      dispatch_source=${value#"$FM_HOME/"}
      break
    fi
  done
  landing_epoch=$(file_epoch "$status_file")
  if [ -n "$landing_epoch" ]; then
    landing_source=${status_file#"$FM_HOME/"}
  fi
  if [ -n "$dispatch_epoch" ] && [ -n "$landing_epoch" ] && [ "$landing_epoch" -ge "$dispatch_epoch" ]; then
    elapsed=$((landing_epoch - dispatch_epoch))
  fi
  now=$(date -u +%s)

  FACTS_BODY=''
  EMITTED_KEYS=''
  add_fact schema 1
  add_fact task "$id"
  add_fact collected_epoch "$now"
  for key in project kind mode yolo harness model effort backend pr; do
    value=$(meta_value "$meta" "$key")
    add_fact "$key" "${value:-unknown}"
  done
  add_fact status_lines "$lines"
  add_fact needs_decision_events "$needs"
  add_fact blocked_events "$blocked"
  add_fact resolved_events "$resolved"
  add_fact paused_events "$paused"
  add_fact decision_keys "$keys"
  add_fact open_decisions "$open_count"
  add_fact evaluation_rounds "$eval_count"
  add_fact branch "$branch"
  add_fact commit_base "$base"
  add_fact commits "$commits"
  add_fact dispatch_source "$dispatch_source"
  add_fact dispatch_epoch "${dispatch_epoch:-unknown}"
  add_fact landing_source "$landing_source"
  add_fact landing_epoch "${landing_epoch:-unknown}"
  add_fact elapsed_seconds "$elapsed"
  FACTS_BODY=$(carry_unrecognized_lines "$FACTS_BODY" "$PREVIOUS_FACTS" "$EMITTED_KEYS")

  ensure_retro_frame "$id" "$file"
  write_block "$file" "$FACTS_OPEN" "$FACTS_CLOSE" "$FACTS_BODY"
  printf 'collected: %s facts -> %s\n' "$id" "$file"
}

command_complete() {
  local id=${1:-} file body attested previous='' supplied='' keys='' now
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$id"
  shift
  file=$(retro_path "$id")
  [ -f "$file" ] || fail "task $id has no collected facts; run: bin/fm-retro.sh collect $id"
  [ -n "$(read_block "$file" "$FACTS_OPEN" "$FACTS_CLOSE")" ] \
    || fail "task $id has an empty facts block; run: bin/fm-retro.sh collect $id"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with lesson keys"
      validate_slug lesson-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  body=$(read_block "$file" "$ATTEST_OPEN" "$ATTEST_CLOSE")
  previous=$(block_value "$body" lesson_keys)
  [ "$previous" != none ] || previous=''
  keys=$(sorted_key_union "$previous" "$supplied")
  now=$(date -u +%s)
  attested=$(printf 'lessons_reviewed=1\nlesson_keys=%s\nattested_epoch=%s\n' "${keys:-none}" "$now")
  write_block "$file" "$ATTEST_OPEN" "$ATTEST_CLOSE" \
    "$(carry_unrecognized_lines "$attested" "$body" 'lessons_reviewed lesson_keys attested_epoch')"
  printf 'complete: %s lessons reviewed (%s)\n' "$id" "${keys:-none}"
}

command_verify() {
  local id=${1:-} file body
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$id"
  file=$(retro_path "$id")
  [ -f "$file" ] || fail "task $id has no retro record at $file"
  [ -n "$(read_block "$file" "$FACTS_OPEN" "$FACTS_CLOSE")" ] \
    || fail "task $id has no collected facts in $file"
  body=$(read_block "$file" "$ATTEST_OPEN" "$ATTEST_CLOSE")
  [ "$(block_value "$body" lessons_reviewed)" = 1 ] \
    || fail "task $id has no lessons-learned attestation in $file"
  printf 'verified: %s lessons-learned attestation (%s)\n' "$id" \
    "$(block_value "$body" lesson_keys)"
}

case "${1:-}" in
  collect) shift; command_collect "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
