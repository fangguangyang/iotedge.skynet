#!/bin/sh
set -e

CONFIG=$1
NAME=$2
TOKEN=$3
URI=$4

if [ ! -f ${CONFIG} ]; then
    echo "${CONFIG} does not exist"
    exit 1
fi

REVPLAT=$(cat PLATFORM)
REV=${REVPLAT%-*}
PLAT=${REVPLAT#*-}

if [ ${CONFIG} = "config.tb.lua" ]; then
    if [ -z "${NAME}" ] || [ -z "${TOKEN}" ] || [ -z "${URI}" ]; then
        echo "$0 <config> <name> <token> <uri>"
        exit 1
    fi
    sed -i "s|SYS_ID|${NAME}|; \
            s|SYS_VERSION|${REV}|; \
            s|SYS_PLAT|${PLAT}|; \
            s|SYS_CONFIG|${CONFIG}|; \
            s|MQTT_ID|${NAME}|; \
            s|MQTT_USERNAME|${NAME}|; \
            s|MQTT_PASSWORD|${TOKEN}|; \
            s|MQTT_URI|${URI}|" ${CONFIG}
elif [ ${CONFIG} = "config.local.lua" ]; then
    sed -i "s|SYS_VERSION|${REV}|; \
            s|SYS_PLAT|${PLAT}|; \
            s|SYS_CONFIG|${CONFIG}|" ${CONFIG}
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
