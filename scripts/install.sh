#!/bin/sh
set -e

CONFIG=$1
NAME=$2
TOKEN=$3
URI=$4
CLUSTER=$5

if [ -z "${CONFIG}" ] || [ -z "${NAME}" ] || [ -z "${TOKEN}" ]; then
    echo "$0 <config> <name> <token>"
    exit 1
fi

if [ ! -f ${CONFIG} ]; then
    echo "${CONFIG} does not exist"
    exit 1
fi

REV=$(cat VERSION)
PLAT=$(ls build)
if [ -z "${CLUSTER}" ]; then
    CLUSTER=30002
fi

if [ ${CONFIG} = "config.tb.lua" ]; then
    if [ -z "${URI}" ]; then
        echo "$0 <config> <name> <token> <uri>"
        exit 1
    fi
    sed -i "s|SYS_ID|${NAME}|; \
            s|SYS_VERSION|${REV}|; \
            s|SYS_PLAT|${PLAT}|; \
            s|SYS_CONFIG|${CONFIG}|; \
            s|30002|${CLUSTER}|; \
            s|USERNAME|${NAME}|; \
            s|PASSWORD|${TOKEN}|; \
            s|MQTT_ID|${NAME}|; \
            s|MQTT_URI|${URI}|" ${CONFIG}
elif [ ${CONFIG} = "config.local.lua" ]; then
    sed -i "s|SYS_ID|${NAME}|; \
            s|SYS_VERSION|${REV}|; \
            s|SYS_PLAT|${PLAT}|; \
            s|SYS_CONFIG|${CONFIG}|; \
            s|30002|${CLUSTER}|; \
            s|USERNAME|${NAME}|; \
            s|PASSWORD|${TOKEN}|" ${CONFIG}
fi

sed -i "s|config.lua|${CONFIG}|" ./build/${PLAT}/skynet.config.prod

UNIT=iotedge-${REV}.service
UNIT_TPL=./scripts/iotedge.service
UNIT_FILE=/etc/systemd/system/${UNIT}
cp -f ${UNIT_TPL} ${UNIT_FILE}

sed -i "s|WORKING_DIR|${PWD}|g; s|PLAT|${PLAT}|g" ${UNIT_FILE}

systemctl daemon-reload
#systemctl enable ${UNIT}
systemctl start ${UNIT}
