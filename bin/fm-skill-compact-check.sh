#!/usr/bin/env bash
# fm-skill-compact-check.sh - guard the mechanical half of a skill rewrite.
#
# Usage:
#   bin/fm-skill-compact-check.sh
#   bin/fm-skill-compact-check.sh --skill <name>...
#   bin/fm-skill-compact-check.sh --root <repo> [--baseline <git-ref>]
#   bin/fm-skill-compact-check.sh --prompt <name>
#
# A skill is prose, and prose cannot be verified by diffing it. Its PURPOSE,
# though, is to make an agent decide correctly, and decisions are testable:
# `tests/skill-scenarios/<skill>.md` owns that behavioral half, answered blind
# on a different vendor from whoever rewrote the skill.
#
# This check owns the mechanical half - the two losses a reader reliably fails
# to notice because nothing in the new text looks wrong:
#
#   1. A DROPPED POINTER. Every file path, script name, flag, environment
#      variable, tool name, and config key named in the baseline must still be
#      named, or be retired on purpose. A skill that no longer names
#      `bin/fm-home-seed.sh` reads perfectly and silently stops routing anyone
#      to the script.
#   2. A DROPPED SAFETY BOUNDARY. Every never/always/must/refuse/stop statement
#      must still be stated, or be retired on purpose. This is the loss the
#      activity is most likely to cause, because a hard rule stated twice looks
#      exactly like the redundancy a compaction pass is hunting.
#
# Boundary matching is a coarse tripwire, not a semantic proof: it pairs a
# baseline statement with a rewritten one by shared keyword family and shared
# significant terms. It catches deletion, which is the failure mode. Whether a
# surviving statement still MEANS the same thing is the scenario suite's job,
# and no amount of string matching substitutes for it.
#
# Size is reported, never enforced by itself: a smaller skill that answers a
# scenario differently is a loss wearing a better number. Estimated tokens come
# from bin/fm-startup-memory-budget-lib.sh, the repository's existing estimator,
# so this check never introduces a second, disagreeing number.
#
# Retirement is the escape hatch, and it is deliberately explicit. A skill
# retires a pointer or a boundary in its own `.agents/skills/<name>/RETIRED.md`,
# which is tracked next to the skill but is NOT loaded at startup, so recording
# why something went away costs no prompt budget:
#
#   - retired-pointer <<bin/fm-gone.sh>>: the script was deleted in PR #123.
#   - retired-boundary <<Never do X.>>: X became impossible in PR #123.
#
# A retired POINTER is an ordinary change. A retired BOUNDARY changes a stated
# safety rule, so this check exits 3 and names it: that class of change goes to
# the captain for merge regardless of how small the diff looks, and a standing
# yolo posture does not cover it.
#
# Collapsing a rule stated three times into a rule stated once is the whole
# point of a compaction, and it is NOT a retirement - the rule still binds. That
# case declares which statement absorbed it:
#
#   - consolidated-boundary <<Never do X, and also Y.>> -> <<Never do X.>>: the
#     Notes summary restated the rule already stated under "Voice".
#
# This is verified rather than trusted: the named survivor must actually appear
# in the rewritten skill and carry the same keyword family, so a deletion cannot
# be laundered into a consolidation by asserting one. Because the rule survives,
# a consolidation is an ordinary change and does not trigger the captain-merge
# exit - which is what keeps that signal meaningful instead of firing on every
# compaction.
#
# `--prompt <name>` prints the blind re-answer prompt: the rewritten skill plus
# the scenario questions, with the expected answers and their anchors stripped
# out. Blindness is the whole point of the exercise, so it is produced here
# rather than assembled by hand each time - a leaked expected answer turns the
# independent re-answer into an expensive way to read your own conclusion back.
#
# Scope is every skill whose SKILL.md differs from the baseline ref, so an
# ordinary skill edit is checked for silent pointer loss too. A skill that
# shrank materially is treated as a compaction and must also carry a scenario
# fixture, because size is only ever half of the acceptance.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE=
SKILLS=
PROMPT_SKILL=

