local coop_remote_avatar = {}

local UEHelpers = nil
local MOD = "[VotVCoopPrototype] "
local paths = nil
local util = nil
local local_state = nil
local remote_state = nil

local is_finite_number = nil
local normalize_yaw = nil
local invert_look_yaw = nil
local get_local_floor_z = nil
local get_local_look_yaw = nil
local atomic_write = nil
local read_all = nil
local split = nil

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
local skeletal_mesh_actor_class = nil
local remote_player_proxy = nil
local remote_player_proxy_ready = false
local remote_player_proxy_pawn_identity = nil
local remote_player_proxy_world_identity = nil
local remote_player_proxy_mesh_identity = nil
local proxy_failure_reasons = {}
local proxy_failure_interval = 5.0

local function log_proxy_failure(reason)
    local now = os.clock()
    local previous = proxy_failure_reasons[reason]
    if not previous or now - previous >= proxy_failure_interval then
        proxy_failure_reasons[reason] = now
        print(MOD .. "remote proxy unavailable: " .. reason .. "\n")
    end
end

local function safe_full_name(object)
    local ok, full_name = pcall(function()
        return object:GetFullName()
    end)
    if ok and full_name then return tostring(full_name) end
    return "<unknown>"
end

local function has_valid_remote_player_proxy()
    local ok, valid = pcall(function()
        return remote_player_proxy_ready and remote_player_proxy and remote_player_proxy:IsValid()
    end)
    return ok and valid
end

local function safe_object_identity(object)
    if not object then return nil end
    local ok, address = pcall(function()
        return object:GetAddress()
    end)
    if ok and address ~= nil then return "address:" .. tostring(address) end
    return object
end

local function cleanup_proxy_actor(proxy, reason)
    if not proxy then return true end

    local valid_ok, valid_result = pcall(function()
        return proxy:IsValid()
    end)
    if not valid_ok then
        log_proxy_failure("could not verify proxy before cleanup (" .. tostring(reason) .. "): " .. tostring(valid_result))
        return false
    end
    if not valid_result then return true end

    local collision_ok, collision_error = pcall(function()
        proxy:SetActorEnableCollision(false)
    end)
    if not collision_ok then log_proxy_failure("could not disable proxy collision before cleanup (" .. tostring(reason) .. "): " .. tostring(collision_error)) end

    local hide_ok, hide_error = pcall(function()
        proxy:SetActorHiddenInGame(true)
    end)
    if not hide_ok then log_proxy_failure("could not hide proxy before destroy (" .. tostring(reason) .. "): " .. tostring(hide_error)) end

    local destroy_ok, destroy_error = pcall(function()
        proxy:K2_DestroyActor()
    end)
    if not destroy_ok then
        log_proxy_failure("could not destroy proxy (" .. tostring(reason) .. "): " .. tostring(destroy_error))
        return false
    end

    local verify_ok, still_valid = pcall(function()
        return proxy:IsValid()
    end)
    if not verify_ok then
        log_proxy_failure("could not verify proxy after destroy (" .. tostring(reason) .. "): " .. tostring(still_valid))
        return false
    end
    if still_valid then
        log_proxy_failure("proxy remained valid after destroy (" .. tostring(reason) .. ")")
        return false
    end
    return true
end

local function cleanup_remote_player_proxy(reason)
    local proxy = remote_player_proxy
    remote_player_proxy_ready = false
    if not proxy then
        remote_player_proxy_pawn_identity = nil
        remote_player_proxy_world_identity = nil
        remote_player_proxy_mesh_identity = nil
        return true
    end

    if not cleanup_proxy_actor(proxy, reason) then
        log_proxy_failure("proxy cleanup unresolved (" .. tostring(reason) .. ")")
        return false
    end

    remote_player_proxy = nil
    remote_player_proxy_pawn_identity = nil
    remote_player_proxy_world_identity = nil
    remote_player_proxy_mesh_identity = nil
    return true
end

