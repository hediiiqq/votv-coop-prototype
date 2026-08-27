local coop_actions = {}

local UEHelpers = nil
local MOD = "[VotVCoopPrototype] "
local paths = nil
local util = nil
local local_action = nil
local remote_action = nil

local is_finite_number = nil
local normalize_yaw = nil
local invert_look_yaw = nil
local get_local_floor_z = nil
local get_local_look_yaw = nil
local atomic_write = nil
local read_all = nil
local split = nil

local action_sequence = 0
local last_local_action_sequence = -1
local last_local_action_name = ""
local last_local_action_time = 0
local rendered_local_action_x, rendered_local_action_y, rendered_local_action_z = 0, 0, 0
local rendered_local_action_yaw = 0

local last_remote_action_sequence = -1
local last_remote_action_name = ""
local last_remote_peer_name = ""
local last_remote_action_time = 0
local rendered_action_x, rendered_action_y, rendered_action_z = 0, 0, 0
local rendered_action_yaw = 0
local kismet_system_library = nil

local function sanitize_action_name(name)
    return tostring(name or "Ping"):gsub("|", "_")
end

local function emit_local_action(action_name)
    local controller = UEHelpers:GetPlayerController()
    if not controller or not controller:IsValid() then return end
    local pawn = controller.Pawn
    if not pawn or not pawn:IsValid() then return end

    local location = pawn:K2_GetActorLocation()
    if not location or not is_finite_number(location.X) or not is_finite_number(location.Y) or not is_finite_number(location.Z) then return end
    local floor_z = get_local_floor_z(pawn)
    local look_yaw = invert_look_yaw(get_local_look_yaw(controller, pawn))
    local sanitized_name = sanitize_action_name(action_name)
    action_sequence = action_sequence + 1
    atomic_write(local_action, string.format("%d|%s|%.3f|%.3f|%.3f|%.3f",
        action_sequence, sanitized_name, location.X, location.Y, floor_z, look_yaw))

    last_local_action_sequence = action_sequence
    last_local_action_name = sanitized_name
    rendered_local_action_x = location.X
    rendered_local_action_y = location.Y
    rendered_local_action_z = floor_z
    rendered_local_action_yaw = normalize_yaw(look_yaw)
    last_local_action_time = os.clock()

    print(string.format("%semitted action %s (#%d) at X=%.1f Y=%.1f Z=%.1f yaw=%.1f\n",
        MOD, sanitized_name, action_sequence, location.X, location.Y, floor_z, look_yaw))
end

local function consume_remote_action()
    local fields = split(read_all(remote_action))
    -- Bridge writes: peer_name|action_sequence|action_name|x|y|z|yaw
    if #fields < 7 then return end
    local peer_name = fields[1]
    local remote_action_sequence = tonumber(fields[2])
    local action_name = fields[3]
    local remote_x = tonumber(fields[4])
    local remote_y = tonumber(fields[5])
    local remote_z = tonumber(fields[6])
    local remote_yaw = tonumber(fields[7])
    if not is_finite_number(remote_action_sequence) or remote_action_sequence == last_remote_action_sequence then return end
    if not action_name or action_name == "" then return end
    if not is_finite_number(remote_x) or not is_finite_number(remote_y)
        or not is_finite_number(remote_z) or not is_finite_number(remote_yaw) then return end

    last_remote_action_sequence = remote_action_sequence
    last_remote_action_name = action_name
    last_remote_peer_name = peer_name
    rendered_action_x = remote_x
    rendered_action_y = remote_y
    rendered_action_z = remote_z
    rendered_action_yaw = normalize_yaw(remote_yaw)
    last_remote_action_time = os.clock()
    print(string.format("%saction %s (#%d) from %s at X=%.1f Y=%.1f Z=%.1f yaw=%.1f\n",
        MOD, action_name, remote_action_sequence, peer_name, remote_x, remote_y, remote_z, rendered_action_yaw))
end

