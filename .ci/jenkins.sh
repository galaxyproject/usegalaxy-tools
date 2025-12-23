#!/usr/bin/env bash
set -euo pipefail

# Set this variable to 'true' to publish on successful installation
: ${PUBLISH:=false}

LOCAL_PORT=8080
REMOTE_PORT=8080
GALAXY_URL="http://127.0.0.1:${LOCAL_PORT}"
SSH_MASTER_SOCKET_DIR="${HOME}/.cache/usegalaxy-tools"

# Set to 'centos:7' and set GALAXY_GIT_* below to use a clone
GALAXY_DOCKER_IMAGE='galaxy/galaxy-min:dev'
# Disable if using a locally built image e.g. for debugging
GALAXY_DOCKER_IMAGE_PULL=true

#GALAXY_TEMPLATE_DB_URL='https://raw.githubusercontent.com/davebx/galaxyproject-sqlite/master/20.01.sqlite'
#GALAXY_TEMPLATE_DB="${GALAXY_TEMPLATE_DB_URL##*/}"
# Unset to use create_db.py, which is fast now that it doesn't migrate new DBs
GALAXY_TEMPLATE_DB_URL=
GALAXY_TEMPLATE_DB='galaxy.sqlite'

# Need to run dev until 0.10.4
#EPHEMERIS="git+https://github.com/galaxyproject/ephemeris.git"

# Should be set by Jenkins, so the default here is for development
: ${GIT_COMMIT:=$(git rev-parse HEAD)}

# Set to true to perform everything on the Jenkins worker and copy results to the Stratum 0 for publish, instead of
# performing everything directly on the Stratum 0. Requires preinstallation/preconfiguration of CVMFS and for
# fuse-overlayfs to be installed on Jenkins workers.
USE_LOCAL_OVERLAYFS=true

# Parent dir of the persistent CVMFS cache
JENKINS_ROOT=/data/jenkins

#
# Development/debug options
#

# If $GALAXY_DOCKER_IMAGE is a CloudVE image, you can set this to a patch file in .ci/ that will be applied to Galaxy in
# the image before Galaxy is run
GALAXY_PATCH_FILE=

# If $GALAXY_DOCKER_IMAGE is centos*, you can set these to clone Galaxy at a specific revision and mount it in to the
# container. Not fully tested because I was essentially using this to bisect for the bug, but Martin figured out what
# the bug was before I finished. But everything up to starting Galaxy works.
GALAXY_GIT_REPO= #https://github.com/galaxyproject/galaxy.git/
GALAXY_GIT_HEAD= #963093448eb6d029d44aa627354d2e01761c8a7b
# Branch is only used if the depth is set
GALAXY_GIT_BRANCH= #release_19.09
GALAXY_GIT_DEPTH= #100

#
# Ensure that everything is defined for set -u
#

TOOL_YAMLS=()
REPO_USER=
REPO_STRATUM0=
CONDA_PATH=
CONDA_EXEC=
INSTALL_DATABASE=
SHED_TOOL_CONFIG=
SHED_TOOL_DATA_TABLE_CONFIG=
SHED_DATA_MANAGER_CONFIG=
SSH_MASTER_SOCKET=
WORKDIR=
USER_UID="$(id -u)"
USER_GID="$(id -g)"
GALAXY_DATABASE_TMPDIR=
GALAXY_SOURCE_TMPDIR=
OVERLAYFS_UPPER=
OVERLAYFS_LOWER=
OVERLAYFS_WORK=
OVERLAYFS_MOUNT=

CONDA_ENV_OPTION=
CONDA_EXEC_OPTION=

SSH_MASTER_UP=false
CVMFS_TRANSACTION_UP=false
GALAXY_CONTAINER_UP=false
LOCAL_CVMFS_MOUNTED=false
LOCAL_OVERLAYFS_MOUNTED=false


function trap_handler() {
    { set +x; } 2>/dev/null
    $GALAXY_CONTAINER_UP && stop_galaxy
    clean_preconfigured_container
    $LOCAL_CVMFS_MOUNTED && unmount_overlay
    # $LOCAL_OVERLAYFS_MOUNTED does not need to be checked here since if it's true, $LOCAL_CVMFS_MOUNTED must be true
    $CVMFS_TRANSACTION_UP && abort_transaction
    $SSH_MASTER_UP && stop_ssh_control
    return 0
}
trap "trap_handler" SIGTERM SIGINT ERR EXIT


function log() {
    [ -t 0 ] && echo -e '\033[1;32m#' "$@" '\033[0m' || echo '#' "$@"
}


function log_error() {
    [ -t 0 ] && echo -e '\033[0;31mERROR:' "$@" '\033[0m' || echo 'ERROR:' "$@"
}


function log_debug() {
    echo "####" "$@"
}


function log_exec() {
    local rc
    if $USE_LOCAL_OVERLAYFS && ! $SSH_MASTER_UP; then
        set -x
        eval "$@"
    else
        set -x
        "$@"
    fi
    { rc=$?; set +x; } 2>/dev/null
    return $rc
}


function log_exit_error() {
    log_error "$@"
    exit 1
}


function log_exit() {
    echo "$@"
    exit 0
}


function exec_on() {
    if $USE_LOCAL_OVERLAYFS && ! $SSH_MASTER_UP; then
        log_exec "$@"
    else
        log_exec ssh -S "$SSH_MASTER_SOCKET" -l "$REPO_USER" "$REPO_STRATUM0" -- "$@"
    fi
}


