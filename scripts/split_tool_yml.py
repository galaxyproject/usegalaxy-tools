#!/usr/bin/env python

import yaml
from collections import defaultdict
import re
import os
import sys
import argparse

def slugify(value):
    """
    Normalizes string, converts to lowercase, removes non-alpha characters,
    and converts spaces to hyphens.
    """
    value = re.sub('[^\w\s-]', '', value).strip().lower()
    value = re.sub('[-\s]+', '_', value)
    return value

def strip_superflous(cat):
    """
    Re-arranges the ehpemeris returned yml format for tools to the usegalaxy-tools minimal tool yml format

    i.e. Takes a list like:

    - name: substitution_rates
      owner: devteam
      revisions:
      - d1b35bcdaacc
      tool_panel_section_label: Regional Variation
      tool_shed_url: toolshed.g2.bx.psu.edu
    - name: indels_3way
      owner: devteam
      revisions:
      - 5ad24b81dd10
      tool_panel_section_label: Regional Variation
      tool_shed_url: toolshed.g2.bx.psu.edu

      ...

     and returns:

     tool_panel_section_label: Regional Variation
     - name: substitution_rates
       owner: devteam
     - name: indels_3way
       owner: devteam

       ...
    """

    out = {'tool_panel_section_label': cat[0]['tool_panel_section_label']}

    for tool in cat:
        del tool['tool_panel_section_label']
        del tool['revisions']
        del tool['tool_shed_url']

    out['tools'] = cat

    return out


def main():

    VERSION = 0.1

    parser = argparse.ArgumentParser(description="Splits up a Ephemeris `get_tool_list` yml file for a Galaxy server into individual files for each Section Label.")
    parser.add_argument("-i", "--infile", help="The returned `get_tool_list` yml file to split.")
    parser.add_argument("-o", "--outdir", help="The output directory to put the split files into. Defaults to infile without the .yml.")
    parser.add_argument("-l", "--lockfiles", action='store_true', help="Produce lock files instead of plain yml files.")
    parser.add_argument("--version", action='store_true')
    parser.add_argument("--verbose", action='store_true')

    args = parser.parse_args()

    if args.version:
        print("split_tool_yml.py version: %.1f" % VERSION)
        return

    filename = args.infile

    a = yaml.safe_load(open(filename, 'r'))
    outdir = re.sub('\.yml','',filename)
    if args.outdir:
        outdir = args.outdir

    if args.verbose:
        print('Outdir: %s' % outdir)
    if not os.path.isdir(outdir):
        os.mkdir(outdir)

    tools = a['tools']
    categories = defaultdict(list)

    for tool in tools:
        categories[tool['tool_panel_section_label']].append(tool)

    for cat in categories:
        fname = str(cat)
        good_fname = outdir + "/" + slugify(fname) + ".yml"
        if args.lockfiles:
            good_fname += ".lock"
            tool_yaml = {'tools': categories[cat]}
        else:
            tool_yaml = strip_superflous(categories[cat])
        if args.verbose:
            print("Working on: %s" % good_fname)
        with open(good_fname, 'w') as outfile:
            yaml.dump(tool_yaml, outfile, default_flow_style=False)

    return

if __name__ == "__main__": main()
