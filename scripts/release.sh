#!/bin/sh
set -e

RELEASE_DIR=release
mkdir -p ${RELEASE_DIR}
LUAC=skynet/3rd/lua/luac

PLAT=$1
REPO=$2

upload() {
    if [ -n "${REPO}" ]; then
        DIR=$1
        TARBALL=$2
        ssh -oStrictHostKeyChecking=no ${REPO%:*} "mkdir -p ${REPO#*:}/${DIR}"
        scp -oStrictHostKeyChecking=no -q ${TARBALL} ${REPO}/${DIR}/
        echo "${TARBALL} uploaded to ${REPO}/${DIR}"
        rm -f ${TARBALL}
    fi
}

compile() {
    for DIR in $@; do
        for FD in ${DIR}/*; do
            if [ -d ${FD} ]; then
                compile ${FD}
            else
                if [ ${FD##*.} = "lua" ]; then
                    ${LUAC} -o ${FD%.lua}.luac ${FD}
                fi
            fi
        done
    done
}

if [ -n "${PLAT}" ]; then
    if [ ${PLAT} = "arm_v7" ] || [ ${PLAT} = "x86_64" ]; then
        REV=$(git rev-parse HEAD | cut -c1-5)
        INFO=PLATFORM
        echo -n ${REV}-${PLAT} > ${INFO}

        LUADIRS="lualib skynet/lualib service skynet/service"
        compile ${LUADIRS}

        BUILD_PATH=bin
        TARBALL=${RELEASE_DIR}/${REV}-${PLAT}.tar.gz
        DIRS="${INFO} ${BUILD_PATH} config.*.lua scripts skynet.config*"
        EXCLUDES="--exclude=${BUILD_PATH}/gate.so \
                  --exclude=${BUILD_PATH}/sproto.so \
                  --exclude=${BUILD_PATH}/client.so \
                  --exclude=${BUILD_PATH}/prebuilt/lib* \
                  --exclude=lualib/*.lua \
                  --exclude=skynet/lualib/*.lua \
                  --exclude=service/*.lua \
                  --exclude=skynet/service/*.lua"

        tar --transform "s|^|iotedge-${REV}/|" ${EXCLUDES} -czf ${TARBALL} ${DIRS} ${LUADIRS}
        find . -name "*.luac" |xargs rm -f
        rm -f ${INFO}

        echo "${TARBALL} created"
        upload iotedge ${TARBALL}

        for APP in app/*; do
            compile ${APP}

            BASE=$(basename ${APP})
            TARBALL=${RELEASE_DIR}/v_${BASE#*_v_}-${PLAT}.tar.gz
            EXCLUDES="--exclude=*.lua"
            tar --transform "s|^${APP}|${BASE}-${REV}|" ${EXCLUDES} -czf ${TARBALL} ${APP}
            find . -name "*.luac" |xargs rm -f

            echo "${TARBALL} created"
            upload ${BASE%_v_*} ${TARBALL}
        done
    else
        echo "$0 x86_64/arm_v7 repo"
    fi
else
    echo "$0 x86_64/arm_v7 repo"
fi