local function hide_remote_player_proxy()
    if not remote_player_proxy then return end
    local proxy = remote_player_proxy
    local ok, error_message = pcall(function()
        if not proxy:IsValid() then error("proxy is invalid") end
        proxy:SetActorHiddenInGame(true)
    end)
    if not ok then
        remote_player_proxy_ready = false
        log_proxy_failure("could not hide proxy: " .. tostring(error_message))
    end
end

local function copy_relative_transform(source_mesh, target_mesh)
    if not source_mesh or not target_mesh then return end
    pcall(function()
        local rel_loc = nil
        pcall(function()
            if source_mesh.RelativeLocation then
                rel_loc = { X = source_mesh.RelativeLocation.X, Y = source_mesh.RelativeLocation.Y, Z = source_mesh.RelativeLocation.Z }
            end
        end)

        local rel_rot = nil
        pcall(function()
            if source_mesh.RelativeRotation then
                rel_rot = { Pitch = source_mesh.RelativeRotation.Pitch, Yaw = source_mesh.RelativeRotation.Yaw, Roll = source_mesh.RelativeRotation.Roll }
            end
        end)

        local rel_scale = nil
        pcall(function()
            if source_mesh.RelativeScale3D then
                rel_scale = { X = source_mesh.RelativeScale3D.X, Y = source_mesh.RelativeScale3D.Y, Z = source_mesh.RelativeScale3D.Z }
            end
        end)

        if rel_loc and rel_rot then
            local set_loc_rot_ok = pcall(function()
                target_mesh:K2_SetRelativeLocationAndRotation(rel_loc, rel_rot, false, {}, false)
            end)
            if not set_loc_rot_ok then
                pcall(function() target_mesh:K2_SetRelativeLocation(rel_loc, false, {}, false) end)
                pcall(function() target_mesh:K2_SetRelativeRotation(rel_rot, false, {}, false) end)
            end
        elseif rel_loc then
            pcall(function() target_mesh:K2_SetRelativeLocation(rel_loc, false, {}, false) end)
        elseif rel_rot then
            pcall(function() target_mesh:K2_SetRelativeRotation(rel_rot, false, {}, false) end)
        end

        if rel_loc then
            pcall(function() target_mesh.RelativeLocation = rel_loc end)
        end
        if rel_rot then
            pcall(function() target_mesh.RelativeRotation = rel_rot end)
        end
        if rel_scale then
            local set_scale_ok = pcall(function()
                target_mesh:SetRelativeScale3D(rel_scale)
            end)
            if not set_scale_ok then
                pcall(function() target_mesh.RelativeScale3D = rel_scale end)
            end
        end
    end)
end

local function get_source_mesh_relative_yaw(pawn)
    if not pawn or not pawn:IsValid() then return 0.0 end
    local relative_yaw = nil
    pcall(function()
        local mesh = pawn.Mesh
        if mesh and mesh:IsValid() then
            pcall(function()
                local rot = mesh.RelativeRotation
                if rot and is_finite_number(rot.Yaw) then
                    relative_yaw = rot.Yaw
                end
            end)
        end
    end)
    if relative_yaw and is_finite_number(relative_yaw) then
        return relative_yaw
    end
    return 0.0
end

