local coop_util = {}

local function is_finite_number(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function normalize_yaw(yaw)
    return (yaw + 180.0) % 360.0 - 180.0
end

local function invert_look_yaw(yaw)
    return normalize_yaw(yaw + 180.0)
end

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

local function safe_argument(value)
    return '"' .. tostring(value):gsub('"', '') .. '"'
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

local function get_local_floor_z(pawn)
    if not pawn or not pawn:IsValid() then return 0.0 end
    local location = nil
    local loc_ok = pcall(function()
        location = pawn:K2_GetActorLocation()
    end)
    if not loc_ok or not location or not is_finite_number(location.Z) then return 0.0 end

    local actor_z = location.Z
    local half_height = nil

    pcall(function()
        local capsule = pawn.CapsuleComponent
        if capsule and capsule:IsValid() then
            local hh = nil
            pcall(function() hh = capsule:GetScaledCapsuleHalfHeight() end)
            if not is_finite_number(hh) or hh <= 0 then
                pcall(function() hh = capsule:GetUnscaledCapsuleHalfHeight() end)
            end
            if not is_finite_number(hh) or hh <= 0 then
                pcall(function() hh = capsule.CapsuleHalfHeight end)
            end
            if is_finite_number(hh) and hh > 0 then
                half_height = hh
            end
        end
    end)

    if not half_height then
        pcall(function()
            local root = pawn.RootComponent
            if root and root:IsValid() then
                local hh = nil
                pcall(function() hh = root:GetScaledCapsuleHalfHeight() end)
                if not is_finite_number(hh) or hh <= 0 then
                    pcall(function() hh = root.CapsuleHalfHeight end)
                end
                if is_finite_number(hh) and hh > 0 then
                    half_height = hh
                end
            end
        end)
    end

    if not half_height then
        pcall(function()
            local mesh = pawn.Mesh
            if mesh and mesh:IsValid() then
                local min_vec, max_vec = nil, nil
                pcall(function() min_vec, max_vec = mesh:GetLocalBounds() end)
                if min_vec and max_vec and is_finite_number(min_vec.Z) and is_finite_number(max_vec.Z) then
                    local hh = (max_vec.Z - min_vec.Z) / 2.0
                    if hh > 0 then
                        half_height = hh
                    end
                end
            end
        end)
    end

    if half_height then
        return actor_z - half_height
    end

    return actor_z
end

local function get_local_look_yaw(controller, pawn)
    if controller and controller:IsValid() then
        local control_yaw = nil
        pcall(function()
            local rot = controller:GetControlRotation()
            if rot and is_finite_number(rot.Yaw) then
                control_yaw = rot.Yaw
            end
        end)
        if not control_yaw then
            pcall(function()
                local rot = controller.ControlRotation
                if rot and is_finite_number(rot.Yaw) then
                    control_yaw = rot.Yaw
                end
            end)
        end
        if control_yaw then
            return control_yaw
        end
    end

    if pawn and pawn:IsValid() then
        local actor_yaw = nil
        pcall(function()
            local rot = pawn:K2_GetActorRotation()
            if rot and is_finite_number(rot.Yaw) then
                actor_yaw = rot.Yaw
            end
        end)
        if actor_yaw then
            return actor_yaw
        end
    end

    return 0.0
end

local function safe_object_identity(object)
    if not object then return nil end
    local ok, address = pcall(function()
        return object:GetAddress()
    end)
    if ok and address ~= nil then return "address:" .. tostring(address) end
    return object
end

local function safe_full_name(object)
    local ok, full_name = pcall(function()
        return object:GetFullName()
    end)
    if ok and full_name then return tostring(full_name) end
    return "<unknown>"
end

coop_util.is_finite_number = is_finite_number
coop_util.normalize_yaw = normalize_yaw
coop_util.invert_look_yaw = invert_look_yaw
coop_util.read_config = read_config
coop_util.safe_argument = safe_argument
coop_util.atomic_write = atomic_write
coop_util.read_all = read_all
coop_util.split = split
coop_util.get_local_floor_z = get_local_floor_z
coop_util.get_local_look_yaw = get_local_look_yaw
coop_util.safe_object_identity = safe_object_identity
coop_util.safe_full_name = safe_full_name

return coop_util
