# Local Multi-Agent Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dependency-free, Windows-first workflow where Codex orchestrates isolated Antigravity implementation work, manual Grok Web research, and project-aware quality gates.

**Architecture:** Repository policy and task Markdown define the contract. Focused PowerShell and Python scripts validate all external boundaries, while offline test harnesses use temporary Git repositories and fake executables so no model, browser, login, API, or quota is touched.

**Tech Stack:** Windows PowerShell 5.1/PowerShell 7, Python standard library, Git, .NET SDK discovery, Codex repository config.

**Spec:** `docs/superpowers/specs/2026-08-26-local-multi-agent-workflow-design.md`

## Global Constraints

- Preserve the existing clean `main`, its three local commits, and `.worktrees/go-bridge`.
- Do not install dependencies, invoke a model, open a browser, commit, merge, or clean worktrees.
- Do not use Gemini API, xAI API, API keys, cookies, scraping, or automatic billing.
- Codex alone creates tasks/worktrees, reviews results, and may commit or merge after user authorization.
- Every missing quality gate is `SKIPPED (not configured)`, never PASS.

---

### Task 1: Task contracts and repository policy

**Files:**
- Create: `AGENTS.md`
- Create: `tasks/TASK.template.md`
- Create: `tasks/current.md`
- Create: `tasks/research/.gitkeep`

**Interfaces:**
- Consumes: existing repository layout and approved design.
- Produces: the task sections `Task`, `Goal`, `Context`, `Requirements`, `Constraints`, `Files to modify`, `Tests`, `Research`, and `Acceptance criteria`; orchestration rules read by Codex and Antigravity.

- [ ] **Step 1: Add minimal policy and task files**

Write the nine-heading template exactly and an unfilled `current.md` whose fields explain that Codex must replace the instructional text before delegation. Add repository-specific orchestration, scope, verification, quality, secret, worker-branch, and user-authorized merge rules to `AGENTS.md`.

- [ ] **Step 2: Audit the policy against the approved requirements**

Read the complete files and check every required orchestration, verification, secret, branch, and merge rule against the spec. Human-facing policy prose is reviewed directly instead of protected by brittle source-text assertions.

---

### Task 2: Guarded Antigravity worker

**Files:**
- Create: `tests/workflow/Test-AntigravityWorker.ps1`
- Create: `scripts/antigravity-worker.ps1`

**Interfaces:**
- Consumes: `-TaskPath <string>`, `-WorktreePath <string>`, optional `-DryRun`; registered Git worktree on `gemini/*`.
- Produces: validated `agy -p <prompt> --output-format json` invocation, dry-run text, and the child process exit code.

- [ ] **Step 1: Write worker validation tests**

The test harness creates a temporary Git repository, an initial commit, `main`, and registered worktrees for `gemini/test` and invalid branches. Fake `node`, `npm`, and `agy` commands are placed first in a temporary `PATH`. Assertions cover missing task, missing worktree, primary checkout, `main`/`master`, non-`gemini/*`, dirty worktree, safe dry-run, prompt requirements, and fake `agy` exit 23 propagation.

- [ ] **Step 2: Run worker tests and verify RED**

Run: `pwsh -NoProfile -File .\tests\workflow\Test-AntigravityWorker.ps1`

Expected: nonzero exit because `scripts/antigravity-worker.ps1` does not exist.

- [ ] **Step 3: Implement validation helpers**

Implement strict-mode helpers that resolve canonical paths, query `git worktree list --porcelain`, identify the main checkout, read the selected worktree branch, require a clean `git status --porcelain`, and inspect local `agy --help` for `--prompt`/`-p` and `--output-format` before live execution.

- [ ] **Step 4: Implement prompt and launch behavior**

Build a prompt containing the complete task plus explicit scope, test, secret, branch, merge, summary, changed-file, verification-result, and risk instructions. In dry-run, print paths, branch, supported flags, and prompt without calling `agy`. In live mode, `Push-Location` to the worktree, invoke `agy -p $prompt --output-format json`, restore location in `finally`, and `exit $LASTEXITCODE` on failure.

- [ ] **Step 5: Run worker tests and verify GREEN**

Run: `pwsh -NoProfile -File .\tests\workflow\Test-AntigravityWorker.ps1`

Expected: all worker scenarios PASS and overall exit 0.

---

### Task 3: Offline Grok research handoff

**Files:**
- Create: `tests/workflow/test_research.py`
- Create: `scripts/research.py`

**Interfaces:**
- Consumes: positional question, optional `--open`, or `--validate <path>`.
- Produces: `tasks/research/YYYYMMDD-HHMMSS-<safe-slug>.md`, clipboard prompt when available, optional opening of exactly `https://grok.com/`, and structural validation exit status.

- [ ] **Step 1: Write Python unit tests**

Use `unittest`, `tempfile`, and `unittest.mock` to test `build_prompt(question)`, `safe_slug(question)`, `create_artifact(question, root)`, `validate_response(text)`, and `main(argv)`. Assert all required sections, primary-source/direct-URL instructions, safe filenames, empty-question rejection, missing Sources, missing URL, offline operation with `webbrowser.open` uncalled, and source text free of xAI endpoints/API libraries/cookie access.

- [ ] **Step 2: Run research tests and verify RED**

Run using the discovered Python runtime: `python -m unittest .\tests\workflow\test_research.py -v`

Expected: import failure because `scripts/research.py` does not exist.

- [ ] **Step 3: Implement pure research functions**

