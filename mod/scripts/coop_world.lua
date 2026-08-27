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
local last_hook_attempt_time = 0
local hook_retry_interval = 2.0
local has_logged_hook_failures = false
local last_hook_failure_summary_time = 0
local hook_failure_summary_interval = 30.0

-- Client hook failure warning tracking
local level_loaded_time = 0
local client_hook_warn_timeout = 30.0
local last_client_hook_warn_time = 0
local client_hook_warn_interval = 30.0

-- Cache scan throttling and periodic rescan
local last_cache_scan_time = 0
local cache_scan_interval = 1.0
local periodic_rescan_interval = 5.0
local last_world_identity = nil
local last_scanned_count = -1

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

-- ---------------------------------------------------------------------------
-- Object kinds
--
-- Every VotV interactable we sync is described once, here. Adding a new kind
-- means adding a row below: identification, the boolean properties that make
-- up its state, and how to commit that state to the game. The rest of this
-- module stays generic.
--
-- `props` order defines the wire format, so it must not be reordered once a
-- kind ships: the payload is "name=value,name=value".
-- ---------------------------------------------------------------------------

local function read_prop(actor, names)
    for _, name in ipairs(names) do
        local value = nil
        local ok = pcall(function() value = actor[name] end)
        if ok and value ~= nil then
            return value and true or false, true
        end
    end
    return false, false
end

local function write_prop(actor, names, value)
    for _, name in ipairs(names) do
        local present = nil
        pcall(function() present = actor[name] end)
        if present ~= nil then
            local ok = pcall(function() actor[name] = value end)
            if ok then return true end
        end
    end
    return false
end

local KINDS = {
    {
        name = "door",
        class_hint = "door_C",
        probe = "isOpened",
        props = {
            { key = "isOpened", names = { "isOpened" } },
        },
        commit = function(actor, target)
            if target.isOpened then
                if actor.doorOpen then actor:doorOpen(true) end
            else
                if actor.doorClose then actor:doorClose(true) end
            end
        end,
    },
    {
        name = "lightswitch",
        class_hint = "lightswitch_C",
        probe = "A",
        props = {
            { key = "A", names = { "A" } },
        },
        commit = function(actor)
            if actor.runTrigger then
                actor:runTrigger()
            elseif actor.player_use then
                actor:player_use()
            end
        end,
    },
    {
        name = "powerControl",
        class_hint = "powerControl_C",
        probe = "press_calc",
        -- The Key of a power panel is generated per save (e.g. UrCgZUozHxXzTc5Ky5a9ZQ)
        -- and differs between players, so it is addressed by actor path instead.
        identify_by_path = true,
        props = {
            { key = "press_calc",  names = { "press_calc" },                aliases = { "calc" } },
            { key = "press_coord", names = { "press_coord", "press_coords" }, aliases = { "coord" } },
            { key = "press_downl", names = { "press_downl" },               aliases = { "downl" } },
            { key = "press_play",  names = { "press_play" },                aliases = { "play" } },
            { key = "press_light", names = { "press_light" },               aliases = { "light" } },
        },
        commit = function(actor, target)
            if actor.powerChanged then
                actor:powerChanged(target.press_calc, target.press_downl,
                    target.press_coord, target.press_play, target.press_light)
            end
            if actor.moveLevers then actor:moveLevers() end
        end,
    },
    {
        name = "trigger",
        class_hint = "triggerBase_C",
        props = {},
    },
}

local function class_name_of(actor)
    local class_name = "<unknown>"
    pcall(function()
        local c = actor:GetClass()
        if c and c:IsValid() then
            class_name = safe_full_name(c)
        end
    end)
    return class_name
end

-- Returns the descriptor for this actor, or nil when we do not sync it.
local function kind_of(actor)
    if not actor then return nil end
    local class_name = class_name_of(actor)
    local full_name = safe_full_name(actor)
    for _, kind in ipairs(KINDS) do
        if class_name:find(kind.class_hint, 1, true) or full_name:find(kind.class_hint, 1, true) then
            return kind
        end
        if kind.probe then
            local present = nil
            pcall(function() present = actor[kind.probe] end)
            if present ~= nil then return kind end
        end
    end
    return nil
end

local function get_object_type(actor)
    local kind = kind_of(actor)
    return kind and kind.name or "unknown"
end

-- The id both players agree on. Doors and switches carry a stable map key;
-- anything without one falls back to its actor path.
local function get_object_identifier(actor)
    if not actor then return nil end
    local valid = false
    pcall(function() valid = actor:IsValid() end)
    if not valid then return nil end

    local full_name = safe_full_name(actor)
    local kind = kind_of(actor)
    if kind and kind.identify_by_path then
        return full_name
    end

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

    return full_name
