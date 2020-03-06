local skynet = require "skynet"
local log = require "log"
local seri = require "seri"
local mqtt = require "mqtt"
local text = require("text").mqtt

local publish_retry_timeout = 200
local publish_max_retry_timeout = 3000
local subsribe_retry_timeout = 200
local subsribe_ack_err_code = 128

local client
local running = true
local log_prefix = ""
local keepalive_timeout = 6000
local telemetry_topic = ""
local telemetry_qos = 1

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

local function handle_connect(connack, cli)
    if connack.rc ~= 0 then
        return
    end
    log.error(log_prefix, "connected")
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

function on_conf(conf)
    log_prefix = "MQTT client "..conf.id.."("..conf.uri..")"
    keepalive_timeout = conf.keep_alive*100
    telemetry_topic = conf.topic.telemetry.txt
    telemetry_qos = conf.topic.telemetry.qos

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
        while running do
            if client.connection then
                client:iteration()
            else
                skynet.sleep(100)
                client:start_connecting()
            end
        end
    end)
end

function on_data(dev, data)
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

function on_exit()
    running = false
    client:close_connection(text.client_closed)
end
