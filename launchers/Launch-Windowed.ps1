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

Start-Process -FilePath $game -ArgumentList $arguments -WorkingDirectory $PSScriptRoot
