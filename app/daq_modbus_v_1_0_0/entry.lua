local log = require "log"
local text = require("text").app
local api = require "api"
local client = require "modbus.client"
local mpdu = require "modbus.pdu"
local mdata = require "modbus.data"
local basexx = require "utils.basexx"
local skynet = require "skynet"

local tblins = table.insert

local cli
local pack
local registered = false
local running = false
local max_poll = 100 * 60 -- 1 min
local devlist = {}

local cmd_desc = {
    read_coin = "{ slave=<s>,addr=<a>,number=<n> }",
    read_input = "{ slave=<s>,addr=<a>,number=<n> }",
    read_holding_register = "{ slave=<s>,addr=<a>,number=<n> }",
    read_input_register = "{ slave=<s>,addr=<a>,number=<n> }",
    write_coin = "{ slave=<s>,addr=<a>,value=<v>/{} }",
    write_register = "{ slave=<s>,addr=<a>,value=<v>/{} }"
}

local function hex_dump(buf)
    print(basexx.to_hex(buf))
    io.write('\n')
end

local function reg_cmd()
    for k, v in pairs(cmd_desc) do
        api.reg_cmd(k, v)
    end
end

function read_coin(arg)
    if cli then
        local p = pack(1, arg.addr, arg.number)
        return cli:request(arg.slave, p)
    else
        return false
    end
end

function read_input(arg)
    if cli then
        local p = pack(2, arg.addr, arg.number)
        return cli:request(arg.slave, p)
    else
        return false
    end
end

function read_holding_register(arg)
    if cli then
        local p = pack(3, arg.addr, arg.number)
        return cli:request(arg.slave, p)
    else
        return false
    end
end

function read_input_register(arg)
    if cli then
        local p = pack(4, arg.addr, arg.number)
        return cli:request(arg.slave, p)
    else
        return false
    end
end

function write_coin(arg)
    if cli then
        local p
        if type(arg.value) == "table" then
            p = pack(15, arg.addr, arg.value)
        else
            p = pack(5, arg.addr, arg.value)
        end
        return cli:request(arg.slave, p)
    else
        return false
    end
end

function write_register(arg)
    if cli then
        local p
        if type(arg.value) == "table" then
            p = pack(16, arg.addr, arg.value)
        else
            p = pack(6, arg.addr, arg.value)
        end
        return cli:request(arg.slave, p)
    else
        return false
    end
end

local function unregdev()
    for _, d in pairs(devlist) do
        api.unreg_dev(d)
    end
    devlist = {}
end

local function stop()
    if running then
        running = false
        unregdev()
        skynet.sleep(max_poll)
    end
end

local function poll_interval(dconf, tconf)
    if tconf.poll then
        return tconf.poll
    else
        return dconf[tconf.mode.."_poll"]
    end
end

local function post_function(dname, dconf, tconf)
    if tconf.cov then
        return api.cov_post
    end
    if tconf.mode == "attr" then
        return api.post_attr
    end
    if dconf.batch then
        return api.batch_post(dname, dconf.batch)
    else
        return api.post_data
    end
end

local function make_poll(interval, dname, unitid, fc, addr, number, tags, postfunc)
    local p = pack(fc, addr, number)
    local log_prefix = string.format("%s(%d): %d, %d(%d)", dname, unitid, fc, addr, number)
    local poll = function()
        local ok, ret = cli:request(unitid, p)
        if ok then
            local uid = ret[1]
            local data = ret[2]
            if uid == unitid then
                if type(data) ~= "table" then
                    log.error(log_prefix, text.exception, tostring(data))
                elseif #data ~= number then
                    log.error(log_prefix, text.invalid_resp, "number", tostring(#data))
                else
                    local list = {}
                    for name, unpack in pairs(tags) do
                        local ok, v = pcall(unpack, data)
                        if ok then
                            tblins(list, { name = v })
                        else
                            log.error(log_prefix, text.unpack_fail, name, tostring(v))
                        end
                    end
                    postfunc(list)
                end
            else
                log.error(log_prefix, text.invalid_resp, "unitid", tostring(uid))
            end
        else
            log.error(log_prefix, text.poll_fail, ret)
        end
        if running then
            skynet.timeout(interval, poll)
        end
    end
    return poll
end

local function validate_tag(dle, name, tag)
    local f
    if tag.le ~= nil then
        f = mdata.unpack(tag.fc, tag.t, tag.count, tag.le)
    local function unpack(data)
    end
end

local function validate_devices(d)
    local polls = {}
    for dname, dconf in pairs(d) do
        local dev = {}
        for tname, tconf in pairs(dconf.tags) do
            local tfc = tconf.fc
            if not dev[tfc] then
                dev[tfc] = {}
            end
            local fc = dev[tfc]

            local poll_i = poll_interval(dconf, tconf)
            if not fc[poll_i] then
                fc[poll_i] = {}
            end
            local p = fc[poll_i]

            local poll_f = post_function(dname, dconf, tconf)
            if not p[poll_f] then
                p[poll_f] = {}
            end
            local pf = p[poll_f]

            local validate_tag(dconf.le, tname, tconf)

        end
    end
    return polls
end

local function regdev(d)
    for name, conf in pairs(d) do
        local desc = string.format("unitid(%d)", conf.unit_id)
        api.reg_dev(name, desc)
        tblins(devlist, name)
    end
end

local function config_devices(d)
    local ok, polls = pcall(validate_devices, d)
    if ok and next(polls) then
        stop()
        -- wait for mqtt up
        skynet.sleep(500)
        regdev(d)
        running = true
        math.randomseed(skynet.time())
        for _, f in pairs(polls) do
            f()
            skynet.sleep(math.random(100, 500))
        end
    else
        log.error(text.conf_device_fail, polls)
    end
end

local function validate_transport(t)
    if type(t) ~= "table" then
        return false
    end
    local mode = t.mode
    if mode == 'rtu' then
        return type(t.rtu) == "table" and
        type(t.ascii) == "boolean" and
        type(t.le) == "boolean" and
        type(t.timeout) == "number"
    elseif mode == 'rtu_tcp' then
        return type(t.tcp) == "table" and
        type(t.ascii) == "boolean" and
        type(t.le) == "boolean" and
        type(t.timeout) == "number"
    elseif mode == 'tcp' then
        return type(t.tcp) == "table" and
        type(t.le) == "boolean" and
        type(t.timeout) == "number"
    else
        return false
    end
end

local function config_transport(t)
    if not validate_transport(t) then
        log.error(text.conf_fail)
    else
        stop()
        local mode = t.mode
        local arg
        if mode == 'rtu' then
            arg = t.rtu
            arg.ascii = t.ascii
            arg.le = t.le
            arg.timeout = t.timeout
            cli = client.new_rtu(arg)
            pack = mpdu.pack(t.le)
        elseif mode == 'rtu_tcp' then
            arg = t.tcp
            arg.ascii = t.ascii
            arg.le = t.le
            arg.timeout = t.timeout
            cli = client.new_rtu_tcp(arg)
            pack = mpdu.pack(t.le)
        elseif mode == 'tcp' then
            arg = t.tcp
            arg.le = t.le
            arg.timeout = t.timeout
            cli = client.new_tcp(arg)
            pack = mpdu.pack(t.le)
        end
    end
end

function on_conf(conf)
    if not registered then
        reg_cmd()
    end
    config_transport(conf.transport)
    if cli then
        config_devices(conf.devices)
    end
end
