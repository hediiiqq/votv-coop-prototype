param([string]$BridgeExe = 'F:\VOTV\prototype\standalone\VotVCoopBridge.exe')

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('VotVCoopTelemetry-' + [guid]::NewGuid().ToString('N'))
$hostRuntime = Join-Path $testRoot 'host'
$clientRuntime = Join-Path $testRoot 'client'
[System.IO.Directory]::CreateDirectory($hostRuntime) | Out-Null
[System.IO.Directory]::CreateDirectory($clientRuntime) | Out-Null
[System.IO.File]::WriteAllText((Join-Path $hostRuntime 'local_state.txt'), '1|0.000|0.000|0.000|0.000')
[System.IO.File]::WriteAllText((Join-Path $clientRuntime 'local_state.txt'), '1|300.000|400.000|0.000|90.000')
$hostLog = Join-Path $testRoot 'host.log'
$clientLog = Join-Path $testRoot 'client.log'
$port = 27119
$hostProcess = $null
$clientProcess = $null

try {
    $hostProcess = Start-Process -FilePath $BridgeExe -ArgumentList '--role','host','--bridge',$hostRuntime,'--port',$port,'--name','TestHost' -RedirectStandardOutput $hostLog -WindowStyle Hidden -PassThru
    $clientProcess = Start-Process -FilePath $BridgeExe -ArgumentList '--role','client','--bridge',$clientRuntime,'--host','127.0.0.1','--port',$port,'--name','TestClient' -RedirectStandardOutput $clientLog -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 100
        $hostOutput = if (Test-Path $hostLog) { Get-Content $hostLog -Raw } else { '' }
        $clientOutput = if (Test-Path $clientLog) { Get-Content $clientLog -Raw } else { '' }
    } while ((($hostOutput -notmatch 'CONNECTED peer=TestClient') -or ($clientOutput -notmatch 'CONNECTED peer=TestHost')) -and [DateTime]::UtcNow -lt $deadline)

    if ($hostOutput -notmatch 'CONNECTED peer=TestClient.*distance=5\.0m') { throw "Host telemetry missing or incorrect:`n$hostOutput" }
    if ($clientOutput -notmatch 'CONNECTED peer=TestHost.*distance=5\.0m') { throw "Client telemetry missing or incorrect:`n$clientOutput" }
}
finally {
    if ($hostProcess -and -not $hostProcess.HasExited) { Stop-Process -Id $hostProcess.Id -Force }
    if ($clientProcess -and -not $clientProcess.HasExited) { Stop-Process -Id $clientProcess.Id -Force }
    if (Test-Path $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Output 'PASS: both bridges print peer telemetry and distance.'
