local skynet = require "skynet"
local log = require "log"
local text = require("text").app
local api = require "api"
local client = require "modbus.client"
local mpdu = require "modbus.pdu"
local mdata = require "modbus.data"

local tblins = table.insert
local strfmt = string.format

local MODBUS_SLAVE_MIN = 1
local MODBUS_SLAVE_MAX = 247

local cli
local cli_pack
local registered = false
local running = false
local max_poll = 100 * 60 -- 1 min
local devlist = {}

local cmd_desc = {
    read = "<tag>",
    write = "{<tag>,<val>}",
    list = "list tags"
}

local function reg_cmd()
    for k, v in pairs(cmd_desc) do
        api.reg_cmd(k, v)
    end
end

function list(dev)
    if cli then
        local d = devlist[dev]
        if d then
            if not d.help then
                local h = {
                    unitid = d.unitid,
                    write = {},
                    read = {}
                }
                for name, t in pairs(d.tags) do
                    if t.read then
                        h.read[name] = {
                            fc = t.fc,
                            dtype = t.dt,
                            addr = t.addr,
                            number = t.number
                        }
                    end
                    if t.write then
                        h.write[name] = {
                            fc = t.wfc,
                            dtype = t.dt,
                            addr = t.addr,
                            number = t.number
                        }
                    end
                end
                d.help = h
            end
            return d.help
        else
            return false, text.invalid_dev
        end
    else
        return false, text.not_online
    end
end

function read(dev, tag)
    if cli then
        return pcall(function()
            local u = assert(devlist[dev].unitid, text.invalid_dev)
            local t = assert(devlist[dev].tags[tag], text.invalid_tag)

            -- all tag can be read, no check here
            local ok, ret = cli:request(u, t.read)
            assert(ok, strfmt("%s:%s", text.req_fail, ret))
            local uid = ret[1]
            assert(uid==u, strfmt("%s:%s:%s", text.invalid_unit, u, uid))
            local fc = ret[2]
            assert(fc==t.fc, strfmt("%s:%s:%s", text.invalid_fc, t.fc, fc))
            local data = ret[3]
            assert(type(data)=="table", strfmt("%s:%s", text.exception, data))
            if t.fc == 3 or t.fc == 4 then
                local n = #data
                assert(n==t.number, strfmt("%s:%s:%s", text.invalid_num, t.number, n))
            end
            return t.unpack(1, data)
        end)
    else
        return false, text.not_online
    end
end

function write(dev, arg)
    if cli then
        return pcall(function()
            local u = assert(devlist[dev].unitid, text.invalid_dev)
            assert(type(arg) == "table", text.invalid_arg)
            local tag = arg[1]
            assert(type(tag) == "string", text.invalid_arg)
            local val = arg[2]
            assert(type(val) == "number" or
                type(val) == "boolean" or
                type(val) == "string", text.invalid_arg)
            local t = assert(devlist[dev].tags[tag], text.invalid_tag)
            local w = assert(t.write, text.read_only)
            local p = assert(w(val), strfmt("%s", text.pack_fail))

            local ok, ret = cli:request(u, p)
            assert(ok, strfmt("%s:%s", text.req_fail, ret))
            local uid = ret[1]
            assert(uid==u, strfmt("%s:%s:%s", text.invalid_unit, u, uid))
            local fc = ret[2]
            assert(fc==t.wfc, strfmt("%s:%s:%s", text.invalid_fc, t.wfc, fc))
            local addr = ret[3]
            local data = ret[4]
            assert(data ~= nil, strfmt("%s:%s", text.exception, addr))
            assert(addr==t.addr, strfmt("%s:%s:%s", text.invalid_addr, t.addr, addr))
            if fc == 5 or fc == 6 then
                local v = t.unpack(1, {data})
                assert(val==v, strfmt("%s:%s:%s", text.invalid_write, val, v))
            else
                assert(data==t.number, strfmt("%s:%s:%s", text.invalid_num, t.number, data))
            end
        end)
    else
        return false, text.not_online
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

local function do_make_poll(interval, dname, unitid, fc, addr, number, tags, postfunc)
--    local p = pack(fc, addr, number)
--    local log_prefix = string.format("%s(%d): %d, %d(%d)", dname, unitid, fc, addr, number)
--    local poll = function()
--        local ok, ret = cli:request(u, t.read)
--        assert(ok, strfmt("%s:%s", text.req_fail, ret))
--        local uid = ret[1]
--        assert(uid==u, strfmt("%s:%s:%s", text.invalid_unit, u, uid))
--        local fc = ret[2]
--        assert(fc==t.fc, strfmt("%s:%s:%s", text.invalid_fc, t.fc, fc))
--        local data = ret[3]
--        assert(type(data)=="table", strfmt("%s:%s", text.exception, data))
--        local n = #data
--        assert(n==t.number, strfmt("%s:%s:%s", text.invalid_num, t.number, n))
--
--        local list = {}
--        for index, t in pairs(tags) do
--            local ok, v = pcall(t.unpack, index, data)
--            if ok then
--                tblins(list, { t.name = v })
--            else
--                log.error(log_prefix, text.unpack_fail, name, tostring(v))
--            end
--        end
--        postfunc(list)
--
--        if running then
--            skynet.timeout(interval, poll)
--        end
--    end
--    return poll
end

