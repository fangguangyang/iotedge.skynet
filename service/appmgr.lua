local skynet = require "skynet"
local core = require "skynet.core"
local api = require "api"
local log = require "log"
local text = require("text").appmgr

local interval = 500 -- 5 seconds
local limit = 4 -- 15 seconds
local locked = true

local sysmgr_addr, gateway_addr, wsapp_addr, mqttapp_addr = ...
local wsappid = "ws"
local mqttappid = "mqtt"

local sysinfo = {}
local applist = {}
local pipelist = {}
local tpllist = {}

local appmonitor = {}

local command = {}

local function clone(tpl, custom)
    if type(tpl) == "table" then
        local copy = {}
        for k, v in pairs(tpl) do
            if custom[k] then
                copy[k] = clone(v, custom[k])
            else
                copy[k] = v
            end
        end
        return copy
    else
        return custom
    end
end

local function sysapp(id)
    return id == mqttappid or id == wsappid
end

local function make_name(tpl, id)
    return tpl.."_"..id
end

local function info()
    local name

    local apps = {}
    for id, app in pairs(applist) do
        if not sysapp(id) then
            name = make_name(app.tpl, id)
        else
            name = id
        end
        apps[name] = {}
        apps[name].conf = app.conf
        apps[name].load_time = app.load_time
    end

    local pipes = {}
    for id, pipe in pairs(pipelist) do
        pipes[id] = {}
        if pipe.start_time then
            pipes[id].start_time = pipe.start_time
        end
        if pipe.stop_time then
            pipes[id].stop_time = pipe.stop_time
        end
        pipes[id].apps = {}
        for _, appid in ipairs(pipe.apps) do
            if not sysapp(appid) then
                name = make_name(applist[appid].tpl, appid)
            else
                name = appid
            end
            table.insert(pipes[id].apps, name)
        end
    end
    sysinfo.apps = apps
    sysinfo.pipes = pipes
    sysinfo.sys.uptime = string.format("%d seconds", math.floor(skynet.now()/100))
    return sysinfo
end

local function invalidate_info()
    command.info = nil
end
local function update_app(id, tpl, conf)
    invalidate_info()
    skynet.call(sysmgr_addr, "lua", "update_app", id, tpl, conf)
end
local function remove_app(id)
    skynet.send(applist[id].addr, "lua", "exit")
    local tpl = applist[id].tpl
    applist[id] = nil
    invalidate_info()
    skynet.call(sysmgr_addr, "lua", "update_app", id, tpl, false)
end
local function update_pipes()
    invalidate_info()
    local list = {}
    for k, v in pairs(pipelist) do
        list[k] = {}
        list[k].auto = (v.start_time ~= false)
        list[k].apps = v.apps
    end
    skynet.call(sysmgr_addr, "lua", "update_pipes", list)
end

local function validate_repo(repo)
    if repo then
        if type(repo) ~= "table" or
            type(repo.uri) ~= "string" then
            return false, text.invalid_arg
        end
        local auth
        if type(repo.auth) == "string" then
            local k, v = repo.auth:match("^([%g%s]+):([%g%s]+)$")
            if k and v then
                auth = { [k] = v }
            else
                return false, text.invalid_repo
            end
        elseif type(repo.auth) == "table" then
            local k, v = next(repo.auth)
            if type(k) == "string" and type(v) == "string" then
                auth = repo.auth
            else
                return false, text.invalid_repo
            end
        else
            return false, text.invalid_repo
        end
        local ok, ret = skynet.call(sysmgr_addr, "lua", "set_repo", repo.uri, auth)
        if ok then
            sysinfo.sys.repo = repo.uri
            --invalidate_info()
            return ok
        else
            return ok, ret
        end
    else
        if sysinfo.sys.repo then
            return true
        else
            return false, text.invalid_repo
        end
    end
end
local function validate_app_name(name)
    if type(name) == "string" then
        local tpl, id = name:match("^(.+)_(%d+)$")
        local i = tonumber(id)
        if tpllist[tpl] and applist[i] then
            return tpl, i
        else
            return false
        end
    else
        return false
    end
