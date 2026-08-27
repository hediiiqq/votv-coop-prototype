[CmdletBinding()]
param(
    [string]$RepositoryPath = '.',
    [string]$TestsCommand,
    [string]$LintCommand,
    [string]$TypecheckCommand,
    [string]$BuildCommand,
    [string]$SecurityCommand,
    [switch]$DiscoveryOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Add-Result([System.Collections.Generic.List[object]]$Results, [string]$Gate, [string]$Status, [string]$Detail) {
    $Results.Add([pscustomobject]@{ Gate = $Gate; Status = $Status; Detail = $Detail }) | Out-Null
}

function Get-PackageScripts([string]$Root) {
    $path = Join-Path $Root 'package.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $scripts = @{}
    if ($null -ne $json.scripts) {
        foreach ($property in $json.scripts.PSObject.Properties) { $scripts[$property.Name] = [string]$property.Value }
    }
    return $scripts
}

function Find-ProjectFile([string]$Root) {
    $solution = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.sln' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($solution) { return $solution.FullName }
    $project = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.csproj' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/](bin|obj|\.worktrees)[\\/]' } | Select-Object -First 1
    if ($project) { return $project.FullName }
    return $null
}

function Invoke-GateCommand([string]$Command) {
    $shellPath = (Get-Process -Id $PID).Path
    $prevEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $null = & $shellPath -NoProfile -Command $Command 2>&1
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEAP
    }
}

function Invoke-SecretScan([string]$Root) {
    $rules = @(
        @{ Id = 'private-key'; Pattern = '-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----' },
        @{ Id = 'known-token-prefix'; Pattern = '\b(?:gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,})\b' },
        @{ Id = 'credential-assignment'; Pattern = '(?i)\b(?:api[_-]?key|access[_-]?token|password|client[_-]?secret)\s*[:=]\s*["''][^"'']{8,}["'']' }
    )
    $findings = @()
    $tracked = @(git -C $Root ls-files)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate tracked files for secret scan.' }
    foreach ($relative in $tracked) {
        $path = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $item = Get-Item -LiteralPath $path
        if ($item.Length -gt 1MB) { continue }
        if ($item.Extension -match '^\.(exe|dll|pdb|pak|zip|png|jpg|jpeg|gif|ico|pdf)$') { continue }
        try { $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop } catch { continue }
        foreach ($rule in $rules) {
            if ($text -match $rule.Pattern) {
                $findings += [pscustomobject]@{ File = $relative; Rule = $rule.Id }
            }
        }
    }
    return @($findings)
}

$root = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepositoryPath).Path)
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Required command not found: git' }
git -C $root rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) { throw "Not a Git repository: $root" }

$packageScripts = Get-PackageScripts $root
$projectFile = Find-ProjectFile $root
$workflowRunner = Join-Path $root 'tests\workflow\Run-WorkflowTests.ps1'
$commands = [ordered]@{
    Tests = if ($TestsCommand) { @{ Command = $TestsCommand; Detail = 'override' } } elseif ($packageScripts.ContainsKey('test')) { @{ Command = 'npm test'; Detail = 'npm script: test' } } elseif (Test-Path -LiteralPath $workflowRunner) { @{ Command = "& '$workflowRunner'"; Detail = 'PowerShell workflow tests' } } else { $null }
    Lint = if ($LintCommand) { @{ Command = $LintCommand; Detail = 'override' } } elseif ($packageScripts.ContainsKey('lint')) { @{ Command = 'npm run lint'; Detail = 'npm script: lint' } } else { $null }
    Typecheck = if ($TypecheckCommand) { @{ Command = $TypecheckCommand; Detail = 'override' } } elseif ($packageScripts.ContainsKey('typecheck')) { @{ Command = 'npm run typecheck'; Detail = 'npm script: typecheck' } } else { $null }
    Build = if ($BuildCommand) { @{ Command = $BuildCommand; Detail = 'override' } } elseif ($packageScripts.ContainsKey('build')) { @{ Command = 'npm run build'; Detail = 'npm script: build' } } elseif ($projectFile) { @{ Command = "dotnet build '$projectFile' --no-restore"; Detail = 'dotnet build' } } else { $null }
    DependencySecurity = if ($SecurityCommand) { @{ Command = $SecurityCommand; Detail = 'override' } } elseif ($packageScripts.ContainsKey('security')) { @{ Command = 'npm run security'; Detail = 'npm script: security' } } elseif ($packageScripts.ContainsKey('audit')) { @{ Command = 'npm run audit'; Detail = 'npm script: audit' } } else { $null }
}

if ($DiscoveryOnly) {
    $discovered = [System.Collections.Generic.List[object]]::new()
    foreach ($gate in $commands.Keys) {
        if ($null -eq $commands[$gate]) { Add-Result $discovered $gate 'SKIPPED' 'not configured' }
        else { Add-Result $discovered $gate 'DISCOVERED' $commands[$gate].Detail }
    }
    $discovered | Format-Table -AutoSize
    exit 0
}

$results = [System.Collections.Generic.List[object]]::new()
$failed = $false

$prevEAP = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $null = git -C $root diff --check 2>&1
}
finally {
    $ErrorActionPreference = $prevEAP
}
if ($LASTEXITCODE -eq 0) { Add-Result $results 'GitDiffSafety' 'PASS' 'git diff --check' }
else { Add-Result $results 'GitDiffSafety' 'FAIL' 'git diff --check'; $failed = $true }

foreach ($gate in @('Tests','Lint','Typecheck','Build')) {
    $configuration = $commands[$gate]
    if ($null -eq $configuration) { Add-Result $results $gate 'SKIPPED' 'not configured'; continue }
    $exitCode = Invoke-GateCommand $configuration.Command
    if ($exitCode -eq 0) { Add-Result $results $gate 'PASS' $configuration.Detail }
    else { Add-Result $results $gate 'FAIL' "$($configuration.Detail); exit $exitCode"; $failed = $true }
}

$findings = @(Invoke-SecretScan $root)
if ($findings.Count -eq 0) { Add-Result $results 'SecretScan' 'PASS' 'tracked files; no high-confidence matches' }
else {
    Add-Result $results 'SecretScan' 'FAIL' "$($findings.Count) high-confidence match(es)"
    foreach ($finding in $findings) { Write-Warning "Potential credential: file=$($finding.File); rule=$($finding.Rule)" }
    $failed = $true
}

$security = $commands.DependencySecurity
if ($null -eq $security) { Add-Result $results 'DependencySecurity' 'SKIPPED' 'not configured' }
else {
    $exitCode = Invoke-GateCommand $security.Command
    if ($exitCode -eq 0) { Add-Result $results 'DependencySecurity' 'PASS' $security.Detail }
    else { Add-Result $results 'DependencySecurity' 'FAIL' "$($security.Detail); exit $exitCode"; $failed = $true }
}

$results | Format-Table -AutoSize
if ($failed) { exit 1 }
exit 0
