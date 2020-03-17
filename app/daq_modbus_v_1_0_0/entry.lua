local skynet = require "skynet"
local log = require "log"
local text = require("text").modbus
local api = require "api"
local validate = require "utils.validate"
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
            assert(devlist[dev], text.invalid_dev)
            assert(devlist[dev].tags[tag], text.invalid_tag)
            local u = devlist[dev].unitid
            local t = devlist[dev].tags[tag]

            -- all tag can be read, no check here
            local ok, err = cli:request(u, t.read)
            assert(ok, strfmt("%s:%s", text.req_fail, err))

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
            assert(devlist[dev], text.invalid_dev)
            assert(type(arg) == "table" and
                type(arg[1]) == "string" and
                (type(arg[2]) == "number" or
                 type(arg[2]) == "boolean" or
                 type(arg[2]) == "string"), text.invalid_arg)
            assert(devlist[dev].tags[arg[1]], text.invalid_tag)
            local u = devlist[dev].unitid
            local t = devlist[dev].tags[arg[1]]

            assert(t.write, text.read_only)
            local val = arg[2]
            local ok = pcall(t.write, val)
            assert(ok, text.pack_fail)

            local ok, err = cli:request(u, p)
            assert(ok, strfmt("%s:%s", text.req_fail, err))
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
    for _, t in pairs(index) do
        if t.cov then
            if t.gain then
                t.val = t.val * t.gain + t.offset
            end
            api.post_cov(dname, { [t.name] = t.val })
        else
            if t.poll_cum + interval >= t.poll then
                t.poll_cum = 0
                if t.gain then
                    t.val = t.val * t.gain + t.offset
                end
                if t.mode == "ts" then
                    tblins(ts, { [t.name] = t.val })
                else
                    tblins(attr, { [t.name] = t.val })
                end
            else
                t.poll_cum = t.poll_cum + interval
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
        local ok, err = cli:request(unitid, p)
        assert(ok, strfmt("%s %s:%s", log_prefix, text.req_fail, err))
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
            local v = t.unpack(i, data)
            t.val = v
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

local function make_polls(dname, unitid, addrlist, polls)
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
        local function init(addr, t)
            start = addr
            number = t.number
            interval = t.poll
            index = { [1] = t }
        end
        for a = addrinfo.min, addrinfo.max do
            local t = list[a]
            if type(t) == "table" then
                if not start then
                    init(a, t)
                else
                    if number + t.number <= maxnumber then
                        index[number+1] = t
                        number = number + t.number
                        if t.poll < interval then
                            interval = t.poll
                        end
                    else
                        make()
                        init(a, t)
                    end
                end
            elseif t == nil then
                if start then
                    make()
                    start = false
                end
            end
        end
        make()
    end
end

local function validate_poll_addr(t, addrlist)
    if not addrlist[t.fc] then
        addrlist[t.fc] = { list = {} }
    end
    local addr = addrlist[t.fc]
    local list = addr.list
    local min = MODBUS_ADDR_MAX
    local max = MODBUS_ADDR_MIN
    for a = t.addr, t.addr+t.number-1 do
        assert(not list[a], text.invalid_addr_conf)
        if a == t.addr then
            list[a] = t
            if a <= min then
                addr.min = a
            end
            if a >= max then
                addr.max = a
            end
        else
            list[a] = true
        end
    end
end

local function validate_write_addr(t, addrlist)
    if not addrlist[t.fc] then
        addrlist[t.fc] = {}
    end
    local list = addrlist[t.fc]
    for a = t.addr, t.addr+t.number-1 do
        assert(not list[a], text.invalid_addr_conf)
        if a == t.addr then
            list[a] = t
        else
            list[a] = true
        end
    end
end

local function validate_addr(polllist, writelist)
    for fc, list in pairs(writelist) do
        if polllist[fc] then
            local poll = polllist[fc].list
            for a, t in pairs(list) do
                if type(poll[a]) == "table" then
                    local pt = poll[a]
                    assert(pt.number == t.number and
                        pt.dt == t.dt and
                        pt.le == t.le and
                        pt.bit == t.bit,
                        text.invalid_addr_conf)
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

local tag_schema = {
    fc = function(v)
        return v==1 or v==2 or v==3 or v==4 or v==5 or v==15 or v==6 or v==16
    end,
    addr = function(v)
        return math.tointeger(v) and v>=MODBUS_ADDR_MIN and v<=MODBUS_ADDR_MAX
    end,
    number = function(v)
        return math.tointeger(v) and v>0
    end,
    mode = function(v)
        return v=="ts" or v=="attr" or v=="ctrl"
    end,
    cov  = function(v)
        return v==nil or type(v)=="boolean"
    end,
    le = function(v)
        return v==nil or type(v)=="boolean"
    end,
    poll = function(v)
        return v==nil or (math.tointeger(v) and v>=poll_min and v<=poll_max)
    end,
    gain = function(v)
        return v==nil or type(v)=="number"
    end,
    offset = function(v)
        return v==nil or type(v)=="number"
    end
}

