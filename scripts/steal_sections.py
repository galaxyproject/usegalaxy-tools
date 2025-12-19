#!/usr/bin/env python
#
# given an input yaml and a toolset, find tools in sections on another server and add to toolset

import yaml
import glob
import os
import string
import argparse
import requests


def steal_section(repo_dict, toolset: str, leftovers_file: str, galaxy_url: str, verbose: bool = False):
    section_files = glob.glob(os.path.join(toolset, "*.yml"))

    other_tools = {}
    other_labels = {}

    url = f"{galaxy_url}/api/tools?in_panel=false"
    if verbose:
        print(f"Loading tools from: {url}")
    for tool in requests.get(url).json():
        if 'tool_shed_repository' not in tool:
            continue
        # this overwrites multi-tool repos but that's not a biggie
        tool_key = (tool['tool_shed_repository']['name'], tool['tool_shed_repository']['owner'])
        section_label = tool['panel_section_name']
        section_id = ''.join(c if c in string.ascii_letters + string.digits else '_' for c in section_label).lower()
        other_tools[tool_key] = section_id
        other_labels[section_id] = section_label

    existing = {}
    leftover_tools = []
    new = {}

    for section_file in section_files:
        if verbose:
            print(f"Reading section file: {section_file}")
        a = yaml.safe_load(open(section_file, 'r'))
        tools = a['tools']
        for tool in tools:
            tool_key = (tool['name'], tool['owner'])
            existing[tool_key] = section_file

    tools = repo_dict['tools']
    for tool in tools:
        tool_key = (tool['name'], tool['owner'])
        if tool_key in existing:
            if verbose:
                print(f"Skipping existing tool: {tool['owner']}/{tool['name']}")
            continue
        elif tool_key in other_tools:
            try:
                new[other_tools[tool_key]].append(tool_key)
            except:
                new[other_tools[tool_key]] = [tool_key]
        else:
            leftover_tools.append(tool)

    print(f"Found sections for {len(new)} tools ({len(leftover_tools)} left over)")

    for section, repos in new.items():
        section_file = os.path.join(toolset, section + ".yml")
        if not os.path.exists(section_file):
            a = {'tool_panel_section_label': other_labels[section], 'tools': []}
            if verbose:
                print(f"Adding to new section file: {section_file}")
        else:
            a = yaml.safe_load(open(section_file, 'r'))
            if verbose:
                print(f"Adding to existing section file: {section_file}")
        tools = a['tools']
        # Get existing tool keys to avoid duplicates
        existing_tools = {(tool['name'], tool['owner']) for tool in tools}
        # Deduplicate repos list (same tool may appear in multiple workflows)
        unique_repos = list(dict.fromkeys(repos))  # Preserves order while removing duplicates
        # Only add tools that don't already exist in this section file
        new_tools = [{"name": t[0], "owner": t[1]} for t in unique_repos if t not in existing_tools]
        tools.extend(new_tools)

        with open(section_file, 'w') as out:
            yaml.dump(a, out, default_flow_style=False)

    if leftover_tools:
        # Keep only name and owner fields to match the standard .yml format
        cleaned_tools = []
        for tool in leftover_tools:
            cleaned_tool = {'name': tool['name'], 'owner': tool['owner']}
            cleaned_tools.append(cleaned_tool)

        with open(leftovers_file, 'w') as out:
            yaml.dump({'tool_panel_section_label': 'Uncategorized', 'tools': cleaned_tools}, out, default_flow_style=False)

def main():

    VERSION = 0.1

    parser = argparse.ArgumentParser(description="")
    parser.add_argument("-t", "--tools", default="tools.yaml", help="Input tools.yaml")
    parser.add_argument("-s", "--toolset", default="usegalaxy.org", help="The toolset dir to add versions to")
    parser.add_argument("-l", "--leftovers-file", default="leftovers.yaml", help="The file to store leftover (unmatched) repos in.")
    parser.add_argument("-g", "--galaxy-url", default="https://usegalaxy.eu", help="The Galaxy server to steal from")
    parser.add_argument("--version", action='store_true')
    parser.add_argument("--verbose", action='store_true')

    args = parser.parse_args()

    if args.version:
        print("merge_versions.py version: %.1f" % VERSION)
        return

    with open(args.tools) as fh:
        repo_dict = yaml.safe_load(fh)
    toolset = args.toolset
    steal_section(repo_dict=repo_dict, toolset=toolset, leftovers_file=args.leftovers_file, galaxy_url=args.galaxy_url, verbose=args.verbose)


if __name__ == "__main__":
    main()
