$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$worker = Join-Path $repoRoot 'scripts\antigravity-worker.ps1'
if (-not (Test-Path -LiteralPath $worker)) { throw "Worker script is missing: $worker" }

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agy-worker-test-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $tempRoot 'repo'
$fakeBin = Join-Path $tempRoot 'bin'
$task = Join-Path $tempRoot 'TASK.md'
$agyLog = Join-Path $tempRoot 'agy-invocation.json'
$script:failures = 0

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { $script:failures++; Write-Error $message -ErrorAction Continue }
}

function Invoke-Worker([string[]]$arguments) {
    $ps = if (Get-Command 'pwsh' -ErrorAction SilentlyContinue) { 'pwsh' } else { (Get-Process -Id $PID).Path }
    $prevEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $ps -NoProfile -File $worker @arguments 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    finally {
        $ErrorActionPreference = $prevEAP
    }
}

try {
    New-Item -ItemType Directory -Path $fixture,$fakeBin -Force | Out-Null
    Set-Content -LiteralPath $task -Encoding utf8 -Value "# Task`n`n## Goal`nImplement fixture behavior."
    Set-Content -LiteralPath (Join-Path $fakeBin 'node.cmd') -Encoding ascii -Value "@echo v24.0.0"
    Set-Content -LiteralPath (Join-Path $fakeBin 'npm.cmd') -Encoding ascii -Value "@echo 11.0.0"
    Set-Content -LiteralPath (Join-Path $fakeBin 'agy.ps1') -Encoding utf8 -Value @'
if ($args[0] -eq '--help') {
    Write-Output 'Usage: agy --mode <mode> --add-dir <path> --prompt <text> --output-format json'
    exit 0
}
[pscustomobject]@{
    Cwd = (Get-Location).Path
    Arguments = @($args)
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $env:FAKE_AGY_LOG -Encoding utf8
if ($env:FAKE_AGY_MODE -eq 'empty-success') {
    Write-Output '{"status":"SUCCESS","response":""}'
}
else {
    Write-Output '{"status":"SUCCESS","response":"fixture"}'
}
exit [int]$env:FAKE_AGY_EXIT
'@
    $oldPath = $env:Path
    $env:Path = "$fakeBin;$env:Path"
    $env:FAKE_AGY_EXIT = '0'
    $env:FAKE_AGY_LOG = $agyLog
    $env:FAKE_AGY_MODE = 'success'

    git -C $fixture init -b main | Out-Null
    git -C $fixture config user.email test@example.invalid
    git -C $fixture config user.name 'Workflow Test'
    Set-Content -LiteralPath (Join-Path $fixture 'seed.txt') -Value 'seed'
    git -C $fixture add seed.txt
    git -C $fixture commit -m seed | Out-Null

    $okTree = Join-Path $tempRoot 'wt-ok'
    $badTree = Join-Path $tempRoot 'wt-feature'
    $masterTree = Join-Path $tempRoot 'wt-master'
    git -C $fixture worktree add -b gemini/test $okTree | Out-Null
    git -C $fixture worktree add -b feature/test $badTree | Out-Null
    git -C $fixture worktree add -b master $masterTree | Out-Null

    $result = Invoke-Worker @('-TaskPath',(Join-Path $tempRoot 'missing.md'),'-WorktreePath',$okTree,'-DryRun')
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'TASK.*not found') 'Missing TASK.md must fail clearly.'

    $result = Invoke-Worker @('-TaskPath',$task,'-WorktreePath',(Join-Path $tempRoot 'absent'),'-DryRun')
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'worktree.*not found') 'Missing worktree must fail clearly.'

    $result = Invoke-Worker @('-TaskPath',$task,'-WorktreePath',$fixture,'-DryRun')
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'primary checkout') "Primary checkout must be rejected. Output: $($result.Output)"

    $result = Invoke-Worker @('-TaskPath',$task,'-WorktreePath',$masterTree,'-DryRun')
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'main|master') 'Main/master branches must be rejected.'

    $result = Invoke-Worker @('-TaskPath',$task,'-WorktreePath',$badTree,'-DryRun')
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'gemini/') "Branches outside gemini/* must be rejected. Output: $($result.Output)"

    Set-Content -LiteralPath (Join-Path $okTree 'dirty.txt') -Value 'dirty'
    $result = Invoke-Worker @('-TaskPath',$task,'-WorktreePath',$okTree,'-DryRun')
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'not clean') "Dirty worktrees must be rejected. Output: $($result.Output)"
    Remove-Item -LiteralPath (Join-Path $okTree 'dirty.txt')

    $result = Invoke-Worker @('-TaskPath',$task,'-WorktreePath',$okTree,'-DryRun')
    Assert-True ($result.ExitCode -eq 0) "A valid dry-run must succeed. Output: $($result.Output)"
    Assert-True ($result.Output -match 'DRY RUN' -and $result.Output -match 'Implement fixture behavior') 'Dry-run must show the task-derived prompt.'
    Assert-True ($result.Output -match 'changed files' -and $result.Output -match 'unresolved risks') 'Worker prompt must require changed files and risks.'

    $result = Invoke-Worker @('-TaskPath',$task,'-WorktreePath',$okTree)
    Assert-True ($result.ExitCode -eq 0) "A valid live invocation must succeed. Output: $($result.Output)"
    $invocation = Get-Content -Raw -LiteralPath $agyLog | ConvertFrom-Json
    $addDirIndex = [array]::IndexOf([object[]]$invocation.Arguments, '--add-dir')
    Assert-True ($addDirIndex -ge 0 -and $invocation.Arguments[$addDirIndex + 1] -eq $okTree) 'Worker must bind Antigravity to the selected worktree with --add-dir.'
    $modeIndex = [array]::IndexOf([object[]]$invocation.Arguments, '--mode')
    Assert-True ($modeIndex -ge 0 -and $invocation.Arguments[$modeIndex + 1] -eq 'accept-edits') 'Worker must allow workspace file edits without interactive artifact prompts.'
    $promptArgument = @($invocation.Arguments | Where-Object { $_ -match 'implementation worker' }) | Select-Object -First 1
    Assert-True ($promptArgument -match [regex]::Escape($okTree) -and $promptArgument -match 'run exactly `git status`' -and $promptArgument -match 'Never combine shell commands') 'Worker prompt must pin command execution to the worktree and deterministic single commands.'
    Assert-True ($promptArgument -match 'Do not run version checks' -and $promptArgument -match 'only.*commands.*Tests') 'Worker prompt must prohibit unapproved discovery commands and restrict execution to the task test commands.'

    $env:FAKE_AGY_MODE = 'empty-success'
    $result = Invoke-Worker @('-TaskPath',$task,'-WorktreePath',$okTree)
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'empty response|permission') 'Empty SUCCESS output must fail because it can represent a headless permission soft-deny.'

    $env:FAKE_AGY_MODE = 'success'
    $env:FAKE_AGY_EXIT = '23'
    $result = Invoke-Worker @('-TaskPath',$task,'-WorktreePath',$okTree)
    Assert-True ($result.ExitCode -eq 23) 'The worker must propagate a nonzero agy exit code.'
}
finally {
    $env:Path = $oldPath
    Remove-Item Env:FAKE_AGY_EXIT -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_AGY_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_AGY_MODE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

if ($script:failures -gt 0) { exit 1 }
Write-Output 'PASS: Antigravity worker validation, prompt, dry-run, and exit propagation.'
