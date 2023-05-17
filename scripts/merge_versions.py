#!/usr/bin/env python
#
# given an input yaml and a toolset, find tools in existing sections and add versions

import yaml
import glob
import re
import os
import sys
import argparse

def main():

    VERSION = 0.1

    parser = argparse.ArgumentParser(description="")
    parser.add_argument("-t", "--tools", default="tools.yaml", help="Input tools.yaml")
    parser.add_argument("-s", "--toolset", default="usegalaxy.org", help="The toolset dir to add versions to")
    parser.add_argument("-l", "--leftovers-file", default="leftovers.yaml", help="The file to store leftover (uninstalled) repos in.")
    parser.add_argument("--version", action='store_true')
    parser.add_argument("--verbose", action='store_true')

    args = parser.parse_args()

    if args.version:
        print("merge_versions.py version: %.1f" % VERSION)
        return

    tools_yaml = args.tools
    toolset = args.toolset

    lock_files = glob.glob(os.path.join(args.toolset, "*.lock"))

    revisions = {}
    leftover_tools = []

    for lock_file in lock_files:
        if args.verbose:
            print(f"Reading lock file: {lock_file}")
        a = yaml.safe_load(open(lock_file, 'r'))
        tools = a['tools']
        for tool in tools:
            tool_key = (tool['name'], tool['owner'])
            revisions[tool_key] = tool['revisions'] 

    if args.verbose:
        print(f"Processing input tools.yaml: {tools_yaml}")
    a = yaml.safe_load(open(tools_yaml, 'r'))
    tools = a['tools']
    tools_already_seen_on_this_instance = []
    for tool in tools:
        tool_key = (tool['name'], tool['owner'])
        if tool_key in revisions:
            revisions[tool_key] = sorted(list(set(tool['revisions']).union(set(revisions[tool_key]))))
        else:
            leftover_tools.append(tool)

    for lock_file in lock_files:
        if args.verbose:
            print(f"Updating lock file: {lock_file}")
        a = yaml.safe_load(open(lock_file, 'r'))
        tools = a['tools']
        for tool in tools:
            tool_key = (tool['name'], tool['owner'])
            tool['revisions'] = revisions[tool_key]

        with open(lock_file, 'w') as out:
            yaml.dump(a, out, default_flow_style=False)

    with open(args.leftovers_file, 'w') as out:
        yaml.dump({'tools': leftover_tools}, out, default_flow_style=False)

if __name__ == "__main__":
    main()
