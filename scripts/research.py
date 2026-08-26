#!/usr/bin/env python3
"""Create and validate a manual Grok Web research handoff."""

from __future__ import annotations

import argparse
import datetime as dt
import pathlib
import re
import subprocess
import sys
import unicodedata
import webbrowser


REQUIRED_SECTIONS = (
    "RESEARCH RESULT",
    "Question:",
    "Sources:",
    "Summary:",
    "Important changes:",
    "Recommendation:",
)


def default_research_dir() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[1] / "tasks" / "research"


def safe_slug(question: str) -> str:
    ascii_text = unicodedata.normalize("NFKD", question).encode("ascii", "ignore").decode("ascii")
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_text.lower()).strip("-")[:60].strip("-")
    reserved = {"con", "prn", "aux", "nul", *(f"com{i}" for i in range(1, 10)), *(f"lpt{i}" for i in range(1, 10))}
    first_component = slug.split("-", 1)[0] if slug else ""
    if not slug or first_component in reserved:
        slug = "research"
    return slug


def build_prompt(question: str) -> str:
    question = question.strip()
    if not question:
        raise ValueError("question must not be empty")
    return f"""Research this current technical question using official primary sources whenever available:

{question}

Requirements:
- Provide direct HTTP/HTTPS URLs, not search-result links.
- Separate confirmed facts, inferences, and uncertainty explicitly.
- Note recent or breaking changes and the date/version they apply to.
- Do not invent a source or claim that a source says more than it does.
- Return exactly this structure:

RESEARCH RESULT

Question:
{question}

Sources:
1. <official primary source URL and title>
2. <additional primary source URL and title>

Summary:
<confirmed facts, then clearly labeled inferences and uncertainty>

Important changes:
<current breaking, version, policy, or availability changes>

Recommendation:
<actionable recommendation and what must still be verified>
"""


def create_artifact(question: str, directory: pathlib.Path | None = None) -> pathlib.Path:
    prompt = build_prompt(question)
    target = directory if directory is not None else default_research_dir()
    target.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    stem = f"{stamp}-{safe_slug(question)}"
    path = target / f"{stem}.md"
    sequence = 2
    while path.exists():
        path = target / f"{stem}-{sequence}.md"
        sequence += 1
    path.write_text(
        "# Grok Web Research Handoff\n\n## Prompt\n\n```text\n"
        + prompt
        + "\n```\n\n## Saved response\n\nPaste the Grok response here, then run validation.\n",
        encoding="utf-8",
    )
    return path


def validate_response(text: str) -> list[str]:
    errors = [f"Missing required section: {section}" for section in REQUIRED_SECTIONS if section not in text]
    if not re.search(r"https?://[^\s)>]+", text):
        errors.append("No HTTP/HTTPS source URL found.")
    return errors


def copy_to_clipboard(text: str) -> bool:
    if sys.platform != "win32":
        return False
    try:
        subprocess.run(["clip.exe"], input=text, text=True, check=True, capture_output=True)
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("question", nargs="?", help="Current technical question for manual Grok Web research")
    parser.add_argument("--open", action="store_true", dest="open_web", help="Open only https://grok.com/")
    parser.add_argument("--validate", type=pathlib.Path, metavar="FILE", help="Validate a saved response file")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.validate is not None:
        try:
            text = args.validate.read_text(encoding="utf-8")
        except OSError as exc:
            print(f"ERROR: unable to read response: {exc}", file=sys.stderr)
            return 2
        errors = validate_response(text)
        if errors:
            for error in errors:
                print(f"ERROR: {error}", file=sys.stderr)
            print("Structural validation does not verify factual accuracy.", file=sys.stderr)
            return 1
        print("PASS: required sections and source URL are present.")
        print("WARNING: structural validation does not verify factual accuracy.")
        return 0

    try:
        prompt = build_prompt(args.question or "")
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    artifact = create_artifact(args.question or "")
    copied = copy_to_clipboard(prompt)
    print(f"Created: {artifact}")
    print("Prompt copied to clipboard." if copied else "Clipboard unavailable; copy the prompt from the artifact.")
    if args.open_web:
        webbrowser.open("https://grok.com/")
        print("Opened: https://grok.com/")
    else:
        print("Offline mode: browser not opened.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
