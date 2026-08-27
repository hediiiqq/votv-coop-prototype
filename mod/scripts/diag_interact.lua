local diag_interact = {}

local UEHelpers = nil
local MOD = "[VotVCoopPrototype] "
local DIAG_TAG = "[Diag] "
local paths = nil
local util = nil
local kismet_system_library = nil

local function log_diag(msg)
    print(string.format("%s%s%s\n", MOD, DIAG_TAG, msg))
end

local function safe_get_name(obj)
    if not obj then return "<nil>" end
    local name = nil
    pcall(function()
        if obj.GetFName then
            name = obj:GetFName():ToString()
        end
    end)
    return name or "<unknown>"
end

local function safe_get_full_name(obj)
    if not obj then return "<nil>" end
    local full_name = nil
    pcall(function()
        if obj.GetFullName then
            full_name = obj:GetFullName()
        end
    end)
    return full_name or "<unknown>"
end

local function safe_format_property_value(actor, prop_name, prop)
    if not actor then return "<invalid actor>" end
    local val_str = "<unreadable>"
    local ok, res = pcall(function()
        local val = actor[prop_name]
        if val == nil then
            return "nil"
        end
        local val_type = type(val)
        if val_type == "boolean" then
            return val and "true" or "false"
        elseif val_type == "number" then
            return string.format("%g", val)
        elseif val_type == "string" then
            return string.format("%q", val)
        elseif val_type == "userdata" or val_type == "table" then
            local formatted = nil
            pcall(function()
                if val.GetFullName then
                    formatted = string.format("[UObject: %s]", tostring(val:GetFullName()))
                end
            end)
            if not formatted then
                pcall(function()
                    if val.X ~= nil and val.Y ~= nil and val.Z ~= nil then
                        formatted = string.format("FVector(X=%.2f, Y=%.2f, Z=%.2f)", val.X, val.Y, val.Z)
                    end
                end)
            end
            if not formatted then
                pcall(function()
                    if val.Pitch ~= nil and val.Yaw ~= nil and val.Roll ~= nil then
                        formatted = string.format("FRotator(P=%.2f, Y=%.2f, R=%.2f)", val.Pitch, val.Yaw, val.Roll)
                    end
                end)
            end
            if not formatted then
                pcall(function()
                    if val.ToString then
                        formatted = tostring(val:ToString())
                    end
                end)
            end
            if not formatted then
                pcall(function()
                    if val.GetArrayNum then
                        formatted = string.format("[Array num=%d]", val:GetArrayNum())
                    end
                end)
            end
            return formatted or tostring(val)
        else
            return tostring(val)
        end
    end)
    if ok and res ~= nil then
        val_str = res
    else
        val_str = "<error: " .. tostring(res) .. ">"
    end
    return val_str
end

local function extract_hit_actor(hit_result)
    if not hit_result then return nil end
    local actor = nil

    pcall(function()
        if UEHelpers and UEHelpers.GetActorFromHitResult then
            local candidate = UEHelpers.GetActorFromHitResult(hit_result)
            if candidate and candidate:IsValid() then
                actor = candidate
            end
        end
    end)
    if actor then return actor end

    pcall(function()
        if hit_result.Actor and hit_result.Actor.Get then
            local candidate = hit_result.Actor:Get()
            if candidate and candidate:IsValid() then
                actor = candidate
            end
        elseif hit_result.Actor and hit_result.Actor:IsValid() then
            actor = hit_result.Actor
        end
    end)
    if actor then return actor end

    pcall(function()
        if hit_result.HitObjectHandle then
            if hit_result.HitObjectHandle.Actor and hit_result.HitObjectHandle.Actor.Get then
                local candidate = hit_result.HitObjectHandle.Actor:Get()
                if candidate and candidate:IsValid() then
                    actor = candidate
                end
            elseif hit_result.HitObjectHandle.ReferenceObject and hit_result.HitObjectHandle.ReferenceObject.Get then
                local candidate = hit_result.HitObjectHandle.ReferenceObject:Get()
                if candidate and candidate:IsValid() then
                    actor = candidate
                end
            end
        end
    end)
    if actor then return actor end

    pcall(function()
        if hit_result.GetActor then
            local candidate = hit_result:GetActor()
            if candidate and candidate:IsValid() then
                actor = candidate
            end
        end
    end)

    return actor
