# VotV Coop Prototype

Experimental LAN cooperative-play prototype for Voices of the Void 0.9.x, with a repository-local workflow for reviewed AI-assisted development.

## Current state and layout

The prototype exchanges UDP handshake, heartbeat, player position, and yaw through a .NET companion and UE4SS Lua bridge. It is not full multiplayer; world interactions, inventories, saves, events, and a visible replicated character remain future work.

- `bridge/` — .NET UDP companion source.
- `mod/` — UE4SS Lua mod.
- `installer/`, `launchers/` — setup and windowed launch helpers.
- `tests/` — integration checks and offline workflow tests.
- `tasks/` — worker task contract and manual research artifacts.
- `scripts/` — guarded worker, research handoff, and quality gate.
- `.codex/` — minimal trusted repository settings.
- `docs/multi-agent-system.md` — architecture and trust boundaries.

## Architecture, cost, and authorization

Codex is the only orchestrator and final reviewer. It may create a `gemini/*` branch and sibling worktree, then call official Antigravity CLI as an implementation worker. Grok research uses the free consumer page through a manual clipboard handoff. Git and `scripts/review.ps1` provide verification evidence.

The baseline does **not** use Gemini API, `GEMINI_API_KEY`, xAI API, `XAI_API_KEY`, paid AI orchestration, VPS, n8n, or automatic billing. Scripts cannot enable billing. Consumer and subscription quotas are finite and may change.

Google ended Gemini CLI service for individual Google AI Pro/Ultra and free accounts on June 18, 2026. This repository uses Google's official replacement, Antigravity CLI (`agy`), with interactive Google sign-in. Gemini CLI is not a supported consumer worker path.

## Diagnose installed tools

Open a fresh PowerShell after installation:

```powershell
git --version
node --version
npm --version
python --version
code --version
codex --version
agy --version
dotnet --version
```

When this workflow was created, Git, Node.js/npm, VS Code, Codex, PowerShell 7, and .NET were present. A working system Python and `agy` still required verification.

## Official Windows installation commands

Install only missing tools. `winget` generally supports per-user installation, but installers or local policy may show UAC. Review remote scripts before execution in security-sensitive environments.

```powershell
winget install --id Git.Git -e
winget install --id OpenJS.NodeJS.LTS -e
winget install --id Python.Python.3.13 -e
winget install --id Microsoft.VisualStudioCode -e
powershell -ExecutionPolicy ByPass -c "irm https://chatgpt.com/codex/install.ps1 | iex"
irm https://antigravity.google/cli/install.ps1 | iex
```

