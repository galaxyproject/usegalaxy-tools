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

def main():

    VERSION = 0.1

    parser = argparse.ArgumentParser(description="Splits up a Ephemeris `get_tool_list` yml file for a Galaxy server into individual files for each Section Label.")
    parser.add_argument("-i", "--infile", help="The returned `get_tool_list` yml file to split.")
    parser.add_argument("-o", "--outdir", help="The output directory to put the split files into. Defaults to infile without the .yml.")
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
        tool_yaml = {'tools': categories[cat]}
        if args.verbose:
            print("Working on: %s" % good_fname)
        with open(good_fname, 'w') as outfile:
            yaml.dump(tool_yaml, outfile, default_flow_style=False)

    return

if __name__ == "__main__": main()