local function update_remote_player_proxy(pawn)
    local candidate = nil
    local candidate_pawn_identity = nil
    local candidate_world_identity = nil
    local candidate_mesh_identity = nil
    local ok, success_or_error = pcall(function()
        local source_mesh_relative_yaw = get_source_mesh_relative_yaw(pawn)
        local proxy_actor_yaw = normalize_yaw(rendered_remote_yaw - source_mesh_relative_yaw)
        local location = { X = rendered_remote_x, Y = rendered_remote_y, Z = rendered_remote_z }
        local rotation = { Pitch = 0.0, Yaw = proxy_actor_yaw, Roll = 0.0 }

        local pawn_identity = safe_object_identity(pawn)
        if not pawn_identity then error("local pawn identity is unavailable") end
        local world = pawn:GetWorld()
        if not world or not world:IsValid() then error("local pawn world is invalid") end
        local world_identity = safe_object_identity(world)
        if not world_identity then error("local pawn world identity is unavailable") end
        local mesh_component = pawn.Mesh
        if not mesh_component or not mesh_component:IsValid() then error("local pawn Mesh is invalid") end
        local mesh_asset = mesh_component.SkeletalMesh
        if not mesh_asset or not mesh_asset:IsValid() then error("local pawn Mesh.SkeletalMesh is invalid") end
        local mesh_identity = safe_object_identity(mesh_asset)
        if not mesh_identity then error("local pawn mesh identity is unavailable") end
        candidate_pawn_identity = pawn_identity
        candidate_world_identity = world_identity
        candidate_mesh_identity = mesh_identity

        local identity_changed = remote_player_proxy_pawn_identity ~= nil
            and (remote_player_proxy_pawn_identity ~= pawn_identity
                or remote_player_proxy_world_identity ~= world_identity
                or remote_player_proxy_mesh_identity ~= mesh_identity)
        if identity_changed then
            if not cleanup_remote_player_proxy("local pawn/world/mesh changed") then
                error("proxy cleanup failed after local identity change")
            end
        end

        if remote_player_proxy then
            local proxy_valid_ok, proxy_valid_result = pcall(function()
                return remote_player_proxy:IsValid()
            end)
            if not proxy_valid_ok then
                remote_player_proxy_ready = false
                error("existing proxy validity check failed")
            end
            if proxy_valid_result and remote_player_proxy_ready then
                local collision_ok, collision_error = pcall(function()
                    remote_player_proxy:SetActorEnableCollision(false)
                end)
                if not collision_ok then
                    error("could not disable collision on ready proxy: " .. tostring(collision_error))
                end
                remote_player_proxy:SetActorHiddenInGame(false)
                remote_player_proxy:K2_SetActorLocationAndRotation(location, rotation, false, {}, false)
                return true
            end
            if not cleanup_remote_player_proxy("unready or invalid proxy") then
                error("existing proxy cleanup failed")
            end
        end

        if not skeletal_mesh_actor_class or not skeletal_mesh_actor_class:IsValid() then
            skeletal_mesh_actor_class = StaticFindObject("/Script/Engine.SkeletalMeshActor")
        end
        if not skeletal_mesh_actor_class or not skeletal_mesh_actor_class:IsValid() then
            error("SkeletalMeshActor class was not found")
        end

        candidate = world:SpawnActor(skeletal_mesh_actor_class, location, rotation)
        if not candidate or not candidate:IsValid() then error("SkeletalMeshActor spawn failed") end
        candidate:SetActorEnableCollision(false)
        candidate:SetActorHiddenInGame(true)

        local proxy_mesh = candidate.SkeletalMeshComponent
        if not proxy_mesh or not proxy_mesh:IsValid() then error("proxy SkeletalMeshComponent is invalid") end
        local set_mesh_ok = pcall(function()
            proxy_mesh:SetSkeletalMesh(mesh_asset, true)
        end)
        if not set_mesh_ok then
            proxy_mesh.SkeletalMesh = mesh_asset
        end
        copy_relative_transform(mesh_component, proxy_mesh)
        proxy_mesh:SetVisibility(true, true)
        proxy_mesh:SetHiddenInGame(false, true)

        candidate:K2_SetActorLocationAndRotation(location, rotation, false, {}, false)
        candidate:SetActorHiddenInGame(false)

        remote_player_proxy = candidate
        remote_player_proxy_pawn_identity = pawn_identity
        remote_player_proxy_world_identity = world_identity
        remote_player_proxy_mesh_identity = mesh_identity
        remote_player_proxy_ready = true
        print(string.format("%sremote proxy ready: class=%s mesh=%s\n",
            MOD, safe_full_name(pawn:GetClass()), safe_full_name(mesh_asset)))
        candidate = nil
        return true
    end)
    if not ok then
        remote_player_proxy_ready = false
        if candidate then
            if not cleanup_proxy_actor(candidate, "candidate setup failed") then
                local collision_ok, collision_error = pcall(function()
                    candidate:SetActorEnableCollision(false)
                end)
                if not collision_ok then
                    log_proxy_failure("could not disable candidate collision while tracking: " .. tostring(collision_error))
                end
                pcall(function()
                    candidate:SetActorHiddenInGame(true)
                end)
                remote_player_proxy = candidate
                remote_player_proxy_pawn_identity = candidate_pawn_identity
                remote_player_proxy_world_identity = candidate_world_identity
                remote_player_proxy_mesh_identity = candidate_mesh_identity
                remote_player_proxy_ready = false
                log_proxy_failure("candidate cleanup unresolved; tracking candidate")
            end
        elseif remote_player_proxy then
            cleanup_remote_player_proxy("proxy update failed")
        end
        log_proxy_failure(tostring(success_or_error))
        return false
    end
    return success_or_error == true
