#!/usr/bin/env bash
# fm-skill-trigger-check.sh - assert every tracked firstmate skill has a load trigger.
#
# Usage:
#   bin/fm-skill-trigger-check.sh
#   bin/fm-skill-trigger-check.sh --root <repo> [--instructions <path>]
#
# A skill nothing loads is dead weight, and nothing in the repository notices:
# a new .agents/skills/<name>/SKILL.md is syntactically complete and completely
# inert until some instruction tells the agent when to load it. This check makes
# `firstmate-coding-guidelines`' trigger-hygiene rule enforceable instead of
# aspirational.
#
# Surface discovery is `git ls-files`, matching bin/fm-doc-audience-check.sh, so
# an untracked scratch skill in a working copy is out of scope and a tracked one
# can never be missed.
#
# Two ways a skill declares its trigger, and no third:
#   1. `user-invocable: true` in its frontmatter. The captain types /<name>, the
#      harness surfaces it from that field, and AGENTS.md needs no line for it.
#   2. Otherwise it is agent-only, and AGENTS.md must name it. AGENTS.md section
#      13 is the usual home; any mention counts, because an operating section is
#      a legitimate trigger site too.
# Missing or unparseable frontmatter fails: the carve-out cannot be evaluated
# without it, and a skill whose own metadata is unreadable is not registered.
#
# This check validates registration structure only. Whether a trigger is stated
# as a load CONDITION rather than a vague pointer is a review judgment owned by
# .agents/skills/firstmate-coding-guidelines/SKILL.md.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTRUCTIONS=

need_value() {  # <flag> <remaining-arg-count>
  [ "$2" -gt 1 ] || {
    printf 'fm-skill-trigger-check: %s needs a path\n' "$1" >&2
    exit 2
  }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    # Guard the value before shifting: with the value missing, the loop's
    # trailing `shift` runs at $# = 0, and `set -eu` would exit before the
    # actionable message below could print, leaving a bare exit code.
    --root) need_value --root "$#"; shift; ROOT=$1 ;;
    --instructions) need_value --instructions "$#"; shift; INSTRUCTIONS=$1 ;;
    -h|--help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0
      ;;
    *) printf 'fm-skill-trigger-check: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$ROOT" ] || { printf 'fm-skill-trigger-check: --root needs a path\n' >&2; exit 2; }
ROOT=$(cd "$ROOT" 2>/dev/null && pwd) \
  || { printf 'fm-skill-trigger-check: root is not a directory\n' >&2; exit 2; }
[ -n "$INSTRUCTIONS" ] || INSTRUCTIONS="$ROOT/AGENTS.md"

fail() {
  printf 'fm-skill-trigger-check: %s\n' "$*" >&2
  exit 1
}

[ -f "$INSTRUCTIONS" ] || fail "instructions file is missing: $INSTRUCTIONS"

# Value of one top-level frontmatter key, read from the leading `---` block only.
# Prints nothing when the block or the key is absent.
frontmatter_value() {  # <file> <key>
  local file=$1 key=$2 line seen=0 value
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [ "$seen" = 0 ]; then
      [ "$line" = "---" ] || return 0
      seen=1
      continue
    fi
    [ "$line" != "---" ] || return 0
    case "$line" in
      "$key":*)
        value=${line#*:}
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}
        printf '%s' "$value"
        return 0
        ;;
    esac
  done < "$file"
}

# 0 when the instructions name <skill> as a whole token, so a longer skill name
# containing a shorter one never lends the shorter one a trigger it lacks.
instructions_reference() {  # <skill-name>
  grep -qE "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_-]|$)" "$INSTRUCTIONS"
}

total=0
agent_only=0
captain_invocable=0
missing=

while IFS= read -r path; do
  [ -n "$path" ] || continue
  name=${path#.agents/skills/}
  name=${name%/SKILL.md}
  case "$name" in
    ''|*/*) fail "unexpected skill path layout: $path" ;;
  esac
  total=$((total + 1))
  declared=$(frontmatter_value "$ROOT/$path" name)
  [ -n "$declared" ] || fail "$path has no frontmatter name; a skill without frontmatter is not registered"
  [ "$declared" = "$name" ] \
    || fail "$path declares name '$declared' but lives in directory '$name'"
  invocable=$(frontmatter_value "$ROOT/$path" user-invocable)
  case "$invocable" in
    true)
      captain_invocable=$((captain_invocable + 1))
      ;;
    false)
      agent_only=$((agent_only + 1))
      instructions_reference "$name" || missing="${missing}${missing:+ }$name"
      ;;
    '')
      fail "$path has no user-invocable field; declare true for a captain-invoked skill or false for an agent-only one"
      ;;
    *)
      fail "$path has user-invocable: $invocable; only true or false declare a trigger"
      ;;
  esac
done <<EOF
$(git -C "$ROOT" ls-files -- '.agents/skills/*/SKILL.md')
EOF

[ "$total" -gt 0 ] || fail "no tracked skills found under .agents/skills/"

if [ -n "$missing" ]; then
  instructions_name=${INSTRUCTIONS#"$ROOT/"}
  fail "agent-only skills with no load trigger in $instructions_name: $missing"
fi

printf 'fm-skill-trigger-check: ok skills=%s agent_only=%s captain_invocable=%s\n' \
  "$total" "$agent_only" "$captain_invocable"