need_value() {  # <flag> <remaining-arg-count>
  [ "$2" -gt 1 ] || {
    printf 'fm-skill-compact-check: %s needs a value\n' "$1" >&2
    exit 2
  }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    # Guard the value before shifting: with the value missing, the loop's
    # trailing `shift` runs at $# = 0, and `set -eu` would exit before the
    # actionable message below could print, leaving a bare exit code.
    --root) need_value --root "$#"; shift; ROOT=$1 ;;
    --baseline) need_value --baseline "$#"; shift; BASELINE=$1 ;;
    --skill) need_value --skill "$#"; shift; SKILLS="${SKILLS}${SKILLS:+ }$1" ;;
    --prompt) need_value --prompt "$#"; shift; PROMPT_SKILL=$1 ;;
    -h|--help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0
      ;;
    *) printf 'fm-skill-compact-check: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$ROOT" ] || { printf 'fm-skill-compact-check: --root needs a path\n' >&2; exit 2; }
ROOT=$(cd "$ROOT" 2>/dev/null && pwd) \
  || { printf 'fm-skill-compact-check: root is not a directory\n' >&2; exit 2; }

# The repository already owns one prompt-size estimator, and a check that
# disagreed with the startup budget about the size of the same file would be
# worse than no number at all. This delegates to it rather than restating
# ceil(bytes / 3) anywhere in this file.
ESTIMATOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-startup-memory-budget-lib.sh"
[ -f "$ESTIMATOR" ] \
  || { printf 'fm-skill-compact-check: estimator library is missing: %s\n' "$ESTIMATOR" >&2; exit 2; }

resolve_baseline() {
  local ref
  if [ -n "$BASELINE" ]; then
    git -C "$ROOT" rev-parse --verify --quiet "$BASELINE^{commit}" >/dev/null \
      || { printf 'fm-skill-compact-check: baseline ref is unresolvable: %s\n' "$BASELINE" >&2; exit 2; }
    printf '%s\n' "$BASELINE"
    return 0
  fi
  # Prefer the branch point over the tip of the default branch: a baseline that
  # includes someone else's later work would attribute their pointer removals
  # to this change.
  for ref in origin/main main origin/master master; do
    if git -C "$ROOT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
      git -C "$ROOT" merge-base "$ref" HEAD 2>/dev/null && return 0
      printf '%s\n' "$ref"
      return 0
    fi
  done
  printf 'fm-skill-compact-check: no default branch found; pass --baseline <git-ref>\n' >&2
  exit 2
}

if [ -n "$PROMPT_SKILL" ]; then
  [ -z "$SKILLS" ] \
    || { printf 'fm-skill-compact-check: --prompt renders one skill; drop --skill\n' >&2; exit 2; }
  # Rendering the prompt reads only the current text and the fixture, so it
  # needs no baseline and stays usable on a detached or baseline-less checkout.
  BASE_REF=
else
  BASE_REF=$(resolve_baseline)
fi

exec python3 - "$ROOT" "$BASE_REF" "$SKILLS" "$ESTIMATOR" "$PROMPT_SKILL" <<'PY'
from __future__ import annotations

import math
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
BASE_REF = sys.argv[2]
ONLY = [s for s in sys.argv[3].split() if s]
ESTIMATOR = sys.argv[4]
PROMPT_SKILL = sys.argv[5]

SKILL_GLOB = ".agents/skills/*/SKILL.md"
SCENARIO_DIR = "tests/skill-scenarios"

# A shrink smaller than this is an ordinary edit that happened to remove a line.
# At or beyond it, the change is a compaction, and a compaction without a
# behavioral fixture is exactly the unverifiable prose diff this check exists to
# refuse.
COMPACTION_SHRINK_RATIO = 0.05

CODE_SPAN_RE = re.compile(r"`([^`\n]+)`")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
SOURCE_SUFFIXES = ("sh", "py", "mjs", "md", "json", "toml", "yaml", "yml")

PATH_ROOTS = (
    "bin/", "docs/", "data/", "state/", "config/", "tests/", "projects/",
    "skills/", ".agents/", ".github/", ".no-mistakes/", "assets/",
)

