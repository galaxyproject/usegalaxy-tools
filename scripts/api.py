#!/usr/bin/env python
import glob
import yaml
import json
import os

data = {}
for fn in sorted(glob.glob("usegalaxy.org/*.yml")):
    with open(fn, 'r') as handle:
        tools = yaml.safe_load(handle)
        for x in tools['tools']:
            data[f"{x['owner']}/{x['name']}"] = tools['tool_panel_section_label']

os.makedirs('api/', exist_ok=True)
with open('api/labels.json', 'w') as handle:
    json.dump(data, handle)