end

local function capture_local_player()
    local controller = UEHelpers:GetPlayerController()
    if not controller or not controller:IsValid() then return end
    local pawn = controller.Pawn
    if not pawn or not pawn:IsValid() then return end

    local location = pawn:K2_GetActorLocation()
    local floor_z = get_local_floor_z(pawn)
    local look_yaw = invert_look_yaw(get_local_look_yaw(controller, pawn))
    sequence = sequence + 1
    atomic_write(local_state, string.format("%d|%.3f|%.3f|%.3f|%.3f",
        sequence, location.X, location.Y, floor_z, look_yaw))
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
    if last_remote_sequence < 0 or os.clock() - last_remote_update > 2.0 then
        hide_remote_player_proxy()
        return
    end
    rendered_remote_x = rendered_remote_x + (target_remote_x - rendered_remote_x) * remote_smoothing
    rendered_remote_y = rendered_remote_y + (target_remote_y - rendered_remote_y) * remote_smoothing
    rendered_remote_z = rendered_remote_z + (target_remote_z - rendered_remote_z) * remote_smoothing
    local yaw_delta = normalize_yaw(target_remote_yaw - rendered_remote_yaw)
    rendered_remote_yaw = normalize_yaw(rendered_remote_yaw + yaw_delta * remote_smoothing)

    local controller = UEHelpers:GetPlayerController()
    if not controller or not controller:IsValid() then
        hide_remote_player_proxy()
        return
    end
    local pawn = controller.Pawn
    if not pawn or not pawn:IsValid() then
        hide_remote_player_proxy()
        return
    end

    update_remote_player_proxy(pawn)

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

local function get_status_info()
    return last_remote_name, target_remote_x, target_remote_y, target_remote_z
end

local function init(deps)
    UEHelpers = deps.UEHelpers
    if deps.MOD then MOD = deps.MOD end
    paths = deps.paths
    util = deps.util or deps.coop_util
    if paths then
        local_state = paths.local_state
        remote_state = paths.remote_state
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

coop_remote_avatar.init = init
coop_remote_avatar.create = function(deps)
    init(deps)
    return coop_remote_avatar
end
coop_remote_avatar.log_proxy_failure = log_proxy_failure
coop_remote_avatar.safe_full_name = safe_full_name
coop_remote_avatar.has_valid_remote_player_proxy = has_valid_remote_player_proxy
coop_remote_avatar.safe_object_identity = safe_object_identity
coop_remote_avatar.cleanup_proxy_actor = cleanup_proxy_actor
coop_remote_avatar.cleanup_remote_player_proxy = cleanup_remote_player_proxy
coop_remote_avatar.hide_remote_player_proxy = hide_remote_player_proxy
coop_remote_avatar.copy_relative_transform = copy_relative_transform
coop_remote_avatar.get_source_mesh_relative_yaw = get_source_mesh_relative_yaw
coop_remote_avatar.update_remote_player_proxy = update_remote_player_proxy
coop_remote_avatar.capture_local_player = capture_local_player
coop_remote_avatar.consume_remote_player = consume_remote_player
coop_remote_avatar.draw_remote_marker = draw_remote_marker
coop_remote_avatar.get_status_info = get_status_info

return coop_remote_avatar