function copy_to() {
    local file="$1"
    if $USE_LOCAL_OVERLAYFS && ! $SSH_MASTER_UP; then
        log_exec cp "$file" "${WORKDIR}/${file##*}"
    else
        log_exec scp -o "ControlPath=$SSH_MASTER_SOCKET" "$file" "${REPO_USER}@${REPO_STRATUM0}:${WORKDIR}/${file##*/}"
    fi
}


function check_bot_command() {
    log 'Checking for Github PR Bot commands'
    log_debug "Value of \$ghprbCommentBody is: ${ghprbCommentBody:-UNSET}"
    case "${ghprbCommentBody:-UNSET}" in
        "@galaxybot deploy"*)
            PUBLISH=true
            ;;
    esac
    $PUBLISH && log_debug "Changes will be published" || log_debug "Test installation, changes will be discarded"
}


function load_repo_configs() {
    log 'Loading repository configs'
    . ./.ci/repos.conf
}


function detect_changes() {
    log 'Detecting changes to tool files...'
    log_exec git remote set-branches --add origin master
    log_exec git fetch origin
    COMMIT_RANGE=origin/master...

    log 'Change detection limited to toolset directories:'
    for d in "${!TOOLSET_REPOS[@]}"; do
        echo "${d}/"
    done

    TOOLSET= ;
    while read op path; do
        if [ -n "$TOOLSET" -a "$TOOLSET" != "${path%%/*}" ]; then
            log_exit_error "Changes to tools in multiple toolsets found: ${TOOLSET} != ${path%%/*}"
        elif [ -z "$TOOLSET" ]; then
            TOOLSET="${path%%/*}"
        fi
        case "${path##*.}" in
            lock)
                ;;
            *)
                continue
                ;;
        esac
        case "$op" in
            A|M)
                echo "$op $path"
                TOOL_YAMLS+=("${path}")
                ;;
        esac
    done < <(git diff --color=never --name-status "$COMMIT_RANGE" -- $(for d in "${!TOOLSET_REPOS[@]}"; do echo "${d}/"; done))

    log 'Change detection results:'
    declare -p TOOLSET TOOL_YAMLS

    [ ${#TOOL_YAMLS[@]} -gt 0 ] || log_exit 'No tool changes, terminating'

    log "Getting repo for toolset: ${TOOLSET}"
    # set -u will force exit here if $TOOLSET is invalid
    REPO="${TOOLSET_REPOS[$TOOLSET]}"
    declare -p REPO
}


function set_repo_vars() {
    REPO_USER="${REPO_USERS[$REPO]}"
    REPO_STRATUM0="${REPO_STRATUM0S[$REPO]}"
    # this is used by the fuse config
    export REPO_STRATUM0
    CONDA_PATH="${CONDA_PATHS[$REPO]}"
    CONDA_EXEC="${CONDA_EXECS[$REPO]}"
    INSTALL_DATABASE="${INSTALL_DATABASES[$REPO]}"
    SHED_TOOL_CONFIG="${SHED_TOOL_CONFIGS[$REPO]}"
    SHED_TOOL_DIR="${SHED_TOOL_DIRS[$REPO]}"
    SHED_TOOL_DATA_TABLE_CONFIG="${SHED_TOOL_DATA_TABLE_CONFIGS[$REPO]}"
    SHED_DATA_MANAGER_CONFIG="${SHED_DATA_MANAGER_CONFIGS[$REPO]}"
    CONTAINER_NAME="usegalaxy-tools-${REPO_USER}-${BUILD_NUMBER}"
    if $USE_LOCAL_OVERLAYFS; then
        OVERLAYFS_LOWER="${WORKSPACE}/${BUILD_NUMBER}/lower"
        OVERLAYFS_UPPER="${WORKSPACE}/${BUILD_NUMBER}/upper"
        OVERLAYFS_WORK="${WORKSPACE}/${BUILD_NUMBER}/work"
        OVERLAYFS_MOUNT="${WORKSPACE}/${BUILD_NUMBER}/mount"
        CVMFS_CACHE="${JENKINS_ROOT}/cvmfs-cache"
        CVMFS_SOCKETS="${WORKSPACE}/${BUILD_NUMBER}/cvmfs-sockets"
    else
        OVERLAYFS_UPPER="/var/spool/cvmfs/${REPO}/scratch/current"
        OVERLAYFS_LOWER="/var/spool/cvmfs/${REPO}/rdonly"
        OVERLAYFS_MOUNT="/cvmfs/${REPO}"
    fi
    if [ -n "$CONDA_PATH" ]; then
        CONDA_ENV_OPTION="GALAXY_CONFIG_CONDA_PREFIX=${CONDA_PATH}"
        CONDARC_MOUNT_PATH="${CONDA_PATH}/.condarc"
    else
        CONDA_ENV_OPTION="GALAXY_CONFIG_OVERRIDE_CONDA_AUTO_INIT=false"
        CONDARC_MOUNT_PATH="/.condarc"
    fi
    if [ -n "$CONDA_EXEC" ]; then
        CONDA_EXEC_OPTION="-e GALAXY_CONFIG_CONDA_EXEC=${CONDA_EXEC}"
    else
        CONDA_EXEC_OPTION=
    fi
}


function setup_ephemeris() {
    log "Setting up Ephemeris"
    log_exec python3 -m venv ephemeris
    # FIXME: temporary until Jenkins nodes are updated, new versions of venv properly default unset vars in activate
    set +u
    . ./ephemeris/bin/activate
    set -u
    log_exec pip install --upgrade pip wheel
    log_exec pip install --index-url https://wheels.galaxyproject.org/simple/ \
        --extra-index-url https://pypi.org/simple/ "${EPHEMERIS:=ephemeris}" #"${PLANEMO:=planemo}"
}


function verify_cvmfs_revision() {
    log "Verifying that CVMFS Client and Stratum 0 are in sync"
    local cvmfs_io_sock="${CVMFS_SOCKETS}/${REPO}/cvmfs_io.${REPO}"
    local stratum0_published_url="http://${REPO_STRATUM0}/cvmfs/${REPO}/.cvmfspublished"
    local client_rev=-1
    local stratum0_rev=0
    while [ "$client_rev" -ne "$stratum0_rev" ]; do
        log_exec cvmfs_talk -p "$cvmfs_io_sock" remount sync
        client_rev=$(cvmfs_talk -p "$cvmfs_io_sock" revision)
        stratum0_rev=$(curl -s "$stratum0_published_url" | awk -F '^--$' '{print $1} NF>1{exit}' | grep '^S' | sed 's/^S//')
        if [ -z "$client_rev" ]; then
            log_exit_error "Failed to detect client revision"
        elif [ -z "$stratum0_rev" ]; then
            log_exit_error "Failed to detect Stratum 0 revision"
        elif [ "$client_rev" -ne "$stratum0_rev" ]; then
            log_debug "Client revision '${client_rev}' does not match Stratum 0 revision '${stratum0_rev}'"
            sleep 20
        else
            log "${REPO} is revision ${client_rev}"
            break
        fi
    done
}


function mount_overlay() {
    log "Mounting OverlayFS/CVMFS"
    log_debug "\$JOB_NAME: ${JOB_NAME}, \$WORKSPACE: ${WORKSPACE}, \$BUILD_NUMBER: ${BUILD_NUMBER}"
    log_exec mkdir -p "$OVERLAYFS_LOWER" "$OVERLAYFS_UPPER" "$OVERLAYFS_WORK" "$OVERLAYFS_MOUNT" "$CVMFS_CACHE" "$CVMFS_SOCKETS"
    log_exec cvmfs2 -o config=.ci/cvmfs-fuse.conf,allow_root "$REPO" "$OVERLAYFS_LOWER"
    LOCAL_CVMFS_MOUNTED=true
    verify_cvmfs_revision
    # Attempting to create files as root yields EPERM, even with allow_root/allow_other and user_allow_other
    # FIXME: unprivilged would be preferable but file creation inside docker fails with fuse-overlayfs
    log_exec fuse-overlayfs \
        -o "lowerdir=${OVERLAYFS_LOWER},upperdir=${OVERLAYFS_UPPER},workdir=${OVERLAYFS_WORK},allow_root" \
        "$OVERLAYFS_MOUNT"
    #log_exec sudo --preserve-env=JOB_NAME --preserve-env=WORKSPACE --preserve-env=BUILD_NUMBER \
    #    /usr/local/sbin/jenkins-mount-overlayfs
    LOCAL_OVERLAYFS_MOUNTED=true
}


function unmount_overlay() {
    log "Unmounting OverlayFS/CVMFS"
    if $LOCAL_OVERLAYFS_MOUNTED; then
        log_exec fusermount -u "$OVERLAYFS_MOUNT"
        #log_exec sudo --preserve-env=JOB_NAME --preserve-env=WORKSPACE --preserve-env=BUILD_NUMBER \
        #    /usr/local/sbin/jenkins-umount-overlayfs
        LOCAL_OVERLAYFS_MOUNTED=false
    fi
    # DEBUG: what is holding this?
    log_exec fuser -v "$OVERLAYFS_LOWER" || true
    # Attempt to kill anything still accessing lower so unmount doesn't fail
    log_exec fuser -v -k "$OVERLAYFS_LOWER" || true
    log_exec fusermount -u "$OVERLAYFS_LOWER"
    log_exec rm -rf "${WORKSPACE}/${BUILD_NUMBER}"
    LOCAL_CVMFS_MOUNTED=false
}


function start_ssh_control() {
    log "Starting SSH control connection to Stratum 0"
    SSH_MASTER_SOCKET="${SSH_MASTER_SOCKET_DIR}/ssh-tunnel-${REPO_USER}-${REPO_STRATUM0}.sock"
    log_exec mkdir -p "$SSH_MASTER_SOCKET_DIR"
    $USE_LOCAL_OVERLAYFS || port_forward_flag="-L 127.0.0.1:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}"
    log_exec ssh -S "$SSH_MASTER_SOCKET" -M ${port_forward_flag:-} -Nfn -l "$REPO_USER" "$REPO_STRATUM0"
    USER_UID=$(exec_on id -u)
    USER_GID=$(exec_on id -g)
    SSH_MASTER_UP=true
}


function stop_ssh_control() {
    log "Stopping SSH control connection to Stratum 0"
    log_exec ssh -S "$SSH_MASTER_SOCKET" -O exit -l "$REPO_USER" "$REPO_STRATUM0"
    rm -f "$SSH_MASTER_SOCKET"
    SSH_MASTER_UP=false
}


function begin_transaction() {
    # $1 >= 0 number of seconds to retry opening transaction for
    local max_wait="${1:--1}"
    local start=$(date +%s)
    local elapsed='-1'
    local sleep='4'
    local max_sleep='60'
    log "Opening transaction on $REPO"
    while ! exec_on cvmfs_server transaction "$REPO"; do
        log "Failed to open CVMFS transaction on ${REPO}"
        if [ "$max_wait" -eq -1 ]; then
            log_exit_error 'Transaction open retry disabled, giving up!'
        elif [ "$elapsed" -ge "$max_wait" ]; then
            log_exit_error "Time waited (${elapsed}s) exceeds limit (${max_wait}s), giving up!"
        fi
        log "Will retry in ${sleep}s"
        sleep $sleep
        [ $sleep -ne $max_sleep ] && let sleep="${sleep}*2"
        [ $sleep -gt $max_sleep ] && sleep="$max_sleep"
        let elapsed="$(date +%s)-${start}"
    done
    CVMFS_TRANSACTION_UP=true
}


function abort_transaction() {
    log "Aborting transaction on $REPO"
    exec_on cvmfs_server abort -f "$REPO"
    CVMFS_TRANSACTION_UP=false
}


function publish_transaction() {
    log "Publishing transaction on $REPO"
    exec_on "cvmfs_server publish -a 'tools-${GIT_COMMIT:0:7}' -m 'Automated tool installation for commit ${GIT_COMMIT}' ${REPO}"
    CVMFS_TRANSACTION_UP=false
}


function patch_cloudve_galaxy() {
    [ -n "${GALAXY_PATCH_FILE:-}" ] || return 0
    log "Copying patch to Stratum 0"
    copy_to ".ci/${GALAXY_PATCH_FILE}"
    run_container_for_preconfigure
    log "Installing patch"
    exec_on docker exec --user root "$PRECONFIGURE_CONTAINER_NAME" apt-get -q update
    exec_on docker exec --user root -e DEBIAN_FRONTEND=noninteractive "$PRECONFIGURE_CONTAINER_NAME" apt-get install -y patch
    log "Patching Galaxy"
    exec_on docker exec --workdir /galaxy/server "$PRECONFIGURE_CONTAINER_NAME" patch -p1 -i "/work/$GALAXY_PATCH_FILE"
    commit_preconfigured_container
}


function prep_for_galaxy_run() {
    # Sets globals $GALAXY_DATABASE_TMPDIR $WORKDIR
    log "Copying configs to Stratum 0"
    WORKDIR=$(exec_on mktemp -d -t usegalaxy-tools.work.XXXXXX)
    if [ -n "$GALAXY_TEMPLATE_DB_URL" ]; then
        log_exec curl -o ".ci/${GALAXY_TEMPLATE_DB}" "$GALAXY_TEMPLATE_DB_URL"
        copy_to ".ci/${GALAXY_TEMPLATE_DB}"
    fi
    copy_to ".ci/tool_sheds_conf.xml"
    copy_to ".ci/condarc"
    GALAXY_DATABASE_TMPDIR=$(exec_on mktemp -d -t usegalaxy-tools.database.XXXXXX)
    if [ -n "$GALAXY_TEMPLATE_DB_URL" ]; then
        exec_on mv "${WORKDIR}/${GALAXY_TEMPLATE_DB}" "${GALAXY_DATABASE_TMPDIR}"
    fi
    if $GALAXY_DOCKER_IMAGE_PULL; then
        log "Fetching latest Galaxy image"
        exec_on docker pull "$GALAXY_DOCKER_IMAGE"
    fi
}


function run_container_for_preconfigure() {
    # Sets globals $PRECONFIGURE_CONTAINER_NAME $PRECONFIGURED_IMAGE_NAME
    # $1 = true if should mount $GALAXY_SOURCE_TMPDIR
    local source_mount_flag=
    ${1:-false} && source_mount_flag="-v ${GALAXY_SOURCE_TMPDIR}:/galaxy/server"
    PRECONFIGURE_CONTAINER_NAME="${CONTAINER_NAME}-preconfigure"
    PRECONFIGURED_IMAGE_NAME="${PRECONFIGURE_CONTAINER_NAME}d"
    ORIGINAL_IMAGE_NAME="$GALAXY_DOCKER_IMAGE"
    log "Starting Galaxy container for preconfiguration on Stratum 0"
    exec_on docker run -d --name="$PRECONFIGURE_CONTAINER_NAME" \
        -v "${WORKDIR}/:/work/" \
        $source_mount_flag \
        -v "${GALAXY_DATABASE_TMPDIR}:/galaxy/server/database" \
        "$GALAXY_DOCKER_IMAGE" sleep infinity
    GALAXY_CONTAINER_UP=true
}


function commit_preconfigured_container() {
    log "Stopping and committing preconfigured container on Stratum 0"
    exec_on docker kill "$PRECONFIGURE_CONTAINER_NAME"
    GALAXY_CONTAINER_UP=false
    exec_on docker commit "$PRECONFIGURE_CONTAINER_NAME" "$PRECONFIGURED_IMAGE_NAME"
    GALAXY_DOCKER_IMAGE="$PRECONFIGURED_IMAGE_NAME"
}


function clean_preconfigured_container() {
    [ -n "${PRECONFIGURED_IMAGE_NAME:-}" ] || return 0
    exec_on docker kill "$PRECONFIGURE_CONTAINER_NAME" || true
    exec_on docker rm -v "$PRECONFIGURE_CONTAINER_NAME" || true
    exec_on docker rmi -f "$PRECONFIGURED_IMAGE_NAME" || true
}


# TODO: update for $USE_LOCAL_OVERLAYFS
function run_mounted_galaxy() {
    log "Cloning Galaxy"
    GALAXY_SOURCE_TMPDIR=$(exec_on mktemp -d -t usegalaxy-tools.source.XXXXXX)
    if [ -n "$GALAXY_GIT_BRANCH" -a -n "$GALAXY_GIT_DEPTH" ]; then
        log "Performing shallow clone of branch ${GALAXY_GIT_BRANCH} to depth ${GALAXY_GIT_DEPTH}"
        exec_on git clone --branch "$GALAXY_GIT_BRANCH" --depth "$GALAXY_GIT_DEPTH" "$GALAXY_GIT_REPO" "$GALAXY_SOURCE_TMPDIR"
    else
        exec_on git clone "$GALAXY_GIT_REPO" "$GALAXY_SOURCE_TMPDIR"
    fi
    log "Checking out Galaxy at ref ${GALAXY_GIT_HEAD}"
    # ancient git in EL7 doesn't have -C
    #exec_on git -C "$GALAXY_SOURCE_TMPDIR" checkout "$GALAXY_GIT_HEAD"
    exec_on "cd '$GALAXY_SOURCE_TMPDIR'; git checkout '$GALAXY_GIT_HEAD'"

    run_container_for_preconfigure true
    log "Installing packages"
    exec_on docker exec --user root "$PRECONFIGURE_CONTAINER_NAME" yum install -y python-virtualenv
    log "Installing dependencies"
    exec_on docker exec --user "${USER_UID}:${USER_GID}" --workdir /galaxy/server "$PRECONFIGURE_CONTAINER_NAME" virtualenv .venv
    # $HOME is set for pip cache (~/.cache), which is needed to build wheels
    exec_on docker exec --user "${USER_UID}:${USER_GID}" --workdir /galaxy/server -e "HOME=/galaxy/server/database" "$PRECONFIGURE_CONTAINER_NAME" ./.venv/bin/pip install --upgrade pip setuptools wheel
    exec_on docker exec --user "${USER_UID}:${USER_GID}" --workdir /galaxy/server -e "HOME=/galaxy/server/database" "$PRECONFIGURE_CONTAINER_NAME" ./.venv/bin/pip install -r requirements.txt
    commit_preconfigured_container

    if [ -n "$GALAXY_TEMPLATE_DB_URL" ]; then
        log "Updating database"
        exec_on docker run --rm --user "${USER_UID}:${USER_GID}" --name="${CONTAINER_NAME}-setup" \
            -e "GALAXY_CONFIG_OVERRIDE_DATABASE_CONNECTION=sqlite:////galaxy/server/database/${GALAXY_TEMPLATE_DB}" \
            -v "${GALAXY_SOURCE_TMPDIR}:/galaxy/server" \
            -v "${GALAXY_DATABASE_TMPDIR}:/galaxy/server/database" \
            --workdir /galaxy/server \
            "$GALAXY_DOCKER_IMAGE" ./.venv/bin/python ./scripts/manage_db.py upgrade
    fi

    log "Starting Galaxy on Stratum 0"
    exec_on docker run -d -p 127.0.0.1:${REMOTE_PORT}:8080 --user "${USER_UID}:${USER_GID}" --name="${CONTAINER_NAME}" \
        -e "GALAXY_CONFIG_OVERRIDE_DATABASE_CONNECTION=sqlite:////galaxy/server/database/${GALAXY_TEMPLATE_DB}" \
        -e "GALAXY_CONFIG_OVERRIDE_INTEGRATED_TOOL_PANEL_CONFIG=/tmp/integrated_tool_panel.xml" \
        -e "GALAXY_CONFIG_OVERRIDE_SHED_TOOL_CONFIG_FILE=${SHED_TOOL_CONFIG}" \
        -e "GALAXY_CONFIG_OVERRIDE_MIGRATED_TOOLS_CONFIG=/abcdef" \
        -e "GALAXY_CONFIG_OVERRIDE_TOOL_SHEDS_CONFIG_FILE=/tool_sheds_conf.xml" \
        -e "GALAXY_CONFIG_OVERRIDE_SHED_TOOL_DATA_TABLE_CONFIG=${SHED_TOOL_DATA_TABLE_CONFIG}" \
        -e "GALAXY_CONFIG_OVERRIDE_SHED_DATA_MANAGER_CONFIG_FILE=${SHED_DATA_MANAGER_CONFIG}" \
        -e "GALAXY_CONFIG_TOOL_DATA_PATH=/tmp/tool-data" \
        -e "GALAXY_CONFIG_INSTALL_DATABASE_CONNECTION=sqlite:///${INSTALL_DATABASE}" \
        -e "GALAXY_CONFIG_MASTER_API_KEY=${API_KEY:=deadbeef}" \
        -e "GALAXY_CONFIG_FILE=config/galaxy.yml.sample" \
        -e "${CONDA_ENV_OPTION}" \
        ${CONDA_EXEC_OPTION} \
        -v "${OVERLAYFS_MOUNT}:/cvmfs/${REPO}" \
        -v "${WORKDIR}/tool_sheds_conf.xml:/tool_sheds_conf.xml" \
        -v "${WORKDIR}/condarc:${CONDARC_MOUNT_PATH}" \
        -v "${GALAXY_SOURCE_TMPDIR}:/galaxy/server" \
        -v "${GALAXY_DATABASE_TMPDIR}:/galaxy/server/database" \
        --workdir /galaxy/server \
        "$GALAXY_DOCKER_IMAGE" ./.venv/bin/gunicorn 'galaxy.webapps.galaxy.fast_factory:factory\(\)' --timeout 300 --pythonpath lib -k galaxy.webapps.galaxy.workers.Worker -b 0.0.0.0:8080
    GALAXY_CONTAINER_UP=true
}


function run_cloudve_galaxy() {

    patch_cloudve_galaxy

    if [ -n "$GALAXY_TEMPLATE_DB_URL" ]; then
        log "Updating database"
        exec_on docker run --rm --user "${USER_UID}:${USER_GID}" --name="${CONTAINER_NAME}-setup" \
            -e "GALAXY_CONFIG_OVERRIDE_DATABASE_CONNECTION=sqlite:////galaxy/server/database/${GALAXY_TEMPLATE_DB}" \
            -v "${GALAXY_DATABASE_TMPDIR}:/galaxy/server/database" \
            "$GALAXY_DOCKER_IMAGE" ./.venv/bin/python ./scripts/manage_db.py upgrade
    fi

    # we could just start the patch container and run Galaxy in it with `docker exec`, but then logs aren't captured
    log "Starting Galaxy on Stratum 0"
    exec_on docker run -d -p 127.0.0.1:${REMOTE_PORT}:8080 --user "${USER_UID}:${USER_GID}" --name="${CONTAINER_NAME}" \
        -e "GALAXY_CONFIG_OVERRIDE_DATABASE_CONNECTION=sqlite:////galaxy/server/database/${GALAXY_TEMPLATE_DB}" \
        -e "GALAXY_CONFIG_OVERRIDE_INTEGRATED_TOOL_PANEL_CONFIG=/tmp/integrated_tool_panel.xml" \
        -e "GALAXY_CONFIG_OVERRIDE_SHED_TOOL_CONFIG_FILE=${SHED_TOOL_CONFIG}" \
        -e "GALAXY_CONFIG_OVERRIDE_MIGRATED_TOOLS_CONFIG=/abcdef" \
        -e "GALAXY_CONFIG_OVERRIDE_TOOL_SHEDS_CONFIG_FILE=/tool_sheds_conf.xml" \
        -e "GALAXY_CONFIG_OVERRIDE_SHED_TOOL_DATA_TABLE_CONFIG=${SHED_TOOL_DATA_TABLE_CONFIG}" \
        -e "GALAXY_CONFIG_OVERRIDE_SHED_DATA_MANAGER_CONFIG_FILE=${SHED_DATA_MANAGER_CONFIG}" \
        -e "GALAXY_CONFIG_OVERRIDE_INTERACTIVETOOLS_ENABLE=true" \
        -e "GALAXY_CONFIG_TOOL_DATA_PATH=/galaxy/server/config/mutable" \
        -e "GALAXY_CONFIG_INSTALL_DATABASE_CONNECTION=sqlite:///${INSTALL_DATABASE}" \
        -e "GALAXY_CONFIG_MASTER_API_KEY=${API_KEY:=deadbeef}" \
        -e "GALAXY_CONFIG_FILE=/galaxy/server/lib/galaxy/config/sample/galaxy.yml.sample" \
        -e "${CONDA_ENV_OPTION}" \
        ${CONDA_EXEC_OPTION} \
        -v "${OVERLAYFS_MOUNT}:/cvmfs/${REPO}" \
        -v "${WORKDIR}/tool_sheds_conf.xml:/tool_sheds_conf.xml" \
        -v "${WORKDIR}/condarc:${CONDARC_MOUNT_PATH}" \
        -v "${GALAXY_DATABASE_TMPDIR}:/galaxy/server/database" \
        -v "${GALAXY_DATABASE_TMPDIR}:/galaxy/server/config" \
        --workdir /galaxy/server \
        "$GALAXY_DOCKER_IMAGE" ./.venv/bin/gunicorn 'galaxy.webapps.galaxy.fast_factory:factory\(\)' --timeout 300 --pythonpath lib -k galaxy.webapps.galaxy.workers.Worker -b 0.0.0.0:8080
        #"$GALAXY_DOCKER_IMAGE" ./.venv/bin/uwsgi --yaml config/galaxy.yml
        # TODO: double quoting above probably breaks non-local mode
    GALAXY_CONTAINER_UP=true
}


# TODO: update for $USE_LOCAL_OVERLAYFS
function run_bgruening_galaxy() {
    log "Copying additional configs to Stratum 0"
    copy_to ".ci/nginx.conf"
    log "Starting Galaxy on Stratum 0"
    exec_on docker run -d -p 127.0.0.1:${REMOTE_PORT}:80 --name="${CONTAINER_NAME}" \
        -e "GALAXY_CONFIG_INSTALL_DATABASE_CONNECTION=sqlite:///${INSTALL_DATABASE}" \
        -e "GALAXY_CONFIG_SHED_TOOL_CONFIG_FILE=${SHED_TOOL_CONFIG}" \
        -e "GALAXY_CONFIG_MASTER_API_KEY=${API_KEY:=deadbeef}" \
        -e "${CONDA_ENV_OPTION}" \
        ${CONDA_EXEC_OPTION} \
        -e "GALAXY_HANDLER_NUMPROCS=0" \
        -v "${OVERLAYFS_MOUNT}:/cvmfs/${REPO}" \
        -v "${WORKDIR}/condarc:${CONDARC_MOUNT_PATH}" \
        -v "${WORKDIR}/job_conf.xml:/job_conf.xml" \
        -v "${WORKDIR}/nginx.conf:/etc/nginx/nginx.conf" \
        -e "GALAXY_CONFIG_JOB_CONFIG_FILE=/job_conf.xml" \
        "$GALAXY_DOCKER_IMAGE"
    GALAXY_CONTAINER_UP=true
}


function run_galaxy() {
    prep_for_galaxy_run
    case "$GALAXY_DOCKER_IMAGE" in
        galaxy/galaxy*)
            run_cloudve_galaxy
            ;;
        bgruening/galaxy-stable*)
            run_bgruening_galaxy
            ;;
        centos*)
            run_mounted_galaxy
            ;;
        *)
            log_exit_error "Unknown Galaxy Docker image: ${GALAXY_DOCKER_IMAGE}"
            ;;
    esac
}


