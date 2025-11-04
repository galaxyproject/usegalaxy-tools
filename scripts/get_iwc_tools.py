import argparse
import glob
import json
import os
from collections import defaultdict

import yaml

from ephemeris.generate_tool_list_from_ga_workflow_files import (
    generate_repo_list_from_workflow,
)
from steal_sections import steal_section
from fix_lockfile import update_file as fix_lockfile
from update_tool import update_file

GALAXY_URL = "https://usegalaxy.eu"


def find_workflows(workflow_path):
    workflow_files = []
    for dirpath, _, filenames in os.walk(workflow_path):
        workflow_files.extend(
            (
                os.path.join(dirpath, filename)
                for filename in filenames
                if filename.endswith(".ga")
            )
        )
    return workflow_files


def add_repos(workflow_path, toolset, uncategorized_file):
    workflow_paths = find_workflows(workflow_path)
    repo_list = generate_repo_list_from_workflow(workflow_paths, "Uncategorized")
    steal_section(
        {"tools": repo_list},
        toolset,
        leftovers_file=os.path.join(toolset, uncategorized_file),
        galaxy_url=GALAXY_URL,
        verbose=True,
    )
    section_files = glob.glob(f"{toolset}/*.yml")
    for section_file in section_files:
        fix_lockfile(
            section_file,
            install_repository_dependencies=False,
            install_resolver_dependencies=False,
        )
        update_file(section_file, without=True)
    lock_files = glob.glob(f"{toolset}/*.yml.lock")
    lock_file_contents = {}
    # Keep a global lookup to find which lock file contains each tool
    global_tool_lookup = {}  # (owner, name) -> lock_file

    # Load all lock files
    for lock_file in lock_files:
        with open(lock_file) as lock_file_fh:
            lock_contents = yaml.safe_load(lock_file_fh)
            lock_file_contents[lock_file] = lock_contents

            # Build global lookup for finding tools
            for repo in lock_contents["tools"]:
                key = (repo["owner"], repo["name"])
                if key not in global_tool_lookup:
                    global_tool_lookup[key] = lock_file

    # Add revisions from workflow repos to the appropriate lock files
    for workflow_repo in repo_list:
        key = (workflow_repo["owner"], workflow_repo["name"])
        if key in global_tool_lookup:
            lock_file = global_tool_lookup[key]
            lock_contents = lock_file_contents[lock_file]
            # Find the tool in this specific lock file and add revisions
            for repo in lock_contents["tools"]:
                if repo["owner"] == workflow_repo["owner"] and repo["name"] == workflow_repo["name"]:
                    repo["revisions"] = sorted(
                        list(set(repo.get("revisions", []) + workflow_repo["revisions"]))
                    )
                    break

    # Deduplicate tools within each lock file separately
    for lock_file, entries in lock_file_contents.items():
        # Create deduplicated tools list for this specific file
        tool_map = {}  # key: (owner, name) -> value: merged tool dict

        for tool in entries["tools"]:
            key = (tool["owner"], tool["name"])
            if key not in tool_map:
                # First occurrence in this file - store it
                tool_map[key] = tool
            else:
                # Duplicate in this file - merge revisions into first occurrence
                existing_tool = tool_map[key]
                existing_tool["revisions"] = sorted(
                    list(set(existing_tool.get("revisions", []) + tool.get("revisions", [])))
                )

        # Rebuild the tools list from the deduplicated map, preserving original order
        deduplicated_tools = []
        seen = set()
        for tool in entries["tools"]:
            key = (tool["owner"], tool["name"])
            if key not in seen:
                seen.add(key)
                deduplicated_tools.append(tool_map[key])

        entries["tools"] = deduplicated_tools

        with open(lock_file, "w") as lock_file_fh:
            yaml.safe_dump(json.loads(json.dumps(entries)), stream=lock_file_fh)


if __name__ == "__main__":

    parser = argparse.ArgumentParser(description="")
    parser.add_argument("-w", "--workflow-path", help="Path to directory with workflows")
    parser.add_argument("-s", "--toolset", default="usegalaxy.org", help="The toolset dir to add versions to")
    parser.add_argument("-u", "--uncategorized-file", default="leftovers.yaml", help="The file to store leftover (uninstalled) repos in.")

    args = parser.parse_args()

    add_repos(workflow_path=args.workflow_path, toolset=args.toolset, uncategorized_file=args.uncategorized_file)
