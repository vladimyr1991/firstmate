#!/usr/bin/env python3
"""Validate the structural readiness of an implementation specification."""

from __future__ import annotations

import re
import sys
from pathlib import Path


REQUIRED_SECTIONS = [
    "Readiness",
    "Goal and outcome",
    "Current state",
    "Desired behavior",
    "Scope",
    "Detailed requirements",
    "Interfaces and data contracts",
    "UI and interaction specification",
    "Edge cases and failure behavior",
    "Non-functional requirements",
    "Implementation boundaries",
    "Acceptance criteria",
    "Verification plan",
    "Delivery, rollout, and rollback",
    "Risks and open questions",
    "Implementer handoff",
]


def normalize_heading(value: str) -> str:
    value = re.sub(r"^\d+\.\s*", "", value.strip())
    return re.sub(r"\s+", " ", value).casefold()


def validate(text: str) -> list[str]:
    errors: list[str] = []
    headings = {
        normalize_heading(match.group(1))
        for match in re.finditer(r"^##\s+(.+?)\s*$", text, flags=re.MULTILINE)
    }

    for section in REQUIRED_SECTIONS:
        if normalize_heading(section) not in headings:
            errors.append(f"Missing section: {section}")

    status_match = re.search(
        r"^\s*-\s*Status:\s*(READY|BLOCKED)\s*$",
        text,
        flags=re.MULTILINE | re.IGNORECASE,
    )
    if not status_match:
        errors.append("Readiness must contain exactly '- Status: READY' or '- Status: BLOCKED'")
        return errors

    status = status_match.group(1).upper()
    if status == "READY":
        forbidden = re.findall(r"\b(?:TBD|TODO|FIXME)\b", text, flags=re.IGNORECASE)
        if forbidden:
            errors.append("READY spec contains unresolved placeholder(s): TBD/TODO/FIXME")

        blockers = re.search(
            r"^\s*-\s*Blockers:\s*(.+)$", text, flags=re.MULTILINE | re.IGNORECASE
        )
        if not blockers or blockers.group(1).strip().casefold() != "none":
            errors.append("READY spec must declare '- Blockers: none'")

        open_questions = re.search(
            r"^\s*-\s*Open questions:\s*(.+)$",
            text,
            flags=re.MULTILINE | re.IGNORECASE,
        )
        if open_questions and open_questions.group(1).strip().casefold() != "none":
            errors.append("READY spec has open questions; resolve them or mark BLOCKED")

    if not re.search(r"\b(?:FR|API|NFR)-\d+\b", text):
        errors.append("No stable requirement IDs found (for example FR-1)")
    if not re.search(r"^###\s+AC-\d+\b", text, flags=re.MULTILINE):
        errors.append("No acceptance criterion heading found (for example '### AC-1')")
    if not all(re.search(rf"^\s*-\s*{word}\b", text, flags=re.MULTILINE | re.IGNORECASE) for word in ("Given", "When", "Then")):
        errors.append("Acceptance criteria must include Given, When, and Then lines")

    return errors


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: validate_spec.py SPEC.md", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"ERROR: file not found: {path}", file=sys.stderr)
        return 2

    errors = validate(path.read_text(encoding="utf-8"))
    if errors:
        print("INVALID")
        for error in errors:
            print(f"- {error}")
        return 1

    print("VALID: structural readiness checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
