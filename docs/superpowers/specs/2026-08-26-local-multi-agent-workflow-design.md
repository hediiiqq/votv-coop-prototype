# Local Multi-Agent Workflow Design

## Goal

Add a repository-local, Windows-first development workflow in which Codex is the sole orchestrator and quality authority, Antigravity CLI is an optional implementation worker in an isolated Git worktree, and Grok Web is a manual research handoff. The baseline workflow must not require Gemini API, xAI API, API keys, paid orchestration, browser automation, or automatic billing.

## Existing project

The repository is a small Voices of the Void cooperative-play prototype. Its maintained source is organized as `bridge/` (.NET console application), `mod/` (UE4SS Lua), `installer/`, `launchers/`, and `tests/` (PowerShell integration checks). These directories and the existing `.worktrees/go-bridge` worktree remain unchanged except where documentation must describe them.

The main checkout is on `main`, is clean, and has three local commits not present on `origin/main`. New workflow files must preserve that state and must not merge, reset, clean, or rewrite existing history.

## Architecture

Codex remains the only component allowed to define tasks, select an integration branch, create worktrees, judge implementation quality, commit, or merge. Antigravity receives a concrete task document and can edit only a previously created worktree on a `gemini/*` branch. The historical `gemini/` branch prefix is retained as the repository's worker-branch policy even though Google replaced consumer Gemini CLI with Antigravity CLI.

The workflow has four independent units:

1. Repository policy and task contracts in `AGENTS.md` and `tasks/`.
2. A guarded Antigravity worker launcher in `scripts/antigravity-worker.ps1`.
3. A manual Grok Web research handoff in `scripts/research.py`.
4. Project-aware quality-gate discovery and execution in `scripts/review.ps1`.

No unit treats an AI-generated report as proof. Git state, changed-file scope, tests, build results, architecture, and security are verified independently by Codex.

## Antigravity worker

`scripts/antigravity-worker.ps1` accepts a mandatory task file, a mandatory pre-existing worktree, and optional `-DryRun`. It supports Windows PowerShell 5.1 and PowerShell 7 with strict error handling.

Before a live invocation it verifies Git, Node.js/npm, `agy`, local `agy --help`, the task file, and repository/worktree registration. It rejects the primary checkout, detached HEAD, `main`, `master`, branches outside `gemini/*`, and a dirty worktree. It never creates or removes a branch or worktree.

The worker runs from the validated worktree using the locally supported headless interface:

```text
agy -p <worker-prompt> --output-format json
```

The script does not enable `--dangerously-skip-permissions`. The prompt instructs Antigravity to inspect the repository and `AGENTS.md`, remain within the task scope, add or update tests, avoid secrets and unrelated changes, never merge, and report changed files, verification commands, results, and unresolved risks. `-DryRun` performs all validation and prints a redacted launch description and prompt without invoking `agy` or consuming quota.

The process exit code is propagated. A zero exit code proves only that the CLI process completed, not that the implementation is correct.

## Research handoff

`scripts/research.py` uses only the Python standard library. Given a non-empty question, it creates a timestamped Markdown artifact under `tasks/research/`, builds a strict prompt requiring primary sources and direct URLs, and attempts a local clipboard copy without failing if clipboard access is unavailable.

`--open` may open only `https://grok.com/` with the platform browser. The default path is fully offline. The validation mode checks required headings and at least one HTTP/HTTPS URL in a saved response, while explicitly warning that structural validity does not establish truth. The script never reads credentials or cookies, scrapes a website, or calls an xAI endpoint.

Codex independently opens and checks material sources before relying on a Grok response.

## Quality gate

`scripts/review.ps1` discovers commands from files already present in the repository and accepts explicit command overrides. It does not install dependencies. Gates run in this order:

1. Git and diff safety.
2. Tests.
3. Lint.
4. Typecheck.
5. Build.
6. Secret heuristic scan of tracked files.
7. Dependency or security commands already configured by the project.

For this repository, .NET build discovery is based on `bridge/VotVCoopBridge.csproj`. Existing integration tests that require game copies or a prebuilt bridge are reported accurately and are not silently treated as portable unit tests. Missing gates print `SKIPPED (not configured)`. Any configured failing gate produces a nonzero aggregate exit code. The final table uses only PASS, FAIL, and SKIPPED.

Secret scanning inspects tracked text files for high-confidence credential shapes and suspicious assignments without printing matched values. It avoids broad keyword-only matches that would flag documentation discussing secrets.

After the automated gate, Codex separately reviews correctness, scope, architecture, security, error handling, edge cases, dependency changes, API compatibility, performance, and unnecessary complexity.

## Repository configuration and documentation

`.codex/config.toml` contains only documented repository-local settings:

```toml
approval_policy = "on-request"
sandbox_mode = "workspace-write"
```

Operational policy that cannot be expressed safely through Codex configuration belongs in `AGENTS.md`.

`README.md` is extended rather than replaced. It documents the real project layout, offline workflow, current Google migration, installation diagnostics, official installation commands, initial interactive Antigravity login, `/usage`, task/worktree lifecycle, dry-run and live worker commands, Grok handoff, review, diff, commit/merge, cleanup, troubleshooting, and quota limitations.

The README states clearly that Gemini API and Grok API are not used and billing is never enabled automatically.

## Tests

Tests are dependency-free and offline:

- PowerShell test harnesses exercise worker validation, dry-run prompt formation, process exit propagation, review discovery, PASS/FAIL/SKIPPED behavior, and aggregate exit codes using temporary repositories and fake executables.
- Python `unittest` exercises empty questions, prompt structure, safe artifact names, response validation, offline operation, and absence of API/network behavior.
- No test opens a real browser, invokes a model, authenticates, or consumes quota.

Implementation follows red-green-refactor: each behavior test is written and observed failing before the minimal production change is added.

## Smoke test and completion criteria

The free smoke test reports detected versions; runs all offline tests; exercises research creation without `--open`; validates an Antigravity worker dry-run against a temporary registered worktree with fake tool shims; runs quality-gate discovery; and runs `git diff --check`. It reports PASS, FAIL, and SKIPPED without relabeling skipped checks.

The optional live task proposes a small `slugify` change in a separate `gemini/smoke-test` worktree. It is documented but neither created nor run without explicit user permission.

The workflow is complete only when fresh verification succeeds or every failure and skipped gate is disclosed. No commit or merge is performed without explicit user authorization, and worker worktrees or branches are never cleaned up automatically.

## Official sources

- Codex repository configuration: https://learn.chatgpt.com/docs/config-file/config-basic
- Codex configuration reference: https://learn.chatgpt.com/docs/config-file/config-reference
- Google transition announcement: https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/
- Antigravity CLI installation: https://antigravity.google/docs/cli/getting-started
- Antigravity headless mode: https://antigravity.google/docs/cli/headless/
- Antigravity CLI reference: https://antigravity.google/docs/cli/reference/
- Grok consumer plans: https://x.ai/pricing
- xAI API pricing (documented only to distinguish the paid API from the consumer workflow): https://x.ai/api