function stop_galaxy() {
    log "Stopping Galaxy on Stratum 0"
    # NOTE: docker rm -f exits 1 if the container does not exist
    exec_on docker stop "$CONTAINER_NAME" || true  # try graceful shutdown first
    exec_on docker kill "$CONTAINER_NAME" || true  # probably failed to start, don't prevent the rest of cleanup
    exec_on docker rm -v "$CONTAINER_NAME" || true
    [ -n "$GALAXY_DATABASE_TMPDIR" ] && exec_on rm -rf "$GALAXY_DATABASE_TMPDIR"
    [ -n "${GALAXY_SOURCE_TMPDIR:-}" ] && exec_on rm -rf "$GALAXY_SOURCE_TMPDIR"
    GALAXY_CONTAINER_UP=false
}


function wait_for_galaxy() {
    log "Waiting for Galaxy connection"
    log_exec galaxy-wait -v -g "$GALAXY_URL" --timeout 120 || {
        log_error "Timed out waiting for Galaxy"
        log_debug "contents of docker log";
        exec_on docker logs "$CONTAINER_NAME"
        # bgruening log paths
        #for f in /var/log/nginx/error.log /home/galaxy/logs/uwsgi.log; do
        #    log_debug "contents of ${f}";
        #    exec_on docker exec "$CONTAINER_NAME" cat $f;
        #done
        log_debug "response from ${GALAXY_URL}";
        curl "$GALAXY_URL";
        log_exit_error "Terminating build due to previous errors"
    }
}


