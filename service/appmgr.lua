local skynet = require "skynet"
local core = require "skynet.core"
local api = require "api"
local log = require "log"
local text = require("text").appmgr

local interval = 500 -- 5 seconds
local limit = 4 -- 15 seconds
local locked = true

local wsapp_addr, mqttapp_addr = ...
local wsappid = "ws"
local mqttappid = "mqtt"

local sysinfo = {}
local applist = {}
local pipelist = {}
local tpllist = {}
local appmonitor = {}
local command = {}

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

local function update_app(id, app)
    invalidate_info()
    local tpl, conf = next(app)
    api.internal_request("update_app", { id, tpl, conf })
end

local function remove_app(id)
    skynet.send(applist[id].addr, "lua", "exit")
    local tpl = applist[id].tpl
    applist[id] = nil
    invalidate_info()
    api.internal_request("update_app", { id, tpl, false })
end

local function update_pipes()
    invalidate_info()
    local list = {}
    for k, v in pairs(pipelist) do
        list[k] = {}
        list[k].auto = (v.start_time ~= false)
        list[k].apps = v.apps
    end
    api.internal_request("update_pipes", list)
end

local function validate_repo(repo)
    if repo then
        assert(type(repo) == "table" and
            type(repo.uri) == "string" and
            (type(repo.auth) == "string" or type(repo.auth) == "table"),
            text.invalid_repo)

        local auth
        if type(repo.auth) == "string" then
            local k, v = repo.auth:match("^([%g%s]+):([%g%s]+)$")
            if k and v then
                auth = { [k] = v }
            end
        elseif type(repo.auth) == "table" then
            local k, v = next(repo.auth)
            if type(k) == "string" and type(v) == "string" then
                auth = repo.auth
            end
        end
        assert(auth, text.invalid_repo)
        local ok, err = api.internal_request("update_repo", { repo.uri, auth })
        if ok then
            sysinfo.sys.repo = repo.uri
        else
            error(err)
        end
    end
    assert(sysinfo.sys.repo, text.invalid_repo)
end

local function validate_app_name(name)
    if type(name) == "string" then
        local tpl, id = name:match("^(.+)_(%d+)$")
        local i = tonumber(id)
        if tpllist[tpl] and applist[i] then
            return tpl, i
        else
            error(text.unknown_app)
        end
    else
        error(text.unknown_app)
    end
end

local function validate_pipe_with_apps(pipe, apps)
    assert(type(pipe) == "table" and
        type(pipe.apps) == "table" and #(pipe.apps) > 1 and
        (pipe.auto == "nil" or type(pipe.auto) == "boolean"),
        text.invalid_arg)
    for _, name in pairs(pipe.apps) do
        if sysapp(name) then
            assert(applist[name], text.unknown_app)
        else
            assert(apps[name], text.unknown_app)
        end
    end
end

local function validate_pipe(pipe)
    assert(type(pipe) == "table" and
        type(pipe.apps) == "table" and #(pipe.apps) > 1 and
        (pipe.auto == "nil" or type(pipe.auto) == "boolean"),
        text.invalid_arg)
    for i, name in pairs(pipe.apps) do
        if sysapp(name) then
            assert(applist[name], text.unknown_app)
        else
            local tpl, id = validate_app_name(name)
            pipe.apps[i] = id
        end
    end
end

local function install_tpl(tpl)
    if not tpllist[tpl] then
        validate_repo()
        local ok, ret = api.internal_request("install_tpl", tpl)
        if ok then
            tpllist[tpl] = ret
        else
            error(ret)
        end
    end
end

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
        local d = custom["devices"]
        if d then
            copy["devices"] = d
        end
        return copy
    else
        return custom
    end
end

local function validate_existing_app(arg)
    assert(type(arg) == "table", text.invalid_arg)
    local name, conf = next(arg)
    assert(type(conf) == "table", text.invalid_arg)
    local tpl, id = validate_app_name(name)
    return { [id] = clone(tpllist[tpl], conf) }
end

