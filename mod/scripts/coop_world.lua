local coop_world = {}

local UEHelpers = nil
local MOD = "[VotVCoopPrototype] "
local paths = nil
local util = nil
local config = nil
local role = "client"

local local_world_state = nil
local remote_world_state = nil
local local_interact = nil
local remote_interact = nil

local is_finite_number = nil
local atomic_write = nil
local safe_full_name = nil
local safe_object_identity = nil
local read_all_lines_fn = nil

-- Echo protection: flag active while applying network state or interact requests
-- to prevent local hooks and tick delta detection from sending the state back.
local is_applying_remote = false

-- Sequence counters and deduplication trackers
local world_sequence = 0
local interact_sequence = 0
local last_processed_world_seq = -1
local last_processed_interact_seq = -1

-- Canonical objects: canonical_id -> AActor (strictly 1 entry per physical object, used for polling)
local canonical_objects = {}
-- Alias / lookup index: alias/path/id -> AActor (used for fast resolution on receive)
local object_cache = {}
-- Per-object latest received sequence number: objectId -> seq
local object_latest_world_seq = {}
-- Processed interact sequence tracker (for host deduplication)
local processed_interact_seqs = {}
-- Host-side last known state payload: canonical_id -> state_string
local last_known_states = {}

-- Local journal memory buffers (capped at 1024 lines)
local max_journal_size = 1024
local local_world_journal = {}
local local_interact_journal = {}

-- Polling performance management:
-- If hooks are successfully registered, polling is only a low-frequency fallback (e.g. 0.5s / 2 Hz).
-- If hooks are not registered or failed, polling runs at 0.1s (10 Hz).
local last_poll_time = 0
local poll_interval_with_hooks = 0.5
local poll_interval_fallback = 0.1
local hooks_installed = false

-- Cache scan throttling to avoid scanning the world every tick
local last_cache_scan_time = 0
local cache_scan_interval = 1.0