function show_logs() {
    local lines=
    if [ -n "${1:-}" ]; then
        lines="--tail ${1:-}"
        log_debug "tail ${lines} of server log";
    else
        log_debug "contents of server log";
    fi
    exec_on docker logs $lines "$CONTAINER_NAME"
    # bgruening log paths
    #for f in /var/log/nginx/error.log /var/log/nginx/access.log /home/galaxy/logs/uwsgi.log; do
    #    log_debug "tail of ${f}";
    #    exec_on docker exec "$CONTAINER_NAME" tail -500 $f;
    #done;
}


function show_paths() {
    log_debug "contents of \$GALAXY_DATABASE_TMPDIR (will be discarded)"
    exec_on tree -L 6 "$GALAXY_DATABASE_TMPDIR"
    log_debug "contents of OverlayFS upper mount (will be published)"
    exec_on tree -L 6 "$OVERLAYFS_UPPER"
}


function install_tools() {
    local tool_yaml
    log "Installing tools"
    for tool_yaml in "${TOOL_YAMLS[@]}"; do
        log "Installing tools in ${tool_yaml}"
        # FIXME: after https://github.com/galaxyproject/ephemeris/pull/181 is merged you would need to remove
        # --skip_install_resolver_dependencies for install_resolver_dependencies: true in tools.yaml to work
        log_exec shed-tools install --skip_install_resolver_dependencies -v -g "$GALAXY_URL" -a "$API_KEY" -t "$tool_yaml" || {
            log_error "Tool installation failed"
            show_logs
            show_paths
            log_exit_error "Terminating build due to previous errors"
        }
        #shed-tools install -v -a deadbeef -t "$tool_yaml" --test --test_json "${tool_yaml##*/}"-test.json || {
        #    # TODO: test here if test failures should be ignored (but we can't separate test failures from install
        #    # failures at the moment) and also we can't easily get the job stderr
        #    [ "$TRAVIS_PULL_REQUEST" == "false" -a "$TRAVIS_BRANCH" == "master" ] || {
        #        log_error "Tool install/test failed";
        #        show_logs
        #        show_paths
        #        log_exit_error "Terminating build due to previous errors"
        #    };
        #}
    done
}



