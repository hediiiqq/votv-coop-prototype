$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..\mod\scripts\main.lua'
$source = Get-Content -Raw $scriptPath

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

function Get-LuaFunctionBlock([string] $Name) {
    $start = $source.IndexOf("local function $Name()")
    Assert-True ($start -ge 0) "Lua function $Name must exist"
    $nextFunction = $source.IndexOf("`nlocal function ", $start + 1)
    if ($nextFunction -lt 0) { $nextFunction = $source.Length }
    return $source.Substring($start, $nextFunction - $start)
}

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

$consumeBlock = Get-LuaFunctionBlock 'consume_remote_player'
$drawBlock = Get-LuaFunctionBlock 'draw_remote_marker'
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

Write-Output 'PASS: Lua remote avatar source and reference math checks'