local function fill_tag(t, name, dev)
    t.name = name
    if t.le == nil then
        t.le = dev.le
    end
    if t.mode == "ts" then
        t.poll_cum = 0
        t.poll = t.poll or dev.ts_poll
    elseif t.mode == "attr" then
        t.poll_cum = 0
        t.poll = t.poll or dev.attr_poll
    end
end

local function validate_tags(dev, tle)
    local polllist = {}
    local writelist = {}
    local max_poll = 0

    for name, t in pairs(dev.tags) do
        assert(type(name)=="string", text.invalid_tag_conf)
        local ok = pcall(validate, t, tag_schema)
        assert(ok, text.invalid_tag_conf)

        fill_tag(t, name, dev)
        t.read = cli_pack(t.fc, t.addr, t.number)
        t.unpack = mdata.unpack(t.fc, t.dt, t.number, tle, t.le, t.bit)

        if t.mode == "ctrl" then
            t.wfc = t.fc
            t.fc = assert(fc_map[t.fc], text.invalid_fc_conf)
            validate_write_addr(t, writelist)

            local pack = mdata.pack(t.wfc, t.dt, t.number, tle, t.le, t.bit)
            t.write = function(val)
                local v = pack(val)
                return cli_pack(t.wfc, t.addr, v)
            end
        else
            validate_poll_addr(t, polllist)
            if t.poll > max_poll then
                max_poll = t.poll
            end
        end
    end
    validate_addr(polllist, writelist)
    return polllist, max_poll
end

local d_schema = {
    unitid = function(v)
        return math.tointeger(v) and v>=MODBUS_SLAVE_MIN and v<=MODBUS_SLAVE_MAX
    end,
    attr_poll = function(v)
        return math.tointeger(v) and v>=poll_min and v<=poll_max
    end,
    ts_poll = function(v)
        return math.tointeger(v) and v>=poll_min and v<=poll_max
    end,
    le = function(v)
        return type(v)=="boolean"
    end,
    batch = function(v)
        return v==nil or (math.tointeger(v) and v<=batch_max)
    end
}

local function validate_devices(d, tle)
    local polls = {}
    local max = 0
    for name, dev in pairs(d) do
        assert(type(name)=="string", text.invalid_device_conf)
        local ok = pcall(validate, dev, d_schema)
        assert(ok, text.invalid_device_conf)

        local addrlist, max_poll = validate_tags(dev, tle)
        if max_poll > max then
            max = max_poll
        end
        make_polls(name, dev.unitid, addrlist, polls)
    end
    return polls, max
end

local function unregdev()
    for name, _ in pairs(devlist) do
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
    if cli then
        cli.channel:close()
    end
    if running then
        log.error(text.poll_stop)
        running = false
        unregdev()
        skynet.sleep(max_wait)
    end
end

local function config_devices(d, tle)
    local ok, polls, max = pcall(validate_devices, d, tle)
    if ok then
        math.randomseed(skynet.time())
        max_wait = max // 10
        -- wait for mqtt up
        skynet.sleep(500)
        regdev(d)
        running = true

        for _, p in pairs(polls) do
            local ok, err = pcall(p)
            if not ok then
                log.error(err)
            end
            skynet.sleep(math.random(100, 200))
        end
        log.error(strfmt("%s: total(%d), max interval(%d s)",
                text.poll_start, #polls, max // 1000))
        return ok
    else
        return ok, polls
    end
end

local t_schema = {
    mode = function(v)
        return v=="rtu" or v=="rtu_tcp" or v=="tcp"
    end,
    ascii = function(v)
        return v==nil or type(v)=="boolean"
    end,
    le = function(v)
        return type(v)=="boolean"
    end,
    timeout = function(v)
        return math.tointeger(v) and v>poll_min
    end,
    tcp = {
        host = function(v)
            return type(v)=="string" and v:match("^[%w%.%-]+$")
        end,
        port = function(v)
            return math.tointeger(v) and v>0 and v<0xFF
        end
    },
    rtu = {
        port = function(v)
            return type(v)=="string"
        end,
        baudrate = function(v)
            return math.tointeger(v) and v>0
        end,
        mode = function(v)
            return v=="rs232" or v=="rs485"
        end,
        databits = function(v)
            return math.tointeger(v) and v>0
        end,
        parity = function(v)
            return v=="none" or v=="odd" or v=="even"
        end,
        stopbits = function(v)
            return math.tointeger(v) and v>=0
        end,
        rtscts = function(v)
            return type(v)=="boolean"
        end,
        r_timeout = function(v)
            return math.tointeger(v) and v>0
        end,
        b_timeout = function(v)
            return math.tointeger(v) and v>0
        end
    }
}

local function config_transport(t)
    local ok = pcall(validate, t, t_schema)
    if not ok then
        return false
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
        return true
    end
end

function on_conf(conf)
    if config_transport(conf.transport) then
        local ok, err = config_devices(conf.devices, conf.transport.le)
        if ok then
            if not registered then
                reg_cmd()
                registered = true
            end
            return ok
        else
            return ok, err
        end
    else
        return false, text.invalid_transport_conf
    end
end

function on_exit()
    stop()
end
