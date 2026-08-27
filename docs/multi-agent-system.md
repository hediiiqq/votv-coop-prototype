# Local Multi-Agent System

## Control flow

```text
USER
  -> CODEX (sole orchestrator and quality authority)
       -> task contract
       -> Git branch + registered sibling worktree
       -> Antigravity CLI implementation worker
       -> manual Grok Web research when current facts matter
       -> tests / lint / typecheck / build / secret / dependency gates
       -> independent correctness, architecture, and security review
       -> user-authorized commit and merge
```

Codex owns every state transition. Antigravity receives a fixed task and preselected worktree; it cannot choose the integration branch or accept its own output. Grok is a manual research assistant and never edits the repository.

## Trust boundaries

- AI output remains untrusted until Codex checks the complete diff and reruns applicable gates.
- The main checkout, main/master branches, existing worktrees, and user changes are protected boundaries.
- Worker execution is restricted to registered, clean `gemini/*` worktrees.
- The worker keeps Antigravity's default review permissions and does not bypass safeguards.
- Research is clipboard/browser handoff only; no consumer endpoint automation occurs.
- No API key, credential, browser data, or secret belongs in the repository or script output.

## Gate semantics

`PASS` means a configured command ran and returned zero. `FAIL` means a configured check failed and blocks completion. `SKIPPED (not configured)` means the project provides no applicable command; it is disclosed and never counted as success.

Automated checks cannot establish architectural fitness. Codex separately evaluates correctness, boundaries, security, error handling, edge cases, dependencies, compatibility, performance, and complexity.

## Google consumer migration

Google stopped serving individual Google AI Pro/Ultra and free accounts through Gemini CLI on June 18, 2026. The official consumer terminal replacement is Antigravity CLI. This repository uses `agy` headless mode after one interactive Google login. Gemini API and paid enterprise keys are outside this workflow.

## Manual operations

- Install and interactively authenticate Antigravity CLI.
- Review current `/usage` quota.
- Paste a generated research prompt into `https://grok.com/` and save the response.
- Authorize any live model smoke test, dependency restore, commit, merge, or cleanup.

Everything else in the baseline test and research-artifact workflow is offline and deterministic.
