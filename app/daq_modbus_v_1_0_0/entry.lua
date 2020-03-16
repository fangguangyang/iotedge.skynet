local skynet = require "skynet"
local log = require "log"
local text = require("text").modbus
local api = require "api"
local client = require "modbus.client"
local mpdu = require "modbus.pdu"
local mdata = require "modbus.data"

local tblins = table.insert
local strfmt = string.format

local MODBUS_SLAVE_MIN = 1
local MODBUS_SLAVE_MAX = 247
local MODBUS_ADDR_MIN = 0x0000
local MODBUS_ADDR_MAX = 0x270E
local MODBUS_MAX_READ_BITS = 2000
local MODBUS_MAX_READ_REGISTERS = 125

local cli
local cli_pack
local registered = false
local running = false
local max_wait = 100 * 60 -- 1 min
local poll_min = 10 -- ms
local poll_max = 1000 * 60 * 60 -- 1 hour
local batch_max = 200
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

local function post(dname, index, interval)
    local ts = {}
    local attr = {}
    for i, t in pairs(index) do
        local tag = t.tag
        if tag.cov then
            if tag.gain then
                t.val = t.val * t.gain + t.offset
            end
            api.post_cov(dname, { [tag.name] = t.val })
        else
            if tag.poll_cum + interval >= tag.poll then
                tag.poll_cum = 0
                if tag.gain then
                    t.val = t.val * t.gain + t.offset
                end
                if tag.mode == "ts" then
                    tblins(ts, { [tag.name] = t.val })
                else
                    tblins(attr, { [tag.name] = t.val })
                end
            else
                tag.poll_cum = tag.poll_cum + interval
            end
        end
    end
    if next(ts) then
        api.post_data(dname, ts)
    end
    if next(attr) then
        api.post_attr(dname, attr)
    end
end

local function make_poll(dname, unitid, fc, start, number, interval, index)
    local p = cli_pack(fc, start, number)
    local log_prefix = string.format("%s(%d): %d, %d(%d)", dname, unitid, fc, start, number)
    local timeout = interval // 10
    local poll = function()
        local ok, ret = cli:request(unitid, p)
        assert(ok, strfmt("%s %s:%s", log_prefix, text.req_fail, ret))
        local uid = ret[1]
        assert(uid==unitid, strfmt("%s %s:%s:%s", log_prefix, text.invalid_unit, unitid, uid))
        local c = ret[2]
        assert(c==fc, strfmt("%s %s:%s:%s", log_prefix, text.invalid_fc, fc, c))
        local data = ret[3]
        assert(type(data)=="table", strfmt("%s %s:%s", log_prefix, text.exception, data))
        if fc == 3 or fc == 4 then
            local n = #data
            assert(n==number, strfmt("%s %s:%s:%s", log_prefix, text.invalid_num, number, n))
        end
        for i, t in pairs(index) do
            local v = t.tag.unpack(i, data)
            index[i].val = v
        end
        post(dname, index, interval)
        if running then
            skynet.timeout(timeout, function()
                local ok, err = pcall(poll)
                if not ok then
                    log.error(err)
                end
            end)
        end
    end
    return poll
end

local maxnumber = {
    [1] = MODBUS_MAX_READ_BITS,
    [2] = MODBUS_MAX_READ_BITS,
    [3] = MODBUS_MAX_READ_REGISTERS,
    [4] = MODBUS_MAX_READ_REGISTERS
}

local function make_polls(dname, unitid, tags, addrlist, polls)
    for fc, addrinfo in pairs(addrlist) do
        local maxnumber = maxnumber(fc)
        local list = addrinfo.list
        local start = false
        local index
        local number
        local interval
        local function make()
            local poll = make_poll(dname, unitid, fc, start, number, interval, index)
            tblins(polls, poll)
        end
        local function init(addr, tag)
            start = addr
            number = tag.number
            interval = tag.poll
            index = { [1] = { tag = tag } }
        end
        for a = addrinfo.min, addrinfo.max do
            local t = tags[list[a]]
            if t then
                if not start then
                    init(a, t)
                else
                    if number + t.number <= maxnumber then
                        index[number+1] = { tag = t }
                        number = number + t.number
                        if t.poll < interval then
                            interval = t.poll
                        end
                    else
                        make()
                        init(a, t)
                    end
                end
            else
                if list[a] == nil then
                    if start then
                        make()
                        start = false
                    end
                end
            end
        end
        make()
    end
end

local function validate_tag(name, tag)
    if type(name) ~= "string" or type(tag) ~= "table" or
        not math.tointeger(tag.addr) or
        (tag.mode ~= "ts" and tag.mode ~= "attr" and tag.mode ~= "ctrl") or
        (tag.cov ~= nil and type(tag.cov) ~= "boolean") or
        (tag.le ~= nil and type(tag.le) ~= "boolean") or
        (tag.poll ~= nil and not math.tointeger(tag.poll)) or
        (tag.poll and tag.poll < poll_min or tag.poll > poll_max) then
        error(text.invalid_tag_conf)
    end
end

