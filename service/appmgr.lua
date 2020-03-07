local skynet = require "skynet"
local core = require "skynet.core"
local api = require "api"
local regex = require("text").regex
local log = require "log"
local text = require("text").appmgr

local interval = 500 -- 5 seconds
local limit = 4 -- 15 seconds
local locked = true

local sysmgr_addr, gateway_addr, wsapp, mqttapp = ...
local wsappid = nil
local mqttappid = nil

local sysinfo = {
    apps = {},
    pipes = {}
}
local applist = sysinfo.apps
local pipelist = sysinfo.pipes
local tpllist = {}

local installlist = {}
local appmonitor = {}
local approute = {}

local function conf_get(k)
    return skynet.call(sysmgr_addr, "lua", "get", k)
end
local function conf_set(k, v)
    return skynet.call(sysmgr_addr, "lua", "set", k, v)
end
local function install_tpl(tpl)
    return skynet.call(sysmgr_addr, "lua", "install_tpl", tpl)
end
local function upgrade(version)
    return skynet.call(sysmgr_addr, "lua", "upgrade", version)
end
local function set_repo(uri, auth)
    return skynet.call(sysmgr_addr, "lua", "set_repo", uri, auth)
end

local function clone(tpl, custom)
    local copy
    if type(tpl) == "table" then
        copy = {}
        for k, v in pairs(tpl) do
            if custom and custom[k] then
                copy[k] = clone(v, custom[k])
            else
                copy[k] = clone(v)
            end
        end
    else
        if custom then
            copy = custom
        else
            copy = tpl
        end
    end
    return copy
end

local function save_applist()
    local list = {}
    for k, v in pairs(applist) do
        if k ~= mqttappid and k ~= wsappid then
            list[k] = {}
            list[k][v.app] = v.conf
        end
    end
    conf_set("app_list", list)
end

local function save_pipelist()
    local list = {}
    for k, v in pairs(pipelist) do
        list[k] = {}
        list[k].auto = (v.start_time ~= false)
        list[k].apps = v.apps
    end
    conf_set("pipe_list", list)
end

local function load_app(id, tpl, conf)
    if not tpllist[tpl] then
        if type(tpl) ~= "string" or
            not tpl:match(regex.tpl_full_name) then
            return false, text.invalid_tpl
        end
        if installlist[tpl] then
            return false, text.dup_tpl_install
        end
        if not sysinfo.sys.repo then
            return false, text.invalid_repo
        end

        installlist[tpl] = true
        local ok, ret = install_tpl(tpl)
        installlist[tpl] = false
        if ok then
            tpllist[tpl] = ret
        else
            return ok, ret
        end
    end

    -- Borrow to reserve id
    approute[id] = {}
    local ok, addr = pcall(skynet.newservice, "appcell", tpl, id, gateway_addr, mqttapp)
    if not ok then
        approute[id] = nil
        log.error(text.load_fail, id, tpl, addr)
        return false, text.load_fail
    end

    local full_conf = clone(tpllist[tpl], conf)
    skynet.send(addr, "lua", "conf", full_conf)

    applist[id] = {
        addr = addr,
        load_time = api.datetime(),
        app = tpl,
        conf = conf
    }
    appmonitor[addr] = {
        id = id,
        counter = 0
    }
    log.error(text.load_suc, id, tpl)
    return true
end

local function start_pipe(id)
    local apps = pipelist[id].apps
    for _, appid in pairs(apps) do
        local r = approute[appid][id]
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
        local r = approute[appid][id]
        if r.target then
            skynet.send(applist[appid].addr, "lua", "route_del", r.source, r.target)
        end
    end
    pipelist[id].start_time = false
    pipelist[id].stop_time = api.datetime()
    log.error(text.pipe_stop_suc, id)
end

