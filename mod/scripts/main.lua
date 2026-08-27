local UEHelpers = require("UEHelpers")

local MOD = "[VotVCoopPrototype] "
local game_directories = IterateGameDirectories()
local win64_directory = game_directories.Game.Binaries.Win64.__absolute_path:gsub("\\", "/")
local mod_dir = win64_directory .. "/Mods/VotVCoopPrototype"

local coop_util = dofile(mod_dir .. "/scripts/coop_util.lua")
local coop_bridge = dofile(mod_dir .. "/scripts/coop_bridge.lua")
local coop_remote_avatar = dofile(mod_dir .. "/scripts/coop_remote_avatar.lua")
local coop_actions = dofile(mod_dir .. "/scripts/coop_actions.lua")
local diag_interact = dofile(mod_dir .. "/scripts/diag_interact.lua")
local coop_world = dofile(mod_dir .. "/scripts/coop_world.lua")

local config = coop_util.read_config(mod_dir .. "/config.ini")
local bridge_dir = mod_dir .. "/runtime"
local local_state = bridge_dir .. "/local_state.txt"
local remote_state = bridge_dir .. "/remote_state.txt"
local local_action = bridge_dir .. "/local_action.txt"
local remote_action = bridge_dir .. "/remote_action.txt"
local local_interact = bridge_dir .. "/local_interact.txt"
local remote_interact = bridge_dir .. "/remote_interact.txt"
local local_world_state = bridge_dir .. "/local_world_state.txt"
local remote_world_state = bridge_dir .. "/remote_world_state.txt"
local status_file = bridge_dir .. "/status.txt"

local paths = {
    mod_dir = mod_dir,
    bridge_dir = bridge_dir,
    local_state = local_state,
    remote_state = remote_state,
    local_action = local_action,
    remote_action = remote_action,
    local_interact = local_interact,
    remote_interact = remote_interact,
    local_world_state = local_world_state,
    remote_world_state = remote_world_state,
    status_file = status_file,
}

local avatar = coop_remote_avatar.create({
    UEHelpers = UEHelpers,
    MOD = MOD,
    paths = paths,
    util = coop_util,
})

local actions = coop_actions.create({
    UEHelpers = UEHelpers,
    MOD = MOD,
    paths = paths,
    util = coop_util,
})

local diag = diag_interact.create({
    UEHelpers = UEHelpers,
    MOD = MOD,
    paths = paths,
    util = coop_util,
})

local world = coop_world.create({
    UEHelpers = UEHelpers,
    MOD = MOD,
    paths = paths,
    util = coop_util,
    config = config,
})

local capture_local_player = avatar.capture_local_player
local consume_remote_player = avatar.consume_remote_player
local draw_remote_marker = avatar.draw_remote_marker
local consume_remote_action = actions.consume_remote_action
local draw_local_action_marker = actions.draw_local_action_marker
local draw_remote_action_marker = actions.draw_remote_action_marker
local sync_world = world.tick

local function tick()
    local ok, error_message = pcall(function()
        capture_local_player()
        consume_remote_player()
        draw_remote_marker()
        consume_remote_action()
        draw_local_action_marker()
        draw_remote_action_marker()
        sync_world()
    end)
    if not ok then print(MOD .. "tick failed: " .. tostring(error_message) .. "\n") end
end

RegisterKeyBind(Key.F8, function()
    ExecuteInGameThread(function()
        local status = (coop_util.read_all(status_file) or "bridge not running"):gsub("%s+$", "")
        local name, x, y, z = avatar.get_status_info()
        print(string.format("%s%s; remote %s at X=%.1f Y=%.1f Z=%.1f\n",
            MOD, status, name, x, y, z))
    end)
end)

RegisterKeyBind(Key.F9, function()
    ExecuteInGameThread(function()
        actions.emit_local_action("Ping")
    end)
end)

RegisterKeyBind(Key.F7, function()
    ExecuteInGameThread(function()
        diag.inspect_object_under_crosshair()
    end)
end)

coop_bridge.start_bridge(mod_dir, bridge_dir, config, coop_util)
print(string.format("%sloaded as %s; bridge directory: %s\n", MOD, config.role, bridge_dir))
LoopAsync(50, function()
    ExecuteInGameThread(tick)
    return false
end)
