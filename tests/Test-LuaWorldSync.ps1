$ErrorActionPreference = 'Stop'

$scriptsDir = Join-Path $PSScriptRoot '..\mod\scripts'
$scriptFiles = @(
    'coop_util.lua',
    'coop_bridge.lua',
    'coop_remote_avatar.lua',
    'coop_actions.lua',
    'coop_world.lua',
    'main.lua'
)

$sources = @{}
foreach ($file in $scriptFiles) {
    $filePath = Join-Path $scriptsDir $file
    if (-not (Test-Path -LiteralPath $filePath)) {
        throw "FAIL: Script file $file must exist"
    }
    $sources[$file] = Get-Content -Raw -LiteralPath $filePath
}

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

$worldSrc = $sources['coop_world.lua']
$mainSrc = $sources['main.lua']
$utilSrc = $sources['coop_util.lua']

# -------------------------------------------------------------
# 1. Module loading and integration checks
# -------------------------------------------------------------
Assert-True ($mainSrc -match 'dofile\(mod_dir\s*\.\.\s*"/scripts/coop_world\.lua"\)') 'main.lua must load coop_world.lua'
Assert-True ($mainSrc -match 'coop_world\.create\(') 'main.lua must instantiate coop_world via create()'
Assert-True ($mainSrc -match 'sync_world\(\)|world\.tick\(\)') 'main.lua tick must invoke coop_world sync/tick'
Assert-True ($mainSrc -match 'local_interact\s*=' -and $mainSrc -match 'remote_interact\s*=') 'main.lua must configure interact paths'
Assert-True ($mainSrc -match 'local_world_state\s*=' -and $mainSrc -match 'remote_world_state\s*=') 'main.lua must configure world state paths'
Assert-True ($worldSrc -match 'return\s+coop_world') 'coop_world.lua must return module table'

# -------------------------------------------------------------
# 2. Echo protection checks
# -------------------------------------------------------------
Assert-True ($worldSrc -match 'local\s+is_applying_remote\s*=\s*false') 'coop_world.lua must define is_applying_remote echo protection flag'
Assert-True ($worldSrc -match 'if\s+is_applying_remote\s+then\s+return\s+end') 'coop_world.lua must check is_applying_remote guard before local emission or hooks'

# Applying state must set is_applying_remote = true before change and reset to false
$applyStateStart = $worldSrc.IndexOf('local function apply_object_state(')
Assert-True ($applyStateStart -ge 0) 'apply_object_state function must exist'
$applyStateEnd = $worldSrc.IndexOf("`nlocal function ", $applyStateStart + 1)
if ($applyStateEnd -lt 0) { $applyStateEnd = $worldSrc.Length }
$applyStateBlock = $worldSrc.Substring($applyStateStart, $applyStateEnd - $applyStateStart)

Assert-True ($applyStateBlock -match 'is_applying_remote\s*=\s*true') 'apply_object_state must set is_applying_remote = true'
Assert-True ($applyStateBlock -match 'is_applying_remote\s*=\s*false') 'apply_object_state must reset is_applying_remote = false'

# Applying interact request must set is_applying_remote = true and reset to false
$applyInteractStart = $worldSrc.IndexOf('local function apply_interact_request(')
Assert-True ($applyInteractStart -ge 0) 'apply_interact_request function must exist'
$applyInteractEnd = $worldSrc.IndexOf("`nlocal function ", $applyInteractStart + 1)
if ($applyInteractEnd -lt 0) { $applyInteractEnd = $worldSrc.Length }
$applyInteractBlock = $worldSrc.Substring($applyInteractStart, $applyInteractEnd - $applyInteractStart)

Assert-True ($applyInteractBlock -match 'is_applying_remote\s*=\s*true') 'apply_interact_request must set is_applying_remote = true'
Assert-True ($applyInteractBlock -match 'is_applying_remote\s*=\s*false') 'apply_interact_request must reset is_applying_remote = false'

# -------------------------------------------------------------
# 3. Multi-line journal reading checks (ALL lines processed)
# -------------------------------------------------------------
$readLinesStart = $worldSrc.IndexOf('local function read_all_lines(')
Assert-True ($readLinesStart -ge 0) 'read_all_lines helper must exist'
$readLinesEnd = $worldSrc.IndexOf("`nlocal function ", $readLinesStart + 1)
if ($readLinesEnd -lt 0) { $readLinesEnd = $worldSrc.Length }
$readLinesBlock = $worldSrc.Substring($readLinesStart, $readLinesEnd - $readLinesStart)

