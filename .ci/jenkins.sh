#!/usr/bin/env bash
set -euo pipefail

LOCAL_PORT=8080
REMOTE_PORT=8080
GALAXY_URL="http://127.0.0.1:${LOCAL_PORT}"
REMOTE_WORKDIR='.local/share/usegalaxy-tools'
SSH_MASTER_SOCKET_DIR="${HOME}/.cache/usegalaxy-tools"

GALAXY_DOCKER_IMAGE='galaxy/galaxy:19.05'
GALAXY_TEMPLATE_DB='galaxy-153.sqlite'

TOOL_YAMLS=()
REPO_USER=
REPO_STRATUM0=
CONDA_PATH=
INSTALL_DATABASE=
SHED_TOOL_CONFIG=
SSH_MASTER_SOCKET=
GALAXY_TMPDIR=

SSH_MASTER_UP=false
CVMFS_TRANSACTION_UP=false
GALAXY_UP=false


function trap_handler() {
    { set +x; } 2>/dev/null
    $GALAXY_UP && stop_galaxy
    $CVMFS_TRANSACTION_UP && abort_transaction
    $SSH_MASTER_UP && stop_ssh_control
}
trap "trap_handler" SIGTERM SIGINT ERR EXIT


function log() {
    echo "#" "$@"
}


function log_error() {
    log "ERROR:" "$@"
}


function log_debug() {
    echo "####" "$@"
}


function log_exec() {
    local rc
    set -x
    "$@"
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
    log_exec ssh -S "$SSH_MASTER_SOCKET" -l "$REPO_USER" "$REPO_STRATUM0" -- "$@"
}


function copy_to() {
    local file="$1"
    exec_on mkdir -p "$REMOTE_WORKDIR"
    log_exec scp -o "ControlPath=$SSH_MASTER_SOCKET" "$file" "${REPO_USER}@${REPO_STRATUM0}:${REMOTE_WORKDIR}/${file##*/}"
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
    CONDA_PATH="${CONDA_PATHS[$REPO]}"
    INSTALL_DATABASE="${INSTALL_DATABASES[$REPO]}"
    SHED_TOOL_CONFIG="${SHED_TOOL_CONFIGS[$REPO]}"
    CONTAINER_NAME="galaxy-${REPO_USER}"
}


function setup_ephemeris() {
    log "Setting up Ephemeris"
    log_exec python3 -m venv ephemeris
    . ./ephemeris/bin/activate
    log_exec pip install "${EPHEMERIS:=ephemeris}" "${PLANEMO:=planemo}"
}


function start_ssh_control() {
    log "Starting SSH control connection to Stratum 0"
    SSH_MASTER_SOCKET="${SSH_MASTER_SOCKET_DIR}/ssh-tunnel-${REPO_USER}-${REPO_STRATUM0}.sock"
    log_exec mkdir -p "$SSH_MASTER_SOCKET_DIR"
    log_exec ssh -S "$SSH_MASTER_SOCKET" -M -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" -Nfn -l "$REPO_USER" "$REPO_STRATUM0"
    SSH_MASTER_UP=true
}


function stop_ssh_control() {
    log "Stopping SSH control connection to Stratum 0"
    log_exec ssh -S "$SSH_MASTER_SOCKET" -O exit -l "$REPO_USER" "$REPO_STRATUM0"
    rm -f "$SSH_MASTER_SOCKET"
    SSH_MASTER_UP=false
}


function begin_transaction() {
    log "Opening transaction on $REPO"
    exec_on cvmfs_server transaction "$REPO"
    CVMFS_TRANSACTION_UP=true
}


function abort_transaction() {
    log "Aborting transaction on $REPO"
    exec_on cvmfs_server abort -f "$REPO"
    CVMFS_TRANSACTION_UP=false
}


