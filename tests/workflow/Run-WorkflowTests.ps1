[CmdletBinding()]
param([string]$PythonPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$results = [System.Collections.Generic.List[object]]::new()
$failed = $false

function Invoke-Suite([string]$Name, [scriptblock]$Action) {
    try {
        & $Action
        if ($LASTEXITCODE -ne 0) {
            $script:failed = $true
            $script:results.Add([pscustomobject]@{ Suite = $Name; Status = 'FAIL'; Detail = "exit $LASTEXITCODE" }) | Out-Null
        }
        else {
            $script:results.Add([pscustomobject]@{ Suite = $Name; Status = 'PASS'; Detail = 'exit 0' }) | Out-Null
        }
    }
    catch {
        $script:failed = $true
        $script:results.Add([pscustomobject]@{ Suite = $Name; Status = 'FAIL'; Detail = $_.Exception.Message }) | Out-Null
    }
}

function Find-Python {
    if ($PythonPath) {
        if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) { return $null }
        return (Resolve-Path -LiteralPath $PythonPath).Path
    }
    foreach ($name in @('python','py','python3')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $command) { continue }
        try {
            & $command.Source --version 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { return $command.Source }
        }
        catch {
            continue
        }
    }
    return $null
}

function Find-PowerShell {
    $command = Get-Command 'pwsh' -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return (Get-Process -Id $PID).Path
}

$powerShell = Find-PowerShell
Invoke-Suite 'AntigravityWorker' { & $powerShell -NoProfile -File (Join-Path $PSScriptRoot 'Test-AntigravityWorker.ps1') }

$python = Find-Python
if ($null -eq $python) {
    $results.Add([pscustomobject]@{ Suite = 'Research'; Status = 'SKIPPED'; Detail = 'working Python not configured' }) | Out-Null
}
else {
    Invoke-Suite 'Research' { & $python -m unittest (Join-Path $PSScriptRoot 'test_research.py') -v }
}

Invoke-Suite 'Review' { & $powerShell -NoProfile -File (Join-Path $PSScriptRoot 'Test-Review.ps1') }

$results | Format-Table -AutoSize
if ($failed) { exit 1 }
exit 0