Assert-True ($readLinesBlock -match 'file:lines\(\)') 'read_all_lines must iterate file:lines() to read all lines'
Assert-True ($readLinesBlock -notmatch 'file:read\(\s*"\*a"\s*\)') 'read_all_lines must not use rejected *a format'

$consumeWorldStart = $worldSrc.IndexOf('local function consume_remote_world_state(')
Assert-True ($consumeWorldStart -ge 0) 'consume_remote_world_state function must exist'
$consumeWorldEnd = $worldSrc.IndexOf("`nlocal function ", $consumeWorldStart + 1)
if ($consumeWorldEnd -lt 0) { $consumeWorldEnd = $worldSrc.Length }
$consumeWorldBlock = $worldSrc.Substring($consumeWorldStart, $consumeWorldEnd - $consumeWorldStart)

Assert-True ($consumeWorldBlock -match 'for\s+.*?\s+in\s+ipairs\(lines\)\s+do') 'consume_remote_world_state must process all lines from journal'
Assert-True ($consumeWorldBlock -match 'parse_remote_journal_line') 'consume_remote_world_state must parse journal entries'

$consumeInteractStart = $worldSrc.IndexOf('local function consume_remote_interacts(')
Assert-True ($consumeInteractStart -ge 0) 'consume_remote_interacts function must exist'
$consumeInteractEnd = $worldSrc.IndexOf("`nlocal function ", $consumeInteractStart + 1)
if ($consumeInteractEnd -lt 0) { $consumeInteractEnd = $worldSrc.Length }
$consumeInteractBlock = $worldSrc.Substring($consumeInteractStart, $consumeInteractEnd - $consumeInteractStart)

Assert-True ($consumeInteractBlock -match 'for\s+.*?\s+in\s+ipairs\(lines\)\s+do') 'consume_remote_interacts must process all lines from journal'

# -------------------------------------------------------------
# 4. Host / Client role separation and authority checks
# -------------------------------------------------------------
Assert-True ($worldSrc -match 'role\s*==\s*"host"') 'coop_world must have dedicated host role branch'
Assert-True ($worldSrc -match 'role\s*==\s*"client"') 'coop_world must have dedicated client role branch'

$tickStart = $worldSrc.IndexOf('local function tick(')
Assert-True ($tickStart -ge 0) 'tick function must exist'
$tickEnd = $worldSrc.IndexOf("`nlocal function ", $tickStart + 1)
if ($tickEnd -lt 0) { $tickEnd = $worldSrc.Length }
$tickBlock = $worldSrc.Substring($tickStart, $tickEnd - $tickStart)

Assert-True ($tickBlock -match 'consume_remote_interacts\(\)') 'Host tick must consume remote interact requests'
Assert-True ($tickBlock -match 'poll_host_world_state\(\)') 'Host tick must poll local world state'
Assert-True ($tickBlock -match 'consume_remote_world_state\(\)') 'Client tick must consume remote world state'

# Client must never write to local_world_state
$onHookStart = $worldSrc.IndexOf('local function on_hook_triggered(')
Assert-True ($onHookStart -ge 0) 'on_hook_triggered function must exist'
$onHookEnd = $worldSrc.IndexOf("`nlocal function ", $onHookStart + 1)
if ($onHookEnd -lt 0) { $onHookEnd = $worldSrc.Length }
$onHookBlock = $worldSrc.Substring($onHookStart, $onHookEnd - $onHookStart)

Assert-True ($onHookBlock -match 'emit_local_interact\(') 'Client hook must emit local interact request'
Assert-True ($onHookBlock -match 'emit_local_world_state\(') 'Host hook must emit local world state'

# -------------------------------------------------------------
# 5. Identifier generation: Full path for powerControl, Key for doors/switches
# -------------------------------------------------------------
$getIdStart = $worldSrc.IndexOf('local function get_object_identifier(')
Assert-True ($getIdStart -ge 0) 'get_object_identifier function must exist'
$getIdEnd = $worldSrc.IndexOf("`nlocal function ", $getIdStart + 1)
if ($getIdEnd -lt 0) { $getIdEnd = $worldSrc.Length }
$getIdBlock = $worldSrc.Substring($getIdStart, $getIdEnd - $getIdStart)

