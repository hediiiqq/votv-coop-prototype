$ErrorActionPreference = 'Stop'

$scriptsDir = Join-Path $PSScriptRoot '..\mod\scripts'
$scriptFiles = @(
    'coop_util.lua',
    'coop_bridge.lua',
    'coop_remote_avatar.lua',
    'coop_actions.lua',
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

# Aggregate source for global pattern checks and block extraction
$source = ($scriptFiles | ForEach-Object { $sources[$_] }) -join "`n"

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

function Get-LuaFunctionBlock([string] $Name) {
    $start = $source.IndexOf("local function $Name(")
    Assert-True ($start -ge 0) "Lua function $Name must exist"
    $nextFunction = $source.IndexOf("`nlocal function ", $start + 1)
    if ($nextFunction -lt 0) { $nextFunction = $source.Length }
    return $source.Substring($start, $nextFunction - $start)
}

# Module structure and loading checks
Assert-True ($sources['main.lua'] -match 'dofile\(mod_dir\s*\.\.\s*"/scripts/coop_util\.lua"\)') 'main.lua must load coop_util'
Assert-True ($sources['main.lua'] -match 'dofile\(mod_dir\s*\.\.\s*"/scripts/coop_bridge\.lua"\)') 'main.lua must load coop_bridge'
Assert-True ($sources['main.lua'] -match 'dofile\(mod_dir\s*\.\.\s*"/scripts/coop_remote_avatar\.lua"\)') 'main.lua must load coop_remote_avatar'
Assert-True ($sources['main.lua'] -match 'dofile\(mod_dir\s*\.\.\s*"/scripts/coop_actions\.lua"\)') 'main.lua must load coop_actions'
Assert-True ($sources['coop_util.lua'] -match 'return\s+coop_util') 'coop_util must return module table'
Assert-True ($sources['coop_bridge.lua'] -match 'return\s+coop_bridge') 'coop_bridge must return module table'
Assert-True ($sources['coop_remote_avatar.lua'] -match 'return\s+coop_remote_avatar') 'coop_remote_avatar must return module table'
Assert-True ($sources['coop_actions.lua'] -match 'return\s+coop_actions') 'coop_actions must return module table'

function Is-FiniteNumber($Value) {
    return $Value -is [double] -and -not [double]::IsNaN($Value) -and -not [double]::IsInfinity($Value)
}

function Normalize-Yaw([double] $Yaw) {
    return (($Yaw + 180.0) % 360.0 + 360.0) % 360.0 - 180.0
}

function Lerp-RemoteState([double] $Rendered, [double] $Target, [double] $Alpha) {
    return $Rendered + ($Target - $Rendered) * $Alpha
}

function Lerp-RemoteYaw([double] $Rendered, [double] $Target, [double] $Alpha) {
    $delta = Normalize-Yaw ($Target - $Rendered)
    return Normalize-Yaw ($Rendered + $delta * $Alpha)
}

function Invert-LookYaw([double] $Yaw) {
    return Normalize-Yaw ($Yaw + 180.0)
}

# Inverting look yaw by 180 degrees reference math
Assert-True ([math]::Abs((Invert-LookYaw 0.0) - (-180.0)) -lt 0.0001 -or [math]::Abs((Invert-LookYaw 0.0) - (180.0)) -lt 0.0001) 'inverting 0 yaw must yield +-180'
Assert-True ([math]::Abs((Invert-LookYaw 90.0) - (-90.0)) -lt 0.0001) 'inverting 90 yaw must yield -90'
Assert-True ([math]::Abs((Invert-LookYaw -90.0) - (90.0)) -lt 0.0001) 'inverting -90 yaw must yield 90'
Assert-True ([math]::Abs((Invert-LookYaw 45.0) - (-135.0)) -lt 0.0001) 'inverting 45 yaw must yield -135'
Assert-True ([math]::Abs((Invert-LookYaw -45.0) - (135.0)) -lt 0.0001) 'inverting -45 yaw must yield 135'

$captureBlock = Get-LuaFunctionBlock 'capture_local_player'
$consumeBlock = Get-LuaFunctionBlock 'consume_remote_player'
$drawBlock = Get-LuaFunctionBlock 'draw_remote_marker'
$readAllStart = $source.IndexOf('local function read_all(path)')
Assert-True ($readAllStart -ge 0) 'Lua function read_all must exist'
$readAllEnd = $source.IndexOf("`nlocal function ", $readAllStart + 1)
if ($readAllEnd -lt 0) { $readAllEnd = $source.Length }
$readAllBlock = $source.Substring($readAllStart, $readAllEnd - $readAllStart)

# Floor Z and look yaw capture checks
$floorZBlock = Get-LuaFunctionBlock 'get_local_floor_z'
$lookYawBlock = Get-LuaFunctionBlock 'get_local_look_yaw'

Assert-True ($source -match 'local function get_local_floor_z') 'Lua must define a floor Z helper'
Assert-True ($floorZBlock -match 'pcall\(function\(\)') 'floor Z helper must use guarded pcall blocks'
Assert-True ($floorZBlock -match 'GetScaledCapsuleHalfHeight|GetUnscaledCapsuleHalfHeight|CapsuleHalfHeight') 'floor Z helper must inspect capsule half-height'
Assert-True ($floorZBlock -match 'GetLocalBounds') 'floor Z helper must inspect mesh bounds as fallback'
Assert-True ($floorZBlock -match 'K2_GetActorLocation') 'floor Z helper must fall back to actor location Z'

Assert-True ($source -match 'local function get_local_look_yaw') 'Lua must define a look yaw helper'
Assert-True ($lookYawBlock -match 'pcall\(function\(\)') 'look yaw helper must use guarded pcall blocks'
Assert-True ($lookYawBlock -match 'GetControlRotation|ControlRotation') 'look yaw helper must inspect control rotation'
Assert-True ($lookYawBlock -match 'K2_GetActorRotation') 'look yaw helper must fall back to pawn actor rotation'

Assert-True ($source -match 'local function invert_look_yaw') 'Lua must define an inverted look yaw helper'
$invertYawBlock = Get-LuaFunctionBlock 'invert_look_yaw'
Assert-True ($invertYawBlock -match 'normalize_yaw\(.*?\+\s*180') 'invert_look_yaw helper must add 180 degrees and normalize'

Assert-True ($captureBlock -match 'get_local_floor_z\(pawn\)') 'capture_local_player must use floor Z helper'
Assert-True ($captureBlock -match 'get_local_look_yaw\(controller,\s*pawn\)') 'capture_local_player must use look yaw helper'
Assert-True ($captureBlock -match 'invert_look_yaw\(') 'capture_local_player must invert captured look yaw by 180 degrees before serialization'
Assert-True ($captureBlock -match 'atomic_write\(local_state,\s*string\.format\("%d\|%\.3f\|%\.3f\|%\.3f\|%\.3f"') 'capture_local_player must format sequence|x|y|z|yaw'

# UE4SS rejects the Lua "*a" read format; one-line records must use the default read mode.
Assert-True ($readAllBlock -match 'file:read\(\)') 'read_all must read without a format argument'
Assert-True ($readAllBlock -notmatch 'file:read\(\s*"\*a"\s*\)') 'read_all must not use the rejected *a format'
# Non-finite network values must be rejected before any remote state mutation.
Assert-True (Is-FiniteNumber 42.0) 'finite fixture must be accepted'
Assert-True (-not (Is-FiniteNumber $null)) 'nil fixture must be rejected'
Assert-True (-not (Is-FiniteNumber '42')) 'nonnumeric fixture must be rejected'
Assert-True (-not (Is-FiniteNumber ([double]::NaN))) 'NaN fixture must be rejected'
Assert-True (-not (Is-FiniteNumber ([double]::PositiveInfinity))) '+infinity fixture must be rejected'
Assert-True (-not (Is-FiniteNumber ([double]::NegativeInfinity))) '-infinity fixture must be rejected'
Assert-True ($source -match 'local function is_finite_number\(value\)') 'Lua must define a finite-number guard'
Assert-True ($source -match 'type\(value\)\s*==\s*"number"\s*and\s*value\s*==\s*value\s*and\s*value\s*~=\s*math\.huge\s*and\s*value\s*~=\s*-math\.huge') 'Lua finite-number guard must reject nil, nonnumbers, NaN, and infinities'
$duplicateReject = $consumeBlock.IndexOf('remote_sequence == last_remote_sequence')
$finiteReject = $consumeBlock.IndexOf('is_finite_number(remote_sequence)')
$mutation = $consumeBlock.IndexOf('last_remote_sequence = remote_sequence')
Assert-True ($duplicateReject -ge 0 -and $duplicateReject -lt $mutation) 'duplicate sequence rejection must precede state mutation'
Assert-True ($finiteReject -ge 0 -and $finiteReject -lt $mutation) 'finite sequence rejection must precede state mutation'
foreach ($field in @('remote_x', 'remote_y', 'remote_z', 'remote_yaw')) {
    $guard = $consumeBlock.IndexOf("is_finite_number($field)")
    Assert-True ($guard -ge 0 -and $guard -lt $mutation) "finite $field rejection must precede state mutation"
}

# First update snap must be fully inside the rendered-state absence gate.
$snapGate = $consumeBlock.IndexOf('if not remote_has_rendered_state then')
$snapFlagMutation = $consumeBlock.IndexOf('remote_has_rendered_state = true')
Assert-True ($snapGate -ge 0 -and $snapFlagMutation -gt $snapGate) 'first-update snap must be gated by rendered-state absence'
$snapBlock = $consumeBlock.Substring($snapGate, $snapFlagMutation - $snapGate)
foreach ($component in @('x', 'y', 'z', 'yaw')) {
    Assert-True ($snapBlock.IndexOf("rendered_remote_$component = target_remote_$component") -ge 0) "first valid update must snap rendered $component inside state gate"
}

# Position interpolation moves a partial step rather than jumping.
$position = Lerp-RemoteState 0 100 0.2
Assert-True ([math]::Abs($position - 20.0) -lt 0.0001) 'position interpolation must take a partial step'
Assert-True ($source -match 'rendered_remote_x\s*=\s*rendered_remote_x\s*\+\s*\(target_remote_x\s*-\s*rendered_remote_x\)\s*\*\s*remote_smoothing') 'Lua must interpolate rendered X toward target X'
$capsuleDraw = $drawBlock.IndexOf('DrawDebugCapsule')
foreach ($component in @('x', 'y', 'z')) {
    $interpolation = $drawBlock.IndexOf("rendered_remote_$component = rendered_remote_$component +")
    Assert-True ($interpolation -ge 0 -and $interpolation -lt $capsuleDraw) "rendered $component interpolation must be active before capsule draw"
}
$yawDelta = $drawBlock.IndexOf('local yaw_delta = normalize_yaw(target_remote_yaw - rendered_remote_yaw)')
$yawInterpolation = $drawBlock.IndexOf('rendered_remote_yaw = normalize_yaw(rendered_remote_yaw + yaw_delta * remote_smoothing)')
Assert-True ($yawDelta -ge 0 -and $yawDelta -lt $capsuleDraw) 'shortest yaw delta must be active before capsule draw'
Assert-True ($yawInterpolation -ge 0 -and $yawInterpolation -lt $capsuleDraw) 'rendered yaw interpolation must be active before capsule draw'

# 179 to -179 must use +2 degrees, not -358 degrees.
$yaw = Lerp-RemoteYaw 179 -179 0.5
Assert-True ([math]::Abs($yaw - (-180.0)) -lt 0.0001) 'yaw interpolation must use shortest path across boundary'
Assert-True ($source -match 'local function normalize_yaw') 'Lua must normalize yaw deltas'
Assert-True ($source -match 'normalize_yaw\(target_remote_yaw\s*-\s*rendered_remote_yaw\)') 'Lua must normalize target-rendered yaw delta'

# Capsule replaces sphere and sits one half-height above pawn origin.
Assert-True ($source -match 'Z\s*=\s*rendered_remote_z\s*\+\s*90\.0') 'capsule center must be Z + 90'
Assert-True ($source -match 'DrawDebugCapsule\(pawn,\s*center,\s*90\.0,\s*34\.0') 'capsule must use ~90 half-height and ~34 radius'
Assert-True ($source -notmatch 'DrawDebugSphere') 'old debug sphere must be removed'

# Facing line uses rendered yaw, with cos/sin direction and a short length.
Assert-True ($source -match 'math\.rad\(rendered_remote_yaw\)') 'facing line must use rendered yaw'
Assert-True ($source -match 'math\.cos\(yaw_radians\)') 'facing line X must use cosine'
Assert-True ($source -match 'math\.sin\(yaw_radians\)') 'facing line Y must use sine'
Assert-True ($source -match '\*\s*70\.0') 'facing line must be short'

# Stale peers still disappear after two seconds.
Assert-True ($source -match 'os\.clock\(\)\s*-\s*last_remote_update\s*>\s*2\.0') 'stale timeout must remain two seconds'

# The skeletal proxy is deliberately isolated from the gameplay Pawn.  These checks
# inspect the active render lifecycle rather than merely looking for stray strings.
$proxyBlock = Get-LuaFunctionBlock 'update_remote_player_proxy'
$proxyValidityBlock = Get-LuaFunctionBlock 'has_valid_remote_player_proxy'
$proxyFailureBlock = Get-LuaFunctionBlock 'log_proxy_failure'
$cleanupActorBlock = Get-LuaFunctionBlock 'cleanup_proxy_actor'
$cleanupBlock = Get-LuaFunctionBlock 'cleanup_remote_player_proxy'
$hideBlock = Get-LuaFunctionBlock 'hide_remote_player_proxy'
$drawBlock = Get-LuaFunctionBlock 'draw_remote_marker'
$copyTransformBlock = Get-LuaFunctionBlock 'copy_relative_transform'

Assert-True ($source -match 'local\s+skeletal_mesh_actor_class\s*=\s*nil') 'proxy actor class must be cached lazily'
Assert-True ($source -match 'local\s+remote_player_proxy\s*=\s*nil') 'only one remote proxy reference may be retained'
Assert-True ($source -match 'local\s+proxy_failure_reasons\s*=\s*\{\s*\}') 'proxy failures must be tracked by reason'
Assert-True ($proxyFailureBlock -match 'proxy_failure_reasons\[reason\]') 'distinct proxy failures must be rate limited'
Assert-True ($source -match 'local\s+remote_player_proxy_pawn_identity\s*=\s*nil') 'proxy pawn identity must be cached'
Assert-True ($source -match 'local\s+remote_player_proxy_world_identity\s*=\s*nil') 'proxy world identity must be cached'
Assert-True ($source -match 'local\s+remote_player_proxy_mesh_identity\s*=\s*nil') 'proxy mesh identity must be cached'
Assert-True ($source -match 'local function safe_object_identity\(object\)' -or $source -match 'safe_object_identity\s*=\s*function') 'proxy identity must use a safe identity helper'
Assert-True ($source -match 'object:GetAddress\(\)') 'proxy identity helper must prefer stable object addresses'

$candidateSpawn = $proxyBlock.IndexOf('candidate = world:SpawnActor(skeletal_mesh_actor_class, location, rotation)')
$candidateCollision = $proxyBlock.IndexOf('candidate:SetActorEnableCollision(false)')
$candidateHide = $proxyBlock.IndexOf('candidate:SetActorHiddenInGame(true)')
$candidateMesh = $proxyBlock.IndexOf('proxy_mesh:SetSkeletalMesh(mesh_asset, true)')
$candidateMove = $proxyBlock.IndexOf('candidate:K2_SetActorLocationAndRotation(location, rotation, false, {}, false)')
$candidateShow = $proxyBlock.IndexOf('candidate:SetActorHiddenInGame(false)')
$candidatePublish = $proxyBlock.IndexOf('remote_player_proxy = candidate')
Assert-True ($proxyBlock -match 'local candidate = nil') 'new proxy must remain a local candidate during setup'
Assert-True ($candidateSpawn -ge 0 -and $candidateCollision -gt $candidateSpawn -and $candidateHide -gt $candidateCollision) 'candidate must disable collision before hiding immediately after spawn'
Assert-True ($candidateMesh -gt $candidateCollision -and $candidateMove -gt $candidateMesh) 'candidate mesh and transform must be configured before publication'
Assert-True ($candidateShow -gt $candidateMove -and $candidatePublish -gt $candidateShow) 'candidate must be shown before its handle and identities are published'
Assert-True ($proxyBlock -match 'if candidate then[\s\S]*?cleanup_proxy_actor\(candidate, "candidate setup failed"\)') 'partial candidate setup must attempt hide and destroy'

$cleanupHide = $cleanupActorBlock.IndexOf('proxy:SetActorHiddenInGame(true)')
$cleanupCollision = $cleanupActorBlock.IndexOf('proxy:SetActorEnableCollision(false)')
$cleanupDestroy = $cleanupActorBlock.IndexOf('proxy:K2_DestroyActor()')
$cleanupDestroyFailure = $cleanupActorBlock.IndexOf('if not destroy_ok then')
$cleanupValidity = $cleanupActorBlock.IndexOf('return proxy:IsValid()')
$cleanupAlreadyGone = $cleanupActorBlock.IndexOf('if not valid_result then return true end')
$cleanupVerify = $cleanupActorBlock.IndexOf('local verify_ok, still_valid = pcall(function()')
$cleanupStillValid = $cleanupActorBlock.IndexOf('if still_valid then')
$cleanupClear = $cleanupBlock.IndexOf('remote_player_proxy = nil')
Assert-True ($cleanupValidity -ge 0 -and $cleanupValidity -lt $cleanupHide -and $cleanupValidity -lt $cleanupDestroy) 'cleanup must safely verify validity before hide/destroy'
Assert-True ($cleanupAlreadyGone -gt $cleanupValidity -and $cleanupAlreadyGone -lt $cleanupHide) 'invalid actors must take the already-cleaned fast path before hide/destroy'
Assert-True ($cleanupCollision -ge 0 -and $cleanupCollision -lt $cleanupHide -and $cleanupCollision -lt $cleanupDestroy) 'cleanup must reassert collision off before hide/destroy'
Assert-True ($cleanupHide -ge 0 -and $cleanupHide -lt $cleanupDestroy) 'cleanup must hide before invoking destroy'
Assert-True ($cleanupActorBlock -match 'pcall\(function\(\)') 'cleanup UE calls must stay inside pcall'
Assert-True ($cleanupDestroyFailure -ge 0 -and $cleanupClear -gt 0) 'failed destroy must be handled before global clearing'
Assert-True ($cleanupVerify -gt $cleanupDestroy -and $cleanupStillValid -gt $cleanupVerify) 'non-throwing destroy must be followed by safe validity verification'
Assert-True ($cleanupActorBlock -match 'if still_valid then[\s\S]*?return false') 'still-valid actors must remain tracked after destroy'
Assert-True ($cleanupActorBlock -match 'if not verify_ok then[\s\S]*?return false') 'thrown post-destroy validity checks must remain unresolved'
Assert-True ($cleanupBlock -match 'if not cleanup_proxy_actor\(proxy, reason\) then[\s\S]*?return false[\s\S]*?end[\s\S]*?remote_player_proxy = nil') 'cleanup must retain the global handle when destroy cannot be verified'
Assert-True ($hideBlock -match 'remote_player_proxy_ready\s*=\s*false') 'failed hide must mark proxy not ready'
Assert-True ($hideBlock -notmatch 'remote_player_proxy\s*=\s*nil') 'failed hide must retain the proxy handle'

$identityCleanup = $proxyBlock.IndexOf('cleanup_remote_player_proxy("local pawn/world/mesh changed")')
$identityCompare = $proxyBlock.IndexOf('remote_player_proxy_pawn_identity ~= pawn_identity')
Assert-True ($identityCompare -ge 0 -and $identityCleanup -gt $identityCompare) 'pawn/world/mesh identity changes must trigger cleanup before spawn'
Assert-True ($proxyBlock -match 'cleanup_remote_player_proxy\("unready or invalid proxy"\)') 'unready handles must be cleaned before any replacement spawn'
Assert-True ($proxyBlock -match 'if not cleanup_remote_player_proxy\("unready or invalid proxy"\) then[\s\S]*?error\("existing proxy cleanup failed"\)') 'unresolved handles must block a second spawn'
$candidateFailure = $proxyBlock.IndexOf('if not cleanup_proxy_actor(candidate, "candidate setup failed") then')
$candidateCollisionRetry = $proxyBlock.IndexOf('candidate:SetActorEnableCollision(false)', $candidateFailure)
$candidateHideRetry = $proxyBlock.IndexOf('candidate:SetActorHiddenInGame(true)', $candidateFailure)
$candidateTrack = $proxyBlock.IndexOf('remote_player_proxy = candidate', $candidateFailure)
$candidateTrackReady = $proxyBlock.IndexOf('remote_player_proxy_ready = false', $candidateTrack)
Assert-True ($candidateFailure -ge 0 -and $candidateTrack -gt $candidateFailure -and $candidateTrackReady -gt $candidateTrack) 'unresolved candidate cleanup must publish only a not-ready tracked blocker'
Assert-True ($candidateCollisionRetry -gt $candidateFailure -and $candidateHideRetry -gt $candidateCollisionRetry -and $candidateTrack -gt $candidateHideRetry) 'unresolved candidate retention must retry collision-off before hiding and publication'
Assert-True ($proxyBlock -match 'remote_player_proxy_pawn_identity = candidate_pawn_identity') 'unresolved candidate must retain available pawn identity'
Assert-True ($proxyBlock -match 'remote_player_proxy_world_identity = candidate_world_identity') 'unresolved candidate must retain available world identity'
Assert-True ($proxyBlock -match 'remote_player_proxy_mesh_identity = candidate_mesh_identity') 'unresolved candidate must retain available mesh identity'
$trackedHandle = $proxyBlock.IndexOf('if remote_player_proxy then')
$trackedCleanup = $proxyBlock.IndexOf('cleanup_remote_player_proxy("unready or invalid proxy")', $trackedHandle)
Assert-True ($trackedHandle -ge 0 -and $trackedCleanup -gt $trackedHandle -and $candidateSpawn -gt $trackedCleanup) 'tracked not-ready candidates must be cleaned or block before a new spawn'
$readyCollision = $proxyBlock.IndexOf('remote_player_proxy:SetActorEnableCollision(false)')
$readyShow = $proxyBlock.IndexOf('remote_player_proxy:SetActorHiddenInGame(false)')
Assert-True ($readyCollision -ge 0 -and $readyShow -gt $readyCollision) 'ready proxy must disable collision before unhide/update'

$classResolve = $proxyBlock.IndexOf('StaticFindObject("/Script/Engine.SkeletalMeshActor")')
$worldLookup = $proxyBlock.IndexOf('pawn:GetWorld()')
$spawn = $proxyBlock.IndexOf('world:SpawnActor(skeletal_mesh_actor_class, location, rotation)')
Assert-True ($classResolve -ge 0) 'proxy must resolve SkeletalMeshActor rather than the gameplay Pawn class'
Assert-True ($worldLookup -ge 0) 'proxy must get the local pawn world before spawning'
Assert-True ($spawn -gt $worldLookup) 'proxy must spawn SkeletalMeshActor in the pawn world'
Assert-True ($proxyBlock -notmatch 'SpawnActor\(pawn:GetClass\(\)') 'proxy must never spawn the gameplay Pawn class'
Assert-True ($proxyBlock -match 'pawn\.Mesh') 'proxy source component must be pawn.Mesh'
Assert-True ($proxyBlock -match 'mesh_component\.SkeletalMesh') 'proxy source asset must be pawn.Mesh.SkeletalMesh'
Assert-True ($proxyBlock -match 'candidate\.SkeletalMeshComponent') 'proxy destination must be SkeletalMeshComponent'
Assert-True ($proxyBlock -match 'SetSkeletalMesh\(mesh_asset,\s*true\)') 'proxy must prefer SetSkeletalMesh with pose reinitialization for mesh copy'
Assert-True ($proxyBlock -match 'proxy_mesh\.SkeletalMesh\s*=\s*mesh_asset') 'proxy must safely fall back to skeletal-mesh property assignment'
Assert-True ($proxyBlock -match 'SetSkeletalMesh\(mesh_asset,\s*true\)') 'proxy mesh assignment must reinitialize its pose and render state'
Assert-True ($proxyBlock -match 'copy_relative_transform\(mesh_component,\s*proxy_mesh\)') 'proxy setup must copy source mesh relative transform to proxy mesh component'
Assert-True ($proxyBlock -match 'proxy_mesh:SetVisibility\(true,\s*true\)') 'proxy mesh component must be made visible recursively'
Assert-True ($proxyBlock -match 'proxy_mesh:SetHiddenInGame\(false,\s*true\)') 'proxy mesh component must be unhidden recursively'
Assert-True ($proxyBlock -match 'SetActorEnableCollision\(false\)') 'proxy collision must be disabled'
Assert-True ($proxyBlock -match 'K2_SetActorLocationAndRotation\(location, rotation, false, \{\}, false\)') 'proxy must use the smoothed location and yaw transform'
Assert-True ($proxyBlock -match 'pcall\(function\(\)') 'uncertain UE proxy operations must stay inside a local pcall'

Assert-True ($source -match 'local function copy_relative_transform') 'Lua must define a relative transform copy helper'
Assert-True ($copyTransformBlock -match 'RelativeLocation') 'relative transform copy helper must read RelativeLocation'
Assert-True ($copyTransformBlock -match 'RelativeRotation') 'relative transform copy helper must read RelativeRotation'
Assert-True ($copyTransformBlock -match 'RelativeScale3D') 'relative transform copy helper must read RelativeScale3D'
Assert-True ($copyTransformBlock -match 'K2_SetRelativeLocationAndRotation') 'relative transform copy helper must attempt K2_SetRelativeLocationAndRotation'
Assert-True ($copyTransformBlock -match 'pcall\(function\(\)') 'relative transform copy operations must stay inside guarded pcall blocks'

# Relative mesh yaw compensation helper and proxy rotation alignment
Assert-True ($source -match 'local function get_source_mesh_relative_yaw') 'Lua must define a source mesh relative yaw helper'
$yawCompBlock = Get-LuaFunctionBlock 'get_source_mesh_relative_yaw'
Assert-True ($yawCompBlock -match 'pcall\(function\(\)') 'source mesh relative yaw helper must use guarded pcall blocks'
Assert-True ($yawCompBlock -match 'pawn\.Mesh|mesh\.RelativeRotation|RelativeRotation\.Yaw') 'source mesh relative yaw helper must inspect pawn mesh relative rotation yaw'
Assert-True ($yawCompBlock -match 'is_finite_number') 'source mesh relative yaw helper must check finite numbers'

Assert-True ($proxyBlock -match 'get_source_mesh_relative_yaw\(pawn\)') 'update_remote_player_proxy must obtain source mesh relative yaw'
Assert-True ($proxyBlock -match 'normalize_yaw\(rendered_remote_yaw\s*-\s*') 'update_remote_player_proxy must subtract relative yaw from rendered remote yaw to compute compensated proxy actor yaw'
$compActorYaw = $proxyBlock.IndexOf('normalize_yaw(rendered_remote_yaw -')
$rotationDef = $proxyBlock.IndexOf('local rotation = { Pitch = 0.0, Yaw =')
Assert-True ($compActorYaw -ge 0 -and $rotationDef -ge 0) 'proxy rotation must use compensated actor yaw'
Assert-True ($proxyBlock -match 'Yaw = proxy_actor_yaw|Yaw = compensated_yaw') 'proxy rotation struct must use the compensated yaw'

# Ensure ready proxy update uses the compensated rotation
$readyUpdate = $proxyBlock.IndexOf('remote_player_proxy:K2_SetActorLocationAndRotation(location, rotation, false, {}, false)')
Assert-True ($readyUpdate -gt $rotationDef) 'ready proxy update must use the compensated rotation'

# Ensure candidate spawn and update use the compensated rotation
$candidateSpawnWithRot = $proxyBlock.IndexOf('world:SpawnActor(skeletal_mesh_actor_class, location, rotation)')
$candidateUpdateWithRot = $proxyBlock.IndexOf('candidate:K2_SetActorLocationAndRotation(location, rotation, false, {}, false)')
Assert-True ($candidateSpawnWithRot -gt $rotationDef) 'candidate spawn must use the compensated rotation'
Assert-True ($candidateUpdateWithRot -gt $rotationDef) 'candidate update must use the compensated rotation'

$staleCheck = $drawBlock.IndexOf('os.clock() - last_remote_update > 2.0')
$staleHide = $drawBlock.IndexOf('hide_remote_player_proxy()')
$staleReturn = $drawBlock.IndexOf('return', $staleHide)
$proxyUpdate = $drawBlock.IndexOf('update_remote_player_proxy(pawn)')
$capsuleDraw = $drawBlock.IndexOf('DrawDebugCapsule')
Assert-True ($staleCheck -ge 0 -and $staleHide -gt $staleCheck) 'stale remote state must hide an existing proxy before return'
Assert-True ($staleReturn -gt $staleHide) 'stale remote state must return after hiding'
Assert-True ($drawBlock.Substring($staleCheck, $staleReturn - $staleCheck) -notmatch 'K2_DestroyActor') 'ordinary stale state must not destroy a ready proxy'
Assert-True ($proxyUpdate -ge 0 -and $proxyUpdate -lt $capsuleDraw) 'proxy must be updated before drawing the guaranteed marker'
Assert-True ($drawBlock -notmatch 'if has_valid_remote_player_proxy\(\) then return end') 'a valid but invisible proxy must not suppress the guaranteed marker'
Assert-True ($proxyValidityBlock -match 'remote_player_proxy:IsValid\(\)') 'proxy validity must be checked before use'
$controllerCheck = $drawBlock.IndexOf('if not controller or not controller:IsValid() then')
$controllerHide = $drawBlock.IndexOf('hide_remote_player_proxy()', $controllerCheck)
$pawnCheck = $drawBlock.IndexOf('if not pawn or not pawn:IsValid() then')
$pawnHide = $drawBlock.IndexOf('hide_remote_player_proxy()', $pawnCheck)
Assert-True ($controllerCheck -ge 0 -and $controllerHide -gt $controllerCheck) 'invalid controller must hide an existing proxy before return'
Assert-True ($pawnCheck -ge 0 -and $pawnHide -gt $pawnCheck) 'invalid pawn must hide an existing proxy before return'

# Action event bus v1 checks
Assert-True ($source -match 'local\s+local_action\s*=\s*bridge_dir\s*\.\.\s*"/local_action\.txt"') 'Lua must define local action path'
Assert-True ($source -match 'local\s+remote_action\s*=\s*bridge_dir\s*\.\.\s*"/remote_action\.txt"') 'Lua must define remote action path'
Assert-True ($source -match 'local\s+action_sequence\s*=\s*0') 'Lua must define separate action sequence'
Assert-True ($source -match 'local\s+last_local_action_sequence\s*=\s*-1') 'Lua must define local action sequence tracker'
Assert-True ($source -match 'local\s+last_remote_action_sequence\s*=\s*-1') 'Lua must define remote action sequence tracker'

$emitActionBlock = Get-LuaFunctionBlock 'emit_local_action'
$consumeActionBlock = Get-LuaFunctionBlock 'consume_remote_action'
$drawLocalActionBlock = Get-LuaFunctionBlock 'draw_local_action_marker'
$drawRemoteActionBlock = Get-LuaFunctionBlock 'draw_remote_action_marker'

Assert-True ($emitActionBlock -match 'UEHelpers:GetPlayerController\(\)') 'emit_local_action must check player controller'
Assert-True ($emitActionBlock -match 'get_local_floor_z\(pawn\)') 'emit_local_action must use floor Z helper'
Assert-True ($emitActionBlock -match 'get_local_look_yaw\(controller,\s*pawn\)') 'emit_local_action must use look yaw helper'
Assert-True ($emitActionBlock -match 'invert_look_yaw\(') 'emit_local_action must invert look yaw'
Assert-True ($emitActionBlock -match 'action_sequence\s*=\s*action_sequence\s*\+\s*1') 'emit_local_action must increment action sequence'
Assert-True ($emitActionBlock -match 'atomic_write\(local_action,\s*string\.format\("%d\|%s\|%\.3f\|%\.3f\|%\.3f\|%\.3f"') 'emit_local_action must format action_sequence|action_name|x|y|z|yaw'
Assert-True ($emitActionBlock -match 'last_local_action_sequence\s*=\s*action_sequence') 'emit_local_action must update local action sequence state'
Assert-True ($emitActionBlock -match 'rendered_local_action_x\s*=\s*location\.X') 'emit_local_action must record local action X location'
Assert-True ($emitActionBlock -match 'rendered_local_action_y\s*=\s*location\.Y') 'emit_local_action must record local action Y location'
Assert-True ($emitActionBlock -match 'rendered_local_action_z\s*=\s*floor_z') 'emit_local_action must record local action Z location'
Assert-True ($emitActionBlock -match 'rendered_local_action_yaw\s*=\s*normalize_yaw\(look_yaw\)') 'emit_local_action must record local action yaw'
Assert-True ($emitActionBlock -match 'last_local_action_time\s*=\s*os\.clock\(\)') 'emit_local_action must record local action timestamp'
Assert-True ($source -match 'RegisterKeyBind\(Key\.F9,') 'Lua must register F9 keybind for action emission'

# Remote action consumption guards and separation
$actionDuplicateReject = $consumeActionBlock.IndexOf('remote_action_sequence == last_remote_action_sequence')
$actionFiniteReject = $consumeActionBlock.IndexOf('is_finite_number(remote_action_sequence)')
$actionMutation = $consumeActionBlock.IndexOf('last_remote_action_sequence = remote_action_sequence')
Assert-True ($actionDuplicateReject -ge 0 -and $actionDuplicateReject -lt $actionMutation) 'duplicate action sequence rejection must precede action state mutation'
Assert-True ($actionFiniteReject -ge 0 -and $actionFiniteReject -lt $actionMutation) 'finite action sequence rejection must precede action state mutation'
foreach ($field in @('remote_x', 'remote_y', 'remote_z', 'remote_yaw')) {
    $guard = $consumeActionBlock.IndexOf("is_finite_number($field)")
    Assert-True ($guard -ge 0 -and $guard -lt $actionMutation) "finite action $field rejection must precede action state mutation"
}

# Local action marker rendering
Assert-True ($drawLocalActionBlock -match 'last_local_action_sequence\s*<\s*0') 'local action marker must check local action sequence validity'
Assert-True ($drawLocalActionBlock -match 'os\.clock\(\)\s*-\s*last_local_action_time\s*>\s*5\.0') 'local action marker lifetime must be at least 5 seconds'
Assert-True ($drawLocalActionBlock -match 'DrawDebugCapsule') 'local action marker must draw debug capsule'
Assert-True ($drawLocalActionBlock -match 'DrawDebugLine') 'local action marker must draw debug facing line'
Assert-True ($drawLocalActionBlock -match 'DrawDebugString') 'local action marker must include guarded DrawDebugString'
Assert-True ($drawLocalActionBlock -match 'pcall\(function\(\)') 'local action marker DrawDebugString must be guarded with pcall'

# Remote action marker rendering
Assert-True ($drawRemoteActionBlock -match 'last_remote_action_sequence\s*<\s*0') 'remote action marker must check remote action sequence validity'
Assert-True ($drawRemoteActionBlock -match 'os\.clock\(\)\s*-\s*last_remote_action_time\s*>\s*5\.0') 'remote action marker lifetime must be at least 5 seconds'
Assert-True ($drawRemoteActionBlock -match 'DrawDebugCapsule') 'remote action marker must draw debug capsule'
Assert-True ($drawRemoteActionBlock -match 'DrawDebugLine') 'remote action marker must draw debug facing line'
Assert-True ($drawRemoteActionBlock -match 'DrawDebugString') 'remote action marker must include guarded DrawDebugString'
Assert-True ($drawRemoteActionBlock -match 'pcall\(function\(\)') 'remote action marker DrawDebugString must be guarded with pcall'

# Distinct colors for local and remote action markers
Assert-True ($drawLocalActionBlock -match 'R\s*=\s*1\.0,\s*G\s*=\s*0\.85,\s*B\s*=\s*0\.0') 'local action marker must use distinct local color'
Assert-True ($drawRemoteActionBlock -match 'R\s*=\s*0\.0,\s*G\s*=\s*1\.0,\s*B\s*=\s*1\.0') 'remote action marker must use distinct remote color'

# Tick loop integration
$tickBlock = Get-LuaFunctionBlock 'tick'
Assert-True ($tickBlock -match 'consume_remote_action\(\)') 'tick must call consume_remote_action'
Assert-True ($tickBlock -match 'draw_local_action_marker\(\)') 'tick must call draw_local_action_marker'
Assert-True ($tickBlock -match 'draw_remote_action_marker\(\)') 'tick must call draw_remote_action_marker'

Write-Output 'PASS: Lua remote avatar and action event source and reference math checks'
