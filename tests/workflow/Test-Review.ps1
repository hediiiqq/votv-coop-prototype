$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$review = Join-Path $repoRoot 'scripts\review.ps1'
if (-not (Test-Path -LiteralPath $review)) { throw "Review script is missing: $review" }
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('review-test-' + [guid]::NewGuid().ToString('N'))
$script:failures = 0

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { $script:failures++; Write-Error $message -ErrorAction Continue }
}

function New-Fixture([string]$name) {
    $path = Join-Path $tempRoot $name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    git -C $path init -b main | Out-Null
    git -C $path config user.email test@example.invalid
    git -C $path config user.name 'Workflow Test'
    Set-Content -LiteralPath (Join-Path $path 'README.md') -Value 'fixture'
    git -C $path add README.md
    git -C $path commit -m seed | Out-Null
    return $path
}

function Invoke-Review([string[]]$arguments) {
    $output = & pwsh -NoProfile -File $review @arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $fixture = New-Fixture 'basic'

    $result = Invoke-Review @('-RepositoryPath',$fixture,'-TestsCommand','exit 0')
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'Tests\s+PASS') 'Exit-zero override must be PASS.'
    Assert-True ($result.Output -match 'Lint\s+SKIPPED' -and $result.Output -notmatch 'Lint\s+PASS') 'Unconfigured lint must be SKIPPED, never PASS.'

    $result = Invoke-Review @('-RepositoryPath',$fixture,'-TestsCommand','exit 7')
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'Tests\s+FAIL') 'Failing configured gate must fail aggregate status.'

    $projectFixture = New-Fixture 'project'
    Set-Content -LiteralPath (Join-Path $projectFixture 'Sample.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk"></Project>'
    git -C $projectFixture add Sample.csproj
    git -C $projectFixture commit -m project | Out-Null
    $result = Invoke-Review @('-RepositoryPath',$projectFixture,'-DiscoveryOnly')
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'Build\s+DISCOVERED.*dotnet') '.csproj must produce discovered dotnet build.'

    $packageFixture = New-Fixture 'package'
    Set-Content -LiteralPath (Join-Path $packageFixture 'package.json') -Value '{"scripts":{"test":"echo test","lint":"echo lint","typecheck":"echo types","build":"echo build","security":"echo secure"}}'
    git -C $packageFixture add package.json
    git -C $packageFixture commit -m package | Out-Null
    $result = Invoke-Review @('-RepositoryPath',$packageFixture,'-DiscoveryOnly')
    foreach ($gate in 'Tests','Lint','Typecheck','Build','DependencySecurity') {
        Assert-True ($result.Output -match "$gate\s+DISCOVERED") "package.json must discover $gate."
    }

    $secretFixture = New-Fixture 'secret'
    $fakeCredential = 'gh' + 'p_' + '1234567890' + 'abcdefghijklmnopqrstuvwxyz'
    Set-Content -LiteralPath (Join-Path $secretFixture 'credentials.txt') -Value ('api_' + 'key = "' + $fakeCredential + '"')
    git -C $secretFixture add credentials.txt
    git -C $secretFixture commit -m credential | Out-Null
    $result = Invoke-Review @('-RepositoryPath',$secretFixture)
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'SecretScan\s+FAIL') 'Tracked credential shape must fail secret scan.'
    Assert-True ($result.Output -match 'credentials.txt' -and $result.Output -notmatch [regex]::Escape($fakeCredential)) 'Secret scan must name the file without printing the value.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

if ($script:failures -gt 0) { exit 1 }
Write-Output 'PASS: review PASS/FAIL/SKIPPED, discovery, aggregate status, and secret redaction.'