end

local function count_canonical_objects()
    local count = 0
    for _ in pairs(canonical_objects) do
        count = count + 1
    end
    return count
end

local function is_level_ready()
    if not UEHelpers then return false end
    local controller = nil
    local ctrl_ok = pcall(function() controller = UEHelpers:GetPlayerController() end)
    if not ctrl_ok or not controller or not controller:IsValid() then return false end
    local pawn = nil
    local pawn_ok = pcall(function() pawn = controller.Pawn end)
    if not pawn_ok or not pawn or not pawn:IsValid() then return false end
    return true
end

local function reset_world_cache(reason)
    for k in pairs(canonical_objects) do canonical_objects[k] = nil end
    for k in pairs(object_cache) do object_cache[k] = nil end
    for k in pairs(last_known_states) do last_known_states[k] = nil end
    for k in pairs(object_latest_world_seq) do object_latest_world_seq[k] = nil end
    for k in pairs(processed_interact_seqs) do processed_interact_seqs[k] = nil end
    last_scanned_count = -1
    level_loaded_time = 0
    has_logged_hook_failures = false
    print(string.format("%s[World] World cache reset (%s)\n", MOD, tostring(reason or "unknown")))
end

local function scan_and_cache_world_objects()
    last_cache_scan_time = os.clock()
    if not is_level_ready() then
        return 0
    end

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

    local total_canonical = count_canonical_objects()
    if total_canonical ~= last_scanned_count then
        last_scanned_count = total_canonical
        print(string.format("%s[World] World scanned: %d canonical objects found\n", MOD, total_canonical))
    end
    return total_canonical
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

-- ---------------------------------------------------------------------------
-- State serialization
-- ---------------------------------------------------------------------------

local function bool_word(value)
    return value and "true" or "false"
end

