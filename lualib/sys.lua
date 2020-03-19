local skynet = require "skynet"
local dns = require "skynet.dns"

local upgrade_cmd = "scripts/upgrade.sh"
local uninstall_cmd = "scripts/uninstall.sh"
local zip_fmt = ".tar.gz"
local core_prefix = "iotedge"

local function execute(cmd)
    if type(cmd) == "string" then
        local ok, exit, errno = os.execute(cmd)
        if ok and exit == "exit" and errno == 0 then
            return true
        else
            return false
        end
    else
        return false
    end
end

local sys = {
    app_root = "app",
    db_root = "db",
    run_root = "run",
    repo_cfg = "run/repo",
    pipe_cfg = "run/pipe",
    meta_lua = "meta",
    entry_lua = "entry",
    gateway_global = "iotedge-gateway"
}

function sys.resolve(hostname)
    if hostname:match("^[%.%d]+$") then
        return hostname
    else
        return dns.resolve(hostname)
    end
end

function sys.quit()
    skynet.abort()
    --execute(uninstall_cmd)
end
function sys.unzip(f, dir)
    return execute("tar -C "..dir.." -xzf "..f)
end
function sys.upgrade(config, cluster, name, token, mqtt_uri)
    if name then
        return execute(table.concat({upgrade_cmd, config, cluster, name, token, mqtt_uri}, " "))
    else
        return execute(table.concat({upgrade_cmd, config, cluster}, " "))
    end
end
function sys.core_uri(uri)
    return uri.."/"..core_prefix.."/"
end
function sys.core_tarball(version, platform)
    return version.."-"..platform..zip_fmt
end
function sys.core_dir(version)
    return core_prefix.."-"..version
end
function sys.app_uri(uri, name)
    local d = name:match("(.+)_v_.+")
    return uri.."/"..d.."/"
end
function sys.app_tarball(name, platform)
    local v = name:match(".+_(v_.+)")
    return v.."-"..platform..zip_fmt
end
function sys.memlimit()
    local limit = skynet.getenv("memlimit")
    if limit then
        return tonumber(limit)
    else
        return nil
    end
end

------------------------------------------
return setmetatable({}, {
  __index = sys,
  __newindex = function(t, k, v)
                 error("Attempt to modify read-only table")
               end,
  __metatable = false
})
