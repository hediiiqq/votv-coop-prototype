# Repository Agent Policy

Codex is the sole orchestrator and final quality authority for this repository.

## Before changing anything

- Inspect existing code, architecture, instructions, Git status, build files, and tests before editing.
- Understand affected data flow and interfaces before proposing or implementing changes.
- Preserve all user changes, including uncommitted work. Never use destructive cleanup, forced checkout, or `git reset --hard`.
- Change only files required by the current task. Avoid optional refactoring and unrelated formatting.

## Task delegation

- Codex may delegate a substantial implementation to official Antigravity CLI when useful; small work stays with Codex.
- Before delegation, Codex must fill `tasks/current.md` with concrete, testable requirements, allowed files, tests, constraints, research, and acceptance criteria.
- Codex creates the worker branch and registered sibling worktree. The worker never selects the integration branch.
- Worker branches must match `gemini/*`; the historical prefix remains repository policy after Google's consumer migration from Gemini CLI to Antigravity CLI.
- Never run a worker in the primary checkout, on `main` or `master`, on detached HEAD, or in a dirty worktree.
- Antigravity must not merge, modify `main`/`master`, create integration branches, commit secrets, or change unrelated files.
- Do not delete worker branches or worktrees automatically. Cleanup is a separate explicit action.

## Verification

- Never trust AI-generated code or an AI text report without independent verification.
- Inspect Git status, the complete diff, and complete changed-file list after worker execution.
- Verify scope against the task and acceptance criteria.
- Run every applicable test, lint, typecheck, build, and configured dependency/security command.
- If a gate is absent, report `SKIPPED (not configured)`; never call an absent or skipped gate successful.
- A configured failing gate blocks completion.
- After automated gates, review correctness, architecture, security, error handling, edge cases, dependencies, API compatibility, performance, and unnecessary complexity.
- Re-run affected checks after every correction.

## Research

- Use current web research only for current documentation, breaking changes, current library versions, API behavior, or other time-sensitive facts.
- Grok Web is a manual secondary research handoff, not an implementation worker.
- Independently open and verify important primary sources from every Grok response before relying on them.
- Do not use xAI API, browser scraping, browser credentials, or unofficial consumer-service automation.

## Secrets and integration

- Never store or print keys, tokens, passwords, browser data, or other credentials.
- The baseline workflow needs no API keys. Future optional integrations must use per-user environment variables or Windows Credential Manager and never print values.
- Codex alone may prepare a commit or merge, only after acceptance criteria and quality gates are satisfied.
- Never merge or commit without explicit user authorization.
