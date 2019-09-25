#!/bin/bash

export SCRIPT_PATH="$(dirname ${BASH_SOURCE[0]})"

if [ ! -d $SCRIPT_PATH/../venv ]; then
  virtualenv ${SCRIPT_PATH}/../venv
  source ${SCRIPT_PATH}/../venv/bin/activate
  pip install -r ${SCRIPT_PATH}/../requirements.txt
fi

export EPH_PATH="${SCRIPT_PATH}/../venv/bin/python"
export GET_TOOL_LIST_COMMAND="${SCRIPT_PATH}/../venv/bin/get-tool-list"


export GALAXY_SERVERS=( "usegalaxy.org" "usegalaxy.eu" "usegalaxy.org.au" )

TDIR=$(mktemp -d)
#echo $TDIR

OUTFILES=()

for SERVER in "${GALAXY_SERVERS[@]}"; do
  echo $SERVER
  OUTPATH=${TDIR}/${SERVER}.yml
  $EPH_PATH $GET_TOOL_LIST_COMMAND -g https://${SERVER} -o ${OUTPATH}

  OUTFILES+=($OUTPATH)
done

#echo ${OUTFILES[@]}

$EPH_PATH ${SCRIPT_PATH}/intersect_tool_yaml.py -o ${TDIR}/intersection.yml "${OUTFILES[@]}"

$EPH_PATH ${SCRIPT_PATH}/split_tool_yml.py -i ${TDIR}/intersection.yml -o $1

#Make the intersection
cleanup() {
  rm -rf $TDIR
}
#split the files
trap cleanup EXIT
