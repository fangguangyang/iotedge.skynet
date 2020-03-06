#!/bin/sh
set -e

RELEASE_DIR=release
mkdir -p ${RELEASE_DIR}
LUAC=skynet/3rd/lua/luac

TYPE=$1
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
        for F in ${DIR}/*; do
            if [ -d ${F} ]; then
                compile ${F}
            else
                if [ ${F##*.} = "lua" ]; then
                    ${LUAC} -o ${F%.lua}.luac ${F}
                fi
            fi
        done
    done
}

if [ -n "${TYPE}" ]; then
    REV=$(git rev-parse HEAD | cut -c1-5)
    if [ ${TYPE} = "arm_v7" ] || [ ${TYPE} = "x86_64" ]; then
        BUILD_PATH=build/${TYPE}
        REVFILE=VERSION
        echo ${REV} > ${REVFILE}

        LUADIRS="lualib skynet/lualib service skynet/service"
        compile ${LUADIRS}

        TARBALL=${RELEASE_DIR}/${REV}-${TYPE}.tar.gz
        DIRS="${REVFILE} ${BUILD_PATH} config.*.lua scripts"
        EXCLUDES="--exclude=${BUILD_PATH}/cservice/gate.so \
                  --exclude=${BUILD_PATH}/luaclib/sproto.so \
                  --exclude=${BUILD_PATH}/luaclib/client.so \
                  --exclude=${BUILD_PATH}/prebuilt/lib* \
                  --exclude=lualib/*.lua \
                  --exclude=skynet/lualib/*.lua \
                  --exclude=service/*.lua \
                  --exclude=skynet/service/*.lua"

        tar --transform "s|^|iotedge-${REV}/|" ${EXCLUDES} -czf ${TARBALL} ${DIRS} ${LUADIRS}
        find . -name "*.luac" |xargs rm -f
        rm -f ${REVFILE}

        echo "${TARBALL} created"
        upload iotedge ${TARBALL}

        for APP in tpl/*; do
            compile ${APP}

            BASE=$(basename ${APP})
            TARBALL=${RELEASE_DIR}/v_${BASE#*_v_}-${TYPE}.tar.gz
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