local function validate_app(arg)
    assert(type(arg) == "table", text.invalid_arg)
    local tpl, conf = next(arg)
    assert(type(tpl) == "string" and
        tpl:match("^[%l%d_]+_v_[%d_]+$") and
        type(conf) == "table", text.invalid_arg)
    install_tpl(tpl)
    arg[tpl] = clone(tpllist[tpl], conf)
end

local function validate_conf(arg)
    assert(type(arg) == "table" and
        (arg.repo == nil or type(arg.repo) == "table") and
        ((arg.pipes == nil and arg.apps == nil) or
         (arg.pipes == nil and type(arg.apps) == "table") or
         (type(arg.pipes) == "table" and type(arg.apps) == "table")),
        text.invalid_arg)

    if arg.repo then
        validate_repo(arg.repo)
    end

    if type(arg.pipes) == "table" then
        for _, pipe in pairs(arg.pipes) do
            validate_pipe_with_apps(pipe, arg.apps)
        end
        for _, app in pairs(arg.apps) do
            validate_app(app)
        end
    elseif type(arg.apps) == "table" then
        for i, app in pairs(arg.apps) do
            local a = validate_existing_app(app)
            arg.apps[i] = a
        end
    end
end

local function load_app(id, app)
    -- to reserve id
    applist[id] = {}
    local tpl, conf = next(app)
    local name = make_name(tpl, id)
    local ok, addr = pcall(skynet.newservice, "appcell", tpl, name, mqttapp_addr)
    if not ok then
        applist[id] = nil
        log.error(text.load_fail, tpl, addr)
        return false, text.load_fail
    end

    local ok, err = skynet.call(addr, "lua", "conf", conf)
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
    if ok then
        log.error(text.load_suc, name)
    else
        log.error(text.conf_fail, name, err)
    end
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

local function do_full_configure(arg, save)
    for id, app in pairs(arg.apps) do
        local ok, err = load_app(id, app)
        if ok then
            if save then
                update_app(id, app)
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
    return true
end

local function do_configure(arg)
    for _, app in pairs(arg.apps) do
        local id, conf = next(app)
        local a = applist[id]
        local ok, err = skynet.call(a.addr, "lua", "conf", conf)
        if ok then
            a.conf = conf
            update_app(id, { [a.tpl] = conf })
        else
            return ok, err
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
    if mqttapp_addr then
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

local function load_all()
    api.sys_init(cmd_desc)

    sysinfo.sys = api.internal_request("conf_get", "sys")
    sysinfo.sys.cluster = nil
    sysinfo.sys.up = api.datetime(skynet.starttime())
    sysinfo.sys.repo = false

    load_sysapp()
    tpllist = api.internal_request("conf_get", "tpls")

    local total = api.internal_request("conf_get", "total")
    local ok, err = pcall(validate_conf, total)
    if ok then
        ok, err = do_full_configure(total, false)
        if not ok then
            log.error(text.conf_fail, err)
        end
    else
        log.error(text.conf_fail, err)
    end

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
    local ok, err = pcall(validate_conf, arg)
    if not ok then
        return ok, err
    end
    locked = true
    if type(arg.pipes) == "table" and
        type(arg.apps) == "table" then
        command.clean()
        ok, err = do_full_configure(arg, true)
    else
        ok, err = do_configure(arg)
    end
    locked = false
    return ok, err
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
    local ok, err = pcall(validate_repo)
    if not ok then
        return ok, err
    end
    locked = true
    local ok, err = api.internal_request("upgrade", version)
    --locked = false
    return ok, err
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
    local ok, err = pcall(validate_app, arg)
    if not ok then
        return ok, err
    end
    local id = #applist+1
    local ok, err = load_app(id, arg)
    if ok then
        update_app(id, arg)
        return ok
    else
        return ok, err
    end
end
function command.app_remove(name)
    if locked then
        return false, text.locked
    end
    if sysapp(name) then
        return false, text.sysapp_remove
    end
    local ok, err, id = pcall(validate_app_name, name)
    if not ok then
        return ok, err
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
    local ok, err = pcall(validate_pipe, pipe)
    if not ok then
        return ok, err
    end
    local id = #pipelist+1
    local ok, err = load_pipe(id, pipe.apps)
    if ok then
        try_start_pipe(id, pipe.auto)
        update_pipes()
        return ok, id
    else
        return ok, err
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
