import yaml
import os
import copy
import argparse
import logging
import string

logging.basicConfig(level=logging.INFO)


def section_id_chr(c):
    return (c if c in string.ascii_letters + string.digits else '_').lower()


def section_label_to_id(label):
    return ''.join(map(section_id_chr, label))


def update_file(fn, install_repository_dependencies, install_resolver_dependencies):
    with open(fn, 'r') as handle:
        unlocked = yaml.safe_load(handle)
    # If a lock file exists, load it from that file
    if os.path.exists(fn + '.lock'):
        with open(fn + '.lock', 'r') as handle:
            locked = yaml.safe_load(handle)
    else:
        # Otherwise just clone the "unlocked" list.
        locked = copy.deepcopy(unlocked)

    # We will place entries in a cleaned lockfile, removing defunct entries, etc.
    clean_lockfile = copy.deepcopy(locked)
    clean_lockfile['tools'] = []

    # As here we add any new tools in.
    for tool in unlocked['tools']:
        # If we have an existing locked copy, we'll just use that.
        locked_tools = [x for x in locked['tools'] if x['name'] == tool['name'] and x['owner'] == tool['owner']]

        # If there are no copies of it seen in the lockfile, we'll just copy it
        # over directly, without a reivision. Another script will fix that.
        if len(locked) == 0:
            # new tool, just add directly.
            clean_lockfile['tools'].append(tool)
            continue

        # Otherwise we have one or more locked versions so we'll harmonise +
        # reduce. Revisions are the only thing that could be variable.
        # Name/section/owner should not be. If they are, we take original human
        # edited .yaml file as source of truth.
        revisions = []
        for locked_tool in locked_tools:
            for revision in locked_tool.get('revisions', []):
                revisions.append(revision)

        new_tool = {
            'name': tool['name'],
            'owner': tool['owner'],
            'revisions': sorted(list(set(map(str, revisions)))),  # Cast to list for yaml serialization
        }

        if 'tool_shed_url' in tool:
            ts_url = tool['tool_shed_url']
            logging.warning('Non-default Tool Shed URL for %s/%s: %s', tool['owner'], tool['name'], ts_url)
            new_tool['tool_shed_url'] = ts_url

        # Set the section - id supercedes label/name
        if 'tool_panel_section_id' in unlocked:
            new_tool['tool_panel_section_id'] = unlocked['tool_panel_section_id']
        elif 'tool_panel_section_label' in unlocked:
            new_tool['tool_panel_section_id'] = section_label_to_id(unlocked['tool_panel_section_label'])

        for section_definition in ('tool_panel_section_id', 'tool_panel_section_label'):
            if section_definition in unlocked:
                new_tool[section_definition] = unlocked[section_definition]
                break
        else:
            raise Exception(
                "Unlocked tool definition must include 'tool_panel_section_id' or "
                "'tool_panel_section_label': %s" % str(unlocked)
            )

        clean_lockfile['tools'].append(new_tool)

    # Set appropriate installation flags to true
    clean_lockfile.update({
        "install_repository_dependencies": install_repository_dependencies,
        "install_resolver_dependencies": install_resolver_dependencies,
        "install_tool_dependencies": False,     # These are TS deps, not Conda
    })

    with open(fn + '.lock', 'w') as handle:
        yaml.dump(clean_lockfile, handle, default_flow_style=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--no-install-repository-dependencies', action='store_true', default=False,
                        help="Don't install TS repository dependencies")
    parser.add_argument('--no-install-resolver-dependencies', action='store_true', default=True,
                        help="Don't install tool dependencies via Galaxy dependency resolver (e.g. conda)")
    parser.add_argument('fn', type=argparse.FileType('r'), help="Tool.yaml file")
    args = parser.parse_args()
    logging.info("Processing %s", args.fn.name)
    update_file(args.fn.name, not args.no_install_repository_dependencies, not args.no_install_resolver_dependencies)
