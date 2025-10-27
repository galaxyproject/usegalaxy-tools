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
    repo_name_owner_entries = defaultdict(lambda: defaultdict(dict))
    for lock_file in lock_files:
        with open(lock_file) as lock_file_fh:
            lock_contents = yaml.safe_load(lock_file_fh)
            lock_file_contents[lock_file] = lock_contents
            for repo in lock_contents["tools"]:
                repo_name_owner_entries[repo["owner"]][repo["name"]] = repo
    for workflow_repo in repo_list:
        lock_file_entry = repo_name_owner_entries[workflow_repo["owner"]][
            workflow_repo["name"]
        ]
        lock_file_entry["revisions"] = sorted(
            list(set(lock_file_entry["revisions"] + workflow_repo["revisions"]))
        )
    for lock_file, entries in lock_file_contents.items():
        with open(lock_file, "w") as lock_file_fh:
            yaml.safe_dump(json.loads(json.dumps(entries)), stream=lock_file_fh)


if __name__ == "__main__":

    parser = argparse.ArgumentParser(description="")
    parser.add_argument("-w", "--workflow-path", help="Path to directory with workflows")
    parser.add_argument("-s", "--toolset", default="usegalaxy.org", help="The toolset dir to add versions to")
    parser.add_argument("-u", "--uncategorized-file", default="leftovers.yaml", help="The file to store leftover (uninstalled) repos in.")

    args = parser.parse_args()

    add_repos(workflow_path=args.workflow_path, toolset=args.toolset, uncategorized_file=args.uncategorized_file)
