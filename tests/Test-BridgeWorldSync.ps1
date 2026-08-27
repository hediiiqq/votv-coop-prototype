param([string]$BridgeExe = 'F:\VOTV\votv-coop-prototype\bridge\bin\Debug\net8.0\win-x64\VotVCoopBridge.exe')

$ErrorActionPreference = 'Stop'

function Write-AtomicFile([string]$path, [string]$content) {
    $attempts = 0
    while ($attempts -lt 30) {
        try {
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Dispose()
            return
        } catch {
            Start-Sleep -Milliseconds 10
            $attempts++
        }
    }
    throw "Failed to write to $path after 30 attempts."
}
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('VotVCoopWorld-' + [guid]::NewGuid().ToString('N'))
$hostRuntime = Join-Path $testRoot 'host'
$clientRuntime = Join-Path $testRoot 'client'
$lateClientRuntime = Join-Path $testRoot 'late_client'
$retryClientRuntime = Join-Path $testRoot 'retry_client'

[System.IO.Directory]::CreateDirectory($hostRuntime) | Out-Null
[System.IO.Directory]::CreateDirectory($clientRuntime) | Out-Null
[System.IO.Directory]::CreateDirectory($lateClientRuntime) | Out-Null
[System.IO.Directory]::CreateDirectory($retryClientRuntime) | Out-Null

$hostLog = Join-Path $testRoot 'host.log'
$clientLog = Join-Path $testRoot 'client.log'
$lateClientLog = Join-Path $testRoot 'late_client.log'
$retryClientLog = Join-Path $testRoot 'retry_client.log'

$port = 27150
$retryPort = 27156
$deadPort = 27159

$hostProcess = $null
$clientProcess = $null
$lateClientProcess = $null
$retryClientProcess = $null
$exhaustClientProcess = $null
$mockUdp = $null
$mockDeadUdp = $null

