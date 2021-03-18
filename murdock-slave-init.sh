#!/bin/sh -x

#[ -f "/etc/conf.d/murdock" ] && . /etc/conf.d/murdock
#[ -f "/etc/default/murdock" ] && . /etc/default/murdock

MURDOCK_INSTANCE_PREFIX=${MURDOCK_INSTANCE_PREFIX:-murdock_slave}
MURDOCK_INSTANCE=${MURDOCK_INSTANCE_PREFIX}
MURDOCK_HOSTNAME=${MURDOCK_HOSTNAME:-$(hostname -f)}
MURDOCK_USER=${MURDOCK_USER:-murdock}
MURDOCK_HOME=$(eval echo ~${MURDOCK_USER})
MURDOCK_QUEUES=${MURDOCK_QUEUES:-default}
MURDOCK_WORKERS=${MURDOCK_WORKERS:-4}
RIOT_JOBS=${RIOT_JOBS:-4}
MURDOCK_TMPFS_SIZE=16g
MURDOCK_CCACHE_SIZE=${MURDOCK_CCACHE_SIZE:-10g}
MURDOCK_CONTAINER=kaspar030/riotdocker:latest
CCACHE_MAXSIZE=8g
MURDOCK_GITCACHE_SIZE=5g

mount_ccache_tmpfs() {
    local ccache_dir=${MURDOCK_HOME}/.ccache
    mount | grep -q ${ccache_dir} && return

    mkdir -p "$ccache_dir"
    mount -t tmpfs -o rw,nosuid,nodev,noexec,noatime,size=${MURDOCK_CCACHE_SIZE} tmpfs ${ccache_dir}

    {
        echo "max_size = 30.0G"
        #echo "max_files = 1000000"
        #echo "compression = true"
    } > ${ccache_dir}/ccache.conf

    chown -R murdock ${ccache_dir}
}

mount_gitcache_tmpfs() {
    local gitcache_dir=${MURDOCK_HOME}/.gitcache
    mount | grep -q ${gitcache_dir} && return

    git init --bare "$gitcache_dir"

    mount -t tmpfs -o rw,nosuid,nodev,noexec,noatime,size=${MURDOCK_GITCACHE_SIZE} tmpfs ${gitcache_dir}

    chown -R murdock ${gitcache_dir}
}

_start() {
    [ "$MURDOCK_CCACHE_TMPFS" = "1" ] && mount_ccache_tmpfs
    [ "$MURDOCK_GITCACHE_TMPFS" = "1" ] && mount_gitcache_tmpfs

    if [ "$MURDOCK_SYSTEMD" = "1" ]; then
        MURDOCK_DETACH=""
    else
        MURDOCK_DETACH="-d"
    fi

    docker run -d --rm ${MURDOCK_DETACH} -u $(id -u ${MURDOCK_USER}) \
        --tmpfs /tmp:size=${MURDOCK_TMPFS_SIZE},exec,nosuid,noatime${MURDOCK_CPUSET_MEMS:+,mpol=bind:${MURDOCK_CPUSET_MEMS}} \
        --tmpfs /data/riotbuild:size=8g,exec,nosuid,noatime${MURDOCK_CPUSET_MEMS:+,mpol=bind:${MURDOCK_CPUSET_MEMS}} \
        --tmpfs /data/riotbuild/.ccache:size=${MURDOCK_CCACHE_SIZE},exec,nosuid,noatime${MURDOCK_CPUSET_MEMS:+,mpol=bind:${MURDOCK_CPUSET_MEMS}} \
        --tmpfs /data/riotbuild/.gitcache:size=${MURDOCK_GITCACHE_SIZE},exec,nosuid,noatime${MURDOCK_CPUSET_MEMS:+,mpol=bind:${MURDOCK_CPUSET_MEMS}} \
        -v ${MURDOCK_HOME}/.ssh:/data/riotbuild/.ssh \
        ${MURDOCK_CCACHEDIR:+-v ${MURDOCK_CCACHEDIR}:/data/riotbuild/.ccache} \
        ${MURDOCK_GITCACHEDIR:+-v ${MURDOCK_GITCACHEDIR}:/data/riotbuild/.gitcache} \
        ${MURDOCK_DOCKER_ARGS} \
        -e CCACHE="ccache" \
        -e CCACHE_MAXSIZE \
        -e JOBS=${RIOT_JOBS} \
        -e DWQ_SSH \
        ${MURDOCK_CPUSET_CPUS:+--cpuset-cpus=${MURDOCK_CPUSET_CPUS}} \
        ${MURDOCK_CPUSET_MEMS:+--cpuset-mems=${MURDOCK_CPUSET_MEMS}} \
        --security-opt seccomp=unconfined \
        --name ${MURDOCK_INSTANCE} \
        ${MURDOCK_CONTAINER} \
        murdock_slave \
        --name $MURDOCK_HOSTNAME \
        --queues ${MURDOCK_HOSTNAME} ${MURDOCK_QUEUES} \
        ${MURDOCK_WORKERS:+--jobs ${MURDOCK_WORKERS}}
}

_stop() {
    docker kill ${MURDOCK_INSTANCE} || true
    docker rm ${MURDOCK_INSTANCE} >/dev/null 2>&1 || true
}

iterate_numas() {
    numactl -H | awk -F" " ' \
        $3=="cpus:" { \
            printf "%d ", $2; \
            comma=0;
            for (c=4; c <= NF; c++) { \
                if (comma) { printf ","; } \
                printf "%d", $c; \
                comma=1; \
            } \
            print ""}; \
    '
}

case $1 in
    test)
        docker ps | grep -s -q "\\s${MURDOCK_INSTANCE}\$"
        ;;
    start)
        if [ "$MURDOCK_SYSTEMD" != "1" ]; then
            if [ "$MURDOCK_NUMA" = "1" ]; then
                iterate_numas | while read -r node cpus;
                do
                    MURDOCK_INSTANCE=${MURDOCK_INSTANCE_PREFIX}-$node;
                    _stop
                done
            else
                _stop
            fi
            docker pull ${MURDOCK_CONTAINER}
        fi
        if [ "$MURDOCK_NUMA" = "1" ]; then
            iterate_numas | while read -r node cpus;
            do
                MURDOCK_CPUSET_CPUS=$cpus;
                MURDOCK_CPUSET_MEMS=$node;
                MURDOCK_INSTANCE="${MURDOCK_INSTANCE_PREFIX}-$node";
                _start
            done
        else
            _start
        fi
        ;;
    stop)
        if [ "$MURDOCK_NUMA" = "1" ]; then
            iterate_numas | while read -r node cpus;
            do
                MURDOCK_INSTANCE=${MURDOCK_INSTANCE_PREFIX}-$node;
                _stop
            done
        else
            _stop
        fi
        ;;
esac