# Pointer shapes. Each is a distinct way this repository names something an
# agent has to be able to find again after a rewrite.
RE_FLAG = re.compile(r"^--[a-z][a-z0-9-]*$")
RE_ENVVAR = re.compile(r"^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$")
RE_AXITOOL = re.compile(r"^[a-z][a-z0-9-]*-axi$")
RE_KEYVALUE = re.compile(r"^([A-Za-z_][A-Za-z0-9_.-]*)=")
RE_SUFFIXED = re.compile(r"^[A-Za-z0-9_.][A-Za-z0-9_./-]*\.(?:" + "|".join(SOURCE_SUFFIXES) + r")$")
RE_PATHISH = re.compile(r"^[.A-Za-z0-9_][A-Za-z0-9._/*<>-]*$")

RE_TERM = re.compile(r"[a-z][a-z0-9_.-]{3,}")

# Boundary keyword families. Every member of a family matches every other, so a
# rewrite may say "refuses" where the baseline said "refuse" without tripping.
BOUNDARY_FAMILIES = {
    "never": (r"never",),
    "always": (r"always",),
    "must": (r"must",),
    "refuse": (r"refuse", r"refuses", r"refused", r"refusing", r"refusal"),
    "stop": (r"stop", r"stops", r"stopped", r"stopping"),
}
BOUNDARY_RE = {
    family: re.compile(r"(?<![A-Za-z])(?:" + "|".join(words) + r")(?![A-Za-z])", re.IGNORECASE)
    for family, words in BOUNDARY_FAMILIES.items()
}

STOPWORDS = {
    "that", "this", "with", "from", "them", "they", "then", "than", "when",
    "what", "which", "while", "into", "onto", "over", "under", "each", "every",
    "your", "have", "has", "been", "being", "does", "done", "such", "same",
    "also", "only", "just", "more", "most", "less", "very", "will", "would",
    "shall", "should", "could", "because", "before", "after", "until", "unless",
    "rather", "instead", "however", "still", "even", "both", "either", "other",
    "another", "there", "here", "their", "these", "those", "some", "any", "all",
    "its", "it", "for", "and", "the", "not", "but", "are", "was", "were", "one",
    "two", "own", "way", "use", "used", "uses", "using", "make", "makes", "made",
    "keep", "keeps", "kept", "left", "leave", "leaves", "like", "well", "long",
    "back", "down", "part", "case", "time", "line", "lines", "text", "thing",
    "things", "without", "within", "through", "against", "about", "above",
    "below", "again", "already", "never", "always", "must", "refuse", "refuses",
    "refused", "refusing", "refusal", "stop", "stops", "stopped", "stopping",
}

RETIRE_RE = re.compile(r"^\s*-\s+retired-(pointer|boundary)\s+<<(.+?)>>\s*:\s*(\S.*?)\s*$")
CONSOLIDATE_RE = re.compile(
    r"^\s*-\s+consolidated-boundary\s+<<(.+?)>>\s*->\s*<<(.+?)>>\s*:\s*(\S.*?)\s*$"
)
RETIRE_KEYWORDS = ("retired-pointer", "retired-boundary", "consolidated-boundary")


class CheckError(Exception):
    """One deterministic compaction-check failure."""


def fail(message: str) -> None:
    raise CheckError(message)


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(ROOT), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def tracked_skills() -> list[str]:
    proc = git("ls-files", "-z", "--", SKILL_GLOB)
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        fail(f"git ls-files failed: {detail or 'unknown error'}")
    return sorted(p for p in proc.stdout.decode("utf-8").split("\0") if p)


def baseline_text(path: str) -> str | None:
    proc = git("show", f"{BASE_REF}:{path}")
    if proc.returncode != 0:
        return None
    return proc.stdout.decode("utf-8", "replace")


def working_text(path: str) -> str:
    try:
        return (ROOT / path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"cannot read {path}: {exc}")
    return ""  # unreachable; fail() raises


_TOKEN_CACHE: dict[int, int] = {}


