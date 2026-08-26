param(
    [string]$ServerRoot = 'F:\VOTV\Server',
    [string]$ClientRoot = 'F:\VOTV\Client'
)

$ErrorActionPreference = 'Stop'

function Read-CoopConfig([string]$root) {
    $path = Join-Path $root 'VotV\Binaries\Win64\Mods\VotVCoopPrototype\config.ini'
    $values = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        if ($line -match '^\s*([^#][^=]*)=(.*)$') {
            $values[$matches[1].Trim().ToLowerInvariant()] = $matches[2].Trim()
        }
    }
    return $values
}

function Assert-Equal($actual, $expected, [string]$message) {
    if ($actual -ne $expected) { throw "$message. Expected '$expected', got '$actual'." }
}

$serverConfig = Read-CoopConfig $ServerRoot
$clientConfig = Read-CoopConfig $ClientRoot
Assert-Equal $serverConfig.role 'host' 'Server role is incorrect'
Assert-Equal $clientConfig.role 'client' 'Client role is incorrect'
Assert-Equal $clientConfig.host '127.0.0.1' 'Local client address is incorrect'
Assert-Equal $clientConfig.port $serverConfig.port 'Server and client ports differ'

foreach ($root in @($ServerRoot, $ClientRoot)) {
    $launcher = Join-Path $root 'Launch-Windowed.ps1'
    if (-not (Test-Path -LiteralPath $launcher)) { throw "Windowed launcher is missing: $launcher" }
    $result = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -ValidateOnly
    if ($LASTEXITCODE -ne 0) { throw "Windowed launcher validation failed: $launcher" }
    Assert-Equal ($result | Select-Object -Last 1) '-windowed -ResX=960 -ResY=540' 'Windowed arguments are incorrect'
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('VotVCoopTest-' + [guid]::NewGuid().ToString('N'))
$serverRuntime = Join-Path $testRoot 'server'
$clientRuntime = Join-Path $testRoot 'client'
[System.IO.Directory]::CreateDirectory($serverRuntime) | Out-Null
[System.IO.Directory]::CreateDirectory($clientRuntime) | Out-Null
$serverBridge = Join-Path $ServerRoot 'VotV\Binaries\Win64\Mods\VotVCoopPrototype\tools\VotVCoopBridge.exe'
$clientBridge = Join-Path $ClientRoot 'VotV\Binaries\Win64\Mods\VotVCoopPrototype\tools\VotVCoopBridge.exe'
$port = [int]$serverConfig.port
$serverProcess = $null
$clientProcess = $null

try {
    $serverProcess = Start-Process -FilePath $serverBridge -ArgumentList '--role','host','--bridge',$serverRuntime,'--port',$port,'--name','TestHost' -WindowStyle Hidden -PassThru
    $clientProcess = Start-Process -FilePath $clientBridge -ArgumentList '--role','client','--bridge',$clientRuntime,'--host','127.0.0.1','--port',$port,'--name','TestClient' -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 100
        $serverStatus = if (Test-Path (Join-Path $serverRuntime 'status.txt')) { Get-Content (Join-Path $serverRuntime 'status.txt') -Raw } else { '' }
        $clientStatus = if (Test-Path (Join-Path $clientRuntime 'status.txt')) { Get-Content (Join-Path $clientRuntime 'status.txt') -Raw } else { '' }
    } while ((($serverStatus -notmatch '^connected\|host') -or ($clientStatus -notmatch '^connected\|client')) -and [DateTime]::UtcNow -lt $deadline)

    if ($serverStatus -notmatch '^connected\|host') { throw "Server bridge did not connect: $serverStatus" }
    if ($clientStatus -notmatch '^connected\|client') { throw "Client bridge did not connect: $clientStatus" }
}
finally {
    if ($serverProcess -and -not $serverProcess.HasExited) { Stop-Process -Id $serverProcess.Id -Force }
    if ($clientProcess -and -not $clientProcess.HasExited) { Stop-Process -Id $clientProcess.Id -Force }
    if (Test-Path $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Output 'PASS: roles, windowed launchers, and local UDP connection are valid.'