function run_cloudve_galaxy() {
    log "Copying configs to Stratum 0"
    copy_to ".ci/${GALAXY_TEMPLATE_DB}"
    log "Fetching latest Galaxy image"
    exec_on docker pull "$GALAXY_DOCKER_IMAGE"
    log "Updating database"
    exec_on docker run --rm --user '$(id -u)' --name="${CONTAINER_NAME}-setup" \
        -e "GALAXY_CONFIG_OVERRIDE_DATABASE_CONNECTION=sqlite:////${GALAXY_TEMPLATE_DB}" \
        -v "\$(pwd)/${REMOTE_WORKDIR}/${GALAXY_TEMPLATE_DB}:/${GALAXY_TEMPLATE_DB}" \
        "$GALAXY_DOCKER_IMAGE" ./.venv/bin/python ./scripts/manage_db.py upgrade
    log "Starting Galaxy on Stratum 0"
    GALAXY_TMPDIR=$(exec_on mktemp -d -t usegalaxy-tools.XXXXXX)
    exec_on docker run -d -p 127.0.0.1:${REMOTE_PORT}:8080 --user '$(id -u)' --name="${CONTAINER_NAME}" \
        -e "GALAXY_CONFIG_OVERRIDE_DATABASE_CONNECTION=sqlite:////${GALAXY_TEMPLATE_DB}" \
        -e "GALAXY_CONFIG_OVERRIDE_INTEGRATED_TOOL_PANEL_CONFIG=/tmp/integrated_tool_panel.xml" \
        -e "GALAXY_CONFIG_TOOL_DATA_PATH=/tmp/tool-data" \
        -e "GALAXY_CONFIG_INSTALL_DATABASE_CONNECTION=sqlite:///${INSTALL_DATABASE}" \
        -e "GALAXY_CONFIG_TOOL_CONFIG_FILE=${SHED_TOOL_CONFIG}" \
        -e "GALAXY_CONFIG_MASTER_API_KEY=${API_KEY:=deadbeef}" \
        -e "GALAXY_CONFIG_CONDA_PREFIX=${CONDA_PATH}" \
        -e "CONDARC=${CONDA_PATH}rc" \
        -v "\$(pwd)/${REMOTE_WORKDIR}/${GALAXY_TEMPLATE_DB}:/${GALAXY_TEMPLATE_DB}" \
        -v "/cvmfs/${REPO}:/cvmfs/${REPO}" \
        -v "${GALAXY_TMPDIR}:/galaxy/server/database" \
        "$GALAXY_DOCKER_IMAGE" ./.venv/bin/uwsgi --yaml config/galaxy.yml
    GALAXY_UP=true
}


function run_bgruening_galaxy() {
    log "Copying configs to Stratum 0"
    copy_to ".ci/job_conf.xml"
    copy_to ".ci/nginx.conf"
    log "Fetching latest Galaxy image"
    exec_on docker pull "$GALAXY_DOCKER_IMAGE"
    log "Starting Galaxy on Stratum 0"
    exec_on docker run -d -p 127.0.0.1:${REMOTE_PORT}:80 --name="${CONTAINER_NAME}" \
        -e "GALAXY_CONFIG_INSTALL_DATABASE_CONNECTION=sqlite:///${INSTALL_DATABASE}" \
        -e "GALAXY_CONFIG_TOOL_CONFIG_FILE=${SHED_TOOL_CONFIG}" \
        -e "GALAXY_CONFIG_MASTER_API_KEY=${API_KEY:=deadbeef}" \
        -e "GALAXY_CONFIG_CONDA_PREFIX=${CONDA_PATH}" \
        -e "GALAXY_HANDLER_NUMPROCS=0" \
        -e "CONDARC=${CONDA_PATH}rc" \
        -v "/cvmfs/${REPO}:/cvmfs/${REPO}" \
        -v "\$(pwd)/${REMOTE_WORKDIR}/job_conf.xml:/job_conf.xml" \
        -v "\$(pwd)/${REMOTE_WORKDIR}/nginx.conf:/etc/nginx/nginx.conf" \
        -e "GALAXY_CONFIG_JOB_CONFIG_FILE=/job_conf.xml" \
        "$GALAXY_DOCKER_IMAGE"
    GALAXY_UP=true
}


