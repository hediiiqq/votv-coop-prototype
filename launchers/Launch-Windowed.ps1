param([switch]$ValidateOnly)

$ErrorActionPreference = 'Stop'
$arguments = '-windowed -ResX=960 -ResY=540'

if ($ValidateOnly) {
    Write-Output $arguments
    exit 0
}

$game = Join-Path $PSScriptRoot 'VotV.exe'
if (-not (Test-Path -LiteralPath $game)) {
    Write-Error "VotV.exe not found: $game"
    exit 1
}

$sourceCandidates = @(
    $env:VOTV_COOP_MOD_SCRIPTS,
    $env:VOTV_MOD_SCRIPTS,
    $(if ($env:VOTV_COOP_MOD_PATH) { Join-Path $env:VOTV_COOP_MOD_PATH 'scripts' }),
    $(if ($env:VOTV_MOD_PATH) { Join-Path $env:VOTV_MOD_PATH 'scripts' }),
    (Join-Path $PSScriptRoot '..\votv-coop-prototype\mod\scripts'),
    (Join-Path $PSScriptRoot '..\mod\scripts'),
    (Join-Path $PSScriptRoot '..\..\mod\scripts'),
    (Join-Path $PSScriptRoot 'mod\scripts')
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$sourceScripts = $null
foreach ($candidate in $sourceCandidates) {
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        $sourceScripts = (Resolve-Path -LiteralPath $candidate).Path
        break
    }
}

if ($sourceScripts) {
    $targetScripts = Join-Path $PSScriptRoot 'VotV\Binaries\Win64\Mods\VotVCoopPrototype\scripts'
    if (Test-Path -LiteralPath $targetScripts -PathType Container) {
        Copy-Item -Path (Join-Path $sourceScripts '*.lua') -Destination $targetScripts -Force
    }
}

Start-Process -FilePath $game -ArgumentList $arguments -WorkingDirectory $PSScriptRoot