def estimated_tokens(text: str) -> int:
    """Prompt-token estimate from the repository's one estimator, never a copy."""
    byte_count = len(text.encode("utf-8"))
    if byte_count in _TOKEN_CACHE:
        return _TOKEN_CACHE[byte_count]
    proc = subprocess.run(
        [
            "bash",
            "-c",
            '. "$1"; fm_startup_memory_estimated_tokens_for_bytes "$2"',
            "estimate",
            ESTIMATOR,
            str(byte_count),
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    value = proc.stdout.decode("utf-8", "replace").strip()
    if proc.returncode != 0 or not value.isdigit():
        detail = proc.stderr.decode("utf-8", "replace").strip()
        fail(f"estimator rejected a byte count of {byte_count}: {detail or 'no output'}")
    _TOKEN_CACHE[byte_count] = int(value)
    return _TOKEN_CACHE[byte_count]


def split_regions(text: str) -> tuple[list[str], list[str]]:
    """Return (prose_lines, code_lines) with fenced blocks separated out."""
    prose: list[str] = []
    code: list[str] = []
    in_fence = False
    for line in text.splitlines():
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        (code if in_fence else prose).append(line)
    return prose, code


def clean_token(raw: str) -> str:
    return raw.strip().strip("\"'`(),;:[]{}").rstrip(".").strip()


def tokenize(chunk: str) -> list[str]:
    out: list[str] = []
    for piece in re.split(r"[\s|]+", chunk):
        token = clean_token(piece)
        if token:
            out.append(token)
    return out


def pointer_from(token: str, *, in_code: bool) -> str | None:
    """The pointer a token names, or None when it names nothing findable."""
    if RE_FLAG.match(token):
        return token
    if RE_SUFFIXED.match(token):
        return token
    if RE_AXITOOL.match(token):
        return token
    if RE_ENVVAR.match(token):
        return token
    if any(token.startswith(root) for root in PATH_ROOTS) and RE_PATHISH.match(token):
        return token
    if in_code:
        match = RE_KEYVALUE.match(token)
        if match:
            # The key is the pointer; the example value beside it is prose.
            return match.group(1) + "="
        if "/" in token and RE_PATHISH.match(token) and not token.startswith("/"):
            return token
    return None


def pointers(text: str) -> set[str]:
    prose, code = split_regions(text)
    found: set[str] = set()

    for line in code:
        for token in tokenize(line):
            ptr = pointer_from(token, in_code=True)
            if ptr:
                found.add(ptr)

    prose_text = "\n".join(prose)
    for span in CODE_SPAN_RE.findall(prose_text):
        for token in tokenize(span):
            ptr = pointer_from(token, in_code=True)
            if ptr:
                found.add(ptr)

    # Unbackticked mentions count too: this repository writes plenty of real
    # pointers as bare prose, and losing one of those is the same loss.
    for token in tokenize(CODE_SPAN_RE.sub(" ", prose_text)):
        ptr = pointer_from(token, in_code=False)
        if ptr:
            found.add(ptr)
    return found


def normalize_statement(line: str) -> str:
    """Whitespace- and emphasis-insensitive form, so a survivor can be named."""
    return re.sub(r"\s+", " ", line.replace("**", "").replace("*", "")).strip()


def declared_matches(baseline_terms: set[str], declared_terms: set[str]) -> bool:
    """Does a RETIRED.md entry name this baseline statement?

    Same threshold as boundary_survives, so declaring a statement is exactly as
    hard as restating it, and a vague entry cannot cover a rule it never named.
    """
    if not baseline_terms or not declared_terms:
        return False
    required = max(1, math.ceil(len(baseline_terms) * 0.5))
    return len(baseline_terms & declared_terms) >= required


def significant_terms(line: str) -> set[str]:
    lowered = line.lower()
    return {t for t in RE_TERM.findall(lowered) if t not in STOPWORDS}


def statement_lines(text: str) -> list[str]:
    """Prose statements. This repository writes one sentence per line."""
    prose, _ = split_regions(text)
    out: list[str] = []
    for line in prose:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("---"):
            continue
        out.append(re.sub(r"^[-*+]\s+|^\d+\.\s+", "", stripped))
    return out


def boundaries(text: str) -> list[tuple[str, str, set[str]]]:
    """(family, statement, terms) for every statement that states a boundary."""
    out: list[tuple[str, str, set[str]]] = []
    for line in statement_lines(text):
        for family, pattern in BOUNDARY_RE.items():
            if pattern.search(line):
                out.append((family, line, significant_terms(line)))
    return out


def boundary_survives(family: str, terms: set[str], candidates: list[tuple[str, set[str]]]) -> bool:
    if not terms:
        # A boundary with nothing but keyword and stopwords carries no
        # matchable content; the family surviving anywhere is all this check
        # can honestly assert about it.
        return any(cand_family == family for cand_family, _ in candidates)
    required = max(1, math.ceil(len(terms) * 0.5))
    for cand_family, cand_terms in candidates:
        if cand_family != family:
            continue
        if len(terms & cand_terms) >= required:
            return True
    return False


def load_retirements(skill: str) -> tuple[dict[str, str], list[tuple[str, str]], list[tuple[str, str]]]:
    path = ROOT / ".agents/skills" / skill / "RETIRED.md"
    retired_pointers: dict[str, str] = {}
    retired_boundaries: list[tuple[str, str]] = []
    consolidated: list[tuple[str, str]] = []
    if not path.exists():
        return retired_pointers, retired_boundaries, consolidated
    if path.is_symlink() or not path.is_file():
        fail(f"{skill}: RETIRED.md must be an ordinary file")
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"{skill}: cannot read RETIRED.md: {exc}")
    for number, line in enumerate(lines, start=1):
        if not any(keyword in line for keyword in RETIRE_KEYWORDS):
            continue
        consolidation = CONSOLIDATE_RE.match(line)
        if consolidation:
            subject = consolidation.group(1).strip()
            survivor = consolidation.group(2).strip()
            reason = consolidation.group(3).strip()
            if not subject or not survivor:
                fail(f"{skill}: RETIRED.md line {number} consolidates an empty statement")
            if len(reason) < 8:
                fail(f"{skill}: RETIRED.md line {number} needs a real reason, not {reason!r}")
            consolidated.append((subject, survivor))
            continue
        match = RETIRE_RE.match(line)
        if not match:
            fail(
                f"{skill}: RETIRED.md line {number} is not a retirement entry; "
                "use `- retired-pointer <<subject>>: reason`, "
                "`- retired-boundary <<subject>>: reason`, or "
                "`- consolidated-boundary <<subject>> -> <<survivor>>: reason`"
            )
        kind, subject, reason = match.group(1), match.group(2).strip(), match.group(3).strip()
        if not subject:
            fail(f"{skill}: RETIRED.md line {number} retires an empty subject")
        if len(reason) < 8:
            fail(f"{skill}: RETIRED.md line {number} needs a real reason, not {reason!r}")
        if kind == "pointer":
            retired_pointers[subject] = reason
        else:
            retired_boundaries.append((subject, reason))
    return retired_pointers, retired_boundaries, consolidated


def scenario_path(skill: str) -> Path:
    return ROOT / SCENARIO_DIR / f"{skill}.md"


def validate_scenarios(skill: str) -> int:
    """Count of well-formed scenarios, or fail with what the fixture is missing."""
    path = scenario_path(skill)
    if not path.is_file():
        fail(
            f"{skill}: shrank materially with no behavioral fixture at "
            f"{SCENARIO_DIR}/{skill}.md; size alone is not acceptance"
        )
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"{skill}: cannot read {SCENARIO_DIR}/{skill}.md: {exc}")
    ids = re.findall(r"^##\s+(S\d+)\b", text, re.MULTILINE)
    if not ids:
        fail(f"{skill}: {SCENARIO_DIR}/{skill}.md declares no `## S<n>` scenario")
    duplicates = sorted({i for i in ids if ids.count(i) > 1})
    if duplicates:
        fail(f"{skill}: duplicate scenario ids in {SCENARIO_DIR}/{skill}.md: {', '.join(duplicates)}")
    for label in ("**Question:**", "**Expected answer:**"):
        if text.count(label) != len(ids):
            fail(
                f"{skill}: {SCENARIO_DIR}/{skill}.md has {len(ids)} scenarios but "
                f"{text.count(label)} `{label}` fields; every scenario needs exactly one"
            )
    return len(ids)


