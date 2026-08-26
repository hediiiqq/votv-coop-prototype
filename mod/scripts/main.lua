local UEHelpers = require("UEHelpers")

local MOD = "[VotVCoopPrototype] "
local game_directories = IterateGameDirectories()
local win64_directory = game_directories.Game.Binaries.Win64.__absolute_path:gsub("\\", "/")
local mod_dir = win64_directory .. "/Mods/VotVCoopPrototype"

local function read_config(path)
    local result = { role = "host", host = "127.0.0.1", port = "27071", name = "Player" }
    local file = io.open(path, "r")
    if not file then return result end
    for line in file:lines() do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key and value and not key:match("^#") then result[key:lower()] = value end
    end
    file:close()
    return result
end

local config = read_config(mod_dir .. "/config.ini")
local bridge_dir = mod_dir .. "/runtime"
local local_state = bridge_dir .. "/local_state.txt"
local remote_state = bridge_dir .. "/remote_state.txt"
local status_file = bridge_dir .. "/status.txt"
local sequence = 0
local last_remote_sequence = -1
local last_remote_name = ""
local target_remote_x, target_remote_y, target_remote_z = 0, 0, 0
local target_remote_yaw = 0
local rendered_remote_x, rendered_remote_y, rendered_remote_z = 0, 0, 0
local rendered_remote_yaw = 0
local remote_has_rendered_state = false
local remote_smoothing = 0.2
local last_remote_update = 0
local kismet_system_library = nil

local function safe_argument(value)
    return '"' .. tostring(value):gsub('"', '') .. '"'
end

local function start_bridge()
    os.execute('mkdir "' .. bridge_dir:gsub('/', '\\') .. '" 2>nul')
    local executable = (mod_dir .. "/tools/VotVCoopBridge.exe"):gsub('/', '\\')
    local command = string.format('start "VotV Coop Bridge" /MIN "%s" --role %s --bridge %s --host %s --port %s --name %s',
        executable, safe_argument(config.role), safe_argument(bridge_dir), safe_argument(config.host),
        safe_argument(config.port), safe_argument(config.name))
    os.execute(command)
end

local function atomic_write(path, value)
    local temp = path .. ".tmp"
    local file = io.open(temp, "w")
    if not file then return false end
    file:write(value)
    file:close()
    os.remove(path)
    return os.rename(temp, path) ~= nil
end

local function read_all(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local value = file:read()
    file:close()
    return value
end

local function split(value)
    local result = {}
    for part in string.gmatch(value or "", "([^|]+)") do
        result[#result + 1] = part
    end
    return result
end

local function normalize_yaw(yaw)
    return (yaw + 180.0) % 360.0 - 180.0
end

local function is_finite_number(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function capture_local_player()
    local controller = UEHelpers:GetPlayerController()
    if not controller or not controller:IsValid() then return end
    local pawn = controller.Pawn
    if not pawn or not pawn:IsValid() then return end

    local location = pawn:K2_GetActorLocation()
    local rotation = pawn:K2_GetActorRotation()
    sequence = sequence + 1
    atomic_write(local_state, string.format("%d|%.3f|%.3f|%.3f|%.3f",
        sequence, location.X, location.Y, location.Z, rotation.Yaw))
end

local function consume_remote_player()
    local fields = split(read_all(remote_state))
    -- Bridge writes: name|sequence|x|y|z|yaw
    if #fields < 6 then return end
    local remote_sequence = tonumber(fields[2])
    local remote_x = tonumber(fields[3])
    local remote_y = tonumber(fields[4])
    local remote_z = tonumber(fields[5])
    local remote_yaw = tonumber(fields[6])
    if not is_finite_number(remote_sequence) or remote_sequence == last_remote_sequence then return end
    if not is_finite_number(remote_x) or not is_finite_number(remote_y)
        or not is_finite_number(remote_z) or not is_finite_number(remote_yaw) then return end

    last_remote_sequence = remote_sequence
    last_remote_name = fields[1]
    target_remote_x = remote_x
    target_remote_y = remote_y
    target_remote_z = remote_z
    target_remote_yaw = normalize_yaw(remote_yaw)
    if not remote_has_rendered_state then
        rendered_remote_x = target_remote_x
        rendered_remote_y = target_remote_y
        rendered_remote_z = target_remote_z
        rendered_remote_yaw = target_remote_yaw
        remote_has_rendered_state = true
    end
    last_remote_update = os.clock()
end

local function draw_remote_marker()
    if last_remote_sequence < 0 or os.clock() - last_remote_update > 2.0 then return end
    rendered_remote_x = rendered_remote_x + (target_remote_x - rendered_remote_x) * remote_smoothing
    rendered_remote_y = rendered_remote_y + (target_remote_y - rendered_remote_y) * remote_smoothing
    rendered_remote_z = rendered_remote_z + (target_remote_z - rendered_remote_z) * remote_smoothing
    local yaw_delta = normalize_yaw(target_remote_yaw - rendered_remote_yaw)
    rendered_remote_yaw = normalize_yaw(rendered_remote_yaw + yaw_delta * remote_smoothing)

    local controller = UEHelpers:GetPlayerController()
    if not controller or not controller:IsValid() then return end
    local pawn = controller.Pawn
    if not pawn or not pawn:IsValid() then return end

    if not kismet_system_library or not kismet_system_library:IsValid() then
        kismet_system_library = UEHelpers.GetKismetSystemLibrary()
    end
    if not kismet_system_library or not kismet_system_library:IsValid() then return end

    local center = { X = rendered_remote_x, Y = rendered_remote_y, Z = rendered_remote_z + 90.0 }
    local color = { R = 1.0, G = 0.05, B = 0.05, A = 1.0 }
    local capsule_rotation = { Pitch = 0.0, Yaw = rendered_remote_yaw, Roll = 0.0 }
    local yaw_radians = math.rad(rendered_remote_yaw)
    local facing_end = {
        X = center.X + math.cos(yaw_radians) * 70.0,
        Y = center.Y + math.sin(yaw_radians) * 70.0,
        Z = center.Z
    }
    kismet_system_library:DrawDebugCapsule(pawn, center, 90.0, 34.0, capsule_rotation, color, 0.12, 4.0)
    kismet_system_library:DrawDebugLine(pawn, center, facing_end, color, 0.12, 4.0)
end

local function tick()
    local ok, error_message = pcall(function()
        capture_local_player()
        consume_remote_player()
        draw_remote_marker()
    end)
    if not ok then print(MOD .. "tick failed: " .. tostring(error_message) .. "\n") end
end

RegisterKeyBind(Key.F8, function()
    local status = (read_all(status_file) or "bridge not running"):gsub("%s+$", "")
    print(string.format("%s%s; remote %s at X=%.1f Y=%.1f Z=%.1f\n",
        MOD, status, last_remote_name, target_remote_x, target_remote_y, target_remote_z))
end)

start_bridge()
print(string.format("%sloaded as %s; bridge directory: %s\n", MOD, config.role, bridge_dir))
LoopAsync(50, function()
    ExecuteInGameThread(tick)
    return false
end)
