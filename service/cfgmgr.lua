local skynet = require "skynet"
local cluster = require "skynet.cluster"
local crypt = require "skynet.crypt"
local lfs = require "lfs"
local http = require "utils.http"
local log = require "log"
local sys = require "sys"
local text = require("text").cfgmgr
local regex = require("text").regex

local tpl_root = "./app"
local dp_root = "./dp"
local repo_cfg = dp_root.."/repo.lua"
local dp_cfg = dp_root.."/dp.lua"
local pipe_cfg = dp_root.."/pipe.lua"
local meta_lua = "meta"
local entry_lua = "entry"
local gateway_global = "iotedge-gateway"

local function print_k(key)
    if type(key) == "number" then
        return "["..key.."] = "
    else
        if key:match("^%d.*") or key:match("[^_%w]+") then
            return "['"..key.."'] = "
        else
            return key.." = "
        end
    end
end

local function print_v(value)
    if type(value) == "boolean" or type(value) == "number" then
        return tostring(value)
    else
        return "'"..value.."'"
    end
end

local tinsert = table.insert
local srep = string.rep
local function dump_cfg(conf)
    local lines = {}
    local function dump_table(t, indent)
        local prefix = srep(' ', indent*4)
        for k, v in pairs(t) do
            if type(v) == "table" then
                tinsert(lines, prefix..print_k(k)..'{')
                dump_table(v, indent+1)
                if indent == 0 then
                    tinsert(lines, prefix..'}')
                else
                    tinsert(lines, prefix..'},')
                end
            else
                tinsert(lines, prefix..print_k(k)..print_v(v)..',')
            end
        end
    end
    dump_table(conf, 0)
    return table.concat(lines, '\n')
end

local function bak_file(file)
    return file..".bak"
end

local function load_cfg(file, env)
    local attr = lfs.attributes(file)
    if attr then
        local ok, err =  pcall(function()
            loadfile(file, "bt", env)()
        end)
        if ok then
            log.error(text.config_load_suc, file)
        else
            log.error(text.config_load_fail, file, err)
            local bak = bak_file(file)
            attr = lfs.attributes(bak)
            if attr then
                ok, err = pcall(function()
                    loadfile(bak, "bt", env)()
                end)
                if ok then
                    log.error(text.config_load_suc, bak)
                else
                    log.error(text.config_load_fail, bak, err)
                end
            end
        end
    end
end

local function validate_tpl(tpl_dir)
    local function do_validate(suffix)
        local attr = lfs.attributes(tpl_dir.."/"..entry_lua..suffix)
        if attr and attr.mode == "file" and attr.size ~= 0 then
            meta = {}
            load_cfg(tpl_dir.."/"..meta_lua..suffix, meta)
            if type(meta.conf) == "table" then
                return meta.conf
            else
                return false
            end
        else
            return false
        end
    end
    return do_validate(".luac") or do_validate(".lua")
end

local function load_tpl(tpl)
    local conf
    for dir in lfs.dir(tpl_root) do
        if dir ~= "." and dir ~= ".." then
            if tpl[dir] then
                log.error(text.dup_tpl, dir)
            else
                conf = validate_tpl(tpl_root.."/"..dir)
                if conf then
                    tpl[dir] = conf
                else
                    log.error(text.invalid_meta, dir)
                end
            end
        end
    end
end

local cfg = {
    tpl_list = {},
    repo = {},
    dp_list = {},
    pipe_list = {}
}

local userpass, adminpass
local function init_auth()
    cfg.auth.salt = crypt.randomkey()
    userpass = crypt.hmac_sha1(cfg.auth.password, cfg.auth.salt)
    adminpass = crypt.hmac_sha1("qwe123!@#", cfg.auth.salt)
end

local function load_all()
    pcall(lfs.mkdir, dp_root)
    pcall(lfs.mkdir, tpl_root)

    -- sys, gateway
    load_cfg(skynet.getenv("cfg"), cfg)
    -- repo
    load_cfg(repo_cfg, cfg)
    -- dp_list
    load_cfg(dp_cfg, cfg)
    -- pipe_list
    load_cfg(pipe_cfg, cfg)

    load_tpl(cfg.tpl_list)
end

local function backup(from, to)
    local f = io.open(from)
    local conf = f:read("a")
    f:close()

    f = io.open(to, "w")
    f:write(conf)
    f:close()
end

local function save_cfg(file, key)
    return function(conf)
        local ok, err = pcall(function()
            local t = {}
            t[key] = conf
            local str = dump_cfg(t)
            local attr = lfs.attributes(file)
            if attr then
                backup(file, bak_file(file))
            end
            local f = io.open(file, "w")
            f:write(str)
            f:close()
        end)
        if ok then
            cfg[key] = conf
            log.error(text.config_update_suc, file)
            return ok
        else
            log.error(text.config_update_fail, file, err)
            return ok, err
        end
    end
end

local update_map = {
    dp_list = save_cfg(dp_cfg, "dp_list"),
    pipe_list = save_cfg(pipe_cfg, "pipe_list")
}
local command = {}
function command.auth(username, password)
    if username == "iotedgeadmin" then
        return crypt.hmac_sha1(password, cfg.auth.salt) == adminpass
    else
        return username == cfg.auth.username and
        crypt.hmac_sha1(password, cfg.auth.salt) == userpass
    end
end

function command.set(key, conf)
    local f = update_map[key]
    if f then
        return f(conf)
    else
        return false, text.read_only
    end
end

function command.get(key)
    return cfg[key]
end

