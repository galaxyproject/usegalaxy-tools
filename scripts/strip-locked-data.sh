#!/usr/bin/env bash
function y2j(){
	python -c 'import sys; import yaml; import json; sys.stdout.write(json.dumps(yaml.load(sys.stdin), indent=2))'
}

function j2y(){
	python -c 'import sys; import yaml; import json; yaml.safe_dump(json.load(sys.stdin), sys.stdout, indent=2, default_flow_style=False)'
}

for i in *.yml; do
	echo $i;
	cat $i | y2j | \
		jq '{"tools": [.tools[] | {"name": .name, "owner": .owner}]}' | j2y > tmp;
	mv tmp $i;
done;