end
local function validate_pipe(pipe, list)
    if type(pipe) ~= "table" or
        type(pipe.apps) ~= "table" or #(pipe.apps) <= 1 or
        (type(pipe.auto) ~= "nil" and type(pipe.auto) ~= "boolean") then
        return false, text.invalid_arg
    end
    if list then
        for _, id in pairs(pipe.apps) do
            if sysapp(id) then
                if not applist[id] then
                    return false, text.unknown_app
                end
            else
                if not list[id] then
                    return false, text.unknown_app
                end
            end
        end
    else
        for i, name in pairs(pipe.apps) do
            if sysapp(name) then
                if not applist[name] then
                    return false, text.unknown_app
                end
            else
                local tpl, id = validate_app_name(name)
                if tpl then
                    pipe.apps[i] = id
                else
                    return false, text.unknown_app
                end
            end
        end
    end
    return true
end
local function install_tpl(tpl)
    if tpllist[tpl] then
        return true
    else
        local ok, err = validate_repo()
        if not ok then
            return ok, err
        end
        local ok, ret = skynet.call(sysmgr_addr, "lua", "install_tpl", tpl)
        if ok then
            tpllist[tpl] = ret
            return ok
        else
            return ok, ret
        end
    end
end
local function validate_app(arg, existing)
    if type(arg) ~= "table" then
        return false, text.invalid_arg
    end
    if existing then
        local name, conf = next(arg)
        if type(conf) == "table" then
            local tpl, id = validate_app_name(name)
            if tpl then
                local ok, full_conf = pcall(clone, tpllist[tpl], conf)
                if ok then
                    return id, full_conf
                else
                    return false, text.invalid_conf
                end
            else
                return false, text.unknown_app
            end
        else
            return false, text.invalid_arg
        end
    else
        local tpl, conf = next(arg)
        if type(tpl) == "string" and tpl:match("^[%l%d_]+_v_[%d_]+$") and
            type(conf) == "table" then
            local ok, err = install_tpl(tpl)
            if ok then
                local ok, full_conf = pcall(clone, tpllist[tpl], conf)
                if ok then
                    return tpl, full_conf
                else
                    return false, text.invalid_conf
                end
            else
                return false, err
            end
        else
            return false, text.invalid_arg
        end
    end
end

local function full_configure(arg)
    return type(arg.apps) == "table" and type(arg.pipes) == "table"
end

local function validate_conf(arg)
    if type(arg) ~= "table" then
        return false, text.invalid_arg
    end

    local ok, err = validate_repo(arg.repo)
    if not ok then
        return ok, err
    end

    if full_configure(arg) then
        for _, pipe in pairs(arg.pipes) do
            local ok, err = validate_pipe(pipe, arg.apps)
            if not ok then
                return ok, err
            end
        end
        local apps = arg.apps
        for id, app in pairs(apps) do
            local tpl, full_conf = validate_app(app)
            if tpl then
                app[tpl] = full_conf
            else
                return tpl, full_conf
            end
        end
    elseif type(arg.apps) == "table" then
        local apps = arg.apps
        for i, app in pairs(apps) do
            local id, full_conf = validate_app(app, true)
            if id then
                apps[i] = { [id] = full_conf }
            else
                return id, full_conf
            end
        end
    elseif not arg.repo then
        return false, text.invalid_arg
    end
    return true
end

local function load_app(id, tpl, conf)
    -- to reserve id
    applist[id] = {}
    local name = make_name(tpl, id)
    local ok, addr = pcall(skynet.newservice, "appcell", tpl, name, gateway_addr, mqttapp_addr)
    if not ok then
        applist[id] = nil
        log.error(text.load_fail, tpl, addr)
        return false, text.load_fail
    end

    skynet.send(addr, "lua", "conf", conf)

    applist[id] = {
        addr = addr,
        load_time = api.datetime(),
        conf = conf,
        tpl = tpl,
        route = {}
    }
    appmonitor[addr] = {
        id = name,
        counter = 0
    }
    log.error(text.load_suc, name)
    return true
end

local function start_pipe(id)
    local apps = pipelist[id].apps
    for _, appid in pairs(apps) do
        local r = applist[appid].route[id]
        if r.target then
            skynet.send(applist[appid].addr, "lua", "route_add", r.source, r.target)
        end
    end
    pipelist[id].start_time = api.datetime()
    pipelist[id].stop_time = false
    log.error(text.pipe_start_suc, id)