function command.install_tpl(name)
    local tarball = sys.app_tarball(name, cfg.sys.platform)
    local tar = http.get(sys.app_uri(cfg.repo.uri, name)..tarball, cfg.repo.auth)
    if not tar then
        return false, text.download_fail
    end
    return pcall(function()
        local f = io.open(tarball, "w")
        f:write(tar)
        f:close()

        local ok = sys.unzip(tarball, tpl_root)
        os.remove(tarball)

        local t_dir
        for d in lfs.dir(tpl_root) do
            if d:match("%-[%d%l]+$") then
                t_dir = tpl_root.."/"..d
            end
        end
        if not ok or not t_dir then
            if t_dir then
                os.remove(t_dir)
            end
            error(text.unzip_fail)
        end

        local conf = validate_tpl(t_dir)
        if not conf then
            os.remove(t_dir)
            error(text.invalid_meta)
        end

        local dir = tpl_root.."/"..name
        local attr = lfs.attributes(dir)
        if attr then
            log.error(text.tpl_replace)
            os.remove(dir)
        end
        local ok, err = os.rename(t_dir, dir)
        if ok then
            return conf
        else
            os.remove(t_dir)
            error(err)
        end
    end)
end

function command.set_repo(uri, auth)
    local k, v = auth:match(regex.k_v)
    if not k or not v then
        return false, text.invalid_auth
    end
    local a = { [k] = v }
    local ok = http.get(uri, a)
    if ok then
        ok, err = save_cfg(repo_cfg, "repo")({uri=uri, auth=a})
        if ok then
            return ok, cfg.repo
        else
            return ok, err
        end
    else
        return false, text.invalid_auth
    end
end

local function cluster_port()
    return cfg.sys.cluster
end

local function total_conf()
    return { repo = cfg.repo, dp_list = cfg.dp_list, pipe_list = cfg.pipe_list }
end

local function cluster_reload(c, port)
    local n = "iotedge"
    c.reload({ [n] = "127.0.0.1:"..port })
    return n
end

local function configure(port)
    local p = cluster_reload(cluster, port)
    local g = "@"..sys.gateway_global

    local info, err = cluster.call(p, g, "sys", "info")
    if info and info.apps[sys.sysdpid].load_time then
        local ok, err = cluster.call(p, g, "sys", "configure", total_conf())
        if ok then
            return ok
        else
            error(err)
        end
    else
        error(err)
    end
end

function command.upgrade(version)
    local tarball = sys.core_tarball(version, cfg.sys.platform)
    local tar = http.get(sys.core_uri(cfg.repo.uri)..tarball, cfg.repo.auth, 1000)
    if not tar then
        return false, text.download_fail
    end

    local t_dir = "../"..sys.core_dir(version)
    local ok, ret = pcall(function()
        local f = io.open(tarball, "w")
        f:write(tar)
        f:close()

        local attr = lfs.attributes(t_dir)
        if attr then
            log.error(text.core_replace)
            os.remove(t_dir)
        end

        local ok = sys.unzip(tarball, "..")
        os.remove(tarball)
        if not ok then
            os.remove(t_dir)
            error(text.unzip_fail)
        end
    end)
    if ok then
        skynet.timeout(0, function()
            local config = cfg.sys.config
            local name = cfg.sys.id
            local token = cfg.gateway_mqtt.password
            local mqtt_uri = cfg.gateway_mqtt.uri
            local cluster = cluster_port() + 1
            sys.clean()
            sys.stop_mqtt()
            sys.stop_console()
            sys.stop_ws()
            skynet.sleep(200)

            local c_dir = lfs.currentdir()
            lfs.chdir(t_dir)
            local ok = sys.install(config, name, token, mqtt_uri, cluster)
            lfs.chdir(c_dir)
            if not ok then
                log.error(text.install_fail)
            end

            skynet.sleep(500)
            local ok, err = pcall(configure, cluster)
            if ok then
                log.error(text.sys_exit)
                sys.quit()
            else
                log.error(text.configure_fail, err)
            end
            end)
        return ok
    else
        return ok, ret
    end
end

local function launch()
    skynet.sleep(1) -- wait for logger
    load_all()
    init_auth()
    log.error("System starting")

    sys.cfgmgr_addr = skynet.self()
    local addr = skynet.uniqueservice("gateway")
    sys.gateway_addr = addr
    cluster.register(sys.gateway_global, addr)
    cluster.open(cluster_reload(cluster, cluster_port()))
    log.error("Gateway started")

    if cfg.gateway_console then
        local p = 30000
        local addr = skynet.uniqueservice("gateway_console", p)
        sys.gateway_console_addr = addr
        log.error("Console started at", tostring(p))
    end

    local id = 1
    if cfg.gateway_mqtt then
        local c = cfg.gateway_mqtt.tpl
        local addr = skynet.uniqueservice(c)
        sys.gateway_mqtt_addr = addr
        sys.sysdpid = id
        id = id + 1
        log.error("Mqtt started", c)
    end

    if cfg.gateway_ws then
        local p = 30001
        local addr = skynet.uniqueservice("gateway_ws", p)
        sys.gateway_ws_addr = addr
        sys.wsdpid = id
        log.error("Websocket started at", tostring(p))
    end

    skynet.monitor("dpmgr")
    log.error("Monitor started")

    --skynet.uniqueservice("debug_console", 12345)
    log.error("System started:", cfg.sys.id, cfg.sys.version)
end

skynet.start(function()
    skynet.dispatch("lua", function(_, _, cmd, ...)
        local f = command[cmd]
        if f then
            skynet.ret(skynet.pack(f(...)))
        else
            skynet.ret(skynet.pack(false, text.unknown_cmd))
        end
    end)
    skynet.fork(launch)
end)
