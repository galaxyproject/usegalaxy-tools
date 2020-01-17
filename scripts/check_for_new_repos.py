import argparse
import glob
import os
from collections import defaultdict

import yaml


ROOT_DIR = os.path.join(os.path.dirname(__file__), os.pardir)
IGNORE_REPOS = ('package_', 'suite_')


def list_repos_to_install(infile, toolset, outfile):
    toolset_dir = os.path.join(ROOT_DIR, toolset)
    repos = defaultdict(set)
    for subset in glob.glob("{toolset_dir}/*.yml".format(toolset_dir=toolset_dir)):
        with open(subset) as s:
            loaded_repos = yaml.safe_load(s.read())['tools']
            for repo in loaded_repos:
                repos[repo['owner']].add(repo['name'])
    with open(infile) as i:
        new_repos = yaml.safe_load(i.read())
    new_repos = [r for r in new_repos if not r['name'] in repos.get(r['owner'], {}) and not r['name'].startswith(IGNORE_REPOS)]
    with open(outfile, 'w') as out:
        out.write(yaml.safe_dump(new_repos))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Takes a yaml file produced by planemo list_repos and lists new repos in toolset")
    parser.add_argument("-i", "--infile", help="A list of potentially new repos to compare with list of usegalaxy.* repos")
    parser.add_argument("-t", "--toolset", help="Tool collection to compare input with")
    parser.add_argument("-o", "--outfile", help="Write new tools to this file")
    args = parser.parse_args()
    list_repos_to_install(args.infile, args.toolset, args.outfile)