Sources: [Codex installation](https://github.com/openai/codex), [Codex config](https://learn.chatgpt.com/docs/config-file/config-basic), [Antigravity installation](https://antigravity.google/docs/cli/getting-started), [Antigravity headless mode](https://antigravity.google/docs/cli/headless/), [Google migration](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/), [Grok consumer plans](https://x.ai/pricing), [paid xAI API](https://x.ai/api).

## First Antigravity login and quota

Run `agy` interactively inside the repository, sign in with Google, and approve repository trust. Credentials are cached by the official client; repository scripts never read them. Use `/usage` (alias `/quota`) in the TUI to inspect current quota. Do not infer unlimited quota from a successful login.

The following headless check consumes quota and is not part of the default smoke test:

```powershell
agy -p "Reply with one word: ready" --output-format json
```

## Task, branch, and worktree

Copy the template, then replace every placeholder with concrete requirements:

```powershell
Copy-Item .\tasks\TASK.template.md .\tasks\current.md -Force
notepad .\tasks\current.md
git status --short
git branch gemini/task-001
git worktree add ..\votv-coop-task-001 gemini/task-001
```

Codex, not Antigravity, selects the branch/worktree. Use a sibling path outside the main checkout.

## Worker dry-run and live run

Dry-run validates tools, `agy --help`, registration, branch, checkout, and cleanliness without invoking a model:

```powershell
pwsh -NoProfile -File .\scripts\antigravity-worker.ps1 `
  -TaskPath .\tasks\current.md `
  -WorktreePath ..\votv-coop-task-001 `
  -DryRun
```

After reviewing the prompt, a user-authorized live run is:

```powershell
pwsh -NoProfile -File .\scripts\antigravity-worker.ps1 `
  -TaskPath .\tasks\current.md `
  -WorktreePath ..\votv-coop-task-001
```

The worker report is not proof. Codex must inspect status, the complete changed-file list, the full diff, and all applicable gates.

## Manual Grok Web research

Default operation is offline: it writes an artifact and attempts to copy its prompt to the Windows clipboard.

```powershell
python .\scripts\research.py "What breaking changes affect the current library version?"
python .\scripts\research.py "What breaking changes affect the current library version?" --open
python .\scripts\research.py --validate .\tasks\research\<saved-response>.md
```

`--open` opens only `https://grok.com/`. Paste manually, save the response, and validate its structure. Structural validation does not establish factual accuracy; Codex independently opens important primary sources.

## Quality gates and diff

```powershell
pwsh -NoProfile -File .\scripts\review.ps1 -DiscoveryOnly
pwsh -NoProfile -File .\scripts\review.ps1
pwsh -NoProfile -File .\tests\workflow\Run-WorkflowTests.ps1
```

Explicit overrides are supported:

```powershell
pwsh -NoProfile -File .\scripts\review.ps1 `
  -TestsCommand 'pwsh -NoProfile -File .\tests\workflow\Run-WorkflowTests.ps1' `
  -BuildCommand 'dotnet build .\bridge\VotVCoopBridge.csproj --no-restore'
```

Review worker scope before integration:

```powershell
git -C ..\votv-coop-task-001 status --short
git -C ..\votv-coop-task-001 diff --stat main...HEAD
git -C ..\votv-coop-task-001 diff main...HEAD
git -C ..\votv-coop-task-001 diff --check
```

PASS means a configured command returned zero. FAIL blocks completion. SKIPPED means no command is configured and is never equivalent to PASS. Codex separately performs architecture and security review.

## Safe commit, merge, and cleanup

Only after acceptance criteria pass and the user explicitly authorizes integration:

```powershell
git -C ..\votv-coop-task-001 add <reviewed-files>
git -C ..\votv-coop-task-001 commit -m "feat: describe reviewed change"
git status --short
git merge --no-ff gemini/task-001
```

Antigravity never commits to or merges `main`/`master`. Cleanup is a separate explicit action:

```powershell
git worktree remove ..\votv-coop-task-001
git branch -d gemini/task-001
```

Do not force-delete or destructively clean this lifecycle.

## Daily workflow

1. Inspect Git status, instructions, relevant code, architecture, and tests.
2. Fill `tasks/current.md` with testable scope.
3. Create a `gemini/*` branch and sibling worktree.
4. Run worker `-DryRun`; run live only when desired and quota is available.
5. Inspect all changed files and the full diff.
6. Run workflow tests and `scripts/review.ps1`.
7. Perform independent correctness, architecture, and security review.
8. Report exact PASS/FAIL/SKIPPED evidence.
9. Commit, merge, and clean up only with explicit authorization.

## Build

```powershell
dotnet publish .\bridge\VotVCoopBridge.csproj -c Release -r win-x64 --self-contained true -o .\standalone
```

`review.ps1` uses `dotnet build --no-restore` to avoid automatic dependency installation. Missing restore assets therefore produce FAIL until the user authorizes a restore.

## Troubleshooting and free-tier limits

- Newly installed Node, Python, or `agy` not found: open a fresh PowerShell, then run `Get-Command agy -All`.
- Gemini CLI consumer error: this is Google's June 2026 migration, not a broken AI Pro login. Use official `agy`; do not switch this workflow to an API key.
- Worker rejects a path: check `git worktree list --porcelain`, a clean `git status --porcelain`, and a non-primary `gemini/*` branch.
- Headless auth fails: run `agy` interactively once and complete official Google login.
- Quota unavailable: inspect `/usage`, wait for its documented reset, or continue manually. No fallback API or billing is enabled.
- Research validation fails: add required headings and direct URLs, then independently verify them.
- A gate is skipped or build fails: inspect discovery and provide a safe override. Dependencies are never installed automatically.

## Safety and licensing

This repository excludes the game, game assets, PAK files, saves, UE4SS binaries, compiled executables, and credentials. Obtain Voices of the Void and UE4SS separately from official distribution channels.
