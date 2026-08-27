[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskPath,

    [Parameter(Mandatory = $true)]
    [string]$WorktreePath,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-CanonicalPath([string]$Path) {
    return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path).TrimEnd('\','/')
}

function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Get-WorktreeRecords([string]$RepositoryPath) {
    $lines = @(git -C $RepositoryPath worktree list --porcelain)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read registered Git worktrees.' }
    $records = @()
    $current = $null
    foreach ($line in $lines) {
        if ($line -like 'worktree *') {
            if ($null -ne $current) { $records += [pscustomobject]$current }
            $current = @{ Path = $line.Substring(9); Branch = ''; Detached = $false }
        }
        elseif ($null -ne $current -and $line -like 'branch refs/heads/*') {
            $current.Branch = $line.Substring(18)
        }
        elseif ($null -ne $current -and $line -eq 'detached') {
            $current.Detached = $true
        }
    }
    if ($null -ne $current) { $records += [pscustomobject]$current }
    return @($records)
}

if (-not (Test-Path -LiteralPath $TaskPath -PathType Leaf)) {
    throw "TASK.md not found: $TaskPath"
}
if (-not (Test-Path -LiteralPath $WorktreePath -PathType Container)) {
    throw "Git worktree not found: $WorktreePath"
}

Assert-Command 'git'
Assert-Command 'node'
Assert-Command 'npm'
Assert-Command 'agy'

$resolvedTask = Get-CanonicalPath $TaskPath
$resolvedWorktree = Get-CanonicalPath $WorktreePath
$topLevel = @(git -C $resolvedWorktree rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or $topLevel.Count -eq 0) { throw "Path is not a Git worktree: $resolvedWorktree" }
$records = @(Get-WorktreeRecords $resolvedWorktree)
if ($records.Count -eq 0) { throw 'No registered Git worktrees were found.' }

$selected = $null
$selectedIndex = -1
$selectedGitDir = @(git -C $resolvedWorktree rev-parse --absolute-git-dir 2>$null)
if ($LASTEXITCODE -ne 0 -or $selectedGitDir.Count -eq 0) { throw 'Unable to identify selected worktree metadata.' }
for ($index = 0; $index -lt $records.Count; $index++) {
    $record = $records[$index]
    $recordGitDir = @(git -C $record.Path rev-parse --absolute-git-dir 2>$null)
    if ($LASTEXITCODE -eq 0 -and $recordGitDir.Count -gt 0 -and
        [string]::Equals($recordGitDir[0], $selectedGitDir[0], [System.StringComparison]::OrdinalIgnoreCase)) {
        $selected = $record
        $selectedIndex = $index
        break
    }
}
if ($null -eq $selected) { throw "Path is not a registered Git worktree: $resolvedWorktree" }

if ($selectedIndex -eq 0) {
    throw 'The primary checkout cannot be used as an Antigravity worker worktree.'
}
if ($selected.Detached -or [string]::IsNullOrWhiteSpace($selected.Branch)) {
    throw 'Detached HEAD is not allowed for an Antigravity worker.'
}
if ($selected.Branch -in @('main','master')) {
    throw "Branch '$($selected.Branch)' is forbidden; main and master are integration branches."
}
if ($selected.Branch -notlike 'gemini/*') {
    throw "Worker branch must match gemini/*; got '$($selected.Branch)'."
}

$status = @(git -C $resolvedWorktree status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect worker worktree status.' }
if ($status.Count -gt 0) { throw "Worker worktree is not clean: $resolvedWorktree" }

$helpText = (& agy --help 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'agy --help failed.' }
if ($helpText -notmatch '(?m)(--prompt|-p\b)') { throw 'Installed agy does not advertise a supported prompt flag.' }
if ($helpText -notmatch '--output-format') { throw 'Installed agy does not advertise --output-format.' }
if ($helpText -notmatch '--add-dir') { throw 'Installed agy does not advertise --add-dir.' }
if ($helpText -notmatch '--mode') { throw 'Installed agy does not advertise --mode.' }

$taskText = Get-Content -LiteralPath $resolvedTask -Raw
$prompt = @"
You are an implementation worker operating only inside the assigned Git worktree: $resolvedWorktree

First inspect the repository and obey every applicable AGENTS.md instruction. Implement only the task below. Do not change unrelated files. Write or update tests for the requested behavior. Do not change main or master, do not merge, and do not add credentials, tokens, or other secrets.

For every terminal command, set the working directory to the exact assigned worktree above. Never use the Antigravity scratch directory. Run exactly ``git status`` as the initial terminal command. Never combine shell commands with semicolons or other command separators. Use file tools, not shell directory-listing commands, to inspect files. Do not run version checks or environment discovery commands. After the initial git status, run only the exact commands explicitly listed under the task's Tests section.

TASK:
$taskText

At the end, return a concise summary, a list of changed files, every verification command and its result, and all unresolved risks. Your report is not proof of correctness; Codex will independently inspect the complete diff and rerun quality gates.
"@

if ($DryRun) {
    Write-Output 'DRY RUN: Antigravity will not be invoked and no quota will be consumed.'
    Write-Output "Worktree: $resolvedWorktree"
    Write-Output "Branch: $($selected.Branch)"
    Write-Output 'Command shape: agy --mode accept-edits --add-dir <worktree> -p <worker-prompt> --output-format json'
    Write-Output 'Worker prompt:'
    Write-Output $prompt
    exit 0
}

$exitCode = 1
Push-Location -LiteralPath $resolvedWorktree
try {
    $resultLines = @(& agy --mode accept-edits --add-dir $resolvedWorktree -p $prompt --output-format json)
    $exitCode = $LASTEXITCODE
    $resultText = $resultLines -join [System.Environment]::NewLine
    if (-not [string]::IsNullOrWhiteSpace($resultText)) { Write-Output $resultText }
    if ($exitCode -eq 0) {
        try {
            $resultEnvelope = $resultText | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw 'Antigravity returned invalid or empty JSON output.'
        }
        if ($resultEnvelope.status -ne 'SUCCESS') {
            throw "Antigravity returned status '$($resultEnvelope.status)'."
        }
        if ([string]::IsNullOrWhiteSpace([string]$resultEnvelope.response)) {
            throw 'Antigravity returned an empty response; a headless permission request may have been soft-denied.'
        }
    }
}
finally {
    Pop-Location
}
exit $exitCode