# The power panel Key is generated per save, so it must be addressed by actor
# path. That rule now lives in the kind descriptor, so assert it there.
$powerKindStart = $worldSrc.IndexOf('name = "powerControl"')
Assert-True ($powerKindStart -ge 0) 'a powerControl kind descriptor must exist'
$powerKindLen = [Math]::Min(600, $worldSrc.Length - $powerKindStart)
$powerKindBlock = $worldSrc.Substring($powerKindStart, $powerKindLen)
Assert-True ($powerKindBlock -match 'identify_by_path\s*=\s*true') 'powerControl kind must be identified by actor path, not by Key'
$doorKindStart = $worldSrc.IndexOf('name = "door"')
Assert-True ($doorKindStart -ge 0) 'a door kind descriptor must exist'
$doorKindLen = [Math]::Min(600, $worldSrc.Length - $doorKindStart)
Assert-True ($worldSrc.Substring($doorKindStart, $doorKindLen) -notmatch 'identify_by_path') 'doors must keep using their map Key, not the actor path'
Assert-True ($getIdBlock -match 'identify_by_path') 'get_object_identifier must honour identify_by_path'
Assert-True ($getIdBlock -match 'safe_full_name|GetFullName') 'get_object_identifier must use full actor path for path-identified kinds'
Assert-True ($getIdBlock -match 'actor\.Key') 'get_object_identifier must inspect Key for standard triggerBase actors'

# -------------------------------------------------------------
# 6. Object caching, canonical deduplication, and lookup
# -------------------------------------------------------------
Assert-True ($worldSrc -match 'local\s+canonical_objects\s*=\s*\{\}') 'coop_world must define canonical_objects table for 1:1 polling'
Assert-True ($worldSrc -match 'local\s+object_cache\s*=\s*\{\}') 'coop_world must define object_cache table for alias lookup'
Assert-True ($worldSrc -match 'scan_and_cache_world_objects') 'coop_world must define object caching scanner'

$scanCacheStart = $worldSrc.IndexOf('local function scan_and_cache_world_objects(')
Assert-True ($scanCacheStart -ge 0) 'scan_and_cache_world_objects function must exist'
$scanCacheEnd = $worldSrc.IndexOf("`nlocal function ", $scanCacheStart + 1)
if ($scanCacheEnd -lt 0) { $scanCacheEnd = $worldSrc.Length }
$scanCacheBlock = $worldSrc.Substring($scanCacheStart, $scanCacheEnd - $scanCacheStart)

Assert-True ($scanCacheBlock -match 'canonical_objects\[canonical_id\]\s*=\s*actor') 'scan_and_cache_world_objects must store canonical ID in canonical_objects'
Assert-True ($scanCacheBlock -match 'object_cache\[full_path\]\s*=\s*actor') 'scan_and_cache_world_objects must store full_path in alias lookup cache'

$pollStart = $worldSrc.IndexOf('local function poll_host_world_state(')
Assert-True ($pollStart -ge 0) 'poll_host_world_state function must exist'
$pollEnd = $worldSrc.IndexOf("`nlocal function ", $pollStart + 1)
if ($pollEnd -lt 0) { $pollEnd = $worldSrc.Length }
$pollBlock = $worldSrc.Substring($pollStart, $pollEnd - $pollStart)

# Polling must iterate strictly over canonical_objects without duplicates
Assert-True ($pollBlock -match 'for\s+.*?\s+in\s+pairs\(canonical_objects\)\s+do') 'poll_host_world_state must iterate strictly over canonical_objects without duplicates'
Assert-True ($pollBlock -notmatch 'for\s+.*?\s+in\s+pairs\(object_cache\)\s+do') 'poll_host_world_state must NOT iterate over object_cache (which contains duplicate aliases)'

# Polling must have explicit host-role guard
Assert-True ($pollBlock -match 'if\s+role\s*~=\s*"host"\s+then\s+return\s+end|if\s+role\s*==\s*"host"') 'poll_host_world_state must guard against non-host execution'