function check_for_repo_changes() {
    local stc="${SHED_TOOL_CONFIG%,*}"
    # probbably don't need this unless things fail
    #log "Showing log"
    #show_logs
    log "Checking for changes to repo"
    show_paths
    log_debug "diff of shed_tool_conf.xml"
    exec_on diff -u "${OVERLAYFS_LOWER}${stc##*${REPO}}" "${OVERLAYFS_MOUNT}${stc##*${REPO}}" || true
    log_debug "diff of shed_tool_data_table_conf.xml"
    exec_on diff -u "${OVERLAYFS_LOWER}${SHED_TOOL_DATA_TABLE_CONFIG##*${REPO}}" \
        "${OVERLAYFS_MOUNT}${SHED_TOOL_DATA_TABLE_CONFIG##*${REPO}}" || true
    log_debug "diff of shed_data_manager.xml"
    exec_on diff -u "${OVERLAYFS_LOWER}${SHED_DATA_MANAGER_CONFIG##*${REPO}}" \
        "${OVERLAYFS_MOUNT}${SHED_DATA_MANAGER_CONFIG##*${REPO}}" || true
    if [ -n "$CONDA_PATH" ]; then
        exec_on [ -d "${OVERLAYFS_UPPER}${CONDA_PATH##*${REPO}}" -o -d "${OVERLAYFS_UPPER}${SHED_TOOL_DIR##*${REPO}}" ] || {
            log_error "Tool installation failed";
            show_logs
            log_exit_error "Terminating build: expected changes to ${OVERLAYFS_UPPER} not found!";
        }
    else
        exec_on [ -d "${OVERLAYFS_UPPER}${SHED_TOOL_DIR##*${REPO}}" ] || {
            log_error "Tool installation failed";
            show_logs
            log_exit_error "Terminating build: expected changes to ${OVERLAYFS_UPPER} not found!";
        }
    fi
}


