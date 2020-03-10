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
local wsappid = "ws"
local mqttappid = "mqtt"

local sysinfo = {}
local applist = {}
local pipelist = {}
local tpllist = {}

local installlist = {}
local appmonitor = {}
local approute = {}

local function conf_get(k)
    return skynet.call(sysmgr_addr, "lua", "get", k)
end

local function clone(tpl, custom)
    local copy
    if type(tpl) == "table" then
        copy = {}
        for k, v in pairs(tpl) do
            if custom and custom[k] then
                copy[k] = clone(v, custom[k])
            else
                copy[k] = v
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

local function app_id(i, tpl)
    return tpl.."_"..i
end
local function app_tpl(id)
    return id:match("^(.+)_%d+$")
end
local function app_i(id)
    return tonumber(id:match("^.+_(%d+)$"))
end
local function update_app(i, tpl, conf)
    if type(i) == "string" then
        skynet.call(sysmgr_addr, "lua", "update_app", app_i(i), tpl, conf)
    else
        skynet.call(sysmgr_addr, "lua", "update_app", i, tpl, conf)
    end
end
local function remove_app(id)
    skynet.send(applist[id].addr, "lua", "exit")
    approute[id] = nil
    applist[id] = nil
    skynet.call(sysmgr_addr, "lua", "remove_app", app_i(id))
end

local function update_pipelist()
    local list = {}
    for k, v in pairs(pipelist) do
        list[k] = {}
        list[k].auto = (v.start_time ~= false)
        list[k].apps = v.apps
    end
    skynet.call(sysmgr_addr, "lua", "update_pipelist", list)
end

local function set_repo(arg)
    if type(arg) ~= "table" or
        type(arg.uri) ~= "string" or
        type(arg.auth) ~= "string" then
        return false, text.invalid_arg
    end
    local ok, ret = skynet.call(sysmgr_addr, "lua", "set_repo", arg.uri, arg.auth)
    if ok then
        sysinfo.sys.repo = arg.uri
        return true
    else
        return false, ret
    end
end

local function validate_app(arg)
    if type(arg) == "table" then
        local tpl, conf = next(arg)
        if type(tpl) == "string" and type(conf) == "table" then
            return tpl, conf
        else
            return false
        end
    else
        return false
    end
end

local function validate_conf(arg)
    if type(arg) ~= "table" then
        return false
    end
    if arg.repo then
        local ok, err = set_repo(arg.repo)
        if not ok then
            return false
        end
    end
    if type(arg.apps) == "table" and type(arg.pipes) == "table" then
        for _, pipe in pairs(arg.pipes) do
            if #pipe <= 1 then
                return false
            end
            for _, id in pairs(pipe) do
                if id == mqttappid then
                    if not applist[id] then
                        return false
                    end
                else
                    if not validate_app(arg.apps[id]) then
                        return false
                    end
                end
            end
        end
    else
        for _, app in pairs(arg) do
            local id, conf = next(app)
            if not applist[id] or type(conf) ~= "table" then
                return false
            end
        end
    end
    return true
end

local function do_configure(arg, save)
    if type(arg.apps) == "table" and type(arg.pipes) == "table" then
        for i, app in pairs(arg.apps) do
            local tpl, conf = next(app)
            local ok, err = load_app(i, tpl, conf)
            if ok then
                if save then
                    update_app(i, tpl, conf)
                end
            else
                return ok, err
            end
        end

        for id, pipe in pairs(arg.pipes) do
            local ok, err = load_pipe(id, pipe)
            if ok then
                start_pipe(id)
            else
                return ok, err
            end
        end
        if save then
            update_pipelist()
        end
    else
        for _, app in pairs(arg) do
            local id, conf = next(app)
            local tpl = app_tpl(id)
            local full_conf = clone(tpllist[tpl], conf)
            local a = applist[id]
            skynet.send(a.addr, "lua", "conf", full_conf)
            a.conf = conf
            update_app(id, tpl, conf)
        end
    end
    return true