try {
    # -------------------------------------------------------------
    # Initial Setup: Start Host and Client
    # -------------------------------------------------------------
    $hostProcess = Start-Process -FilePath $BridgeExe -ArgumentList '--role','host','--bridge',$hostRuntime,'--port',$port,'--name','TestHost' -RedirectStandardOutput $hostLog -WindowStyle Hidden -PassThru
    $clientProcess = Start-Process -FilePath $BridgeExe -ArgumentList '--role','client','--bridge',$clientRuntime,'--host','127.0.0.1','--port',$port,'--name','TestClient' -RedirectStandardOutput $clientLog -WindowStyle Hidden -PassThru

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

    # -------------------------------------------------------------
    # Test 1: Client emits INTERACT_REQ -> Host receives remote_interact.txt
    # -------------------------------------------------------------
    $clientLocalInteract = Join-Path $clientRuntime 'local_interact.txt'
    $hostRemoteInteract = Join-Path $hostRuntime 'remote_interact.txt'
    [System.IO.File]::WriteAllText($clientLocalInteract, '1|basedoor_signalroom|toggle')

    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    $hostInteractContent = ''
    do {
        Start-Sleep -Milliseconds 50
        if (Test-Path $hostRemoteInteract) {
            $hostInteractContent = (Get-Content $hostRemoteInteract -Raw).Trim()
        }
    } while ($hostInteractContent -eq '' -and [DateTime]::UtcNow -lt $deadline)

    $expectedHostInteract = 'TestClient|1|basedoor_signalroom|toggle'
    if ($hostInteractContent -ne $expectedHostInteract) {
        throw "Host did not receive expected remote interaction.`nExpected: $expectedHostInteract`nActual: $hostInteractContent"
    }

    # Verify ACK and logs for INTERACT_REQ
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    $clientLogContent = ''
    do {
        Start-Sleep -Milliseconds 50
        $clientLogContent = if (Test-Path $clientLog) { Get-Content $clientLog -Raw } else { '' }
    } while ($clientLogContent -notmatch 'WORLD_ACK received for REQ #1' -and [DateTime]::UtcNow -lt $deadline)

    if ($clientLogContent -notmatch 'INTERACT_REQ sent #1: basedoor_signalroom -> toggle') {
        throw "Client log missing INTERACT_REQ sent log.`nClient log:`n$clientLogContent"
    }
    if ($clientLogContent -notmatch 'WORLD_ACK received for REQ #1') {
        throw "Client log missing WORLD_ACK confirmation for REQ #1.`nClient log:`n$clientLogContent"
    }

    # -------------------------------------------------------------
    # Test 2: Host emits WORLD_STATE -> Client receives remote_world_state.txt
    # -------------------------------------------------------------
    $hostLocalWorld = Join-Path $hostRuntime 'local_world_state.txt'
    $clientRemoteWorld = Join-Path $clientRuntime 'remote_world_state.txt'
    [System.IO.File]::WriteAllText($hostLocalWorld, '1|basedoor_signalroom|isOpened=true')

    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    $clientWorldContent = ''
    do {
        Start-Sleep -Milliseconds 50
        if (Test-Path $clientRemoteWorld) {
            $clientWorldContent = (Get-Content $clientRemoteWorld -Raw).Trim()
        }
    } while ($clientWorldContent -eq '' -and [DateTime]::UtcNow -lt $deadline)

    $expectedClientWorld = 'TestHost|1|basedoor_signalroom|isOpened=true'
    if ($clientWorldContent -ne $expectedClientWorld) {
        throw "Client did not receive expected remote world state.`nExpected: $expectedClientWorld`nActual: $clientWorldContent"
    }

    # Verify ACK and logs for WORLD_STATE
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    $hostLogContent = ''
    do {
        Start-Sleep -Milliseconds 50
        $hostLogContent = if (Test-Path $hostLog) { Get-Content $hostLog -Raw } else { '' }
    } while ($hostLogContent -notmatch 'WORLD_ACK received for STATE #1' -and [DateTime]::UtcNow -lt $deadline)

    if ($hostLogContent -notmatch 'WORLD_STATE sent #1: basedoor_signalroom = isOpened=true') {
        throw "Host log missing WORLD_STATE sent log.`nHost log:`n$hostLogContent"
    }
    if ($hostLogContent -notmatch 'WORLD_ACK received for STATE #1') {
        throw "Host log missing WORLD_ACK confirmation for STATE #1.`nHost log:`n$hostLogContent"
    }

    # -------------------------------------------------------------
    # Test 3: Retry mechanism on lost ACK (guaranteed delivery)
    # -------------------------------------------------------------
    $mockUdp = New-Object System.Net.Sockets.UdpClient($retryPort)
    $mockUdp.Client.ReceiveTimeout = 2000

    $retryClientProcess = Start-Process -FilePath $BridgeExe -ArgumentList '--role','client','--bridge',$retryClientRuntime,'--host','127.0.0.1','--port',$retryPort,'--name','RetryClient' -RedirectStandardOutput $retryClientLog -WindowStyle Hidden -PassThru

    # Handle HELLO handshake with mock host
    $remoteEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $helloBytes = $mockUdp.Receive([ref]$remoteEp)
    $helloStr = [System.Text.Encoding]::UTF8.GetString($helloBytes)
    if ($helloStr -notmatch '^VOTVCOOP1\|HELLO') {
        throw "Mock host expected HELLO from retry client, got: $helloStr"
    }
    $welcomePacket = [System.Text.Encoding]::UTF8.GetBytes("VOTVCOOP1|WELCOME|MockHost")
    $mockUdp.Send($welcomePacket, $welcomePacket.Length, $remoteEp) | Out-Null

    # Client writes interact request
    $retryLocalInteract = Join-Path $retryClientRuntime 'local_interact.txt'
    [System.IO.File]::WriteAllText($retryLocalInteract, '10|lightswitch_signalroom|toggle')

    # Mock host receives first INTERACT_REQ
    $req1Bytes = $mockUdp.Receive([ref]$remoteEp)
    $req1Str = [System.Text.Encoding]::UTF8.GetString($req1Bytes)
    if ($req1Str -notmatch '^VOTVCOOP1\|INTERACT_REQ\|10\|RetryClient\|lightswitch_signalroom\|toggle') {
        throw "Mock host expected INTERACT_REQ #10, got: $req1Str"
    }

    # DELIBERATELY DO NOT ACK: Wait for retry packet from client
    $req2Bytes = $mockUdp.Receive([ref]$remoteEp)
    $req2Str = [System.Text.Encoding]::UTF8.GetString($req2Bytes)
    if ($req2Str -notmatch '^VOTVCOOP1\|INTERACT_REQ\|10\|RetryClient\|lightswitch_signalroom\|toggle') {
        throw "Mock host expected retry INTERACT_REQ #10, got: $req2Str"
    }

    # Now send ACK to mock host
    $ackPacket = [System.Text.Encoding]::UTF8.GetBytes("VOTVCOOP1|WORLD_ACK|REQ|10|MockHost")
    $mockUdp.Send($ackPacket, $ackPacket.Length, $remoteEp) | Out-Null

    Start-Sleep -Milliseconds 150
    $retryClientLogContent = if (Test-Path $retryClientLog) { Get-Content $retryClientLog -Raw } else { '' }
    if ($retryClientLogContent -notmatch 'INTERACT_REQ retry #10') {
        throw "Retry client log missing retransmission log entry.`nLog:`n$retryClientLogContent"
    }
    if ($retryClientLogContent -notmatch 'WORLD_ACK received for REQ #10') {
        throw "Retry client log missing ACK receipt after retransmission.`nLog:`n$retryClientLogContent"
    }

    # Clean up retry client & mock UDP
    Stop-Process -Id $retryClientProcess.Id -Force
    $retryClientProcess.WaitForExit(1000) | Out-Null
    $retryClientProcess = $null
    $mockUdp.Close()
    $mockUdp.Dispose()
    $mockUdp = $null

    # -------------------------------------------------------------
    # Test 4: Deduplication & Outdated State Rejection (Direct UDP)
    # -------------------------------------------------------------
    # Send duplicate INTERACT_REQ #1 directly over UDP to Host to verify server-side deduplication
    $dupUdp = New-Object System.Net.Sockets.UdpClient
    try {
        $hostEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Loopback, $port)
        $dupPacket = [System.Text.Encoding]::UTF8.GetBytes("VOTVCOOP1|INTERACT_REQ|1|TestClient|basedoor_signalroom|toggle")
        $dupUdp.Send($dupPacket, $dupPacket.Length, $hostEp) | Out-Null

        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        $hostLogContent = ''
        do {
            Start-Sleep -Milliseconds 50
            $hostLogContent = if (Test-Path $hostLog) { Get-Content $hostLog -Raw } else { '' }
        } while ($hostLogContent -notmatch 'INTERACT_REQ duplicate ignored #1 from TestClient' -and [DateTime]::UtcNow -lt $deadline)

        if ($hostLogContent -notmatch 'INTERACT_REQ duplicate ignored #1 from TestClient') {
            throw "Host did not log server-side deduplication for direct UDP duplicate INTERACT_REQ #1.`nHost log:`n$hostLogContent"
        }

        # Host remote interact remains valid without corruption
        $hostInteractNow = (Get-Content $hostRemoteInteract -Raw).Trim()
        if ($hostInteractNow -ne 'TestClient|1|basedoor_signalroom|toggle') {
            throw "Host remote_interact corrupted on duplicate: $hostInteractNow"
        }
    }
    finally {
        $dupUdp.Close()
        $dupUdp.Dispose()
    }

    # -------------------------------------------------------------
    # Test 5: Host World State Cache & Late Client Snapshot Delivery
    # -------------------------------------------------------------
    # Stop the first client
    Stop-Process -Id $clientProcess.Id -Force
    $clientProcess.WaitForExit(1000) | Out-Null
    $clientProcess = $null

    # Host updates multiple world state objects while no client is connected
    [System.IO.File]::WriteAllText($hostLocalWorld, "2|lightswitch_signalroom|A=true`n3|powerControl_main|press_calc=true")
    Start-Sleep -Milliseconds 200

    # Start late client
    $lateClientProcess = Start-Process -FilePath $BridgeExe -ArgumentList '--role','client','--bridge',$lateClientRuntime,'--host','127.0.0.1','--port',$port,'--name','TestClientLate' -RedirectStandardOutput $lateClientLog -WindowStyle Hidden -PassThru

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    $lateClientWorldPath = Join-Path $lateClientRuntime 'remote_world_state.txt'
    $lateClientWorldLines = @()
    do {
        Start-Sleep -Milliseconds 100
        if (Test-Path $lateClientWorldPath) {
            $lateClientWorldLines = @(Get-Content $lateClientWorldPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    } while ($lateClientWorldLines.Count -lt 3 -and [DateTime]::UtcNow -lt $deadline)

    $lateClientWorldContent = if (Test-Path $lateClientWorldPath) { Get-Content $lateClientWorldPath -Raw } else { '<file missing>' }
    if ($lateClientWorldLines.Count -lt 3) {
        throw "Late client remote_world_state.txt missing snapshot objects (expected 3 lines, got $($lateClientWorldLines.Count)).`nFile content:`n$lateClientWorldContent"
    }

    $hasDoor = $lateClientWorldLines | Where-Object { $_ -match '^TestHost\|1\|basedoor_signalroom\|isOpened=true' }
    $hasLight = $lateClientWorldLines | Where-Object { $_ -match '^TestHost\|2\|lightswitch_signalroom\|A=true' }
    $hasPower = $lateClientWorldLines | Where-Object { $_ -match '^TestHost\|3\|powerControl_main\|press_calc=true' }

    if (-not $hasDoor) {
        throw "Snapshot in remote_world_state.txt is missing basedoor_signalroom.`nFile content:`n$lateClientWorldContent"
    }
    if (-not $hasLight) {
        throw "Snapshot in remote_world_state.txt is missing lightswitch_signalroom.`nFile content:`n$lateClientWorldContent"
    }
    if (-not $hasPower) {
        throw "Snapshot in remote_world_state.txt is missing powerControl_main.`nFile content:`n$lateClientWorldContent"
    }

    $lateClientLogContent = if (Test-Path $lateClientLog) { Get-Content $lateClientLog -Raw } else { '' }
    if ($lateClientLogContent -notmatch 'WORLD_STATE received from TestHost: #1 basedoor_signalroom' -or
        $lateClientLogContent -notmatch 'WORLD_STATE received from TestHost: #2 lightswitch_signalroom' -or
        $lateClientLogContent -notmatch 'WORLD_STATE received from TestHost: #3 powerControl_main') {
        throw "Late client missing console logs for snapshot receipt.`nLate client log:`n$lateClientLogContent"
    }

    # -------------------------------------------------------------
    # Test 6: Client NEVER broadcasts WORLD_STATE (Authority Protection)
    # -------------------------------------------------------------
    # Write rogue world state to client's folder
    $rogueClientWorld = Join-Path $lateClientRuntime 'local_world_state.txt'
    [System.IO.File]::WriteAllText($rogueClientWorld, '999|rogue_object|isOpened=true')
    Start-Sleep -Milliseconds 500

    $lateClientLogContent = if (Test-Path $lateClientLog) { Get-Content $lateClientLog -Raw } else { '' }
    if ($lateClientLogContent -match 'WORLD_STATE sent #999') {
        throw "Client violated authority by sending WORLD_STATE packet.`nClient log:`n$lateClientLogContent"
    }

    $hostLogContent = if (Test-Path $hostLog) { Get-Content $hostLog -Raw } else { '' }
    if ($hostLogContent -match 'rogue_object') {
        throw "Host received unauthorized WORLD_STATE from client.`nHost log:`n$hostLogContent"
    }

    # -------------------------------------------------------------
    # Test 7: Channel and File Isolation
    # -------------------------------------------------------------
    $clientRemoteState = Join-Path $lateClientRuntime 'remote_state.txt'
    $clientRemoteAction = Join-Path $lateClientRuntime 'remote_action.txt'
    if (Test-Path $clientRemoteState) {
        $stateContent = Get-Content $clientRemoteState -Raw
        if ($stateContent -match 'basedoor' -or $stateContent -match 'lightswitch' -or $stateContent -match 'powerControl') {
            throw "World state polluted remote_state.txt: $stateContent"
        }
    }
    if (Test-Path $clientRemoteAction) {
        $actionContent = Get-Content $clientRemoteAction -Raw
        if ($actionContent -match 'basedoor' -or $actionContent -match 'lightswitch' -or $actionContent -match 'powerControl') {
            throw "World state polluted remote_action.txt: $actionContent"
        }
    }

    # -------------------------------------------------------------
    # Test 8: Client Reconnect & Snapshot Sync (HIGH 2)
    # -------------------------------------------------------------
    Stop-Process -Id $lateClientProcess.Id -Force
    $lateClientProcess.WaitForExit(1000) | Out-Null
    $lateClientProcess = $null

    # Clear remote_world_state.txt to ensure reconnection repopulates all objects
    if (Test-Path $lateClientWorldPath) { Remove-Item $lateClientWorldPath -Force }

    # Host updates basedoor state while client is disconnected
    [System.IO.File]::WriteAllText($hostLocalWorld, '4|basedoor_signalroom|isOpened=false')
    Start-Sleep -Milliseconds 200

    # Start reconnected client
    $reconnectLog = Join-Path $testRoot 'reconnect.log'
    $lateClientProcess = Start-Process -FilePath $BridgeExe -ArgumentList '--role','client','--bridge',$lateClientRuntime,'--host','127.0.0.1','--port',$port,'--name','TestClientReconnect' -RedirectStandardOutput $reconnectLog -WindowStyle Hidden -PassThru

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    $reconnectWorldLines = @()
    do {
        Start-Sleep -Milliseconds 100
        if (Test-Path $lateClientWorldPath) {
            $reconnectWorldLines = @(Get-Content $lateClientWorldPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    } while ($reconnectWorldLines.Count -lt 3 -and [DateTime]::UtcNow -lt $deadline)

    $reconnectWorldContent = if (Test-Path $lateClientWorldPath) { Get-Content $lateClientWorldPath -Raw } else { '<file missing>' }
    if ($reconnectWorldLines.Count -lt 3) {
        throw "Reconnected client failed to receive full snapshot after reconnect.`nFile content:`n$reconnectWorldContent"
    }

    $hasUpdatedDoor = $reconnectWorldLines | Where-Object { $_ -match '^TestHost\|4\|basedoor_signalroom\|isOpened=false' }
    $hasLightAfterReconnect = $reconnectWorldLines | Where-Object { $_ -match '^TestHost\|2\|lightswitch_signalroom\|A=true' }
    $hasPowerAfterReconnect = $reconnectWorldLines | Where-Object { $_ -match '^TestHost\|3\|powerControl_main\|press_calc=true' }

    if (-not $hasUpdatedDoor -or -not $hasLightAfterReconnect -or -not $hasPowerAfterReconnect) {
        throw "Reconnected client snapshot incomplete.`nFile content:`n$reconnectWorldContent"
    }

    # -------------------------------------------------------------
    # Test 10: Slower Reader / Delayed Consumption Buffer Stream Test (CRITICAL)
    # Scenario: Fast sender sends 20 distinct states across 20 distinct cycles (35ms intervals).
    # Slower reader polls with delayed inspection. Reader MUST receive ALL 20 states without loss.
    # -------------------------------------------------------------
    # Part A: Host sends 20 world states (seq 100..119) across separate ticks
    $startSeq = 100
    $endSeq = 119
    $stateLines = @()
    for ($s = $startSeq; $s -le $endSeq; $s++) {
        $stateLines += "$s|bulk_door_$s|state_$s"
        Write-AtomicFile $hostLocalWorld ($stateLines -join "`n")
        Start-Sleep -Milliseconds 35
    }

    # Reader was delayed / not reading during the entire burst. Now reader reads remote_world_state.txt
    Start-Sleep -Milliseconds 200
    $lateClientWorldContent = if (Test-Path $lateClientWorldPath) { Get-Content $lateClientWorldPath -Raw } else { '' }
    $receivedWorldLines = @($lateClientWorldContent -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $missingWorldStates = @()
    for ($s = $startSeq; $s -le $endSeq; $s++) {
        $pattern = "^TestHost\|$s\|bulk_door_$s\|state_$s"
        if (-not ($receivedWorldLines | Where-Object { $_ -match $pattern })) {
            $missingWorldStates += $s
        }
    }

    if ($missingWorldStates.Count -gt 0) {
        throw "CRITICAL DATA LOSS in remote_world_state.txt! Slower reader missed $($missingWorldStates.Count)/20 states. Missing sequences: $($missingWorldStates -join ', '). Total lines in file: $($receivedWorldLines.Count).`nFile content:`n$lateClientWorldContent"
    }

    # Part B: Client sends 20 interaction requests (seq 200..219) across separate ticks
    $startInteractSeq = 200
    $endInteractSeq = 219
    $interactLines = @()
    $lateClientLocalInteract = Join-Path $lateClientRuntime 'local_interact.txt'
    for ($s = $startInteractSeq; $s -le $endInteractSeq; $s++) {
        $interactLines += "$s|bulk_button_$s|press_$s"
        Write-AtomicFile $lateClientLocalInteract ($interactLines -join "`n")
        Start-Sleep -Milliseconds 35
    }

    # Host reader was delayed / not reading during the entire burst. Now host reads remote_interact.txt
    Start-Sleep -Milliseconds 200
    $hostInteractContent = if (Test-Path $hostRemoteInteract) { Get-Content $hostRemoteInteract -Raw } else { '' }
    $receivedInteractLines = @($hostInteractContent -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $missingInteracts = @()
    for ($s = $startInteractSeq; $s -le $endInteractSeq; $s++) {
        $pattern = "^TestClientReconnect\|$s\|bulk_button_$s\|press_$s"
        if (-not ($receivedInteractLines | Where-Object { $_ -match $pattern })) {
            $missingInteracts += $s
        }
    }

    if ($missingInteracts.Count -gt 0) {
        throw "CRITICAL DATA LOSS in remote_interact.txt! Slower reader missed $($missingInteracts.Count)/20 interaction requests. Missing sequences: $($missingInteracts -join ', '). Total lines in file: $($receivedInteractLines.Count).`nFile content:`n$hostInteractContent"
    }

    # -------------------------------------------------------------
    # Test 9: Retransmission Exhaustion Signals Error in status.txt (HIGH 3)
    # -------------------------------------------------------------
    $exhaustClientRuntime = Join-Path $testRoot 'exhaust_client'
    [System.IO.Directory]::CreateDirectory($exhaustClientRuntime) | Out-Null
    $exhaustClientLog = Join-Path $testRoot 'exhaust_client.log'
    $mockDeadUdp = New-Object System.Net.Sockets.UdpClient($deadPort)
    $mockDeadUdp.Client.ReceiveTimeout = 2000

    $exhaustClientProcess = Start-Process -FilePath $BridgeExe -ArgumentList '--role','client','--bridge',$exhaustClientRuntime,'--host','127.0.0.1','--port',$deadPort,'--name','ExhaustClient','--max-retry-attempts','3' -RedirectStandardOutput $exhaustClientLog -WindowStyle Hidden -PassThru

    # Handle HELLO handshake with mock host to reach connected status
    $deadRemoteEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $deadHelloBytes = $mockDeadUdp.Receive([ref]$deadRemoteEp)
    $deadWelcomePacket = [System.Text.Encoding]::UTF8.GetBytes("VOTVCOOP1|WELCOME|MockDeadHost")
    $mockDeadUdp.Send($deadWelcomePacket, $deadWelcomePacket.Length, $deadRemoteEp) | Out-Null

    # Client writes interact request
    $exhaustLocalInteract = Join-Path $exhaustClientRuntime 'local_interact.txt'
    [System.IO.File]::WriteAllText($exhaustLocalInteract, '100|some_button|press')

    # Mock host intentionally does NOT ACK
    # Wait for retry exhaustion (3 attempts * 100ms = 300ms) and status error
    $exhaustStatusPath = Join-Path $exhaustClientRuntime 'status.txt'
    $deadline = [DateTime]::UtcNow.AddSeconds(4)
    $exhaustStatus = ''
    do {
        Start-Sleep -Milliseconds 100
        if (Test-Path $exhaustStatusPath) {
            $exhaustStatus = (Get-Content $exhaustStatusPath -Raw).Trim()
        }
    } while ($exhaustStatus -notmatch '^error\|retransmit_exhausted' -and [DateTime]::UtcNow -lt $deadline)

    if ($exhaustStatus -notmatch '^error\|retransmit_exhausted') {
        throw "Bridge failed to signal retransmit exhaustion in status.txt.`nActual status: $exhaustStatus"
    }

    # Clean up exhaust client & dead mock UDP
    Stop-Process -Id $exhaustClientProcess.Id -Force
    $exhaustClientProcess.WaitForExit(1000) | Out-Null
    $exhaustClientProcess = $null
    $mockDeadUdp.Close()
    $mockDeadUdp.Dispose()
    $mockDeadUdp = $null
}
finally {
    if ($hostProcess -and -not $hostProcess.HasExited) { Stop-Process -Id $hostProcess.Id -Force; $hostProcess.WaitForExit(1000) | Out-Null }
    if ($clientProcess -and -not $clientProcess.HasExited) { Stop-Process -Id $clientProcess.Id -Force; $clientProcess.WaitForExit(1000) | Out-Null }
    if ($lateClientProcess -and -not $lateClientProcess.HasExited) { Stop-Process -Id $lateClientProcess.Id -Force; $lateClientProcess.WaitForExit(1000) | Out-Null }
    if ($retryClientProcess -and -not $retryClientProcess.HasExited) { Stop-Process -Id $retryClientProcess.Id -Force; $retryClientProcess.WaitForExit(1000) | Out-Null }
    if ($exhaustClientProcess -and -not $exhaustClientProcess.HasExited) { Stop-Process -Id $exhaustClientProcess.Id -Force; $exhaustClientProcess.WaitForExit(1000) | Out-Null }
    if ($mockUdp) { $mockUdp.Close(); $mockUdp.Dispose(); $mockUdp = $null }
    if ($mockDeadUdp) { $mockDeadUdp.Close(); $mockDeadUdp.Dispose(); $mockDeadUdp = $null }
    if (Test-Path $testRoot) {
        try { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

Write-Output 'PASS: bridge world sync protocol satisfies reliability, deduplication, snapshot caching, authority model, and channel isolation.'