function run_galaxy() {
    case "$GALAXY_DOCKER_IMAGE" in
        galaxy/galaxy*)
            run_cloudve_galaxy
            ;;
        bgruening/galaxy-stable*)
            run_bgruening_galaxy
            ;;
        *)
            log_exit_error "Unknown Galaxy Docker image: ${GALAXY_DOCKER_IMAGE}"
            ;;
    esac
}


function stop_galaxy() {
    log "Stopping Galaxy on Stratum 0"
    exec_on docker kill "$CONTAINER_NAME" || true  # probably failed to start, don't prevent the rest of cleanup
    exec_on docker rm -v "$CONTAINER_NAME"
    [ -n "$GALAXY_TMPDIR" ] && exec_on rm -rf "$GALAXY_TMPDIR"
    GALAXY_UP=false
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


function install_tools() {
    local tool_yaml
    log "Installing tools"
    for tool_yaml in "${TOOL_YAMLS[@]}"; do
        log "Installing tools in ${tool_yaml}"
        log_exec shed-tools install -v -g "$GALAXY_URL" -a "$API_KEY" -t "$tool_yaml" || {
            log_error "Tool installation failed"
            log_debug "contents of docker log";
            exec_on docker logs "$CONTAINER_NAME"
            # bgruening log paths
            #for f in /var/log/nginx/error.log /var/log/nginx/access.log /home/galaxy/logs/uwsgi.log; do
            #    log_debug "tail of ${f}";
            #    exec_on docker exec "$CONTAINER_NAME" tail -500 $f;
            #done;
            log_exit_error "Terminating build due to previous errors"
        }
        #shed-tools install -v -a deadbeef -t "$tool_yaml" --test --test_json "${tool_yaml##*/}"-test.json || {
        #    # TODO: test here if test failures should be ignored (but we can't separate test failures from install
        #    # failures at the moment) and also we can't easily get the job stderr
        #    [ "$TRAVIS_PULL_REQUEST" == "false" -a "$TRAVIS_BRANCH" == "master" ] || {
        #        log_error "Tool install/test failed";
        #        log_debug "contents of /home/galaxy/logs/uwsgi.log:";
        #        exec_on docker exec "$CONTAINER_NAME" cat /home/galaxy/logs/uwsgi.log;
        #        log_exit_error "Terminating build due to previous errors"
        #    };
        #}
    done
}



function check_for_repo_changes() {
    local upper="/var/spool/cvmfs/${REPO}/scratch/current"
    log "Checking for changes to repo"
    exec_on ls -lR "$upper"
    # FIXME: hardcoded shed tools path should go in repos.conf
    exec_on "[ -d '${upper}${CONDA_PATH##*${REPO}}' -o -d '${upper}/shed_tools' ]" || {
        log_error "Tool installation failed";
        log_debug "contents of docker log";
        exec_on docker logs "$CONTAINER_NAME"
        # bgruening log paths
        #log_debug "contents of /home/galaxy/logs/uwsgi.log:";
        #exec_on docker exec "$CONTAINER_NAME" tail -500 /home/galaxy/logs/uwsgi.log;
        log_exit_error "Expected changes to ${upper} not found!";
    }
}


function post_install() {
    local upper="/var/spool/cvmfs/${REPO}/scratch/current"
    log "Running post-installation tasks"
    exec_on find "$upper" -perm -u+r -not -perm -o+r -not -type l -print0 | sudo xargs -0 --no-run-if-empty chmod go+r
    exec_on find "$upper" -perm -u+rx -not -perm -o+rx -not -type l -print0 | sudo xargs -0 --no-run-if-empty chmod go+rx
}


function main() {
    load_repo_configs
    detect_changes
    set_repo_vars
    setup_ephemeris
    start_ssh_control
    begin_transaction
    run_galaxy
    wait_for_galaxy
    install_tools
    check_for_repo_changes
    stop_galaxy
    abort_transaction
    stop_ssh_control
}


main
