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
#      evidence is scanned for a stray copy of the key, before any model is called. That scan
#      catches a copied or pasted key; it does not prove the evidence is free of every possible
#      restatement, and it deliberately never prints key text, only the key's line number.
#   5. The procedure half of the prompt is refused if it names the incident under test, because
#      the procedure is a repository file an editor can annotate with what the test found. The
#      marker list catches careless wording, not a determined paraphrase; the real protection is
#      that the procedure is meant to stay inert, and the markers only make a slip loud.
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
PROCEDURE="${FM_RETRO_BACKTEST_PROCEDURE:-$FM_ROOT/.agents/skills/lessons-learned/SKILL.md}"
SEALED_KEY="$FM_HOME/data/retro-backtest-0811/SEALED-expected-answers.md"
LEARNINGS="$FM_HOME/data/learnings.md"

# Names for the incident under test. The procedure must never contain one: the evidence
# names the incident because it is the incident, but the procedure is generic by design.
INCIDENT_MARKERS='retro-backtest-0811|2026-08-11|0811|backtest|fleet stall|session limit'
INCIDENT_MARKERS="$INCIDENT_MARKERS|fm-quota-autoresume|fm-quota-dash-grok"

KEY_SCAN=''
SCRATCH_PROMPT=''

DENIED_TOOLS=(Bash Read Write Edit NotebookEdit Glob Grep WebFetch WebSearch Task Agent \
  TodoWrite Skill SlashCommand KillShell BashOutput ListMcpResourcesTool ReadMcpResourceTool)

usage() { sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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

  # Every line the key asserts, not only the first: a copy that drops or rewords one line would
  # otherwise walk straight past a single-marker scan. Only evidence/ is scanned, because only
  # evidence/ reaches the agent, and only long unquoted lines are used as markers: a key for an
  # evidence-based test quotes the evidence to justify its verdicts, and a guard that refuses a
  # clean fixture on the key's own quotations is a guard the next operator turns off.
  if [ -r "$SEALED_KEY" ]; then
    local numbered number text marker markers=0
    while IFS= read -r numbered; do
      number=${numbered%%:*}
      text=${numbered#*:}
      case $text in
        *'"'*|*'`'*|*'>'*) continue ;;
      esac
      marker=$(printf '%s' "$text" | cut -c1-64)
      markers=$((markers + 1))
      if grep -rqF -- "$marker" "$FIXTURE/evidence"; then
        die "fixture evidence repeats sealed key line $number, which the key alone may state"
      fi
    done < <(grep -nE '^[A-Za-z].{63,}' "$SEALED_KEY")
    if [ "$markers" -eq 0 ]; then
      # Neither a completed scan nor a missing key: the key is there and nothing in it fits the
      # marker shape, so nothing was compared and the discriminator needs revisiting.
      KEY_SCAN="inconclusive (key readable at $SEALED_KEY, but no line of it is usable as a marker)"
    else
      KEY_SCAN="ran against $SEALED_KEY ($markers key line(s) compared)"
    fi
  else
    # The key lives outside the repository on purpose, so this is the ordinary case on any
    # checkout but the operator's. Say so, rather than letting a skipped guard read as a pass.
    KEY_SCAN="skipped (key not readable at $SEALED_KEY)"
  fi
}

guard_prompt() {
  local prompt_file=$1
  ! grep -qF -- "SEALED-expected-answers" "$prompt_file" \
    || die "composed prompt names the sealed key"
  ! grep -qF -- "data/learnings.md" "$prompt_file" \
    || die "composed prompt names the learnings file"
}

# The procedure is a repository file, so an editor can annotate it with what this test found -
# and every such annotation is a leak, because the whole file is composed into the prompt.
guard_procedure() {
  local tmp hit
  tmp=$(mktemp) || die "cannot create a temporary file"
  compose_procedure > "$tmp" || die "cannot compose the procedure section"
  hit=$(grep -niE -- "$INCIDENT_MARKERS" "$tmp" | head -n 1)
  rm -f "$tmp"
  [ -z "$hit" ] \
    || die "the procedure names the incident under test, which leaks it to the agent: $hit"
}

# --- prompt -----------------------------------------------------------------------------

compose_procedure() {
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
}

