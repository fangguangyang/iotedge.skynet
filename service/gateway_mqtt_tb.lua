local skynet = require "skynet"
local log = require "log"
local seri = require "seri"
local mqtt = require "mqtt"
local text = require("text").mqtt

local sysmgr_addr, gateway_addr = ...

local client
local running = true

local publish_retry_timeout = 200
local publish_max_retry_timeout = 3000
local subsribe_retry_timeout = 200
local subsribe_ack_err_code = 128

local sys_uri = ""
local sys_name = ""
local sys_app = ""
local log_prefix = ""
local cocurrency = 1
local keepalive_timeout = 6000
local telemetry_topic = ""
local telemetry_qos = 1
local rpc_topic = ""
local rpc_qos = 1
local attributes_topic = ""
local attributes_qos = 1
local connect_topic = ""
local connect_qos = 1
local disconnect_topic = ""
local disconnect_qos = 1

local forked = 0
local function busy()
    if forked < cocurrency then
        forked = forked + 1
        return false
    else
        return true
    end
end
local function done()
    forked = forked - 1
end

local function ensure_publish(cli, msg)
    local done = false
    local first = true
    math.randomseed(skynet.time())
    local function puback(ack)
        done = true
        log.info(log_prefix, "published to", msg.topic, "QoS", msg.qos)
    end
    local function do_publish()
        if cli.connection then
            if not done then
                local dup = true
                if first then
                    first = false
                    dup = false
                end
                cli:publish {
                    topic = msg.topic,
                    qos = msg.qos,
                    payload = msg.payload,
                    callback = puback,
                    dup = dup,
                    retain = false
                }
                skynet.timeout(publish_retry_timeout, do_publish)
            end
        else
            skynet.timeout(
            math.random(publish_retry_timeout, publish_max_retry_timeout),
            do_publish)
        end
    end
    do_publish()
end

local function ensure_subscribe(cli, topic, qos)
    local done = false
    local function suback(ack)
        if ack.rc[1] ~= subsribe_ack_err_code then
            -- Strictly rc[1] >= qos
            done = true
            log.error(log_prefix, "subscribed to", topic, "QoS", qos)
        else
            log.error(log_prefix, "subscribed to", topic, "failed")
        end
    end
    local function do_subscribe()
        if not done and cli.connection then
            cli:subscribe { topic=topic, qos=qos, callback=suback }
            skynet.timeout(subsribe_retry_timeout, do_subscribe)
        end
    end
    do_subscribe()
end

local function handle_connect(connack, cli)
    if connack.rc ~= 0 then
        return
    end
    log.error(log_prefix, "connected")
    ensure_subscribe(cli, rpc_topic, rpc_qos)

    local info = {
        conf = { uri = sys_uri, id = sys_name },
        app = sys_app
    }
    skynet.call(gateway_addr, "lua", "sys", "mqttapp", info)

    local check_timeout = keepalive_timeout+100
    local function ping()
        if cli.connection then
            if skynet.now()-cli.comm_time >= keepalive_timeout then
                cli:send_pingreq()
            end
            skynet.timeout(check_timeout, ping)
        end
    end
    skynet.timeout(check_timeout, ping)
end

local function handle_error(err)
    log.error(log_prefix, "err:", err)
end

local function handle_close(conn)
    log.error(log_prefix, "closed:", conn.close_reason)
end

--[[
msg = {
    type=ptype,
    dup=dup,
    qos=qos,
    retain=retain,
    packet_id=packet_id,
    topic=topic,
    payload=payload
    }
payload = {"device":"Device A",
           "data":{
             "id":$request_id,
             "method":"toggle_gpio",
             "params":{"pin":1}
             }}
--]]
local function decode_request(msg)
    if msg.topic ~= rpc_topic then
        log.error(log_prefix, text.invalid_req, msg.topic)
        return false
    end
    if msg.dup then
        log.error(log_prefix, text.dup_req, msg.topic)
        return false
    end
    local request = seri.unpack(msg.payload)
    if type(request) ~= "table" then
        log.error(log_prefix, text.unpack_fail)
        return false
    end
    if type(request.device) ~= "string" then
        log.error(log_prefix, text.unknown_dev)
        return false
    end
    if type(request.data) == "table" then
        local data = request.data
        if data.id and data.method and data.params then
            return  request.device, data.method, data.params, data.id
        else
            log.error(log_prefix, text.invalid_req)
            return false
        end
    else
        log.error(log_prefix, text.invalid_req)
        return false
    end
end

--[[
payload = {"device":"Device A",
           "id": $request_id,
           "data":{"success": true}
           }
--]]
local function do_respond(cli, dev, ret, session)
    local response = {
        device = dev,
        id = session,
        data = ret
    }
    local payload = seri.pack(response)
    if not payload then
        log.error(log_prefix, text.pack_fail)
        return
    end
    local msg = {}
    msg.topic = rpc_topic
    msg.qos = rpc_qos
    msg.payload = payload
    ensure_publish(cli, msg)
