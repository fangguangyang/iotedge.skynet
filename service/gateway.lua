local skynet = require "skynet"
local log = require "log"
local text = require("text").gateway

local command = {}
local devlist = {}
local dplist = {}
local internal = {
    -- self
    help = true,
    reg_cmd = true,
    reg_dev = true,
    unreg_dev = true,
    -- DP
    route_add = true,
    route_del = true,
    data = true,
    conf = true,
    exit = true
}

local function help()
    local ret = {}
    for k, v in pairs(devlist) do
        if not v.dpname then
            ret[k] = {}
            ret[k].devices = v.sublist
            local cmd = {}
            for c, d in pairs(v.cmdlist) do
                if type(d) == "string" then
                    cmd[c] = d
                end
            end
            ret[k].cmd = cmd
        end
    end
    return ret
end

local function invalidate_cache(name)
    command[name] = nil
end

function command.reg_cmd(addr, name, desc)
    if type(name) ~= "string" or
        (type(desc) ~= "string" and type(desc) ~= "boolean") or
        internal[name] then
        log.error(text.invalid_cmd)
        return
    end
    local dp = dplist[addr]
    if not dp then
        log.error(text.unknown_dp)
        return
    end
    if dp.cmdlist[name] then
        log.error(text.dup_cmd)
        return
    end
    dp.cmdlist[name] = desc
    log.error(text.cmd_registered, name)
end

function command.reg_dev(addr, name, desc)
    if type(name) ~= "string" or
        (type(desc) ~= "boolean" and type(desc) ~= "string") then
        log.error(text.invalid_dev)
        return
    end
    if desc == true then
        if devlist[name] then
            log.error(text.dup_dev, name)
            return
        end
        devlist[name] = {
            addr = addr,
            name = name,
            cmdlist = {},
            sublist = {}
        }
        dplist[addr] = devlist[name]
        invalidate_cache("help")
        invalidate_cache(name)
    else
        if devlist[name] then
            log.error(text.dup_dev, name)
            return
        end
        local dp = dplist[addr]
        if not dp then
            log.error(text.unknown_dp)
            return
        end
        devlist[name] = {
            addr = addr,
            dpname = dp.name
        }
        dp.sublist[name] = desc
        invalidate_cache(name)
    end
    log.error(text.dev_registered, name)
end

function command.unreg_dev(addr, name)
    if type(name) ~= "string" and type(name) ~= "boolean" then
        log.error(text.invalid_dev)
        return
    end
    local dp = dplist[addr]
    if not dp then
        log.error(text.unknown_dp)
        return
    end
    if name == true then
        for dev, _ in pairs(dp.sublist) do
            devlist[dev] = nil
            invalidate_cache(dev)
        end
        devlist[dp.name] = nil
        dplist[addr] = nil
        invalidate_cache("help")
        invalidate_cache(dp.name)
        log.error(text.dev_unregistered, dp.name)
    else
        devlist[name] = nil
        dp.sublist[name] = nil
        invalidate_cache(name)
        log.error(text.dev_unregistered, name)
    end
end

setmetatable(command, { __index = function(t, dev)
    local f
    if dev == "help" then
        local info = help()
        f = function(addr)
            skynet.ret(skynet.pack(info))
        end
    else
        local d = devlist[dev]
        if d then
            local cmdlist
            if d.cmdlist then
                cmdlist = d.cmdlist
            elseif d.dpname and devlist[d.dpname].cmdlist then
                cmdlist = devlist[d.dpname].cmdlist
            end
            if cmdlist then
                f = function(addr, cmd, arg)
                    if cmdlist[cmd] then
                        local ok, ret, err = pcall(skynet.call, d.addr, "lua", cmd, dev, arg)
                        if ok then
                            if err then
                                skynet.ret(skynet.pack({ ret, err }))
                            else
                                skynet.ret(skynet.pack(ret))
                            end
                        else
                            skynet.ret(skynet.pack({ text.internal_err, ret }))
                        end
                    else
                        skynet.ret(skynet.pack(text.unknown_request))
                    end
                end
            else
                f = function(...)
                    skynet.ret(skynet.pack(text.unknown_request))
                end
            end
        else
            f = function(...)
                skynet.ret(skynet.pack(text.unknown_request))
            end
        end
    end
    t[dev] = f
    return f
end})

skynet.start(function()
    local cfg = require("sys").conf_get("gateway")
    if cfg then
        skynet.dispatch("lua", function(_, addr, cmd, ...)
            command[cmd](addr, ...)
        end)
    else
        log.error(text.no_conf)
    end
end)