# Only evidence/ reaches the agent. The fixture README is written for whoever runs and
# grades the test, and it necessarily discusses the key that the agent must not know about.
compose_evidence() {
  local f
  for f in "$FIXTURE"/evidence/*; do
    printf '\n================================ EVIDENCE: %s ================================\n' \
      "$(basename "$f")"
    cat "$f"
  done
}

compose_prompt() {
  compose_procedure
  compose_evidence
}

# Compose to a temporary file, guard it, and emit it only when asked. The trap matters: a
# refusal exits through die, and the composed prompt it just refused must not survive on disk.
guarded_prompt() {
  local emit=${1:-}
  SCRATCH_PROMPT=$(mktemp) || die "cannot create a temporary file for the composed prompt"
  trap 'rm -f "$SCRATCH_PROMPT"' EXIT
  compose_prompt > "$SCRATCH_PROMPT" || die "cannot write the prompt"
  guard_prompt "$SCRATCH_PROMPT"
  if [ "$emit" = emit ]; then
    cat "$SCRATCH_PROMPT"
  fi
  rm -f "$SCRATCH_PROMPT"
  trap - EXIT
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
  guard_procedure
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

  # Contamination is decided before anything else about the answer, so a run that is both
  # contaminated and empty dies on the cause that matters and still quarantines its artifact.
  local tool_uses quarantine="$out/answer.CONTAMINATED.md"
  tool_uses=$(count_tool_uses "$out/stream.jsonl")

  extract_answer "$out/stream.jsonl" > "$out/answer.md" || die "cannot extract the answer"

  isolation_report "$out" > "$out/isolation-report.txt"
  cat "$out/isolation-report.txt"

  # Grading is manual and reads answer.md, so a rejected run must not leave an artifact that
  # looks like a clean one.
  case $tool_uses in
    0) ;;
    unreadable)
      mv "$out/answer.md" "$quarantine" || true
      die "CONTAMINATED: the transcript could not be parsed, so the no-tool-use property is unproven; discard this run and its answer at $quarantine" ;;
    *)
      mv "$out/answer.md" "$quarantine" || true
      die "CONTAMINATED: the agent used $tool_uses tool(s); discard this run and its answer at $quarantine" ;;
  esac

  grep -q '[^[:space:]]' "$out/answer.md" \
    || die "the agent produced no answer; see $out"

  echo "answer: $out/answer.md"
}

# Echoes the number of tool uses in the transcript, or "unreadable" when the transcript cannot
# be parsed at all. Whitespace, key order, and envelope shape in a third-party CLI's output are
# not a contract, so this parses the stream and walks every nested object rather than matching
# bytes or two known content paths, and an unreadable stream counts as contamination: a guard
# that cannot see must not clear the run.
count_tool_uses() {
  python3 - "$1" <<'PY'
import json, sys

def tool_uses(node):
    if isinstance(node, dict):
        found = 1 if node.get("type") == "tool_use" else 0
        return found + sum(tool_uses(value) for value in node.values())
    if isinstance(node, list):
        return sum(tool_uses(item) for item in node)
    return 0

uses = 0
events = 0
broken = False
try:
    stream = open(sys.argv[1], encoding="utf-8")
except OSError:
    print("unreadable")
    sys.exit(0)
for line in stream:
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except ValueError:
        broken = True
        continue
    if not isinstance(event, dict):
        broken = True
        continue
    events += 1
    uses += tool_uses(event)
print("unreadable" if broken or events == 0 else uses)
PY
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
  echo "key content scan:  $KEY_SCAN"
  echo "key in prompt:     $(grep -c 'SEALED-expected-answers' "$out/prompt.md" | tr -d ' ') references"
  echo "learnings path:    $LEARNINGS"
  echo "learnings in prompt: $(grep -c 'data/learnings.md' "$out/prompt.md" | tr -d ' ') references"
  echo "cwd during run:    an empty temporary directory, removed after the run"
}

# --- entry ------------------------------------------------------------------------------

case ${1:---help} in
  --help|-h|help) usage ;;
  prompt) guard_fixture; guard_procedure; guarded_prompt emit ;;
  check) guard_fixture; guard_procedure; guarded_prompt
         echo "isolation guards pass"
         echo "key content scan: $KEY_SCAN" ;;
  run) shift; run_agent "$@" ;;
  *) die "unknown command: $1" ;;
esac