SCENARIO_HEADING_RE = re.compile(r"^##\s+(S\d+)\b\s*-?\s*(.*)$")
BLIND_FIELDS = ("**Situation:**", "**Question:**")


def render_blind_prompt(skill: str) -> str:
    """The rewritten skill plus questions only - never the recorded answers."""
    skill_path = ROOT / ".agents/skills" / skill / "SKILL.md"
    if not skill_path.is_file():
        fail(f"no such tracked skill: {skill}")
    fixture = scenario_path(skill)
    if not fixture.is_file():
        fail(f"{skill}: no scenario fixture at {SCENARIO_DIR}/{skill}.md")
    try:
        skill_text = skill_path.read_text(encoding="utf-8")
        fixture_text = fixture.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"{skill}: cannot read prompt inputs: {exc}")

    questions: list[str] = []
    current: list[str] = []
    keep = False
    for line in fixture_text.splitlines():
        heading = SCENARIO_HEADING_RE.match(line)
        if heading:
            if current:
                questions.append("\n".join(current).strip())
            current = [f"### {heading.group(1)} - {heading.group(2)}".rstrip(" -")]
            keep = False
            continue
        if not current:
            continue
        if line.startswith("**"):
            keep = any(line.startswith(field) for field in BLIND_FIELDS)
        if keep:
            current.append(line)
    if current:
        questions.append("\n".join(current).strip())
    if not questions:
        fail(f"{skill}: {SCENARIO_DIR}/{skill}.md declares no `## S<n>` scenario")

    return "\n".join(
        [
            f"You are given one agent instruction document, `{skill}`, and a list of situations.",
            "",
            "Answer each question using ONLY the document below. Do not use prior knowledge of",
            "this repository, and do not guess at what the document probably meant to say: if the",
            "document does not settle a question, answer exactly `NOT STATED` and say what is",
            "missing. Answer each one in two or three sentences, labelled with its scenario id.",
            "",
            f"--- BEGIN {skill} ---",
            skill_text.rstrip("\n"),
            f"--- END {skill} ---",
            "",
            "## Situations",
            "",
            "\n\n".join(questions),
            "",
        ]
    )


