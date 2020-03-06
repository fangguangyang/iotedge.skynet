local skynet = require "skynet.manager"
local core = require "skynet.core"
local api = require "api"
local regex = require("text").regex
local sys = require "sys"
local log = require "log"
local text = require("text").dp

local interval = 500 -- 5 seconds
local limit = 4 -- 15 seconds

local locked = true
local mqttdpid = sys.mqttdpid
local wsdpid = sys.wsdpid

local sysinfo = {
    apps = {},
    pipes = {}
}
local dplist = sysinfo.apps
local pipelist = sysinfo.pipes
local tpllist = {}

local installlist = {}
local dpmonitor = {}
local dproute = {}

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

local function save_dplist()
    local list = {}
    for k, v in pairs(dplist) do
        if k ~= mqttdpid and k ~= wsdpid then
            list[k] = {}
            list[k][v.app] = v.conf
        end
    end
    sys.conf_set("dp_list", list)
end

local function save_pipelist()
    local list = {}
    for k, v in pairs(pipelist) do
        list[k] = {}
        list[k].auto = (v.start_time ~= false)
        list[k].dps = v.dps
    end
    sys.conf_set("pipe_list", list)
end

local function load_dp(id, tpl, conf)
    if not tpllist[tpl] then
        if type(tpl) ~= "string" or
            not tpl:match(regex.tpl_full_name) then
            return false, text.invalid_tpl
        end
        if installlist[tpl] then
            return false, text.dup_tpl_install
        end
        local uri = sysinfo.sys.repo.uri
        local auth = sysinfo.sys.repo.auth
        if not uri or not auth then
            return false, text.invalid_repo
        end

        installlist[tpl] = true
        local ok, ret = sys.install_tpl(tpl)
        installlist[tpl] = false
        if ok then
            tpllist[tpl] = ret
        else
            return ok, ret
        end
    end

    -- Borrow to reserve id
    dproute[id] = {}
    local ok, addr = pcall(skynet.newservice, "dpcell", tpl, id)
    if not ok then
        dproute[id] = nil
        log.error(text.load_fail, id, tpl, addr)
        return false, text.load_fail
    end

    local full_conf = clone(tpllist[tpl], conf)
    skynet.send(addr, "lua", "conf", full_conf)

    dplist[id] = {
        addr = addr,
        load_time = api.datetime(),
        app = tpl,
        conf = conf
    }
    dpmonitor[addr] = {
        id = id,
        counter = 0
    }
    log.error(text.load_suc, id, tpl)
    return true
end

local function start_pipe(id)
    local dps = pipelist[id].dps
    for _, dpid in pairs(dps) do
        local r = dproute[dpid][id]
        if r.target then
            skynet.send(dplist[dpid].addr, "lua", "route_add", r.source, r.target)
        end
    end
    pipelist[id].start_time = api.datetime()
    pipelist[id].stop_time = false
    log.error(text.pipe_start_suc, id)
end

local function stop_pipe(id)
    local dps = pipelist[id].dps
    for _, dpid in pairs(dps) do
        local r = dproute[dpid][id]
        if r.target then
            skynet.send(dplist[dpid].addr, "lua", "route_del", r.source, r.target)
        end
    end
    pipelist[id].start_time = false
    pipelist[id].stop_time = api.datetime()
    log.error(text.pipe_stop_suc, id)
end

local function load_pipe(id, dps)
    for _, dpid in pairs(dps) do
        if not dplist[dpid] then
            return false, text.unknown_dp
        end
    end

    local source = dps[1]
    for i, dpid in ipairs(dps) do
        local nextid = dps[i+1]
        if nextid then
            dproute[dpid][id] = {
                source = source,
                target = dplist[nextid].addr
            }
        else
            dproute[dpid][id] = {
                source = source
            }
        end
    end

    pipelist[id] = {
        start_time = false,
        stop_time = api.datetime(),
        dps = dps,
    }
    log.error(text.pipe_load_suc, id)
    return true
end

local function load_sysdp()
    if mqttdpid then
        dproute[mqttdpid] = {}
        dplist[mqttdpid] = {
            addr = sys.gateway_mqtt_addr
        }
    end
end

local function load_wsdp()
    if wsdpid then
        dproute[wsdpid] = {}
        dplist[wsdpid] = {
            addr = sys.gateway_ws_addr
        }
    end
end

local function load_dps()
    load_sysdp()
    load_wsdp()
    local dps = sys.conf_get("dp_list")
    for id, dp in pairs(dps) do
        for tpl, conf in pairs(dp) do
            load_dp(id, tpl, conf)
        end
    end
end

local function load_pipes()
    local pipes = sys.conf_get("pipe_list")
    for id, pipe in pairs(pipes) do
        local ok, _ = load_pipe(id, pipe.dps)
        if ok and pipe.auto then
            start_pipe(id)
        end
    end
end

local cmd_desc = {
    sysdp = true,
    clean = true,
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
    sysinfo.sys = sys.conf_get("sys")
    sysinfo.sys.up = api.datetime(skynet.starttime())
    sysinfo.sys.repo = sys.conf_get("repo")
    tpllist = sys.conf_get("tpl_list")
    load_dps()
    load_pipes()
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
    local uri = sysinfo.sys.repo.uri
    local auth = sysinfo.sys.repo.auth
    if not uri or not auth then
        return false, text.invalid_repo
    end
    locked = true
    local ok, ret = sys.upgrade(version)
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
    local ok, ret = sys.set_repo(arg.uri, arg.auth)
    if ok then
        sysinfo.sys.repo = ret
        return true
    else
        return false, ret
    end
end

function command.sysdp(info)
    local sysdp = dplist[mqttdpid]
    sysdp.load_time = api.datetime()
    sysdp.conf = info.conf
    sysdp.app = info.app
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
    local id = #dproute + 1
    local ok, ret = load_dp(id, arg.app, conf)
    if ok then
        save_dplist()
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
    local dp = dplist[id]
    if not dp then
        return false, text.unknown_dp
    end
    if id == mqttdpid or id = wsdpid then
        return false, text.sysdp_remove
    end
    if next(dproute[id]) ~= nil then
        return false, text.dp_in_use
    end

    skynet.send(dp.addr, "lua", "exit")
    dplist[id] = nil
    dproute[id] = nil
    save_dplist()
    return true
end

function command.pipe_new(dps)
    if locked then
        return false, text.locked
    end
    if type(dps) ~= "table" or #dps <= 1 then
        return false, text.invalid_arg
    end
    local id = #pipelist + 1
    local ok, ret = load_pipe(id, dps)
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

    for _, dpid in ipairs(pipelist[id].dps) do
        dproute[dpid][id] = nil
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
    for addr, dp in pairs(dpmonitor) do
        if dp.counter == 0 then
            dp.counter = 1
            skynet.fork(function()
                skynet.call(addr, "debug", "PING")
                if dpmonitor[addr] then
                    dpmonitor[addr].counter = 0
                end
            end)
        elseif dp.counter == limit then
            log.error(text.loop, dp.id)
            signal(addr)
        else
            dp.counter = dp.counter + 1
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
            if dpmonitor[addr] then
                log.error(text.dp_exit, dpmonitor[addr].id)
                dpmonitor[addr] = nil
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
