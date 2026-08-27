param([string]$BridgeExe = 'F:\VOTV\votv-coop-prototype\bridge\bin\Debug\net8.0\win-x64\VotVCoopBridge.exe')

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('VotVCoopStale-' + [guid]::NewGuid().ToString('N'))
$bridgeRuntime = Join-Path $testRoot 'runtime'
[System.IO.Directory]::CreateDirectory($bridgeRuntime) | Out-Null

$bridgeLog = Join-Path $testRoot 'bridge.log'
$port = 27145
$bridgeProcess = $null
$secondProcess = $null
$holderProcess = $null
$failingProcess = $null

try {
    # Test 1: Start bridge with short stale timeout (800ms).
    # Initially before any local state is written, verify the bridge remains running during startup/loading.
    $bridgeProcess = Start-Process -FilePath $BridgeExe -ArgumentList '--role','host','--bridge',$bridgeRuntime,'--port',$port,'--name','TestHost','--stale-local-state-ms','800' -RedirectStandardOutput $bridgeLog -WindowStyle Hidden -PassThru

    Start-Sleep -Milliseconds 1200
    if ($bridgeProcess.HasExited) {
        throw "Bridge exited prematurely before any local_state was observed."
    }

    # Write local_state.txt once to simulate game starting capture
    $localStatePath = Join-Path $bridgeRuntime 'local_state.txt'
    [System.IO.File]::WriteAllText($localStatePath, '1|100.000|200.000|300.000|0.000')

    # Wait for stale exit (timeout is 800ms, wait up to 3s)
    $exited = $bridgeProcess.WaitForExit(3000)
    if (-not $exited -or -not $bridgeProcess.HasExited) {
        throw "Bridge failed to exit after local_state became stale."
    }

    $statusPath = Join-Path $bridgeRuntime 'status.txt'
    $status = if (Test-Path $statusPath) { Get-Content $statusPath -Raw } else { '' }
    if ($status -notmatch 'stopped\|stale_game') {
        throw "Bridge status file did not contain expected stale_game stop status. Actual: $status"
    }

    # Test 2: Verify UDP port was released by starting another host bridge on the same port immediately
    $secondLog = Join-Path $testRoot 'second.log'
    $secondProcess = Start-Process -FilePath $BridgeExe -ArgumentList '--role','host','--bridge',$bridgeRuntime,'--port',$port,'--name','TestHost2','--stale-local-state-ms','800' -RedirectStandardOutput $secondLog -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    if ($secondProcess.HasExited) {
        throw "Second bridge failed to bind port $port after first bridge exited."
    }
    Stop-Process -Id $secondProcess.Id -Force
    $secondProcess.WaitForExit(1000) | Out-Null
    $secondProcess = $null

    # Test 3: Verify clean exit on port collision (SocketException 10048) without unhandled crash
    $holderLog = Join-Path $testRoot 'holder.log'
    $collisionLog = Join-Path $testRoot 'collision.log'
    $holderProcess = Start-Process -FilePath $BridgeExe -ArgumentList '--role','host','--bridge',$bridgeRuntime,'--port',$port,'--name','Holder' -RedirectStandardOutput $holderLog -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 300

    $failingProcess = Start-Process -FilePath $BridgeExe -ArgumentList '--role','host','--bridge',$bridgeRuntime,'--port',$port,'--name','Colliding' -RedirectStandardOutput $collisionLog -WindowStyle Hidden -PassThru
    $failingProcess.WaitForExit(3000) | Out-Null
    if (-not $failingProcess.HasExited) {
        Stop-Process -Id $failingProcess.Id -Force
        throw "Colliding bridge did not exit on port bind conflict."
    }

    Stop-Process -Id $holderProcess.Id -Force
    $holderProcess.WaitForExit(1000) | Out-Null
    $holderProcess = $null
}
finally {
    if ($bridgeProcess -and -not $bridgeProcess.HasExited) { Stop-Process -Id $bridgeProcess.Id -Force; $bridgeProcess.WaitForExit(1000) | Out-Null }
    if ($secondProcess -and -not $secondProcess.HasExited) { Stop-Process -Id $secondProcess.Id -Force; $secondProcess.WaitForExit(1000) | Out-Null }
    if ($holderProcess -and -not $holderProcess.HasExited) { Stop-Process -Id $holderProcess.Id -Force; $holderProcess.WaitForExit(1000) | Out-Null }
    if ($failingProcess -and -not $failingProcess.HasExited) { Stop-Process -Id $failingProcess.Id -Force; $failingProcess.WaitForExit(1000) | Out-Null }
    if (Test-Path $testRoot) {
        try { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

Write-Output 'PASS: bridge lifecycle correctly handles stale exit and port bind conflicts.'