def check_skill(skill: str, path: str) -> dict:
    base = baseline_text(path)
    if base is None:
        return {"skill": skill, "state": "new"}
    current = working_text(path)
    if base == current:
        return {"skill": skill, "state": "unchanged"}

    base_tokens = estimated_tokens(base)
    cur_tokens = estimated_tokens(current)
    delta = cur_tokens - base_tokens

    retired_pointers, retired_boundaries, consolidated = load_retirements(skill)

    base_pointers = pointers(base)
    cur_pointers = pointers(current)
    dropped = sorted(p for p in base_pointers - cur_pointers if p not in retired_pointers)
    if dropped:
        shown = ", ".join(dropped[:12])
        more = f" (+{len(dropped) - 12} more)" if len(dropped) > 12 else ""
        fail(
            f"{skill}: {len(dropped)} pointer(s) named in the baseline are gone and not "
            f"retired: {shown}{more}"
        )

    cur_boundaries = [(family, terms) for family, _, terms in boundaries(current)]
    current_statements = {normalize_statement(s) for s in statement_lines(current)}

    # A claimed survivor is checked against the rewritten text, so a deletion
    # cannot be laundered into a consolidation by asserting one.
    absorbed: list[set[str]] = []
    for subject, survivor in consolidated:
        if normalize_statement(survivor) not in current_statements:
            fail(
                f"{skill}: RETIRED.md claims a boundary was consolidated into a statement that "
                f"is not in the rewritten skill: {survivor!r}"
            )
        absorbed.append(significant_terms(subject))

    retired_terms = [(subject, significant_terms(subject)) for subject, _ in retired_boundaries]
    lost: list[str] = []
    for family, statement, terms in boundaries(base):
        if boundary_survives(family, terms, cur_boundaries):
            continue
        if any(declared_matches(terms, stated) for stated in absorbed):
            continue
        if any(declared_matches(terms, rterms) for _, rterms in retired_terms):
            continue
            # One statement can carry two keyword families ("never ... always ...").
        # It is still one lost rule, so report it once.
        if statement not in lost:
            lost.append(statement)
    if lost:
        shown = "; ".join(f'"{s}"' for s in lost[:5])
        more = f" (+{len(lost) - 5} more)" if len(lost) > 5 else ""
        fail(
            f"{skill}: {len(lost)} safety boundary statement(s) from the baseline are gone "
            f"and not retired: {shown}{more}"
        )

    scenarios = 0
    compacted = base_tokens > 0 and (base_tokens - cur_tokens) / base_tokens >= COMPACTION_SHRINK_RATIO
    if compacted:
        scenarios = validate_scenarios(skill)

    return {
        "skill": skill,
        "state": "compacted" if compacted else "changed",
        "base_tokens": base_tokens,
        "tokens": cur_tokens,
        "delta": delta,
        "pointers": len(base_pointers),
        "boundaries": len(boundaries(base)),
        "scenarios": scenarios,
        "retired_pointers": len(retired_pointers),
        "retired_boundaries": [subject for subject, _ in retired_boundaries],
    }


