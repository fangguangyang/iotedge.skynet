local skynet = require "skynet"
local dns = require "skynet.dns"

local install_cmd = "scripts/install.sh"
local uninstall_cmd = "scripts/uninstall.sh"
local zip_fmt = ".tar.gz"
local core_prefix = "iotedge"

local function call(addr, ...)
    return skynet.call(addr, "lua", ...)
end

local function send(addr, ...)
    skynet.send(addr, "lua", ...)
end

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

local sys = {}

function sys.resolve(hostname)
    if hostname:match("^[%.%d]+$") then
        return hostname
    else
        return dns.resolve(hostname)
    end
end

function sys.auth(...)
    return call(sys.cfgmgr_addr, "auth", ...)
end

function sys.quit()
    skynet.abort()
    --execute(uninstall_cmd)
end
function sys.unzip(f, dir)
    return execute("tar -C "..dir.." -xzf "..f)
end
function sys.install(config, name, token, uri, console)
    return execute(
        install_cmd.." "..
        config.." "..
        name.." "..
        token.." "..
        uri.." "..
        console)
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

function sys.dp_memlimit()
    local limit = skynet.getenv("dp_memlimit")
    if limit then
        return tonumber(limit)
    else
        return nil
    end
end

function sys.conf_get(k)
    return call(sys.cfgmgr_addr, "get", k)
end
function sys.conf_set(k, v)
    return call(sys.cfgmgr_addr, "set", k, v)
end
function sys.install_tpl(...)
    return call(sys.cfgmgr_addr, "install_tpl", ...)
end
function sys.upgrade(...)
    return call(sys.cfgmgr_addr, "upgrade", ...)
end
function sys.set_repo(...)
    return call(sys.cfgmgr_addr, "set_repo", ...)
end

function sys.request(...)
    return call(sys.gateway_addr, ...)
end
function sys.sysdp(...)
    return call(sys.gateway_addr, "sys", "sysdp", ...)
end
function sys.clean(...)
    return call(sys.gateway_addr, "sys", "clean", ...)
end

function sys.stop_mqtt(...)
    local addr = sys.gateway_mqtt_addr
    if addr then
        send(addr, "stop")
    end
end
function sys.stop_ws(...)
    local addr = sys.gateway_ws_addr
    if addr then
        send(addr, "stop")
    end
end
function sys.stop_console(...)
    local addr = sys.gateway_console_addr
    if addr then
        send(addr, "stop")
    end
end

return sys