-- Reads a boolean out of a payload, trying the property name and its aliases.
-- Returns `fallback` when the payload says nothing about this property.
local function parse_bool(payload, prop, fallback)
    local names = { prop.key }
    for _, alias in ipairs(prop.aliases or {}) do names[#names + 1] = alias end
    for _, extra in ipairs(prop.names or {}) do names[#names + 1] = extra end

    for _, name in ipairs(names) do
        local lower = name:lower()
        if payload:find(lower .. "=true", 1, true) or payload:find(lower .. "=1", 1, true) then
            return true
        end
        if payload:find(lower .. "=false", 1, true) or payload:find(lower .. "=0", 1, true) then
            return false
        end
    end
    return fallback
end

local function read_state_values(actor, kind)
    local values = {}
    for _, prop in ipairs(kind.props) do
        values[prop.key] = (read_prop(actor, prop.names))
    end
    return values
end

local function extract_object_state(actor)
    if not actor then return nil end
    local kind = kind_of(actor)
    if not kind then return nil end
    if #kind.props == 0 then return "active=true" end

    local values = read_state_values(actor, kind)
    local parts = {}
    for _, prop in ipairs(kind.props) do
        parts[#parts + 1] = string.format("%s=%s", prop.key, bool_word(values[prop.key]))
    end
    return table.concat(parts, ",")
end

-- Applies a remote payload. Returns true only when something actually changed:
-- re-applying a state the object already holds would replay its animation.
local function apply_object_state(actor, payload)
    if not actor or not payload then return false end
    local valid = false
    pcall(function() valid = actor:IsValid() end)
    if not valid then return false end

    local kind = kind_of(actor)
    if not kind or #kind.props == 0 then return false end

    local lower = payload:lower()
    local current = read_state_values(actor, kind)
    local target = {}
    local differs = false
    for _, prop in ipairs(kind.props) do
        target[prop.key] = parse_bool(lower, prop, current[prop.key])
        if target[prop.key] ~= current[prop.key] then differs = true end
    end

    if not differs then return false end

    -- Suppress our own hooks while we write, or the applied change would be
    -- reported straight back to the sender as a fresh local change.
    is_applying_remote = true
    local ok, err = pcall(function()
        for _, prop in ipairs(kind.props) do
            write_prop(actor, prop.names, target[prop.key])
        end
        if kind.commit then kind.commit(actor, target) end
    end)
    is_applying_remote = false

    if not ok then
        print(string.format("%s[World] Failed to apply %s state: %s\n", MOD, kind.name, tostring(err)))
        return false
    end
    return true
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
    if not actor then return end
    pcall(function()
        if actor.get then
            local unwrap = actor:get()
            if unwrap and unwrap:IsValid() then actor = unwrap end
        end
    end)
    local valid = false
    pcall(function() valid = actor:IsValid() end)
    if not valid then return end

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
        local now = os.clock()
        if not has_logged_hook_failures or (now - last_hook_failure_summary_time >= hook_failure_summary_interval) then
            has_logged_hook_failures = true
            last_hook_failure_summary_time = now
            print(string.format("%s[World] RegisterHook not available; using polling fallback\n", MOD))
        end
        hooks_installed = false
        return false
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
    local should_log_details = not has_logged_hook_failures
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
            if should_log_details then
                local err_msg = ok and "returned nil/false" or tostring(hook_res)
                print(string.format("%s[World] Hook registration failed: %s (%s)\n", MOD, target, err_msg))
            end
        end
    end

    if registered_count > 0 then
        hooks_installed = true
        print(string.format("%s[World] Registered %d hooks successfully; event-driven mode active (polling fallback interval: %.1fs)\n",
            MOD, registered_count, poll_interval_with_hooks))
        return true
    else
        hooks_installed = false
        local now = os.clock()
        if not has_logged_hook_failures then
            has_logged_hook_failures = true
            last_hook_failure_summary_time = now
            print(string.format("%s[World] No hooks registered; polling fallback active (interval: %.1fs)\n",
                MOD, poll_interval_fallback))
        else
            if now - last_hook_failure_summary_time >= hook_failure_summary_interval then
                last_hook_failure_summary_time = now
                print(string.format("%s[World] Hook registration retry failed (0 hooks registered); polling fallback active (interval: %.1fs)\n",
                    MOD, poll_interval_fallback))
            end
        end
        return false
    end
end

local function check_and_register_hooks()
    if hooks_installed then return true end
    local now = os.clock()
    if now - last_hook_attempt_time < hook_retry_interval then return false end
    last_hook_attempt_time = now

    if not is_level_ready() then return false end

    return register_hooks()
end

local function check_world_readiness_and_rescan()
    if not is_level_ready() then return end

    local controller = nil
    pcall(function() controller = UEHelpers:GetPlayerController() end)
    local pawn = controller and controller.Pawn
    local world = nil
    pcall(function() if pawn and pawn:IsValid() then world = pawn:GetWorld() end end)
    local world_identity = safe_object_identity(world)

    if last_world_identity ~= nil and world_identity ~= nil and last_world_identity ~= world_identity then
        reset_world_cache("level transition detected")
        last_world_identity = world_identity
        scan_and_cache_world_objects()
        return
    end
    last_world_identity = world_identity

    local count = count_canonical_objects()
    local now = os.clock()
    if count == 0 then
        if now - last_cache_scan_time >= cache_scan_interval then
            scan_and_cache_world_objects()
        end
    else
        if now - last_cache_scan_time >= periodic_rescan_interval then
            -- Verify at least one existing object is valid
            local has_invalid = false
            for _, actor in pairs(canonical_objects) do
                local valid = false
                pcall(function() valid = actor:IsValid() end)
                if not valid then
                    has_invalid = true
                    break
                end
            end
            if has_invalid then
                reset_world_cache("invalid actors detected during periodic check")
            end
            scan_and_cache_world_objects()
        end
    end
end

local function check_client_hook_warning()
    if role ~= "client" or hooks_installed then return end
    if not is_level_ready() then
        level_loaded_time = 0
        return
    end

    local now = os.clock()
    if level_loaded_time == 0 then
        level_loaded_time = now
        return
    end

    local elapsed = now - level_loaded_time
    if elapsed >= client_hook_warn_timeout then
        if now - last_client_hook_warn_time >= client_hook_warn_interval then
            last_client_hook_warn_time = now
            print(string.format("%s[World] WARNING: Client hooks not registered after %.0fs on loaded level! World interactions (doors, switches) will NOT work because UE4SS hooks failed to attach.\n",
                MOD, elapsed))
        end
    end
end

local function tick()
    local ok, err = pcall(function()
        -- Deferred hook registration and world rescan once level is loaded
        check_and_register_hooks()
        check_world_readiness_and_rescan()

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
            check_client_hook_warning()
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

    -- Initial scan of world objects and hook registration if level is already loaded
    if is_level_ready() then
        level_loaded_time = os.clock()
        register_hooks()
        scan_and_cache_world_objects()
    else
        print(string.format("%s[World] Level not loaded yet; deferring hook registration and world scan\n", MOD))
    end

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
coop_world.check_and_register_hooks = check_and_register_hooks
coop_world.scan_and_cache_world_objects = scan_and_cache_world_objects
coop_world.check_world_readiness_and_rescan = check_world_readiness_and_rescan
coop_world.reset_world_cache = reset_world_cache
coop_world.is_level_ready = is_level_ready
coop_world.count_canonical_objects = count_canonical_objects
coop_world.canonical_objects = canonical_objects
coop_world.object_cache = object_cache

return coop_world