local function read_all_lines(path)
    if not path then return {} end
    local file = io.open(path, "r")
    if not file then return {} end
    local lines = {}
    for line in file:lines() do
        if line and line ~= "" then
            lines[#lines + 1] = line
        end
    end
    file:close()
    return lines
end

local function parse_remote_journal_line(line)
    if not line or line == "" then return nil end
    local p1 = line:find("|", 1, true)
    if not p1 then return nil end
    local p2 = line:find("|", p1 + 1, true)
    if not p2 then return nil end
    local p3 = line:find("|", p2 + 1, true)
    if not p3 then return nil end

    local sender = line:sub(1, p1 - 1)
    local seq_str = line:sub(p1 + 1, p2 - 1)
    local object_id = line:sub(p2 + 1, p3 - 1)
    local payload = line:sub(p3 + 1)
    local seq = tonumber(seq_str)

    if not seq or not is_finite_number(seq) then return nil end
    return {
        sender = sender,
        seq = seq,
        object_id = object_id,
        payload = payload,
    }
end

local function get_object_identifier(actor)
    if not actor then return nil end
    local valid = false
    pcall(function() valid = actor:IsValid() end)
    if not valid then return nil end

    local full_name = safe_full_name(actor)
    local class_name = "<unknown>"
    pcall(function()
        local c = actor:GetClass()
        if c and c:IsValid() then
            class_name = safe_full_name(c)
        end
    end)

    -- powerControl_C: Key is randomly generated (e.g. UrCgZUozHxXzTc5Ky5a9ZQ) and does not match between players.
    -- Use the full actor path as canonical identifier for powerControl.
    if class_name:find("powerControl") or full_name:find("powerControl") then
        return full_name
    end

    -- For door_C, lightswitch_C, and other triggerBase_C objects, use Key from triggerBase_C if present and valid.
    local key = nil
    pcall(function()
        local k = actor.Key
        if k ~= nil then
            if type(k) == "userdata" and k.ToString then
                key = k:ToString()
            else
                key = tostring(k)
            end
        end
    end)

    if key and key ~= "" and key ~= "None" and key ~= "nil" then
        return key
    end

    -- Fallback to full actor path if Key is empty or absent
    return full_name
end

local function scan_and_cache_world_objects()
    last_cache_scan_time = os.clock()
    local classes_to_find = { "door_C", "lightswitch_C", "powerControl_C", "triggerBase_C" }
    for _, cname in ipairs(classes_to_find) do
        pcall(function()
            local actors = FindAllOf(cname)
            if actors then
                for _, actor in ipairs(actors) do
                    if actor and actor:IsValid() then
                        local canonical_id = get_object_identifier(actor)
                        if canonical_id and canonical_id ~= "" then
                            canonical_objects[canonical_id] = actor
                            object_cache[canonical_id] = actor
                        end
                        local full_path = safe_full_name(actor)
                        if full_path and full_path ~= "<unknown>" then
                            object_cache[full_path] = actor
                        end
                    end
                end
            end
        end)
    end
end

local function find_object_by_id(object_id)
    if not object_id or object_id == "" then return nil end

    -- Check lookup alias index first, then canonical cache
    local cached = object_cache[object_id] or canonical_objects[object_id]
    if cached then
        local valid = false
        pcall(function() valid = cached:IsValid() end)
        if valid then return cached end
        object_cache[object_id] = nil
        canonical_objects[object_id] = nil
    end

    -- If not found or invalid, scan world only if throttle interval passed
    local now = os.clock()
    if now - last_cache_scan_time >= cache_scan_interval then
        scan_and_cache_world_objects()
        cached = object_cache[object_id] or canonical_objects[object_id]
        if cached then
            local valid = false
            pcall(function() valid = cached:IsValid() end)
            if valid then return cached end
            object_cache[object_id] = nil
            canonical_objects[object_id] = nil
        end
    end

    print(string.format("%s[World] Object not found for id: %s\n", MOD, tostring(object_id)))
    return nil
end

local function get_object_type(actor)
    if not actor then return "unknown" end
    local class_name = "<unknown>"
    local full_name = safe_full_name(actor)
    pcall(function()
        local c = actor:GetClass()
        if c and c:IsValid() then
            class_name = safe_full_name(c)
        end
    end)
    if class_name:find("door_C") or full_name:find("door_C") or actor.isOpened ~= nil then
        return "door"
    elseif class_name:find("lightswitch_C") or full_name:find("lightswitch_C") or actor.A ~= nil then
        return "lightswitch"
    elseif class_name:find("powerControl_C") or full_name:find("powerControl_C") or actor.press_calc ~= nil then
        return "powerControl"
    elseif class_name:find("triggerBase_C") or full_name:find("triggerBase_C") then
        return "trigger"
    end
    return "unknown"
end

local function extract_object_state(actor)
    if not actor then return nil end
    local obj_type = get_object_type(actor)
    if obj_type == "door" then
        local is_opened = actor.isOpened and true or false
        return string.format("isOpened=%s", is_opened and "true" or "false")
    elseif obj_type == "lightswitch" then
        local a = actor.A and true or false
        return string.format("A=%s", a and "true" or "false")
    elseif obj_type == "powerControl" then
        local calc = actor.press_calc and true or false
        local coord = (actor.press_coord or actor.press_coords) and true or false
        local downl = actor.press_downl and true or false
        local play = actor.press_play and true or false
        local light = actor.press_light and true or false
        return string.format("press_calc=%s,press_coord=%s,press_downl=%s,press_play=%s,press_light=%s",
            calc and "true" or "false", coord and "true" or "false", downl and "true" or "false",
            play and "true" or "false", light and "true" or "false")
    end
    return "active=true"
end

local function apply_object_state(actor, payload)
    if not actor or not payload then return false end
    local valid = false
    pcall(function() valid = actor:IsValid() end)
    if not valid then return false end

    local obj_type = get_object_type(actor)

    if obj_type == "door" then
        local lower = payload:lower()
        local target_opened = nil
        if lower:find("isopened=true") or lower:find("open=true") or lower:find("opened=true") or lower == "true" or lower == "1" then
            target_opened = true
        elseif lower:find("isopened=false") or lower:find("open=false") or lower:find("opened=false") or lower == "false" or lower == "0" then
            target_opened = false
        end

        if target_opened == nil then return false end
        local current_opened = actor.isOpened and true or false
        if current_opened == target_opened then
            -- Object is already in target state; skip to avoid redundant animations
            return false
        end

        is_applying_remote = true
        local ok, err = pcall(function()
            if target_opened then
                if actor.doorOpen then
                    actor:doorOpen(true)
                end
            else
                if actor.doorClose then
                    actor:doorClose(true)
                end
            end
            actor.isOpened = target_opened
        end)
        is_applying_remote = false
        if not ok then
            print(string.format("%s[World] Failed to apply door state: %s\n", MOD, tostring(err)))
            return false
        end
        return true

    elseif obj_type == "lightswitch" then
        local lower = payload:lower()
        local target_a = nil
        if lower:find("a=true") or lower == "true" or lower == "1" then
            target_a = true
        elseif lower:find("a=false") or lower == "false" or lower == "0" then
            target_a = false
        end

        if target_a == nil then return false end
        local current_a = actor.A and true or false
        if current_a == target_a then
            -- Object is already in target state
            return false
        end

        is_applying_remote = true
        local ok, err = pcall(function()
            actor.A = target_a
            if actor.runTrigger then
                actor:runTrigger()
            elseif actor.player_use then
                actor:player_use()
            end
        end)
        is_applying_remote = false
        if not ok then
            print(string.format("%s[World] Failed to apply lightswitch state: %s\n", MOD, tostring(err)))
            return false
        end
        return true

    elseif obj_type == "powerControl" then
        local lower = payload:lower()
        local cur_calc = actor.press_calc and true or false
        local cur_coord = (actor.press_coord or actor.press_coords) and true or false
        local cur_downl = actor.press_downl and true or false
        local cur_play = actor.press_play and true or false
        local cur_light = actor.press_light and true or false

        local function parse_bool(key, fallback)
            if lower:find(key .. "=true") or lower:find(key .. "=1") then
                return true
            elseif lower:find(key .. "=false") or lower:find(key .. "=0") then
                return false
            end
            return fallback
        end

        local tgt_calc = parse_bool("press_calc", parse_bool("calc", cur_calc))
        local tgt_coord = parse_bool("press_coord", parse_bool("press_coords", parse_bool("coord", cur_coord)))
        local tgt_downl = parse_bool("press_downl", parse_bool("downl", cur_downl))
        local tgt_play = parse_bool("press_play", parse_bool("play", cur_play))
        local tgt_light = parse_bool("press_light", parse_bool("light", cur_light))

        if tgt_calc == cur_calc and tgt_coord == cur_coord and tgt_downl == cur_downl
            and tgt_play == cur_play and tgt_light == cur_light then
            -- Object is already in target state
            return false
        end

        is_applying_remote = true
        local ok, err = pcall(function()
            actor.press_calc = tgt_calc
            actor.press_coord = tgt_coord
            actor.press_downl = tgt_downl
            actor.press_play = tgt_play
            actor.press_light = tgt_light
            if actor.powerChanged then
                actor:powerChanged(tgt_calc, tgt_downl, tgt_coord, tgt_play, tgt_light)
            end
            if actor.moveLevers then
                actor:moveLevers()
            end
        end)
        is_applying_remote = false
        if not ok then
            print(string.format("%s[World] Failed to apply powerControl state: %s\n", MOD, tostring(err)))
            return false
        end
        return true
    end

    return false
end

local function apply_interact_request(actor, action_payload)
    if not actor then return false end
    local valid = false
    pcall(function() valid = actor:IsValid() end)
    if not valid then return false end

    local obj_type = get_object_type(actor)
    local lower = (action_payload or ""):lower()

    is_applying_remote = true
    local ok, err = pcall(function()
        if obj_type == "door" then
            if lower:find("open") and not lower:find("close") then
                if actor.doorOpen then actor:doorOpen(true) end
            elseif lower:find("close") then
                if actor.doorClose then actor:doorClose(true) end
            else
                -- toggle / use
                if actor.isOpened then
                    if actor.doorClose then actor:doorClose(true) end
                else
                    if actor.doorOpen then actor:doorOpen(true) end
                end
            end
        elseif obj_type == "lightswitch" then
            if actor.player_use then
                actor:player_use()
            elseif actor.runTrigger then
                actor:runTrigger()
            end
        elseif obj_type == "powerControl" then
            if actor.player_use then
                actor:player_use()
            elseif actor.runTrigger then
                actor:runTrigger()
            elseif actor.moveLevers then
                actor:moveLevers()
            end
        else
            if actor.player_use then
                actor:player_use()
            elseif actor.runTrigger then
                actor:runTrigger()
            end
        end
    end)
    is_applying_remote = false
    if not ok then
        print(string.format("%s[World] Failed to apply interact request: %s\n", MOD, tostring(err)))
        return false
    end
    return true
end

local function emit_local_world_state(object_id, state_payload)
    if is_applying_remote then return end
    if not object_id or not state_payload then return end

    world_sequence = world_sequence + 1
    local line = string.format("%d|%s|%s", world_sequence, object_id, state_payload)
    local_world_journal[#local_world_journal + 1] = line
    if #local_world_journal > max_journal_size then
        table.remove(local_world_journal, 1)
    end

    atomic_write(local_world_state, table.concat(local_world_journal, "\n"))
    last_known_states[object_id] = state_payload
    print(string.format("%s[World] State #%d emitted: %s = %s\n", MOD, world_sequence, object_id, state_payload))
end

local function emit_local_interact(object_id, action_payload)
    if is_applying_remote then return end
    if not object_id then return end

    interact_sequence = interact_sequence + 1
    local action = action_payload or "use"
    local line = string.format("%d|%s|%s", interact_sequence, object_id, action)
    local_interact_journal[#local_interact_journal + 1] = line
    if #local_interact_journal > max_journal_size then
        table.remove(local_interact_journal, 1)
    end

    atomic_write(local_interact, table.concat(local_interact_journal, "\n"))
    print(string.format("%s[World] Interact request #%d emitted: %s -> %s\n", MOD, interact_sequence, object_id, action))
end

local function consume_remote_world_state()
    local read_lines = read_all_lines_fn or read_all_lines
    local lines = read_lines(remote_world_state)
    for _, line in ipairs(lines) do
        local entry = parse_remote_journal_line(line)
        if entry then
            local obj_id = entry.object_id
            local seq = entry.seq
            local prev_seq = object_latest_world_seq[obj_id] or -1
            if seq > prev_seq then
                object_latest_world_seq[obj_id] = seq
                last_processed_world_seq = math.max(last_processed_world_seq, seq)
                local actor = find_object_by_id(obj_id)
                if actor then
                    local changed = apply_object_state(actor, entry.payload)
                    if changed then
                        print(string.format("%s[World] Applied state #%d from %s: %s = %s\n",
                            MOD, seq, entry.sender, obj_id, entry.payload))
                    end
                end
            end
        end
    end
end

local function consume_remote_interacts()
    local read_lines = read_all_lines_fn or read_all_lines
    local lines = read_lines(remote_interact)
    for _, line in ipairs(lines) do
        local entry = parse_remote_journal_line(line)
        if entry then
            local seq = entry.seq
            if not processed_interact_seqs[seq] then
                processed_interact_seqs[seq] = true
                last_processed_interact_seq = math.max(last_processed_interact_seq, seq)
                local obj_id = entry.object_id
                local actor = find_object_by_id(obj_id)
                if actor then
                    apply_interact_request(actor, entry.payload)
                    print(string.format("%s[World] Applied interact #%d from %s: %s -> %s\n",
                        MOD, seq, entry.sender, obj_id, entry.payload))
                    local updated_state = extract_object_state(actor)
                    if updated_state then
                        emit_local_world_state(obj_id, updated_state)
                    end
                end
            end
        end
    end
end

local function poll_host_world_state()
    if role ~= "host" then return end
    if is_applying_remote then return end
    -- Check all canonical objects for state changes (strictly 1 check per canonical object, no duplicates)
    for canonical_id, actor in pairs(canonical_objects) do
        if actor and actor:IsValid() then
            local current_state = extract_object_state(actor)
            if current_state then
                local last_state = last_known_states[canonical_id]
                if last_state == nil then
                    -- Initial state discovery
                    last_known_states[canonical_id] = current_state
                    emit_local_world_state(canonical_id, current_state)
                elseif last_state ~= current_state then
                    -- Local state changed
                    last_known_states[canonical_id] = current_state
                    emit_local_world_state(canonical_id, current_state)
                end
            end
        end
    end
end

local function on_hook_triggered(context, hook_name)
    if is_applying_remote then return end
    local actor = context
    if not actor or not actor:IsValid() then return end

    local obj_id = get_object_identifier(actor)
    if not obj_id or obj_id == "" then return end

    if role == "client" then
        emit_local_interact(obj_id, "use")
    elseif role == "host" then
        local current_state = extract_object_state(actor)
        if current_state then
            last_known_states[obj_id] = current_state
            emit_local_world_state(obj_id, current_state)
        end
    end
end

local function register_hooks()
    if type(RegisterHook) ~= "function" then
        print(string.format("%s[World] RegisterHook not available; using polling fallback\n", MOD))
        hooks_installed = false
        return
    end

    local hook_targets = {
        "Function /Game/objects/door.door_C:doorOpen",
        "Function /Game/objects/door.door_C:doorClose",
        "Function /Game/objects/door.door_C:player_use",
        "Function /Game/objects/door.door_C:runTrigger",
        "Function /Game/objects/lightswitch.lightswitch_C:use",
        "Function /Game/objects/lightswitch.lightswitch_C:player_use",
        "Function /Game/objects/powerControl.powerControl_C:powerChanged",
        "Function /Game/objects/powerControl.powerControl_C:player_use",
        "Function /Game/objects/triggers/triggerBase.triggerBase_C:player_use",
        "Function /Game/objects/triggers/triggerBase.triggerBase_C:runTrigger",
        "/Game/objects/door.door_C:doorOpen",
        "/Game/objects/door.door_C:doorClose",
        "/Game/objects/door.door_C:player_use",
        "/Game/objects/door.door_C:runTrigger",
        "/Game/objects/lightswitch.lightswitch_C:use",
        "/Game/objects/lightswitch.lightswitch_C:player_use",
        "/Game/objects/powerControl.powerControl_C:powerChanged",
        "/Game/objects/powerControl.powerControl_C:player_use",
        "/Game/objects/triggers/triggerBase.triggerBase_C:player_use",
        "/Game/objects/triggers/triggerBase.triggerBase_C:runTrigger",
    }

    local registered_count = 0
    for _, target in ipairs(hook_targets) do
        local ok, hook_res = pcall(function()
            return RegisterHook(target, function(context, ...)
                ExecuteInGameThread(function()
                    on_hook_triggered(context, target)
                end)
            end)
        end)
        if ok and hook_res ~= false and hook_res ~= nil then
            registered_count = registered_count + 1
            print(string.format("%s[World] Hook registration succeeded: %s (id: %s)\n", MOD, target, tostring(hook_res)))
        else
            local err_msg = ok and "returned nil/false" or tostring(hook_res)
            print(string.format("%s[World] Hook registration failed: %s (%s)\n", MOD, target, err_msg))
        end
    end

    if registered_count > 0 then
        hooks_installed = true
        print(string.format("%s[World] Registered %d hooks successfully; event-driven mode active (polling fallback interval: %.1fs)\n",
            MOD, registered_count, poll_interval_with_hooks))
    else
        hooks_installed = false
        print(string.format("%s[World] No hooks registered; polling fallback active (interval: %.1fs)\n",
            MOD, poll_interval_fallback))
    end
end

local function tick()
    local ok, err = pcall(function()
        if role == "host" then
            consume_remote_interacts()
            local now = os.clock()
            local current_interval = hooks_installed and poll_interval_with_hooks or poll_interval_fallback
            if now - last_poll_time >= current_interval then
                last_poll_time = now
                poll_host_world_state()
            end
        elseif role == "client" then
            consume_remote_world_state()
        end
    end)
    if not ok then
        print(string.format("%s[World] tick error: %s\n", MOD, tostring(err)))
    end
end

local function init(deps)
    UEHelpers = deps.UEHelpers
    if deps.MOD then MOD = deps.MOD end
    paths = deps.paths
    util = deps.util or deps.coop_util
    config = deps.config or {}
    role = (config.role or "client"):lower()

    if paths then
        local_world_state = paths.local_world_state
        remote_world_state = paths.remote_world_state
        local_interact = paths.local_interact
        remote_interact = paths.remote_interact
    end

    if util then
        is_finite_number = util.is_finite_number
        atomic_write = util.atomic_write
        safe_full_name = util.safe_full_name
        safe_object_identity = util.safe_object_identity
        read_all_lines_fn = util.read_all_lines
    end

    -- Initial scan of world objects
    pcall(scan_and_cache_world_objects)

    -- Register UE4SS hooks with explicit status logging and polling fallback
    register_hooks()

    print(string.format("%s[World] Initialized as %s\n", MOD, role))
end

coop_world.init = init
coop_world.create = function(deps)
    init(deps)
    return coop_world
end
coop_world.tick = tick
coop_world.get_object_identifier = get_object_identifier
coop_world.find_object_by_id = find_object_by_id
coop_world.get_object_type = get_object_type
coop_world.extract_object_state = extract_object_state
coop_world.apply_object_state = apply_object_state
coop_world.apply_interact_request = apply_interact_request
coop_world.emit_local_world_state = emit_local_world_state
coop_world.emit_local_interact = emit_local_interact
coop_world.consume_remote_world_state = consume_remote_world_state
coop_world.consume_remote_interacts = consume_remote_interacts
coop_world.poll_host_world_state = poll_host_world_state
coop_world.read_all_lines = read_all_lines
coop_world.parse_remote_journal_line = parse_remote_journal_line
coop_world.register_hooks = register_hooks
coop_world.scan_and_cache_world_objects = scan_and_cache_world_objects
coop_world.canonical_objects = canonical_objects
coop_world.object_cache = object_cache

return coop_world