local function draw_local_action_marker()
    if last_local_action_sequence < 0 or os.clock() - last_local_action_time > 5.0 then
        return
    end
    local controller = UEHelpers:GetPlayerController()
    if not controller or not controller:IsValid() then return end
    local pawn = controller.Pawn
    if not pawn or not pawn:IsValid() then return end

    if not kismet_system_library or not kismet_system_library:IsValid() then
        kismet_system_library = UEHelpers.GetKismetSystemLibrary()
    end
    if not kismet_system_library or not kismet_system_library:IsValid() then return end

    local center = { X = rendered_local_action_x, Y = rendered_local_action_y, Z = rendered_local_action_z + 90.0 }
    local color = { R = 1.0, G = 0.85, B = 0.0, A = 1.0 }
    local capsule_rotation = { Pitch = 0.0, Yaw = rendered_local_action_yaw, Roll = 0.0 }
    local yaw_radians = math.rad(rendered_local_action_yaw)
    local facing_end = {
        X = center.X + math.cos(yaw_radians) * 70.0,
        Y = center.Y + math.sin(yaw_radians) * 70.0,
        Z = center.Z
    }
    kismet_system_library:DrawDebugCapsule(pawn, center, 90.0, 34.0, capsule_rotation, color, 0.12, 4.0)
    kismet_system_library:DrawDebugLine(pawn, center, facing_end, color, 0.12, 4.0)
    pcall(function()
        kismet_system_library:DrawDebugString(pawn, { X = center.X, Y = center.Y, Z = center.Z + 95.0 }, last_local_action_name or "Ping", pawn, color, 0.12)
    end)
end

local function draw_remote_action_marker()
    if last_remote_action_sequence < 0 or os.clock() - last_remote_action_time > 5.0 then
        return
    end
    local controller = UEHelpers:GetPlayerController()
    if not controller or not controller:IsValid() then return end
    local pawn = controller.Pawn
    if not pawn or not pawn:IsValid() then return end

    if not kismet_system_library or not kismet_system_library:IsValid() then
        kismet_system_library = UEHelpers.GetKismetSystemLibrary()
    end
    if not kismet_system_library or not kismet_system_library:IsValid() then return end

    local center = { X = rendered_action_x, Y = rendered_action_y, Z = rendered_action_z + 90.0 }
    local color = { R = 0.0, G = 1.0, B = 1.0, A = 1.0 }
    local capsule_rotation = { Pitch = 0.0, Yaw = rendered_action_yaw, Roll = 0.0 }
    local yaw_radians = math.rad(rendered_action_yaw)
    local facing_end = {
        X = center.X + math.cos(yaw_radians) * 70.0,
        Y = center.Y + math.sin(yaw_radians) * 70.0,
        Z = center.Z
    }
    kismet_system_library:DrawDebugCapsule(pawn, center, 90.0, 34.0, capsule_rotation, color, 0.12, 4.0)
    kismet_system_library:DrawDebugLine(pawn, center, facing_end, color, 0.12, 4.0)
    pcall(function()
        local label = (last_remote_peer_name ~= "" and (last_remote_peer_name .. ": " .. last_remote_action_name)) or last_remote_action_name or "Ping"
        kismet_system_library:DrawDebugString(pawn, { X = center.X, Y = center.Y, Z = center.Z + 95.0 }, label, pawn, color, 0.12)
    end)
end

local function init(deps)
    UEHelpers = deps.UEHelpers
    if deps.MOD then MOD = deps.MOD end
    paths = deps.paths
    util = deps.util or deps.coop_util
    if paths then
        local_action = paths.local_action
        remote_action = paths.remote_action
    end
    if util then
        is_finite_number = util.is_finite_number
        normalize_yaw = util.normalize_yaw
        invert_look_yaw = util.invert_look_yaw
        get_local_floor_z = util.get_local_floor_z
        get_local_look_yaw = util.get_local_look_yaw
        atomic_write = util.atomic_write
        read_all = util.read_all
        split = util.split
    end
end

coop_actions.init = init
coop_actions.create = function(deps)
    init(deps)
    return coop_actions
end
coop_actions.sanitize_action_name = sanitize_action_name
coop_actions.emit_local_action = emit_local_action
coop_actions.consume_remote_action = consume_remote_action
coop_actions.draw_local_action_marker = draw_local_action_marker
coop_actions.draw_remote_action_marker = draw_remote_action_marker

return coop_actions

