local log = require "log"
local text = require("text").modbus
local api = require "api"
local client = require "modbus.client"
local pdu = require "modbus.pdu"
local basexx = require "utils.basexx"
local skynet = require "skynet"

local cli
local pack

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
    local p = pack(1, arg.addr, arg.number)
    return cli:request(arg.slave, p)
end

function read_input(arg)
    local p = pack(2, arg.addr, arg.number)
    return cli:request(arg.slave, p)
end

function read_holding_register(arg)
    local p = pack(3, arg.addr, arg.number)
    return cli:request(arg.slave, p)
end

function read_input_register(arg)
    local p = pack(4, arg.addr, arg.number)
    return cli:request(arg.slave, p)
end

function write_coin(arg)
    local p
    if type(arg.value) == "table" then
        p = pack(15, arg.addr, arg.value)
    else
        p = pack(5, arg.addr, arg.value)
    end
    return cli:request(arg.slave, p)
end

function write_register(arg)
    local p
    if type(arg.value) == "table" then
        p = pack(16, arg.addr, arg.value)
    else
        p = pack(6, arg.addr, arg.value)
    end
    return cli:request(arg.slave, p)
end

function on_conf(conf)
    reg_cmd()
    local mode = conf.mode
    local arg
    if conf.le then
        pack = pdu.pack_le
    else
        pack = pdu.pack_be
    end
    if mode == 'rtu' then
        arg = conf.rtu
        arg.ascii = conf.ascii
        arg.le = conf.le
        arg.timeout = conf.timeout
        cli = client.new_rtu(arg)
    elseif mode == 'rtu_tcp' then
        arg = conf.tcp
        arg.ascii = conf.ascii
        arg.le = conf.le
        arg.timeout = conf.timeout
        cli = client.new_rtu_tcp(arg)
    elseif mode == 'tcp' then
        arg = conf.tcp
        arg.le = conf.le
        arg.timeout = conf.timeout
        cli = client.new_tcp(arg)
    else
        log.error(text.conf_fail)
    end
end