function post_install() {
    log "Running post-installation tasks"
    exec_on "find '$OVERLAYFS_UPPER' -perm -u+r -not -perm -o+r -not -type l -print0 | xargs -0 --no-run-if-empty chmod go+r"
    exec_on "find '$OVERLAYFS_UPPER' -perm -u+rx -not -perm -o+rx -not -type l -print0 | xargs -0 --no-run-if-empty chmod go+rx"
    # This is always a (slow) no-op now that we're not installing new conda deps
    #if [ -n "$CONDA_PATH" ]; then
    #    exec_on docker run --rm --user "${USER_UID}:${USER_GID}" --name="${CONTAINER_NAME}" \
    #        -v "${OVERLAYFS_MOUNT}:/cvmfs/${REPO}" \
    #        -v "${WORKDIR}/condarc:${CONDARC_MOUNT_PATH}" \
    #        "$GALAXY_DOCKER_IMAGE" ${CONDA_PATH}/bin/conda clean --tarballs --yes
    #    # we're fixing the links for everything here not just the new stuff in $OVERLAYFS_UPPER
    #    exec_on "find '${OVERLAYFS_UPPER}${CONDA_PATH##*${REPO}}/envs' -maxdepth 1 -mindepth 1 -type d -print0 | xargs -0 --no-run-if-empty -I_ENVPATH_ ln -s '${CONDA_PATH}/bin/activate' '_ENVPATH_/bin/activate'" || true
    #    exec_on "find '${OVERLAYFS_UPPER}${CONDA_PATH##*${REPO}}/envs' -maxdepth 1 -mindepth 1 -type d -print0 | xargs -0 --no-run-if-empty -I_ENVPATH_ ln -s '${CONDA_PATH}/bin/deactivate' '_ENVPATH_/bin/deactivate'" || true
    #    exec_on "find '${OVERLAYFS_UPPER}${CONDA_PATH##*${REPO}}/envs' -maxdepth 1 -mindepth 1 -type d -print0 | xargs -0 --no-run-if-empty -I_ENVPATH_ ln -s '${CONDA_PATH}/bin/conda' '_ENVPATH_/bin/conda'" || true
    #fi
    [ -n "${WORKDIR:-}" ] && exec_on rm -rf "$WORKDIR"
}