end
local function stop_pipe(id)
    local apps = pipelist[id].apps
    for _, appid in pairs(apps) do
        local r = applist[appid].route[id]
        if r.target then
            skynet.send(applist[appid].addr, "lua", "route_del", r.source, r.target)
        end
    end
    pipelist[id].start_time = false
    pipelist[id].stop_time = api.datetime()
    log.error(text.pipe_stop_suc, id)
end

local function try_start_pipe(id, auto)
    if auto == nil or auto == true then
        start_pipe(id)
    end
end

local function load_pipe(id, apps)
    local source = apps[1]
    for i, appid in ipairs(apps) do
        local nextid = apps[i+1]
        if nextid then
            applist[appid].route[id] = {
                source = source,
                target = applist[nextid].addr
            }
        else
            applist[appid].route[id] = {
                source = source
            }
        end
    end
    pipelist[id] = {
        start_time = false,
        stop_time = api.datetime(),
        apps = apps,
    }
    log.error(text.pipe_load_suc, id)
    return true
end

local function do_configure(arg, save)
    if full_configure(arg) then
        for id, app in pairs(arg.apps) do
            local tpl, full_conf = next(app)
            local ok, err = load_app(id, tpl, full_conf)
            if ok then
                if save then
                    update_app(id, tpl, conf)
                end
            else
                return ok, err
            end
        end

        for id, pipe in pairs(arg.pipes) do
            local ok, err = load_pipe(id, pipe.apps)
            if ok then
                try_start_pipe(id, pipe.auto)
                if save then
                    update_pipes()
                end
            else
                return ok, err
            end
        end
    elseif type(arg.apps) == "table" then
        local apps = arg.apps
        for _, app in pairs(apps) do
            local id, full_conf = next(app)
            local a = applist[id]
            skynet.send(a.addr, "lua", "conf", full_conf)
            a.conf = full_conf
            update_app(id, a.tpl, conf)
        end
    end
    return true
end

local function load_sysapp()
    local now = api.datetime()
    applist[wsappid] = {
        addr = wsapp_addr,
        load_time = now,
        app = "gateway_websocket",
        conf = 30001,
        route = {}
    }
    if tonumber(mqttapp_addr) ~= -1 then
        applist[mqttappid] = {
            addr = mqttapp_addr,
            load_time = now,
            app = "gateway_mqtt",
            route = {}
        }
    end
end

local cmd_desc = {
    mqttapp = true,
    clean = true,
    configure = "System configure: {}",
    upgrade = "System upgrade: <string>",
    info = "Show system info",
    apps = "Show all APP template",
    app_new = "New a APP: {<app>=<conf>}",
    app_remove = "Remove a APP: <id>",
    pipe_new = "New a PIPE: {apps={},auto=<boolean>}",
    pipe_remove = "Remove a PIPE: <id>",
    pipe_start = "Start a PIPE: <id>",
    pipe_stop = "Stop a PIPE: <id>",
}
local function reg_cmd()
    for k, v in pairs(cmd_desc) do
        api.reg_cmd(k, v, true)
    end
end

local function conf_get(k)
    return skynet.call(sysmgr_addr, "lua", "get", k)
end

local function load_all()
    sysinfo.sys = conf_get("sys")
    sysinfo.sys.cluster = nil
    sysinfo.sys.up = api.datetime(skynet.starttime())
    sysinfo.sys.repo = false

    load_sysapp()
    tpllist = conf_get("tpls")

    local total = conf_get("total")
    local ok, err = validate_conf(total)
    if ok then
        ok, err = do_configure(total, false)
        if not ok then
            log.error(text.conf_fail, err)
        end
    else
        log.error(text.conf_fail, err)
    end

    api.init(gateway_addr, mqttapp_addr)
    api.reg_dev("sys", true)
    reg_cmd()
    locked = false
end

function command.apps()
    return tpllist
end

function command.clean()
    for id, _ in pairs(pipelist) do
        stop_pipe(id)
    end
    pipelist = {}
    update_pipes()

    for id, _ in pairs(applist) do
        if not sysapp(id) then
            remove_app(id)
        end
    end
    log.error(text.cleaned)
    return true
end

function command.configure(arg)
    if locked then
        return false, text.locked
    end
    locked = true
    local ok, err = validate_conf(arg)
    if ok then
        if full_configure(arg) then
            command.clean()
        end
        local ok, err = do_configure(arg, true)
        locked = false
        if ok then
            return ok
        else
            return ok, err
        end
    else
        locked = false
        return ok, err
    end
