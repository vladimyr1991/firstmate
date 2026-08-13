#!/usr/bin/env bash
# Blind backtest of the lessons-learned retrospective against a preserved incident.
#
# The point of this script is one property: the agent under test sees the procedure and the
# raw evidence, and cannot see the expected answers. That property is ENFORCED, not asserted.
#
#   1. The whole input is one composed prompt, printed and saved before the run, so what the
#      agent saw is inspectable after the fact rather than taken on trust.
#   2. The agent runs with every filesystem, shell, and network tool denied, from an empty
#      temporary directory, so the sealed key and data/learnings.md are unreachable even by a
#      correct absolute path.
#   3. The run is rejected if its transcript contains a single tool use, so a harness that
#      ignored the deny list produces a failed test rather than a contaminated pass.
#   4. The composed prompt is scanned for the sealed key's and learnings file's paths, and the
#      fixture is scanned for a stray copy of either, before any model is called.
#
# Usage:
#   fm-retro-backtest.sh prompt              print the composed prompt and exit
#   fm-retro-backtest.sh check               run the isolation guards only and exit
#   fm-retro-backtest.sh run [options]       compose, guard, run the agent, save the result
#
# run options:
#   --model <model>   model for the agent under test (default: opus)
#   --out <dir>       run directory (default: $FM_HOME/data/retro-backtest-0811/runs/<stamp>)
#   --stamp <text>    directory name under runs/ instead of a timestamp
#
# The run directory receives prompt.md, stream.jsonl, answer.md, and isolation-report.txt.
# It defaults under data/, which is gitignored, so a result never lands next to the fixture.
#
# Grading is deliberately NOT automated. Read the sealed key only against a final answer.md,
# and mark each key item found, partially found, or missed on substance rather than wording.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

FIXTURE="${FM_RETRO_BACKTEST_FIXTURE:-$FM_ROOT/tests/fixtures/retro-backtest-0811}"
PROCEDURE="$FM_ROOT/.agents/skills/lessons-learned/SKILL.md"
SEALED_KEY="$FM_HOME/data/retro-backtest-0811/SEALED-expected-answers.md"
LEARNINGS="$FM_HOME/data/learnings.md"

DENIED_TOOLS=(Bash Read Write Edit NotebookEdit Glob Grep WebFetch WebSearch Task Agent \
  TodoWrite Skill SlashCommand KillShell BashOutput ListMcpResourcesTool ReadMcpResourceTool)

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

die() { echo "error: $*" >&2; exit 1; }

# --- guards -----------------------------------------------------------------------------

# A stray copy of the key or of learnings.md inside the fixture would defeat the whole test,
# and would do it silently, so look for the content rather than only for the filename.
guard_fixture() {
  [ -d "$FIXTURE" ] || die "fixture directory is missing: $FIXTURE"
  [ -r "$PROCEDURE" ] || die "retrospective procedure is missing: $PROCEDURE"

  [ -d "$FIXTURE/evidence" ] || die "fixture has no evidence directory: $FIXTURE/evidence"

  local hit
  hit=$(find "$FIXTURE" -type f \( -iname '*SEALED*' -o -iname 'learnings.md' \) -print -quit)
  [ -z "$hit" ] || die "answer-bearing file inside the fixture: $hit"

  # The README is grader-facing and names the key; it must never sit where the prompt reads.
  hit=$(find "$FIXTURE/evidence" -type f -iname 'README.md' -print -quit)
  [ -z "$hit" ] || die "grader-facing README inside evidence/: $hit"
  if grep -rql -- 'SEALED-expected-answers' "$FIXTURE/evidence"; then
    die "an evidence file names the sealed key"
  fi

  if [ -r "$SEALED_KEY" ]; then
    local marker
    marker=$(grep -m1 -E '^[A-Za-z].{24,}' "$SEALED_KEY" | cut -c1-48)
    if [ -n "$marker" ] && grep -rqF -- "$marker" "$FIXTURE"; then
      die "fixture repeats a line of the sealed key"
    fi
  fi
}

guard_prompt() {
  local prompt_file=$1
  ! grep -qF -- "SEALED-expected-answers" "$prompt_file" \
    || die "composed prompt names the sealed key"
  ! grep -qF -- "data/learnings.md" "$prompt_file" \
    || die "composed prompt names the learnings file"
}

# --- prompt -----------------------------------------------------------------------------

