sys = {
    id = 'SYS_ID',
    version = 'SYS_VERSION',
    platform = 'SYS_PLAT',
    config = 'SYS_CONFIG',
    cluster = 30002
}
auth = {
    username = 'USERNAME',
    password = 'PASSWORD',
}
gateway = {
    flowcontrol = false,
    audit = false
}
gateway_console = true
gateway_ws = true
gateway_mqtt = {
    tpl = "gateway_mqtt_tb",
    id = 'MQTT_ID',
    uri = 'MQTT_URI',
    username = 'MQTT_USERNAME',
    password = 'MQTT_PASSWORD',
    topic = {
        connect = {
            qos = 1,
            txt = 'v1/trina/gateway/connect'
        },
        disconnect = {
            qos = 1,
            txt = 'v1/trina/gateway/disconnect'
        },
        rpc = {
            qos = 1,
            txt = 'v1/trina/gateway/rpc'
        },
        telemetry = {
            qos = 1,
            txt = 'v1/trina/gateway/telemetry'
        },
        attributes = {
            qos = 1,
            txt = 'v1/trina/gateway/attributes'
        },
    },
    version = 'v3.1.1',
    clean = true,
    secure = false,
    keep_alive = 60,
    seri = 'json',
    cocurrency = 5
}