function copy_upper_to_stratum0() {
    log "Copying changes to Stratum 0"
    set -x
    rsync -ah -e "ssh -o ControlPath=${SSH_MASTER_SOCKET}" --stats "${OVERLAYFS_UPPER}/" "${REPO_USER}@${REPO_STRATUM0}:/cvmfs/${REPO}"
    { rc=$?; set +x; } 2>/dev/null
    return $rc
}


function do_install_local() {
    mount_overlay
    run_galaxy
    wait_for_galaxy
    install_tools
    check_for_repo_changes
    stop_galaxy
    clean_preconfigured_container
    post_install
    if $PUBLISH; then
        start_ssh_control
        begin_transaction 600
        copy_upper_to_stratum0
        publish_transaction
        stop_ssh_control
    fi
    unmount_overlay
}


function do_install_remote() {
    start_ssh_control
    begin_transaction
    run_galaxy
    wait_for_galaxy
    install_tools
    check_for_repo_changes
    stop_galaxy
    clean_preconfigured_container
    post_install
    $PUBLISH && publish_transaction || abort_transaction
    stop_ssh_control
}


function main() {
    check_bot_command
    load_repo_configs
    detect_changes
    set_repo_vars
    setup_ephemeris
    if $USE_LOCAL_OVERLAYFS; then
        do_install_local
    else
        do_install_remote
    fi
    return 0
}


main
