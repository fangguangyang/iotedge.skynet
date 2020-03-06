local skynet = require "skynet.manager"
local cluster = require "skynet.cluster"
local crypt = require "skynet.crypt"
local md5 =	require	"md5"
local lfs = require "lfs"
local http = require "utils.http"
local log = require "log"
local sys = require "sys"
local text = require("text").sysmgr
local regex = require("text").regex

local app_root = "./app"
local run_root = "./run"
local repo_cfg = run_root.."/repo.lua"
local app_cfg = run_root.."/app.lua"
local pipe_cfg = run_root.."/pipe.lua"
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
    for dir in lfs.dir(app_root) do
        if dir ~= "." and dir ~= ".." then
            if tpl[dir] then
                log.error(text.dup_tpl, dir)
            else
                conf = validate_tpl(app_root.."/"..dir)
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
    repo = false,
    app_list = {},
    pipe_list = {}
}

local userpass
local function init_auth()
    cfg.auth.salt = crypt.randomkey()
    userpass = crypt.hmac_sha1(cfg.auth.password, cfg.auth.salt)
end

local function load_all()
    pcall(lfs.mkdir, run_root)
    pcall(lfs.mkdir, app_root)

    -- sys, gateway
    load_cfg(skynet.getenv("cfg"), cfg)
    -- repo
    load_cfg(repo_cfg, cfg)
    -- app_list
    load_cfg(app_cfg, cfg)
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
    app_list = save_cfg(app_cfg, "app_list"),
    pipe_list = save_cfg(pipe_cfg, "pipe_list")
}

local command = {}

function command.auth(username, password)
    return md5.sumhexa(username) == cfg.auth.username and
    crypt.hmac_sha1(md5.sumhexa(password), cfg.auth.salt) == userpass
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

        local ok = sys.unzip(tarball, app_root)
        os.remove(tarball)

        local t_dir
        for d in lfs.dir(app_root) do
            if d:match("%-[%d%l]+$") then
                t_dir = app_root.."/"..d
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

        local dir = app_root.."/"..name
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
            return ok
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
    return { repo = cfg.repo, app_list = cfg.app_list, pipe_list = cfg.pipe_list }
end

local function cluster_reload(c, port)
    local n = "iotedge"
    c.reload({ [n] = "127.0.0.1:"..port })
    return n
end

local function configure(port)
    local peer = cluster_reload(cluster, port)
    local g = "@"..gateway_global

    local info, err = cluster.call(peer, g, "sys", "info")
    if info then
        local ok, err = cluster.call(peer, g, "sys", "configure", total_conf())
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
            local cluster = cluster_port() + 1
            local name, token, mqtt_uri
            if cfg.gateway_mqtt then
                name = cfg.sys.id
                token = cfg.gateway_mqtt.password
                mqtt_uri = cfg.gateway_mqtt.uri
            end

            skynet.call(cfg.appmgr, "lua", "clean")
            if cfg.gateway_ws then
                skynet.send(cfg.gateway_ws, "lua", "stop")
            end
            if cfg.gateway_mqtt then
                skynet.send(cfg.gateway_mqtt_addr, "lua", "stop")
            end
            if cfg.gateway_console then
                skynet.send(cfg.gateway_console, "lua", "stop")
            end
            skynet.sleep(200)

            local c_dir = lfs.currentdir()
            lfs.chdir(t_dir)
            local ok = sys.upgrade(config, cluster, name, token, mqtt_uri)
            lfs.chdir(c_dir)
            if not ok then
                log.error(text.install_fail)
            end

            skynet.sleep(500)
            local ok, err = pcall(configure, cluster)
            if ok then
                log.error(text.sys_exit)
            else
                log.error(text.configure_fail, err)
            end
            sys.quit()
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

    local s = skynet.self()
    local g = skynet.uniqueservice("gateway", s)
    cluster.register(gateway_global, g)
    cluster.open(cluster_reload(cluster, cluster_port()))
    log.error("Gateway started")

    if cfg.gateway_console then
        cfg.gateway_console = skynet.uniqueservice("gateway_console", 30000, s, g)
        log.error("Console started")
    end

    if cfg.gateway_ws then
        cfg.gateway_ws = skynet.uniqueservice("gateway_ws", 30001, s, g)
        log.error("Websocket started")
    else
        cfg.gateway_ws = -1
    end

    if cfg.gateway_mqtt then
        local c = cfg.gateway_mqtt.tpl
        cfg.gateway_mqtt_addr = skynet.uniqueservice(c, s, g)
        log.error("MQTT started", c)
    else
        cfg.gateway_mqtt_addr = -1
    end

    cfg.appmgr = skynet.uniqueservice(true, "appmgr", s, g, cfg.gateway_ws, cfg.gateway_mqtt_addr)
    skynet.monitor("appmgr", true)
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