local function make_poll()
--    local dev = {}
--    for tname, tconf in pairs(dconf.tags) do
--        local tfc = tconf.fc
--        if not dev[tfc] then
--            dev[tfc] = {}
--        end
--        local fc = dev[tfc]
--
--        local poll_i = poll_interval(dconf, tconf)
--        if not fc[poll_i] then
--            fc[poll_i] = {}
--        end
--        local p = fc[poll_i]
--
--        local poll_f = post_function(dname, dconf, tconf)
--        if not p[poll_f] then
--            p[poll_f] = {}
--        end
--        local pf = p[poll_f]
--
--        local validate_tag(dconf.le, tname, tconf)
--
--    end
end

local function validate_tag(name, tag)
    if type(name) ~= "string" or type(tag) ~= "table" or
        not math.tointeger(tag.addr) or
        (tag.mode ~= "ts" and tag.mode ~= "attr" and tag.mode ~= "ctrl") or
        (tag.le ~= nil and type(tag.le) ~= "boolean") or
        (tag.poll ~= nil and not math.tointeger(tag.poll)) then
        error(text.invalid_tag_conf)
    end
end

local fc_map = {
    [5] = 1,
    [15] = 1,
    [6] = 3,
    [16] = 3
}

local function validate_tags(tags, dle, tle)
    for name, t in pairs(tags) do
        validate_tag(name, t)
        if t.mode == "ts" or t.mode == "attr" then
            local le
            if t.le == nil then
                le = dle
            else
                le = t.le
            end
            t.unpack = mdata.unpack(t.fc, t.dt, t.number, tle, le, t.bit)
            t.read = cli_pack(t.fc, t.addr, t.number)
        else
            t.wfc = t.fc
            t.fc = assert(fc_map[t.fc], text.invalid_tag_conf)
            if t.le == nil then
                le = dle
            else
                le = t.le
            end
            t.unpack = mdata.unpack(t.fc, t.dt, t.number, tle, le, t.bit)
            local pack = mdata.pack(t.wfc, t.dt, t.number, tle, le, t.bit)
            t.read = cli_pack(t.fc, t.addr, t.number)
            t.write = function(val)
                local v = pack(val)
                return cli_pack(t.wfc, t.addr, v)
            end
        end
    end
end

local function validate_device(name, dev)
    if type(name) ~= "string" or type(dev) ~= "table" or
        not math.tointeger(dev.unitid) or dev.unitid < MODBUS_SLAVE_MIN or
        dev.unitid > MODBUS_SLAVE_MAX or
        not math.tointeger(dev.attr_poll) or not math.tointeger(dev.ts_poll) or
        type(dev.le) ~= "boolean" then
        error(text.invalid_device_conf)
    end
end

local function validate_devices(d, tle)
    for name, dev in pairs(d) do
        validate_device(name, dev)
        validate_tags(dev.tags, dev.le, tle)
    end
end

local function unregdev()
    for name, dev in pairs(devlist) do
        api.unreg_dev(name)
    end
    devlist = {}
end

local function regdev(d)
    devlist = {}
    for name, dev in pairs(d) do
        local desc = string.format("unitid(%d)", dev.unitid)
        api.reg_dev(name, desc)
        if dev.batch then
            api.batch_size(name, dev.batch)
        end
        devlist[name] = dev
    end
end

local function stop()
    if running then
        running = false
        unregdev()
        skynet.sleep(max_poll)
    end
end

local function config_devices(d, tle)
    local ok, err = pcall(validate_devices, d, tle)
    if ok then
        stop()
        -- wait for mqtt up
        skynet.sleep(500)
        regdev(d)
        running = true
       -- math.randomseed(skynet.time())
       -- for _, f in pairs(polls) do
       --     f()
       --     skynet.sleep(math.random(100, 500))
       -- end
       return ok
    else
        return ok, err
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
            cli_pack = mpdu.pack(t.le)
        elseif mode == 'rtu_tcp' then
            arg = t.tcp
            arg.ascii = t.ascii
            arg.le = t.le
            arg.timeout = t.timeout
            cli = client.new_rtu_tcp(arg)
            cli_pack = mpdu.pack(t.le)
        elseif mode == 'tcp' then
            arg = t.tcp
            arg.le = t.le
            arg.timeout = t.timeout
            cli = client.new_tcp(arg)
            cli_pack = mpdu.pack(t.le)
        end
    end
end

function on_conf(conf)
    if not registered then
        reg_cmd()
    end
    config_transport(conf.transport)
    if cli then
        return config_devices(conf.devices, conf.transport.le)
    else
        return false, text.conf_fail
    end
end

function on_exit()
    stop()
    cli.channel:close()
end
