import yaml
import glob
import os
from collections import defaultdict
from ruamel.yaml import YAML
_yaml = YAML()

ROOT_DIR = '../'
IGNORE_REPOS = ('package_', 'suite_')
toolset = 'usegalaxy-eu-tools'
toolset_dir = os.path.join(ROOT_DIR, toolset)
repos = defaultdict(set)
repos = []
for subset in glob.glob("{toolset_dir}/*.y*ml".format(toolset_dir=toolset_dir)):
    with open(subset) as s:
        loaded_repos = yaml.safe_load(s.read())['tools']
        repos.extend(loaded_repos)
repos
missing_repos = yaml.safe_load(open('../missing_repos.yaml'))
missing_repo_list_with_section = []
for m_repo in missing_repos:
    for r in repos:
        if m_repo['name'] == r['name'] and m_repo['owner'] == r['owner']:
            missing_repo_list_with_section.append(r)
            break
missing_repo_list_with_section
missing_repo_list_with_section.sort(key=lambda x: x['tool_panel_section_label'])
per_section = defaultdict(list)
for repo in missing_repo_list_with_section:
    label = repo['tool_panel_section_label']
    del repo['tool_panel_section_label']
    per_section[label].append(repo)
d = {k: v for k, v in per_section.items()}
_yaml.safe_dump(d)
_yaml.dump(d, open('sections.yaml', 'w'))
