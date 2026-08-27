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

    local color = { R = 1.0, G = 0.85, B = 0.0, A = 1.0 }
    local base_x = rendered_local_action_x
    local base_y = rendered_local_action_y
    local base_z = rendered_local_action_z
    local yaw = rendered_local_action_yaw

    -- Vertical beacon pillar above player head
    local pillar_bottom = { X = base_x, Y = base_y, Z = base_z + 180.0 }
    local pillar_top = { X = base_x, Y = base_y, Z = base_z + 480.0 }
    kismet_system_library:DrawDebugLine(pawn, pillar_bottom, pillar_top, color, 0.12, 6.0)

    -- Above-head beacon capsule
    local beacon_center = { X = base_x, Y = base_y, Z = base_z + 240.0 }
    local capsule_rotation = { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }
    kismet_system_library:DrawDebugCapsule(pawn, beacon_center, 40.0, 30.0, capsule_rotation, color, 0.12, 4.0)

    -- Horizontal cross at beacon center
    local cross_arm_len = 45.0
    local cross_x1 = { X = beacon_center.X - cross_arm_len, Y = beacon_center.Y, Z = beacon_center.Z }
    local cross_x2 = { X = beacon_center.X + cross_arm_len, Y = beacon_center.Y, Z = beacon_center.Z }
    local cross_y1 = { X = beacon_center.X, Y = beacon_center.Y - cross_arm_len, Z = beacon_center.Z }
    local cross_y2 = { X = beacon_center.X, Y = beacon_center.Y + cross_arm_len, Z = beacon_center.Z }
    kismet_system_library:DrawDebugLine(pawn, cross_x1, cross_x2, color, 0.12, 4.0)
    kismet_system_library:DrawDebugLine(pawn, cross_y1, cross_y2, color, 0.12, 4.0)

    -- Directional arrow preserving yaw
    local yaw_radians = math.rad(yaw)
    local arrow_len = 120.0
    local arrow_tip = {
        X = beacon_center.X + math.cos(yaw_radians) * arrow_len,
        Y = beacon_center.Y + math.sin(yaw_radians) * arrow_len,
        Z = beacon_center.Z
    }
    kismet_system_library:DrawDebugLine(pawn, beacon_center, arrow_tip, color, 0.12, 6.0)

    local left_yaw = math.rad(yaw + 150.0)
    local right_yaw = math.rad(yaw - 150.0)
    local wing_len = 35.0
    local arrow_left = {
        X = arrow_tip.X + math.cos(left_yaw) * wing_len,
        Y = arrow_tip.Y + math.sin(left_yaw) * wing_len,
        Z = arrow_tip.Z
    }
    local arrow_right = {
        X = arrow_tip.X + math.cos(right_yaw) * wing_len,
        Y = arrow_tip.Y + math.sin(right_yaw) * wing_len,
        Z = arrow_tip.Z
    }
    kismet_system_library:DrawDebugLine(pawn, arrow_tip, arrow_left, color, 0.12, 5.0)
    kismet_system_library:DrawDebugLine(pawn, arrow_tip, arrow_right, color, 0.12, 5.0)

    pcall(function()
        kismet_system_library:DrawDebugString(pawn, { X = base_x, Y = base_y, Z = base_z + 500.0 }, last_local_action_name or "Ping", pawn, color, 0.12)
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

    local color = { R = 0.0, G = 1.0, B = 1.0, A = 1.0 }
    local base_x = rendered_action_x
    local base_y = rendered_action_y
    local base_z = rendered_action_z
    local yaw = rendered_action_yaw

    -- Vertical beacon pillar above avatar head
    local pillar_bottom = { X = base_x, Y = base_y, Z = base_z + 180.0 }
    local pillar_top = { X = base_x, Y = base_y, Z = base_z + 480.0 }
    kismet_system_library:DrawDebugLine(pawn, pillar_bottom, pillar_top, color, 0.12, 6.0)

    -- Above-head beacon capsule
    local beacon_center = { X = base_x, Y = base_y, Z = base_z + 240.0 }
    local capsule_rotation = { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }
    kismet_system_library:DrawDebugCapsule(pawn, beacon_center, 40.0, 30.0, capsule_rotation, color, 0.12, 4.0)

    -- Horizontal cross at beacon center
    local cross_arm_len = 45.0
    local cross_x1 = { X = beacon_center.X - cross_arm_len, Y = beacon_center.Y, Z = beacon_center.Z }
    local cross_x2 = { X = beacon_center.X + cross_arm_len, Y = beacon_center.Y, Z = beacon_center.Z }
    local cross_y1 = { X = beacon_center.X, Y = beacon_center.Y - cross_arm_len, Z = beacon_center.Z }
    local cross_y2 = { X = beacon_center.X, Y = beacon_center.Y + cross_arm_len, Z = beacon_center.Z }
    kismet_system_library:DrawDebugLine(pawn, cross_x1, cross_x2, color, 0.12, 4.0)
    kismet_system_library:DrawDebugLine(pawn, cross_y1, cross_y2, color, 0.12, 4.0)

    -- Directional arrow preserving yaw
    local yaw_radians = math.rad(yaw)
    local arrow_len = 120.0
    local arrow_tip = {
        X = beacon_center.X + math.cos(yaw_radians) * arrow_len,
        Y = beacon_center.Y + math.sin(yaw_radians) * arrow_len,
        Z = beacon_center.Z
    }
    kismet_system_library:DrawDebugLine(pawn, beacon_center, arrow_tip, color, 0.12, 6.0)

    local left_yaw = math.rad(yaw + 150.0)
    local right_yaw = math.rad(yaw - 150.0)
    local wing_len = 35.0
    local arrow_left = {
        X = arrow_tip.X + math.cos(left_yaw) * wing_len,
        Y = arrow_tip.Y + math.sin(left_yaw) * wing_len,
        Z = arrow_tip.Z
    }
    local arrow_right = {
        X = arrow_tip.X + math.cos(right_yaw) * wing_len,
        Y = arrow_tip.Y + math.sin(right_yaw) * wing_len,
        Z = arrow_tip.Z
    }
    kismet_system_library:DrawDebugLine(pawn, arrow_tip, arrow_left, color, 0.12, 5.0)
    kismet_system_library:DrawDebugLine(pawn, arrow_tip, arrow_right, color, 0.12, 5.0)

    pcall(function()
        local label = (last_remote_peer_name ~= "" and (last_remote_peer_name .. ": " .. last_remote_action_name)) or last_remote_action_name or "Ping"
        kismet_system_library:DrawDebugString(pawn, { X = base_x, Y = base_y, Z = base_z + 500.0 }, label, pawn, color, 0.12)
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