end

local function handle_request(msg, cli)
    cli:acknowledge(msg)
    if busy() then
        log.error("gateway_mqtt busy")
    else
        skynet.fork(function()
            local dev, cmd, arg, session = decode_request(msg)
            if dev then
                local ok, ret = pcall(skynet.call, gateway_addr, "lua", dev, cmd, arg)
                if not ok then
                    log.error("call gateway failed:", dev, cmd)
                end
                do_respond(cli, dev, ret, session)
            end
            done()
        end)
    end
end

local command = {}

function command.stop()
    running = false
    local ok, err = client:disconnect()
    if not ok then
        log.error(log_prefix, "stop failed", err)
    end
end

function command.route_add(s, t)
    -- do nothing
end

function command.route_del(s, t)
    -- do nothing
end

function command.data(dev, data)
    if type(dev) ~= "string" or type(data) ~= "table" then
        log.error(log_prefix, "telemetry publish failed")
        return
    end
    local payload = seri.pack({[dev] = data})
    if not payload then
        log.error(log_prefix, "telemetry publish failed", text.pack_fail)
        return
    end
    local msg = {}
    msg.topic = telemetry_topic
    msg.qos = telemetry_qos
    msg.payload = payload
    ensure_publish(client, msg)
end

local post_map = {
    online = function(dev)
        if type(dev) ~= "string" then
            log.error(log_prefix, "online publish failed")
            return
        end
        local payload = seri.pack({device = dev})
        if not payload then
            log.error(log_prefix, "online publish failed", text.pack_fail)
            return
        end
        local msg = {}
        msg.topic = connect_topic
        msg.qos = connect_qos
        msg.payload = payload
        ensure_publish(client, msg)
    end,
    offline = function(dev)
        if type(dev) ~= "string" then
            log.error(log_prefix, "offline publish failed")
            return
        end
        local payload = seri.pack({device = dev})
        if not payload then
            log.error(log_prefix, "offline publish failed", text.pack_fail)
            return
        end
        local msg = {}
        msg.topic = disconnect_topic
        msg.qos = disconnect_qos
        msg.payload = payload
        ensure_publish(client, msg)
    end,
    attributes = function(dev, attr)
        if type(dev) ~= "string" or type(attr) ~= "table" then
            log.error(log_prefix, "attributes publish failed")
            return
        end
        local payload = seri.pack({[dev] = attr})
        if not payload then
            log.error(log_prefix, "attributes publish failed", text.pack_fail)
            return
        end
        local msg = {}
        msg.topic = attributes_topic
        msg.qos = attributes_qos
        msg.payload = payload
        ensure_publish(client, msg)
    end
}

function command.post(k, ...)
    local f = post_map[k]
    if f then
        f(...)
    else
        log.error(log_prefix, text.invalid_post)
    end
end

local function init()
    local conf = skynet.call(sysmgr_addr, "lua", "get", "gateway_mqtt")
    if not conf then
        log.error(text.no_conf)
    else
        sys_uri = conf.uri
        sys_name = conf.username
        sys_app = conf.tpl
        log_prefix = "MQTT client "..conf.id.."("..conf.uri..")"
        cocurrency = conf.cocurrency
        keepalive_timeout = conf.keep_alive*100
        telemetry_topic = conf.topic.telemetry.txt
        telemetry_qos = conf.topic.telemetry.qos
        rpc_topic = conf.topic.rpc.txt
        rpc_qos = conf.topic.rpc.qos
        attributes_topic = conf.topic.attributes.txt
        attributes_qos = conf.topic.attributes.qos
        connect_topic = conf.topic.connect.txt
        connect_qos = conf.topic.connect.qos
        disconnect_topic = conf.topic.disconnect.txt
        disconnect_qos = conf.topic.disconnect.qos

        local seri_map = {
            json = seri.JSON,
            msgpack = seri.MSGPACK
        }
        seri.init(seri_map[conf.seri])

        local version_map = {
            ["v3.1.1"] = mqtt.v311,
            ["v5.0"] = mqtt.v50
        }
        client = mqtt.client {
            uri = conf.uri,
            id = conf.id,
            username = conf.username,
            password = conf.password,
            clean = conf.clean,
            secure = conf.secure,
            keep_alive = conf.keep_alive,
            version = version_map[conf.version]
        }
        local mqtt_callback = {
            connect = handle_connect,
            message = handle_request,
            error = handle_error,
            close = handle_close
        }
        client:on(mqtt_callback)

        skynet.fork(function()
            while true do
                if client.connection then
                    client:iteration()
                elseif running then
                    skynet.sleep(100)
                    client:start_connecting()
                else
                    skynet.sleep(500)
                end
            end
        end)

        skynet.dispatch("lua", function(_, _, cmd, ...)
            local f = command[cmd]
            if f then
                f(...)
            end
        end)
    end
end

skynet.start(init)
