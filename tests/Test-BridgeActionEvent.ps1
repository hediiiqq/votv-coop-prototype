param([string]$BridgeExe = 'F:\VOTV\votv-coop-prototype\bridge\bin\Debug\net8.0\win-x64\VotVCoopBridge.exe')

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('VotVCoopAction-' + [guid]::NewGuid().ToString('N'))
$hostRuntime = Join-Path $testRoot 'host'
$clientRuntime = Join-Path $testRoot 'client'
[System.IO.Directory]::CreateDirectory($hostRuntime) | Out-Null
[System.IO.Directory]::CreateDirectory($clientRuntime) | Out-Null

$hostLog = Join-Path $testRoot 'host.log'
$clientLog = Join-Path $testRoot 'client.log'
$port = 27123
$hostProcess = $null
$clientProcess = $null

try {
    $hostProcess = Start-Process -FilePath $BridgeExe -ArgumentList '--role','host','--bridge',$hostRuntime,'--port',$port,'--name','TestHost' -RedirectStandardOutput $hostLog -WindowStyle Hidden -PassThru
    $clientProcess = Start-Process -FilePath $BridgeExe -ArgumentList '--role','client','--bridge',$clientRuntime,'--host','127.0.0.1','--port',$port,'--name','TestClient' -RedirectStandardOutput $clientLog -WindowStyle Hidden -PassThru

    # Wait for initial connection
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    $hostStatus = Join-Path $hostRuntime 'status.txt'
    $clientStatus = Join-Path $clientRuntime 'status.txt'
    do {
        Start-Sleep -Milliseconds 100
        $hostStat = if (Test-Path $hostStatus) { Get-Content $hostStatus -Raw } else { '' }
        $clientStat = if (Test-Path $clientStatus) { Get-Content $clientStatus -Raw } else { '' }
    } while ((($hostStat -notmatch '^connected') -or ($clientStat -notmatch '^connected')) -and [DateTime]::UtcNow -lt $deadline)

    if ($hostStat -notmatch '^connected' -or $clientStat -notmatch '^connected') {
        throw "Bridges failed to connect within timeout.`nHost: $hostStat`nClient: $clientStat"
    }

    # Test 1: Host emits action, Client receives remote action
    $hostLocalAction = Join-Path $hostRuntime 'local_action.txt'
    $clientRemoteAction = Join-Path $clientRuntime 'remote_action.txt'
    [System.IO.File]::WriteAllText($hostLocalAction, '1|Ping|100.000|200.000|300.000|45.000')

    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    $clientActionContent = ''
    do {
        Start-Sleep -Milliseconds 50
        if (Test-Path $clientRemoteAction) {
            $clientActionContent = (Get-Content $clientRemoteAction -Raw).Trim()
        }
    } while ($clientActionContent -eq '' -and [DateTime]::UtcNow -lt $deadline)

    $expectedClientAction = 'TestHost|1|Ping|100.000|200.000|300.000|45.000'
    if ($clientActionContent -ne $expectedClientAction) {
        throw "Client did not receive expected remote action.`nExpected: $expectedClientAction`nActual: $clientActionContent"
    }

    # Test 2: Client emits action, Host receives remote action
    $clientLocalAction = Join-Path $clientRuntime 'local_action.txt'
    $hostRemoteAction = Join-Path $hostRuntime 'remote_action.txt'
    [System.IO.File]::WriteAllText($clientLocalAction, '1|Ping|500.000|600.000|700.000|-90.000')

    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    $hostActionContent = ''
    do {
        Start-Sleep -Milliseconds 50
        if (Test-Path $hostRemoteAction) {
            $hostActionContent = (Get-Content $hostRemoteAction -Raw).Trim()
        }
    } while ($hostActionContent -eq '' -and [DateTime]::UtcNow -lt $deadline)

    $expectedHostAction = 'TestClient|1|Ping|500.000|600.000|700.000|-90.000'
    if ($hostActionContent -ne $expectedHostAction) {
        throw "Host did not receive expected remote action.`nExpected: $expectedHostAction`nActual: $hostActionContent"
    }

    # Test 3: Verify state isolation - remote_state.txt must not exist or be corrupted by actions
    $clientRemoteState = Join-Path $clientRuntime 'remote_state.txt'
    $hostRemoteState = Join-Path $hostRuntime 'remote_state.txt'
    if (Test-Path $clientRemoteState) {
        $state = Get-Content $clientRemoteState -Raw
        if ($state -match 'Ping') {
            throw "ACTION packet polluted client remote_state.txt: $state"
        }
    }
    if (Test-Path $hostRemoteState) {
        $state = Get-Content $hostRemoteState -Raw
        if ($state -match 'Ping') {
            throw "ACTION packet polluted host remote_state.txt: $state"
        }
    }
}
finally {
    if ($hostProcess -and -not $hostProcess.HasExited) { Stop-Process -Id $hostProcess.Id -Force; $hostProcess.WaitForExit(1000) | Out-Null }
    if ($clientProcess -and -not $clientProcess.HasExited) { Stop-Process -Id $clientProcess.Id -Force; $clientProcess.WaitForExit(1000) | Out-Null }
    if (Test-Path $testRoot) {
        try { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

Write-Output 'PASS: action event bus transmits actions and preserves state isolation.'
