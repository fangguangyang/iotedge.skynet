#!/bin/sh
set -e

CONFIG=$1
CLUSTER=$2
NAME=$3
TOKEN=$4
URI=$5

if [ ! -f ${CONFIG} ]; then
    echo "${CONFIG} does not exist"
    exit 1
fi

REVPLAT=$(cat PLATFORM)
REV=${REVPLAT%-*}
PLAT=${REVPLAT#*-}

if [ ${CONFIG} = "config.tb.lua" ]; then
    sed -i "s|SYS_ID|${NAME}|; \
            s|SYS_VERSION|${REV}|; \
            s|SYS_PLAT|${PLAT}|; \
            s|SYS_CONFIG|${CONFIG}|; \
            s|30002|${CLUSTER}|; \
            s|MQTT_ID|${NAME}|; \
            s|MQTT_USERNAME|${NAME}|; \
            s|MQTT_PASSWORD|${TOKEN}|; \
            s|MQTT_URI|${URI}|" ${CONFIG}
elif [ ${CONFIG} = "config.local.lua" ]; then
    sed -i "s|SYS_VERSION|${REV}|; \
            s|SYS_PLAT|${PLAT}|; \
            s|SYS_CONFIG|${CONFIG}|; \
            s|30002|${CLUSTER}|" ${CONFIG}
fi

sed -i "s|config.lua|${CONFIG}|" skynet.config.prod

UNIT=iotedge-${REV}.service
UNIT_TPL=./scripts/iotedge.service
UNIT_FILE=/etc/systemd/system/${UNIT}
cp -f ${UNIT_TPL} ${UNIT_FILE}

sed -i "s|WORKING_DIR|${PWD}|g" ${UNIT_FILE}

systemctl daemon-reload
#systemctl enable ${UNIT}
systemctl start ${UNIT}
