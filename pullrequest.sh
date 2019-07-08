#!/usr/bin/env bash

#TODOs
# replace
# TRAVIS_COMMIT_RANGE,TRAVIS_PULL_REQUEST,TRAVIS_BRANCH,TRAVIS_COMMIT
# with jenkins specific var or a trick

#BEFORE INSTALL
echo 'Loading repository configs'
. ./.ci/repos.conf
echo 'Detecting changes to tool files...'
git diff --quiet "$TRAVIS_COMMIT_RANGE" --; GIT_DIFF_EXIT_CODE=$?
if [ "$GIT_DIFF_EXIT_CODE" -gt 1 ]; then
    git remote set-branches --add origin master
    git fetch
    TRAVIS_COMMIT_RANGE=origin/master...
fi
echo "\$TRAVIS_COMMIT_RANGE is $TRAVIS_COMMIT_RANGE"
echo "Change detection limited to toolset directories:"; for d in "${!TOOLSET_REPOS[@]}"; do echo "${d}/"; done
TOOLSET= ;
while read op path; do
    if [ -n "$TOOLSET" -a "$TOOLSET" != "${path%%/*}" ]; then
        echo "ERROR: Changes to tools in multiple toolsets found, terminating: ${TOOLSET} != ${path%%/*}"
        exit 1
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
done < <(git diff --color=never --name-status "$TRAVIS_COMMIT_RANGE" -- $(for d in "${!TOOLSET_REPOS[@]}"; do echo "${d}/"; done))
set | grep '^TOOL'
if [ ${#TOOL_YAMLS[@]} -eq 0 ]; then
    echo 'No tool changes, terminating'
    exit 0
fi
REPO="${TOOLSET_REPOS[$TOOLSET]}"
if [ -n "$REPO" ]; then
    echo "Setting up CVMFS for repo ${REPO}"
else
    echo "ERROR: No repo defined for toolset $TOOLSET, set one in \$TOOLSET_REPOS"
    exit 1
fi
sudo groupadd --gid 1450 cvmfs
sudo useradd --uid 1450 --gid 1450 cvmfs
sudo mkdir /lower /upper /work /cvmfs /cvmfs/${REPO}
curl -O https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest_all.deb
sudo dpkg -i cvmfs-release-latest_all.deb
sudo apt-get update
sudo apt-get install --no-install-recommends -y cvmfs
sudo cp .ci/default.local /etc/cvmfs
sudo cp .ci/*.pub /etc/cvmfs/keys
sudo mount -t cvmfs "$REPO" "/lower"
sudo mount -t overlay overlay -o lowerdir=/lower,upperdir=/upper,workdir=/work "/cvmfs/${REPO}"

#INSTALL
sudo pip install git+https://github.com/natefoo/ephemeris.git@spinner planemo
docker run -d -p 8080:80 --name=galaxy \
-e GALAXY_CONFIG_INSTALL_DATABASE_CONNECTION=sqlite:///${INSTALL_DATABASES[$REPO]} \
-e GALAXY_CONFIG_TOOL_CONFIG_FILE=${SHED_TOOL_CONFIGS[$REPO]} \
-e GALAXY_CONFIG_MASTER_API_KEY=deadbeef \
-e GALAXY_CONFIG_CONDA_PREFIX=${CONDA_PATHS[$REPO]} \
-e GALAXY_HANDLER_NUMPROCS=0 \
-e CONDARC=${CONDA_PATHS[$REPO]}rc \
-v /cvmfs/${REPO}:/cvmfs/${REPO} \
-v $(pwd)/.ci/job_conf.xml:/job_conf.xml \
-v $(pwd)/.ci/nginx.conf:/etc/nginx/nginx.conf \
-e GALAXY_CONFIG_JOB_CONFIG_FILE=/job_conf.xml \
bgruening/galaxy-stable

galaxy-wait -v --timeout 120 || {
    echo "#### TIMED OUT WAITING FOR GALAXY ####";
    for f in /var/log/nginx/error.log /home/galaxy/logs/uwsgi.log; do
        echo "#### CONTENTS OF ${f}:";
        docker exec galaxy cat $f;
    done;
    echo "#### RESPONSE FROM http://localhost:8080:";
    curl http://localhost:8080;
    echo "#### TERMINATING BUILD";
    exit 1;
}

#SCRIPT
for tool_yaml in "${TOOL_YAMLS[@]}"; do
    shed-tools install -v -a deadbeef -t "$tool_yaml" || {
        echo "#### TOOL INSTALL ERROR ####";
        for f in /var/log/nginx/error.log /var/log/nginx/access.log /home/galaxy/logs/uwsgi.log; do
            echo "#### TAIL OF ${f}:";
            docker exec galaxy tail -500 $f;
        done;
        echo "#### TERMINATING BUILD";
        exit 1;
    }
    #shed-tools install -v -a deadbeef -t "$tool_yaml" --test --test_json "${tool_yaml##*/}"-test.json || {
    #    # TODO: test here if test failures should be ignored (but we can't separate test failures from install
    #    # failures at the moment) and also we can't easily get the job stderr
    #    [ "$TRAVIS_PULL_REQUEST" == "false" -a "$TRAVIS_BRANCH" == "master" ] || {
    #        echo "#### TOOL INSTALL/TEST FAILED ####";
    #        echo "#### CONTENTS OF /home/galaxy/logs/uwsgi.log:";
    #       docker exec galaxy cat /home/galaxy/logs/uwsgi.log;
    #       echo "#### TERMINATING BUILD";
    #       exit 1;
    #    };
    #}
done
  #  for tool_yaml in "${TOOL_YAMLS[@]}"; do
  #      planemo test_reports --test_output_text tests.txt "${tool_yaml##*/}"-test.json && cat tests.txt
  #  done

#AFTER SUCCESS
[ -d /upper/deps/_conda -o -d /upper/shed_tools ] || { echo "No changes to /upper"; exit 0; }
'[ "$TRAVIS_PULL_REQUEST" != "false" -o "$TRAVIS_BRANCH" != "master" ] && exit 0 || true'
openssl aes-256-cbc -K $encrypted_4ac50eded31b_key -iv $encrypted_4ac50eded31b_iv -in .ci/deploy_key.pem.enc -out .ci/deploy_key.pem -d
cp -p .ci/known_hosts $HOME/.ssh/known_hosts
eval "$(ssh-agent -s)"
chmod 600 .ci/deploy_key.pem
ssh-add .ci/deploy_key.pem
sudo find /upper -perm -u+r -not -perm -o+r -not -type l -print0 | sudo xargs -0 --no-run-if-empty chmod go+r
sudo find /upper -perm -u+rx -not -perm -o+rx -not -type l -print0 | sudo xargs -0 --no-run-if-empty chmod go+rx
CONDA=${CONDA_PATHS[$REPO]}
sudo ${CONDA}/bin/conda clean --tarballs --yes
for env in ${CONDA}/envs/*; do
    for link in conda activate deactivate; do
        [ -h ${env}/bin/${link} ] || ln -s ${CONDA}/bin/${link} ${env}/bin/${link}
    done
done
REPO_USER=${REPO_USERS[$REPO]}
REPO_STRATUM0=${REPO_STRATUM0S[$REPO]}
echo "Pushing changes to repo ${REPO} on CVMFS Stratum 0 ${REPO_STRATUM0} as user ${REPO_USER}"
ssh ${REPO_USER}@${REPO_STRATUM0} cvmfs_server transaction ${REPO}
rsync -a --info=progress2 /upper/ ${REPO_USER}@${REPO_STRATUM0}:/cvmfs/${REPO} || {
    echo "#### RSYNC FAILED, ABORTING TRANSACTION";
    ssh ${REPO_USER}@${REPO_STRATUM0} cvmfs_server abort -f ${REPO};
    exit 1;
}
ssh ${REPO_USER}@${REPO_STRATUM0} "cvmfs_server publish -a 'tools-${TRAVIS_COMMIT:0:7}' -m 'Automated tool install for commit $TRAVIS_COMMIT' ${REPO}"
# ssh ${REPO_USER}@${REPO_STRATUM0} "cvmfs_server abort -f ${REPO}"