end

local function load_app(i, tpl, conf)
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
        local ok, ret = skynet.call(sysmgr_addr, "lua", "install_tpl", tpl)
        installlist[tpl] = false
        if ok then
            tpllist[tpl] = ret
        else
            return ok, ret
        end
    end

    local id = app_id(i, tpl)
    -- to reserve id
    approute[id] = {}
    local ok, addr = pcall(skynet.newservice, "appcell", tpl, id, gateway_addr, mqttapp)
    if not ok then
        approute[id] = nil
        log.error(text.load_fail, id, addr)
        return false, text.load_fail
    end

    local full_conf = clone(tpllist[tpl], conf)
    skynet.send(addr, "lua", "conf", full_conf)

    applist[id] = {
        addr = addr,
        load_time = api.datetime(),
        conf = conf
    }
    appmonitor[addr] = {
        id = id,
        counter = 0
    }
    log.error(text.load_suc, id)
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
    approute[wsappid] = {}
    applist[wsappid] = {
        addr = wsapp,
        load_time = api.datetime(),
        app = "gateway_websocket",
        conf = 30001
    }
    if tonumber(mqttapp) ~= -1 then
        approute[mqttappid] = {}
        applist[mqttappid] = {
            addr = mqttapp
        }
    end
end

local cmd_desc = {
    mqttapp = true,
    clean = true,
    set_repo = "Set SW repository: {uri=<string>,auth=<string>}",
    configure = "System configure: {}",
    upgrade = "System upgrade: <string>",
    info = "Show system info",
    apps = "Show all APP template",
    app_new = "New a APP: {<app>=<conf>}",
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

    load_sysapp()
    tpllist = conf_get("tpls")

    local total = {}
    total.repo = conf_get("repo")
    total.apps = conf_get("apps")
    total.pipes = conf_get("pipes")
    local ok, err = do_configure(total, false)
    if not ok then
        log.error(text.conf_fail, err)
    end

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
    sysinfo.apps = applist
    sysinfo.pipes = pipelist
    sysinfo.sys.uptime = string.format("%d seconds", math.floor(skynet.now()/100))
    return sysinfo
end

function command.clean()
    for id, _ in pairs(pipelist) do
        stop_pipe(id)
    end
    pipelist = {}
    skynet.call(sysmgr_addr, "lua", "remove_pipes")

    for id, _ in pairs(applist) do
        if id ~= mqttappid and id ~= wsappid then
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
    if validate_conf(arg) then
        command.clean()
        local ok, err = do_configure(arg, true)
        locked = false
        if ok then
            return ok
        else
            return ok, err
        end
    else
        locked = false
        return false, text.invalid_arg
    end
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
    local ok, ret = skynet.call(sysmgr_addr, "lua", "upgrade", version)
    --locked = false
    return ok, ret
end

function command.set_repo(arg)
    if locked then
        return false, text.locked
    end
    return set_repo(arg)
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
    local tpl, conf = validate_app(arg)
    if not tpl then
        return false, text.invalid_arg
    end
    local i = #approute+1
    local ok, ret = load_app(i, tpl, conf)
    if ok then
        update_app(i, tpl, conf)
        return true
    else
        return false, ret
    end
end

function command.app_remove(id)
    if locked then
        return false, text.locked
    end
    if id == mqttappid or id == wsappid then
        return false, text.sysapp_remove
    end
    local app = applist[id]
    if not app then
        return false, text.unknown_app
    end
    if next(approute[id]) ~= nil then
        return false, text.app_in_use
    end

    remove_app(id)
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
        update_pipelist()
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

    for _, appid in pairs(pipelist[id].apps) do
        approute[appid][id] = nil
    end
    pipelist[id] = nil
    update_pipelist()
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
    update_pipelist()
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
    update_pipelist()
    return true
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
