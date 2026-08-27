local coop_bridge = {}

local function start_bridge(paths_or_mod_dir, config_or_bridge_dir, util_or_config, maybe_util)
    local mod_dir, bridge_dir, config, coop_util
    if type(paths_or_mod_dir) == "table" and paths_or_mod_dir.bridge_dir then
        mod_dir = paths_or_mod_dir.mod_dir
        bridge_dir = paths_or_mod_dir.bridge_dir
        config = config_or_bridge_dir
        coop_util = util_or_config
    else
        mod_dir = paths_or_mod_dir
        bridge_dir = config_or_bridge_dir
        config = util_or_config
        coop_util = maybe_util
    end

    os.execute('mkdir "' .. bridge_dir:gsub('/', '\\') .. '" 2>nul')
    local executable = (mod_dir .. "/tools/VotVCoopBridge.exe"):gsub('/', '\\')
    local safe_argument = (coop_util and coop_util.safe_argument) or function(v) return '"' .. tostring(v):gsub('"', '') .. '"' end
    local command = string.format('start "VotV Coop Bridge" /MIN "%s" --role %s --bridge %s --host %s --port %s --name %s',
        executable, safe_argument(config.role), safe_argument(bridge_dir), safe_argument(config.host),
        safe_argument(config.port), safe_argument(config.name))
    os.execute(command)
end

local function get_status(paths_or_status_file, coop_util)
    local status_file = (type(paths_or_status_file) == "table" and paths_or_status_file.status_file) or paths_or_status_file
    local read_all = (coop_util and coop_util.read_all) or function(p)
        local f = io.open(p, "r")
        if not f then return nil end
        local content = f:read()
        f:close()
        return content
    end
    return (read_all(status_file) or "bridge not running"):gsub("%s+$", "")
end

coop_bridge.start_bridge = start_bridge
coop_bridge.get_status = get_status

return coop_bridge
