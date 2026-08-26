# Task

## Goal

Add a small deterministic `slugify` function and offline unit tests as an optional live Antigravity smoke test.

## Context

This task validates the guarded worker lifecycle only after the user installs, authenticates, and explicitly authorizes a live Antigravity run.

## Requirements

- Convert ASCII text to lowercase hyphen-separated slugs.
- Collapse repeated separators and trim surrounding separators.
- Return `item` when no ASCII alphanumeric characters remain.

## Constraints

- Do not run without explicit user authorization.
- Work only in a separately created `gemini/smoke-test` worktree.
- Do not merge or modify main/master.
- Do not add dependencies or secrets.

## Files to modify

- Create one focused slugify implementation file under a new `tools/` directory.
- Create one matching offline test file under `tests/`.

## Tests

Run the new test file and `scripts/review.ps1`. Report exact commands and results.

## Research

No current web research is required.

## Acceptance criteria

- Only the two permitted files change.
- Tests cover normal text, repeated separators, surrounding punctuation, and fallback behavior.
- Configured quality gates pass; absent gates remain skipped.