end

function command.upgrade(version)
    if locked then
        return false, text.locked
    end
    if type(version) ~= "string" or
        not version:match("^[%d%l]+$") then
        return false, text.invalid_version
    end
    if version == sysinfo.sys.version then
        return false, text.dup_upgrade_version
    end
    local ok, err = validate_repo()
    if not ok then
        return ok, err
    end
    locked = true
    local ok, ret = skynet.call(sysmgr_addr, "lua", "upgrade", version)
    --locked = false
    return ok, ret
end

function command.mqttapp(conf)
    local m = applist[mqttappid]
    m.conf = conf
    return true
end

function command.app_new(arg)
    if locked then
        return false, text.locked
    end
    local tpl, full_conf = validate_app(arg)
    if not tpl then
        return tpl, conf
    end
    local id = #applist+1
    local ok, ret = load_app(id, tpl, full_conf)
    if ok then
        update_app(id, tpl, conf)
        return true
    else
        return false, ret
    end
end
function command.app_remove(name)
    if locked then
        return false, text.locked
    end
    if sysapp(name) then
        return false, text.sysapp_remove
    end
    local tpl, id = validate_app_name(name)
    if not tpl then
        return false, text.unknown_app
    end
    if next(applist[id].route) ~= nil then
        return false, text.app_in_use
    end

    remove_app(id)
    return true
end

function command.pipe_new(pipe)
    if locked then
        return false, text.locked
    end
    local ok, err = validate_pipe(pipe, false)
    if not ok then
        return ok, err
    end
    local id = #pipelist+1
    local ok, err = load_pipe(id, pipe.apps)
    if ok then
        try_start_pipe(id, pipe.auto)
        update_pipes()
        return true, id
    else
        return false, ret
    end
end
function command.pipe_remove(arg)
    if locked then
        return false, text.locked
    end
    local id = tonumber(arg)
    local pipe = pipelist[id]
    if not pipe then
        return false, text.unknown_pipe
    end
    if pipe.start_time ~= false then
        return false, text.pipe_running
    end

    for _, appid in pairs(pipe.apps) do
        applist[appid].route[id] = nil
    end
    pipelist[id] = nil
    update_pipes()
    return true
end
function command.pipe_start(arg)
    if locked then
        return false, text.locked
    end
    local id = tonumber(arg)
    local pipe = pipelist[id]
    if not pipe then
        return false, text.unknown_pipe
    end
    if pipe.start_time ~= false then
        return false, text.pipe_running
    end

    start_pipe(id)
    update_pipes()
    return true
end
function command.pipe_stop(arg)
    if locked then
        return false, text.locked
    end
    local id = tonumber(arg)
    local pipe = pipelist[id]
    if not pipe then
        return false, text.unknown_pipe
    end
    if pipe.stop_time ~= false then
        return false, text.pipe_stopped
    end

    stop_pipe(id)
    update_pipes()
    return true
end

setmetatable(command, { __index = function(t, cmd)
    if cmd == "info" then
        local info = info()
        f = function()
            return info
        end
    else
        f = function()
            return false, text.unknown_cmd
        end
    end
    t[cmd] = f
    return f
end})

local function signal(addr)
    core.command("SIGNAL", skynet.address(addr))
end

local function check()
    for addr, app in pairs(appmonitor) do
        if app.counter == 0 then
            app.counter = 1
            skynet.fork(function()
                skynet.call(addr, "debug", "PING")
                if appmonitor[addr] then
                    appmonitor[addr].counter = 0
                end
            end)
        elseif app.counter == limit then
            log.error(text.loop, app.id)
            signal(addr)
        else
            app.counter = app.counter + 1
        end
    end
    skynet.timeout(interval, check)
end

skynet.start(function()
    skynet.register_protocol {
        name = "client",
        id = skynet.PTYPE_CLIENT,
        unpack = function() end,
        dispatch = function(_, addr)
            if appmonitor[addr] then
                log.error(text.app_exit, appmonitor[addr].id)
                appmonitor[addr] = nil
            end
        end
    }
    skynet.timeout(interval, check)
    skynet.dispatch("lua", function(_, _, cmd, dev, arg)
        skynet.ret(skynet.pack(command[cmd](arg)))
    end)
    skynet.fork(load_all)
end)