local function validate_poll_addr(tname, fc, addr, number, addrlist)
    -- number to be validated in modbus.data
    assert(addr >= MODBUS_ADDR_MIN and addr <= MODBUS_ADDR_MAX, text.invalid_addr_conf)
    if not addrlist[fc] then
        addrlist[fc] = { list = {} }
    end
    local addrs = addrlist[fc].list
    local min = MODBUS_ADDR_MAX
    local max = MODBUS_ADDR_MIN
    for a = addr, addr+number-1 do
        assert(addrs[a] == nil, ext.invalid_addr_conf)
        if a == addr then
            addrs[a] = tname
            if a < min then
                addrlist[fc].min = a
            end
            if a > max then
                addrlist[fc].max = a
            end
        else
            addrs[a] = true
        end
    end
end

local function validate_write_addr(tname, fc, addr, number, addrlist)
    -- number to be validated in modbus.data
    assert(addr >= MODBUS_ADDR_MIN and addr <= MODBUS_ADDR_MAX, text.invalid_addr_conf)
    if not addrlist[fc] then
        addrlist[fc] = {}
    end
    local addrs = addrlist[fc]
    for a = addr, addr+number-1 do
        assert(addrs[a] == nil, ext.invalid_addr_conf)
        if a == addr then
            addrs[a] = tname
        else
            addrs[a] = true
        end
    end
end

local function validate_addr(polllist, writelist, tags)
    for fc, list in pairs(writelist) do
        if polllist[fc] then
            local poll = polllist[fc].list
            for a, name in pairs(list) do
                if type(poll[a]) == "string" then
                    assert(type(name) == "string", text.invalid_addr_conf)
                    local pt = tags[poll[a]]
                    local wt = tags[name]
                    assert(pt.number == wt.number and
                        pt.dt == wt.dt and
                        pt.le == wt.le and
                        pt.bit == wt.bit, text.invalid_addr_conf)
                end
            end
        end
    end
end

local fc_map = {
    [5] = 1,
    [15] = 1,
    [6] = 3,
    [16] = 3
}

local function validate_tags(tags, dle, ts_poll, attr_poll, tle)
    local polllist = {}
    local writelist = {}
    local max_poll = attr_poll > ts_poll and attr_poll or ts_poll
    for name, t in pairs(tags) do
        validate_tag(name, t)
        if t.mode == "ts" or t.mode == "attr" then
            validate_poll_addr(name, t.fc, t.addr, t.number, polllist)
            if t.le == nil then
                t.le = dle
            end
            if t.poll == nil then
                if t.mode == "ts" then
                    t.poll = ts_poll
                else
                    t.poll = attr_poll
                end
            elseif ts.poll > max_poll then
                max_poll = ts.poll
            end
            t.unpack = mdata.unpack(t.fc, t.dt, t.number, tle, t.le, t.bit)
            t.read = cli_pack(t.fc, t.addr, t.number)
            t.name = name
            t.poll_cum = 0
        else
            t.wfc = t.fc
            t.fc = assert(fc_map[t.fc], text.invalid_fc_conf)
            validate_write_addr(name, t.fc, t.addr, t.number, writelist)
            if t.le == nil then
                t.le = dle
            end
            t.unpack = mdata.unpack(t.fc, t.dt, t.number, tle, t.le, t.bit)
            local pack = mdata.pack(t.wfc, t.dt, t.number, tle, t.le, t.bit)
            t.read = cli_pack(t.fc, t.addr, t.number)
            t.write = function(val)
                local v = pack(val)
                return cli_pack(t.wfc, t.addr, v)
            end
        end
    end
    validate_addr(polllist, writelist, tags)
    return polllist, max_poll
end

local function validate_device(name, dev)
    if type(name) ~= "string" or type(dev) ~= "table" or
        not math.tointeger(dev.unitid) or
        dev.unitid < MODBUS_SLAVE_MIN or
        dev.unitid > MODBUS_SLAVE_MAX or
        not math.tointeger(dev.attr_poll) or
        dev.attr_poll < poll_min or
        dev.attr_poll > poll_max or
        not math.tointeger(dev.ts_poll) or
        dev.ts_poll < poll_min or
        dev.ts_poll > poll_max or
        type(dev.le) ~= "boolean" or
        (dev.batch ~= nil and not math.tointeger(dev.batch) or
        (dev.batch and dev.batch > batch_max)) then
        error(text.invalid_device_conf)
    end
end

local function validate_devices(d, tle)
    local polls = {}
    local max = 0
    for name, dev in pairs(d) do
        validate_device(name, dev)
        local addrlist, max_poll = validate_tags(dev.tags, dev.le, dev.ts_poll, dev.attr_poll, tle)
        if max_poll > max then
            max = max_poll
        end
        make_polls(name, dev.unitid, dev.tags, addrlist, polls)
    end
    return polls, max
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
        skynet.sleep(max_wait)
    end
end

local function config_devices(d, tle)
    local ok, polls, max = pcall(validate_devices, d, tle)
    if ok then
        stop()
        max_wait = max // 10
        -- wait for mqtt up
        skynet.sleep(500)
        regdev(d)
        running = true
        math.randomseed(skynet.time())

        log.error(strfmt("%s: total(%d), max interval(%d s)",
                text.poll_start, #polls, max // 1000))
        for _, p in ipairs(polls) do
            local ok, err = pcall(p)
            if not ok then
                log.error(err)
            end
            skynet.sleep(math.random(100, 500))
        end
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