compose_prompt() {
  cat <<'HEADER'
You are running a retrospective on a finished incident, using the procedure your organisation
has already adopted. The procedure is reproduced below, followed by the surviving evidence.

You have no tools. Everything you are allowed to use is in this message. Do not ask for more
evidence; work the evidence you have and say plainly where it runs out.

Produce candidate lessons. For each one give:
  - the lesson, as a change someone could make;
  - the exact evidence from the logs that produced it, quoted with its timestamp;
  - where it should be routed, per the procedure's routing section;
  - how confident you are, and what would disconfirm it.

Order them by how much the fleet would gain from fixing them. Say "nothing" where a draft
prompt genuinely has no answer here, rather than filling it.

================================ THE PROCEDURE ================================
HEADER
  cat "$PROCEDURE"

  # Only evidence/ reaches the agent. The fixture README is written for whoever runs and
  # grades the test, and it necessarily discusses the key that the agent must not know about.
  local f
  for f in "$FIXTURE"/evidence/*; do
    printf '\n================================ EVIDENCE: %s ================================\n' \
      "$(basename "$f")"
    cat "$f"
  done
}

# --- run --------------------------------------------------------------------------------

run_agent() {
  local model=opus
  local out=''
  local stamp=''
  while [ "$#" -gt 0 ]; do
    case $1 in
      --model) model=${2:-} ; shift 2 || die "--model needs a value" ;;
      --out) out=${2:-} ; shift 2 || die "--out needs a value" ;;
      --stamp) stamp=${2:-} ; shift 2 || die "--stamp needs a value" ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$model" ] || die "--model needs a value"

  # Guard the fixture before anything else, so a contaminated fixture costs a
  # refusal rather than a model call.
  guard_fixture
  command -v claude >/dev/null || die "the claude CLI is not on PATH"

  [ -n "$stamp" ] || stamp=$(date -u +%Y%m%dT%H%M%SZ)
  [ -n "$out" ] || out="$FM_HOME/data/retro-backtest-0811/runs/$stamp"
  mkdir -p "$out" || die "cannot create run directory: $out"

  compose_prompt > "$out/prompt.md" || die "cannot write the prompt"
  guard_prompt "$out/prompt.md"

  # An empty cwd, so a tool that escaped the deny list still starts nowhere useful.
  local sandbox
  sandbox=$(mktemp -d) || die "cannot create the sandbox directory"

  echo "running $model against $(wc -l < "$out/prompt.md") lines of prompt; this takes a while" >&2
  ( cd "$sandbox" && claude -p \
      --model "$model" \
      --output-format stream-json --verbose \
      --disallowed-tools "${DENIED_TOOLS[@]}" \
      --settings '{"permissions":{"defaultMode":"plan","deny":["Bash","Read","Write","Edit","Glob","Grep","WebFetch","WebSearch","Task"]}}' \
      < "$out/prompt.md" ) > "$out/stream.jsonl"
  local rc=$?
  rmdir "$sandbox" 2>/dev/null || true
  [ "$rc" -eq 0 ] || die "the agent under test exited $rc; see $out/stream.jsonl"

  extract_answer "$out/stream.jsonl" > "$out/answer.md" || die "cannot extract the answer"
  [ -s "$out/answer.md" ] || die "the agent produced no answer; see $out/stream.jsonl"

  isolation_report "$out" > "$out/isolation-report.txt"
  cat "$out/isolation-report.txt"

  local tool_uses
  tool_uses=$(count_tool_uses "$out/stream.jsonl")
  [ "$tool_uses" -eq 0 ] \
    || die "CONTAMINATED: the agent used $tool_uses tool(s); discard this run"

  echo "answer: $out/answer.md"
}

count_tool_uses() {
  grep -o '"type":"tool_use"' "$1" 2>/dev/null | wc -l | tr -d ' '
}

extract_answer() {
  # The final result event carries the complete answer text.
  python3 - "$1" <<'PY'
import json, sys
text = ""
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("type") == "result" and isinstance(event.get("result"), str):
        text = event["result"]
print(text)
PY
}

isolation_report() {
  local out=$1
  echo "fixture:           $FIXTURE"
  echo "procedure:         $PROCEDURE"
  echo "prompt sha256:     $(shasum -a 256 "$out/prompt.md" | cut -d' ' -f1)"
  echo "prompt lines:      $(wc -l < "$out/prompt.md" | tr -d ' ')"
  echo "tools denied:      ${DENIED_TOOLS[*]}"
  echo "tool uses in run:  $(count_tool_uses "$out/stream.jsonl")"
  echo "sealed key path:   $SEALED_KEY"
  echo "key in prompt:     $(grep -c 'SEALED-expected-answers' "$out/prompt.md" | tr -d ' ') references"
  echo "learnings path:    $LEARNINGS"
  echo "learnings in prompt: $(grep -c 'data/learnings.md' "$out/prompt.md" | tr -d ' ') references"
  echo "cwd during run:    an empty temporary directory, removed after the run"
}

# --- entry ------------------------------------------------------------------------------

case ${1:---help} in
  --help|-h|help) usage ;;
  prompt) guard_fixture; compose_prompt ;;
  check) guard_fixture; tmp=$(mktemp); compose_prompt > "$tmp"; guard_prompt "$tmp"; rm -f "$tmp"
         echo "isolation guards pass" ;;
  run) shift; run_agent "$@" ;;
  *) die "unknown command: $1" ;;
esac