end

local function extract_hit_component(hit_result)
    if not hit_result then return nil end
    local comp = nil
    pcall(function()
        if hit_result.Component and hit_result.Component.Get then
            local candidate = hit_result.Component:Get()
            if candidate and candidate:IsValid() then comp = candidate end
        elseif hit_result.Component and hit_result.Component:IsValid() then
            comp = hit_result.Component
        end
    end)
    if comp then return comp end
    pcall(function()
        if hit_result.HitComponent and hit_result.HitComponent.Get then
            local candidate = hit_result.HitComponent:Get()
            if candidate and candidate:IsValid() then comp = candidate end
        elseif hit_result.HitComponent and hit_result.HitComponent:IsValid() then
            comp = hit_result.HitComponent
        end
    end)
    return comp
end

local function inspect_actor(actor, hit_component, hit_point, distance)
    local ok, err = pcall(function()
        local actor_name = safe_get_name(actor)
        local actor_full_name = safe_get_full_name(actor)
        local actor_class = nil
        pcall(function() actor_class = actor:GetClass() end)
        local class_full_name = safe_get_full_name(actor_class)

        local actor_loc_str = "<unknown>"
        pcall(function()
            local loc = actor:K2_GetActorLocation()
            if loc then
                actor_loc_str = string.format("X=%.1f, Y=%.1f, Z=%.1f", loc.X, loc.Y, loc.Z)
            end
        end)

        local hit_comp_name = hit_component and safe_get_full_name(hit_component) or "None"

        -- Collect class hierarchy
        local hierarchy = {}
        local current_class = actor_class
        while current_class and current_class:IsValid() do
            local c_name = safe_get_full_name(current_class)
            table.insert(hierarchy, { class_obj = current_class, name = c_name, functions = {}, properties = {} })

            local parent_class = nil
            pcall(function() parent_class = current_class:GetSuperStruct() end)
            if not parent_class or not parent_class:IsValid() then
                pcall(function()
                    if current_class.GetSuperClass then
                        parent_class = current_class:GetSuperClass()
                    end
                end)
            end
            current_class = parent_class
        end

        -- Collect functions and properties for each class in hierarchy
        local key_function_candidates = {}

        for _, class_entry in ipairs(hierarchy) do
            local class_obj = class_entry.class_obj

            -- Functions
            pcall(function()
                class_obj:ForEachFunction(function(func)
                    local fname = safe_get_name(func)
                    local full_fname = safe_get_full_name(func)
                    local params = {}
                    pcall(function()
                        func:ForEachProperty(function(param_prop)
                            local pname = safe_get_name(param_prop)
                            local ptype = safe_get_name(param_prop:GetClass())
                            table.insert(params, ptype .. " " .. pname)
                        end)
                    end)

                    local fn_info = {
                        name = fname,
                        full_name = full_fname,
                        params = params,
                        defining_class = class_entry.name,
                    }
                    table.insert(class_entry.functions, fn_info)

                    -- Check if potential interaction candidate
                    local lower_name = fname:lower()
                    if lower_name:find("interact") or lower_name:find("use") or lower_name:find("door")
                        or lower_name:find("open") or lower_name:find("close") or lower_name:find("toggle")
                        or lower_name:find("press") or lower_name:find("button") or lower_name:find("switch")
                        or lower_name:find("lock") or lower_name:find("action") or lower_name:find("trigger")
                        or lower_name:find("bndevt") or lower_name:find("click") or lower_name:find("touch") then
                        table.insert(key_function_candidates, fn_info)
                    end
                end)
            end)

            -- Properties
            pcall(function()
                class_obj:ForEachProperty(function(prop)
                    local pname = safe_get_name(prop)
                    local ptype = safe_get_name(prop:GetClass())
                    local poffset = nil
                    pcall(function() poffset = prop:GetOffset_Internal() end)
                    local val_str = safe_format_property_value(actor, pname, prop)

                    table.insert(class_entry.properties, {
                        name = pname,
                        type = ptype,
                        offset = poffset,
                        value_str = val_str,
                    })
                end)
            end)
        end

        -- Print structured diagnostic output
        print(string.format("\n%s%s==================== INTERACTION TARGET DIAGNOSTIC ====================\n", MOD, DIAG_TAG))
        log_diag(string.format("TARGET ACTOR: %s", actor_name))
        log_diag(string.format("ACTOR FULL PATH: %s", actor_full_name))
        log_diag(string.format("ACTOR CLASS: %s", class_full_name))
        log_diag(string.format("ACTOR LOCATION: %s", actor_loc_str))
        log_diag(string.format("HIT LOCATION: X=%.1f, Y=%.1f, Z=%.1f (Distance: %.1f units)", hit_point.X or 0, hit_point.Y or 0, hit_point.Z or 0, distance or 0))
        log_diag(string.format("HIT COMPONENT: %s", hit_comp_name))

        log_diag("--- CLASS INHERITANCE CHAIN ---")
        for idx, entry in ipairs(hierarchy) do
            log_diag(string.format("  [%d] %s", idx, entry.name))
        end

        if #key_function_candidates > 0 then
            log_diag("--- KEY INTERACTION CANDIDATE FUNCTIONS ---")
            for _, fn in ipairs(key_function_candidates) do
                local param_str = table.concat(fn.params, ", ")
                log_diag(string.format("  * %s(%s) [Defined in: %s]", fn.name, param_str, fn.defining_class))
            end
        end

        log_diag("--- ALL UFUNCTIONS (BY CLASS) ---")
        for _, entry in ipairs(hierarchy) do
            if #entry.functions > 0 then
                log_diag(string.format("  [%s] (%d functions):", entry.name, #entry.functions))
                for _, fn in ipairs(entry.functions) do
                    local param_str = table.concat(fn.params, ", ")
                    log_diag(string.format("    - %s(%s)", fn.name, param_str))
                end
            else
                log_diag(string.format("  [%s] (0 functions)", entry.name))
            end
        end

        log_diag("--- ALL PROPERTIES & CURRENT VALUES (BY CLASS) ---")
        for _, entry in ipairs(hierarchy) do
            if #entry.properties > 0 then
                log_diag(string.format("  [%s] (%d properties):", entry.name, #entry.properties))
                for _, prop in ipairs(entry.properties) do
                    local offset_str = prop.offset and string.format(" [offset: 0x%04X]", prop.offset) or ""
                    log_diag(string.format("    - %s %s = %s%s", prop.type, prop.name, prop.value_str, offset_str))
                end
            else
                log_diag(string.format("  [%s] (0 properties)", entry.name))
            end
        end

        print(string.format("%s%s=======================================================================\n\n", MOD, DIAG_TAG))
    end)

    if not ok then
        log_diag("Error while inspecting actor: " .. tostring(err))
    end
end

local function inspect_object_under_crosshair()
    local ok, error_message = pcall(function()
        local controller = UEHelpers:GetPlayerController()
        if not controller or not controller:IsValid() then
            log_diag("Raycast ignored: PlayerController is not valid.")
            return
        end
        local pawn = controller.Pawn
        if not pawn or not pawn:IsValid() then
            log_diag("Raycast ignored: Player Pawn is not valid.")
            return
        end

        local camera_manager = controller.PlayerCameraManager
        local start_loc = nil
        local cam_rot = nil
        if camera_manager and camera_manager:IsValid() then
            pcall(function() start_loc = camera_manager:GetCameraLocation() end)
            pcall(function() cam_rot = camera_manager:GetCameraRotation() end)
        end
        if not start_loc then
            pcall(function()
                local loc = pawn:K2_GetActorLocation()
                if loc then
                    start_loc = { X = loc.X, Y = loc.Y, Z = loc.Z + 60.0 }
                end
            end)
        end
        if not cam_rot then
            pcall(function() cam_rot = controller:GetControlRotation() end)
        end
        if not cam_rot then
            pcall(function() cam_rot = pawn:K2_GetActorRotation() end)
        end

        if not start_loc or not cam_rot then
            log_diag("Raycast ignored: unable to obtain camera location or rotation.")
            return
        end

        local pitch = cam_rot.Pitch or 0.0
        local yaw = cam_rot.Yaw or 0.0
        local pitch_rad = math.rad(pitch)
        local yaw_rad = math.rad(yaw)
        local cos_pitch = math.cos(pitch_rad)
        local forward_x = cos_pitch * math.cos(yaw_rad)
        local forward_y = cos_pitch * math.sin(yaw_rad)
        local forward_z = math.sin(pitch_rad)
        local trace_distance = 15000.0 -- 150 meters

        local end_loc = {
            X = start_loc.X + forward_x * trace_distance,
            Y = start_loc.Y + forward_y * trace_distance,
            Z = start_loc.Z + forward_z * trace_distance,
        }

        if not kismet_system_library or not kismet_system_library:IsValid() then
            kismet_system_library = UEHelpers.GetKismetSystemLibrary()
        end
        if not kismet_system_library or not kismet_system_library:IsValid() then
            log_diag("Raycast failed: KismetSystemLibrary unavailable.")
            return
        end

        local trace_color = { R = 0.0, G = 1.0, B = 0.0, A = 1.0 }
        local trace_hit_color = { R = 1.0, G = 0.0, B = 0.0, A = 1.0 }
        local actors_to_ignore = {}
        if pawn and pawn:IsValid() then
            table.insert(actors_to_ignore, pawn)
        end

        local hit_result = {}
        local was_hit = false
        local trace_ok, trace_res = pcall(function()
            return kismet_system_library:LineTraceSingle(
                pawn,
                start_loc,
                end_loc,
                0, -- ETraceTypeQuery_TraceTypeQuery1 (Visibility)
                false, -- bTraceComplex
                actors_to_ignore,
                2, -- EDrawDebugTrace_Type_ForDuration
                hit_result,
                true, -- bIgnoreSelf
                trace_color,
                trace_hit_color,
                3.0 -- DrawTime
            )
        end)

        if trace_ok and trace_res then
            was_hit = true
        end

        if not was_hit then
            log_diag(string.format("Raycast MISSED: nothing found in crosshair within %.0f units.", trace_distance))
            return
        end

        local hit_point = hit_result.ImpactPoint or hit_result.Location or { X = 0, Y = 0, Z = 0 }
        local dx = (hit_point.X or 0) - start_loc.X
        local dy = (hit_point.Y or 0) - start_loc.Y
        local dz = (hit_point.Z or 0) - start_loc.Z
        local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

        local hit_actor = extract_hit_actor(hit_result)
        local hit_component = extract_hit_component(hit_result)

        -- Draw debug visual indicator at hit point
        pcall(function()
            local debug_color = { R = 0.0, G = 1.0, B = 1.0, A = 1.0 }
            kismet_system_library:DrawDebugCapsule(pawn, hit_point, 25.0, 15.0, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }, debug_color, 3.0, 2.0)
            kismet_system_library:DrawDebugLine(pawn, start_loc, hit_point, debug_color, 3.0, 1.5)
            kismet_system_library:DrawDebugString(pawn, { X = hit_point.X, Y = hit_point.Y, Z = hit_point.Z + 35.0 }, "[Diag Target]", pawn, debug_color, 3.0)
        end)

        if not hit_actor or not hit_actor:IsValid() then
            log_diag(string.format("Raycast HIT at distance %.1f (X=%.1f, Y=%.1f, Z=%.1f), but no valid AActor was hit (hit component: %s).",
                distance, hit_point.X or 0, hit_point.Y or 0, hit_point.Z or 0,
                hit_component and safe_get_full_name(hit_component) or "None"))
            return
        end

        inspect_actor(hit_actor, hit_component, hit_point, distance)
    end)

    if not ok then
        log_diag("Raycast execution failed: " .. tostring(error_message))
    end
end

local function init(deps)
    UEHelpers = deps.UEHelpers
    if deps.MOD then MOD = deps.MOD end
    paths = deps.paths
    util = deps.util or deps.coop_util
end

diag_interact.init = init
diag_interact.create = function(deps)
    init(deps)
    return diag_interact
end
diag_interact.inspect_object_under_crosshair = inspect_object_under_crosshair
diag_interact.inspect_actor = inspect_actor
diag_interact.extract_hit_actor = extract_hit_actor
diag_interact.extract_hit_component = extract_hit_component
diag_interact.safe_format_property_value = safe_format_property_value

return diag_interact