local function load_pipe(id, apps)
    for _, appid in pairs(apps) do
        if not applist[appid] then
            return false, text.unknown_app
        end
    end

    local source = apps[1]
    for i, appid in ipairs(apps) do
        local nextid = apps[i+1]
        if nextid then
            approute[appid][id] = {
                source = source,
                target = applist[nextid].addr
            }
        else
            approute[appid][id] = {
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

local function load_sysapp()
    local id = 1
    if tonumber(wsapp) ~= -1 then
        wsappid = id
        approute[id] = {}
        applist[id] = {
            addr = wsapp,
            load_time = api.datetime(),
            app = "gateway_websocket",
            conf = 30001
        }
        id = id + 1
    end
    if tonumber(mqttapp) ~= -1 then
        mqttappid = id
        approute[id] = {}
        applist[id] = {
            addr = mqttapp
        }
    end
end

local function load_apps()
    load_sysapp()
    local apps = conf_get("app_list")
    for id, app in pairs(apps) do
        for tpl, conf in pairs(app) do
            load_app(id, tpl, conf)
        end
    end
end

local function load_pipes()
    local pipes = conf_get("pipe_list")
    for id, pipe in pairs(pipes) do
        local ok, _ = load_pipe(id, pipe.apps)
        if ok and pipe.auto then
            start_pipe(id)
        end
    end
end

local cmd_desc = {
    mqttapp = true,
    set_repo = "Set SW repository: {uri=<string>,auth=<string>}",
    configure = "System configure: {}",
    upgrade = "System upgrade: <string>",
    info = "Show system info",
    apps = "Show all APP template",
    app_new = "New a APP: {app=<string>,conf={}}",
    app_remove = "Remove a APP: <id>",
    pipe_new = "New a PIPE: {<id>,<id>, ...}",
    pipe_remove = "Remove a PIPE: <id>",
    pipe_start = "Start a PIPE: <id>",
    pipe_stop = "Stop a PIPE: <id>",
}

local function reg_cmd()
    for k, v in pairs(cmd_desc) do
        api.reg_cmd(k, v, true)
    end
end

local function load_all()
    sysinfo.sys = conf_get("sys")
    sysinfo.sys.up = api.datetime(skynet.starttime())
    local repo = conf_get("repo")
    if repo then
        sysinfo.sys.repo = repo.uri
    end
    tpllist = conf_get("tpl_list")
    load_apps()
    load_pipes()
    api.init(gateway_addr, mqttapp)
    api.reg_dev("sys", true)
    reg_cmd()
    locked = false
end

local command = {}
function command.apps()
    return tpllist
end

function command.info()
    sysinfo.sys.uptime = string.format("%d seconds", math.floor(skynet.now()/100))
    return sysinfo
end

function command.clean()
    return true
end

function command.upgrade(version)
    if locked then
        return false, text.locked
    end
    if type(version) ~= "string" or
        not version:match(regex.version) then
        return false, text.invalid_version
    end
    if version == sysinfo.sys.version then
        return false, text.dup_upgrade_version
    end
    if not sysinfo.sys.repo then
        return false, text.invalid_repo
    end
    locked = true
    local ok, ret = upgrade(version)
    --locked = false
    return ok, ret
end

function command.set_repo(arg)
    if locked then
        return false, text.locked
    end
    if type(arg) ~= "table" or
        type(arg.uri) ~= "string" or
        type(arg.auth) ~= "string" then
        return false, text.invalid_arg
    end
    local ok, ret = set_repo(arg.uri, arg.auth)
    if ok then
        sysinfo.sys.repo = arg.uri
        return true
    else
        return false, ret
    end
end

function command.mqttapp(info)
    local m = applist[mqttappid]
    m.load_time = api.datetime()
    m.conf = info.conf
    m.app = info.app
    return true
end

function command.app_new(arg)
    if locked then
        return false, text.locked
    end
    if type(arg) ~= "table" or
        type(arg.app) ~= "string" then
        return false, text.invalid_arg
    end
    local conf
    if arg.conf then
        if type(arg.conf) ~= "table" then
            return false, text.invalid_arg
        else
            conf = arg.conf
        end
    else
        conf = {}
    end
    local id = #approute + 1
    local ok, ret = load_app(id, arg.app, conf)
    if ok then
        save_applist()
        return true, id
    else
        return false, ret
    end
end

function command.app_remove(idstr)
    if locked then
        return false, text.locked
    end
    if not idstr or not tonumber(idstr) then
        return false, text.invalid_arg
    end
    local id = tonumber(idstr)
    local app = applist[id]
    if not app then
        return false, text.unknown_app
    end
    if id == mqttappid or id == wsappid then
        return false, text.sysapp_remove
    end
    if next(approute[id]) ~= nil then
        return false, text.app_in_use
    end

    skynet.send(app.addr, "lua", "exit")
    applist[id] = nil
    approute[id] = nil
    save_applist()
    return true
end

function command.pipe_new(apps)
    if locked then
        return false, text.locked
    end
    if type(apps) ~= "table" or #apps <= 1 then
        return false, text.invalid_arg
    end
    local id = #pipelist + 1
    local ok, ret = load_pipe(id, apps)
    if ok then
        save_pipelist()
        return true, id
    else
        return false, ret
    end
end

function command.pipe_remove(idstr)
    if locked then
        return false, text.locked
    end
    if not idstr or not tonumber(idstr) then
        return false, text.invalid_arg
    end
    local id = tonumber(idstr)
    local pipe = pipelist[id]
    if not pipe then
        return false, text.unknown_pipe
    end
    if pipe.start_time ~= false then
        return false, text.pipe_running
    end

    for _, appid in ipairs(pipelist[id].apps) do
        approute[appid][id] = nil
    end
    pipelist[id] = nil
    save_pipelist()
    return true
end

function command.pipe_start(idstr)
    if locked then
        return false, text.locked
    end
    if not idstr or not tonumber(idstr) then
        return false, text.invalid_arg
    end
    local id = tonumber(idstr)
    local pipe = pipelist[id]
    if not pipe then
        return false, text.unknown_pipe
    end
    if pipe.start_time ~= false then
        return false, text.pipe_running
    end

    start_pipe(id)
    save_pipelist()
    return true
end

function command.pipe_stop(idstr)
    if locked then
        return false, text.locked
    end
    if not idstr or not tonumber(idstr) then
        return false, text.invalid_arg
    end
    local id = tonumber(idstr)
    local pipe = pipelist[id]
    if not pipe then
        return false, text.unknown_pipe
    end
    if pipe.stop_time ~= false then
        return false, text.pipe_stopped
    end

    stop_pipe(id)
    save_pipelist()
    return true
end

function command.configure(arg)
    if locked then
        return false, text.locked
    end
    if type(arg) ~= "table" then
        return false, text.invalid_arg
    end
    locked = true
    local ok = true
    locked = false
    if ok then
        return ok
    else
        return ok, ret
    end
end

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

local function init()
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
        local f = command[cmd]
        if f then
            skynet.ret(skynet.pack(f(arg)))
        else
            skynet.ret(skynet.pack(false, text.unknown_cmd))
        end
    end)
    skynet.fork(load_all)
end

skynet.start(init)
