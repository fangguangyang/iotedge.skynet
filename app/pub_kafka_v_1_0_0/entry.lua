local seri = require "seri"
local log = require "log"
local producer = require "kafka.producer"
local text = require("text").kafka

local p
local log_prefix = ""

function on_conf(conf)
    log_prefix = "Kafka client "..conf.producer.id.."("..conf.producer.topic..")"
    local seri_map = {
        json = seri.JSON,
        msgpack = seri.MSGPACK
    }
    seri.init(seri_map[conf.seri])
    p = producer.new(conf.broker, conf.producer)
    p.client:fetch_metadata(conf.producer.topic)
end

function on_data(dev, data)
    if type(dev) ~= "string" or type(data) ~= "table" then
        log.error(log_prefix, "kafka publish failed")
        return
    end
    local payload = seri.pack({[dev] = data})
    if not payload then
        log.error(log_prefix, "kafka publish failed", text.pack_fail)
        return
    end
    p:send(conf.producer.topic, nil, payload)
end