Implement deterministic prompt generation and validation around these exact response headings: `RESEARCH RESULT`, `Question:`, `Sources:`, `Summary:`, `Important changes:`, and `Recommendation:`. URL validation uses `https?://[^\s)>]+`; artifact slugs use normalized ASCII alphanumerics and hyphens with a bounded fallback of `research`.

- [ ] **Step 4: Implement CLI and safe platform actions**

Use `argparse`, `pathlib`, `datetime`, `subprocess`, and `webbrowser`. Clipboard copy uses `clip.exe` only on Windows with prompt passed over stdin and errors downgraded to a clear warning. `--open` calls `webbrowser.open("https://grok.com/")`. No network library is imported.

- [ ] **Step 5: Run research tests and verify GREEN**

Run: `python -m unittest .\tests\workflow\test_research.py -v`

Expected: all research tests PASS and exit 0.

---

### Task 4: Project-aware review gate

**Files:**
- Create: `tests/workflow/Test-Review.ps1`
- Create: `scripts/review.ps1`

**Interfaces:**
- Consumes: optional repository path and explicit `TestsCommand`, `LintCommand`, `TypecheckCommand`, `BuildCommand`, and `SecurityCommand` overrides.
- Produces: ordered PASS/FAIL/SKIPPED table and aggregate process exit code.

- [ ] **Step 1: Write review behavior tests**

Create temporary Git fixtures and invoke the review script in child PowerShell processes. Test an exit-0 override (PASS), exit-7 override (FAIL and aggregate nonzero), absent commands (SKIPPED, never PASS), `package.json` script discovery, `.csproj` build discovery, and mixed aggregate results. Add a tracked fake credential-shaped file and assert only the filename/reason—not its value—is printed.

- [ ] **Step 2: Run review tests and verify RED**

Run: `pwsh -NoProfile -File .\tests\workflow\Test-Review.ps1`

Expected: nonzero exit because `scripts/review.ps1` does not exist.

- [ ] **Step 3: Implement discovery and gate execution**

Implement exact discovery for npm scripts in `package.json`, PowerShell workflow tests, and `.sln`/`.csproj` build files. Overrides take precedence. Each command runs in a child process, captures only safe status metadata, and records PASS or FAIL; absence records SKIPPED with `not configured`.

- [ ] **Step 4: Implement Git and secret safety**

Require a Git repository, run `git diff --check`, enumerate tracked text files with `git ls-files`, skip binary/oversized files, and scan high-confidence private-key headers, known token prefixes, and credential assignments. Print file and rule identifiers only.

- [ ] **Step 5: Run review tests and verify GREEN**

Run: `pwsh -NoProfile -File .\tests\workflow\Test-Review.ps1`

Expected: all fixture scenarios PASS and exit 0.

---

### Task 5: Codex configuration and operator documentation

**Files:**
- Create: `.codex/config.toml`
- Create: `docs/multi-agent-system.md`
- Modify: `.gitignore`
- Modify: `README.md`

**Interfaces:**
- Consumes: implemented CLI contracts and official URLs from the design.
- Produces: safe repository defaults and complete setup/daily-operation documentation.

- [ ] **Step 1: Add minimal config and extend ignore rules**

Create the two-key TOML file. Append narrow exclusions for `.env`, `.env.*` with a negated example pattern, local credential artifacts, and generated research drafts while retaining `.gitkeep`; do not add broad source-file patterns.

- [ ] **Step 2: Extend README and add system documentation**

Preserve the existing project introduction/build/safety sections, then add verified Windows commands and the complete operator lifecycle. Explain that consumer Gemini CLI OAuth ended June 18, 2026 and that official `agy` is the replacement. Document interactive login and `/usage` as manual steps.

- [ ] **Step 3: Validate configuration and audit documentation**

Run `codex --strict-config --help` from the repository and confirm exit 0. Then review README and system documentation line by line against every documentation requirement in the approved spec.

---

### Task 6: Unified offline smoke test and final review

**Files:**
- Create: `tests/workflow/Run-WorkflowTests.ps1`
- Create: `tasks/OPTIONAL-LIVE-SMOKE.md`
- Modify: earlier files only to fix failures exposed by this task.

**Interfaces:**
- Consumes: all workflow tests and scripts.
- Produces: one offline test entry point, optional unexecuted live task, and fresh verification evidence.

- [ ] **Step 1: Add the unified runner and optional task**

The runner locates PowerShell and Python, runs worker, research, and review suites, prints per-suite PASS/FAIL/SKIPPED, and returns nonzero if any configured suite fails. The optional task uses the standard task format, permits only new slugify implementation/test files, and explicitly says it must not run without user permission.

- [ ] **Step 2: Run the complete offline test suite**

Run: `pwsh -NoProfile -File .\tests\workflow\Run-WorkflowTests.ps1`

Expected: every configured offline suite PASS; unavailable runtime suites SKIPPED with an explicit reason.

- [ ] **Step 3: Run free smoke commands**

Run detected versions, create a research artifact without `--open`, exercise worker `-DryRun` with fake commands and a temporary registered worktree, execute review discovery, and run `git diff --check`. No real `agy` call is permitted.

- [ ] **Step 4: Inspect full scope and security**

Run `git status --short`, `git diff --stat`, `git diff --check`, and `git diff -- . ':(exclude)docs/superpowers/plans/2026-08-26-local-multi-agent-workflow.md'`. Review every changed file for correctness, architecture, error handling, edge cases, dependencies, compatibility, performance, complexity, secret exposure, and unrelated edits.

- [ ] **Step 5: Re-run all applicable quality gates**

Run `pwsh -NoProfile -File .\scripts\review.ps1` and the unified workflow tests again after any fix. Record exact PASS/FAIL/SKIPPED results and do not claim completion if a configured gate fails.