$findObjStart = $worldSrc.IndexOf('local function find_object_by_id(')
Assert-True ($findObjStart -ge 0) 'find_object_by_id function must exist'
$findObjEnd = $worldSrc.IndexOf("`nlocal function ", $findObjStart + 1)
if ($findObjEnd -lt 0) { $findObjEnd = $worldSrc.Length }
$findObjBlock = $worldSrc.Substring($findObjStart, $findObjEnd - $findObjStart)

Assert-True ($findObjBlock -match 'object_cache\[object_id\]') 'find_object_by_id must check alias lookup cache before scanning'
Assert-True ($findObjBlock -match 'Object not found for id') 'find_object_by_id must log clear message when object is missing'

# -------------------------------------------------------------
# 7. Redundant state prevention (no redundant animations)
# -------------------------------------------------------------
# One generic guard now covers every kind: compare each declared property
# against the target and bail out when nothing differs.
Assert-True ($applyStateBlock -match 'target\[prop\.key\]\s*~=\s*current\[prop\.key\]') 'apply_object_state must compare every declared property against current state'
Assert-True ($applyStateBlock -match 'if not differs then return false end') 'apply_object_state must skip the apply when the object already holds the target state'

# -------------------------------------------------------------
# 8. Game thread & crash safety
# -------------------------------------------------------------
Assert-True ($worldSrc -match 'pcall\(') 'coop_world must guard UE operations with pcall'
Assert-True ($worldSrc -match 'IsValid\(\)') 'coop_world must verify actor validity before access'
Assert-True ($worldSrc -match 'ExecuteInGameThread') 'coop_world must execute hook callbacks inside ExecuteInGameThread'

# -------------------------------------------------------------
# 9. Real hook paths (/Game/ not /Script/) & explicit registration logging
# -------------------------------------------------------------
$registerHooksStart = $worldSrc.IndexOf('local function register_hooks(')
Assert-True ($registerHooksStart -ge 0) 'register_hooks function must exist'
$registerHooksEnd = $worldSrc.IndexOf("`nlocal function ", $registerHooksStart + 1)
if ($registerHooksEnd -lt 0) { $registerHooksEnd = $worldSrc.Length }
$registerHooksBlock = $worldSrc.Substring($registerHooksStart, $registerHooksEnd - $registerHooksStart)

# Hook paths must point to BlueprintGeneratedClass in /Game/
Assert-True ($registerHooksBlock -match '/Game/objects/door\.door_C') 'register_hooks must target BlueprintGeneratedClass /Game/objects/door.door_C'
Assert-True ($registerHooksBlock -match '/Game/objects/lightswitch\.lightswitch_C') 'register_hooks must target BlueprintGeneratedClass /Game/objects/lightswitch.lightswitch_C'
Assert-True ($registerHooksBlock -match '/Game/objects/powerControl\.powerControl_C') 'register_hooks must target BlueprintGeneratedClass /Game/objects/powerControl.powerControl_C'
Assert-True ($registerHooksBlock -match '/Game/objects/triggers/triggerBase\.triggerBase_C') 'register_hooks must target BlueprintGeneratedClass /Game/objects/triggers/triggerBase.triggerBase_C'

# Must NOT contain fictional /Script/VotV paths
Assert-True ($registerHooksBlock -notmatch '/Script/VotV\.') 'register_hooks must NOT use fictional /Script/VotV paths'

# Explicit logging for each hook registration (success and failure)
Assert-True ($registerHooksBlock -match 'Hook registration succeeded' -or $registerHooksBlock -match 'Hook registered') 'register_hooks must explicitly log successful hook registration'
Assert-True ($registerHooksBlock -match 'Hook registration failed') 'register_hooks must explicitly log failed hook registration'

# -------------------------------------------------------------
# 10. Polling performance management & interval throttling
# -------------------------------------------------------------
Assert-True ($worldSrc -match 'poll_interval_with_hooks' -or $worldSrc -match 'poll_interval') 'coop_world must configure polling interval'
Assert-True ($tickBlock -match 'last_poll_time' -or $tickBlock -match 'interval') 'tick must throttle polling rather than unconditionally polling all objects every frame'

Write-Host "PASS: Lua world sync (coop_world.lua) structure, echo protection, multi-line journal, role authority, canonical deduplication, real /Game/ hook paths, and polling throttling checks."