def main() -> int:
    if PROMPT_SKILL:
        try:
            sys.stdout.write(render_blind_prompt(PROMPT_SKILL))
        except CheckError as exc:
            print(f"fm-skill-compact-check: {exc}", file=sys.stderr)
            return 1
        return 0

    try:
        paths = tracked_skills()
    except CheckError as exc:
        print(f"fm-skill-compact-check: {exc}", file=sys.stderr)
        return 1
    if not paths:
        print("fm-skill-compact-check: no tracked skills found under .agents/skills/", file=sys.stderr)
        return 1

    selected = []
    for path in paths:
        name = path[len(".agents/skills/"):-len("/SKILL.md")]
        if "/" in name or not name:
            print(f"fm-skill-compact-check: unexpected skill path layout: {path}", file=sys.stderr)
            return 1
        if ONLY and name not in ONLY:
            continue
        selected.append((name, path))

    unknown = sorted(set(ONLY) - {name for name, _ in selected})
    if unknown:
        print(f"fm-skill-compact-check: no such tracked skill: {', '.join(unknown)}", file=sys.stderr)
        return 2

    results = []
    try:
        for name, path in selected:
            results.append(check_skill(name, path))
    except CheckError as exc:
        print(f"fm-skill-compact-check: {exc}", file=sys.stderr)
        return 1

    changed = [r for r in results if r["state"] in {"changed", "compacted"}]
    for result in sorted(changed, key=lambda r: r["skill"]):
        percent = (result["delta"] / result["base_tokens"] * 100) if result["base_tokens"] else 0.0
        print(
            "fm-skill-compact-check: {skill} {state} baseline_tokens={base} tokens={cur} "
            "delta={delta:+d} ({pct:+.1f}%) pointers={ptr} boundaries={bnd} scenarios={scn}".format(
                skill=result["skill"],
                state=result["state"],
                base=result["base_tokens"],
                cur=result["tokens"],
                delta=result["delta"],
                pct=percent,
                ptr=result["pointers"],
                bnd=result["boundaries"],
                scn=result["scenarios"],
            )
        )

    retired_boundaries = [
        (r["skill"], subject) for r in changed for subject in r["retired_boundaries"]
    ]
    print(
        "fm-skill-compact-check: ok checked={checked} changed={changed} compacted={compacted} "
        "retired_boundaries={rb}".format(
            checked=len(selected),
            changed=len(changed),
            compacted=len([r for r in changed if r["state"] == "compacted"]),
            rb=len(retired_boundaries),
        )
    )

    if retired_boundaries:
        # Not a failure - the retirement is on purpose and documented. It is a
        # routing fact: a changed safety boundary is the captain's merge, and no
        # standing autonomy covers it.
        print(
            "fm-skill-compact-check: CAPTAIN MERGE REQUIRED - this change retires a stated "
            "safety boundary:",
            file=sys.stderr,
        )
        for skill, subject in retired_boundaries:
            print(f"  {skill}: {subject}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
