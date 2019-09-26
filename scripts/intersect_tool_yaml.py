#!/bin/env python

import yaml
from collections import defaultdict
import re
import os
import sys
import argparse

def main():

    VERSION = 0.1

    parser = argparse.ArgumentParser(description="")
    parser.add_argument("-o", "--outfile", help="The output file to write the intersection into.")
    parser.add_argument("-u", "--unionfile", help="The name of the outputfile to write the union tool_list to.")
    parser.add_argument("-m", "--minimum_occurences", default=2, help="The minimum number of servers a tool has to appear in to be added to intersection. Default = 2")
    parser.add_argument("--version", action='store_true')
    parser.add_argument("--verbose", action='store_true')
    parser.add_argument("infiles", nargs="+")

    args = parser.parse_args()

    if args.version:
        print("intersect_tool_yaml.py version: %.1f" % VERSION)
        return

    min_intersect = int(args.minimum_occurences)

    filenames = args.infiles
    outfile = args.outfile

    tools_count = defaultdict(int)
    tools_union = defaultdict(dict)

    for file in filenames:
        if args.verbose:
            print("Processing: %s" % file)
        a = yaml.safe_load(open(file, 'r'))
        these_tools = a['tools']
        tools_already_seen_on_this_instance = []
        for tool in these_tools:
            # deal with tools that have the same name
            tool_id = tool['name'] + tool['owner']
            # deal with tools duplicated in different sections
            if tool_id in tools_already_seen_on_this_instance:
                continue
            else:
                tools_already_seen_on_this_instance.append(tool_id)
            if tools_count[tool['name']]:
                tools_count[tool['name']] += 1
            else:
                tools_count[tool['name']] = 1
                tools_union[tool['name']] = tool

    intersection = defaultdict(list)
    for tool in tools_count:
        if tools_count[tool] >= min_intersect:
            intersection['tools'].append(tools_union[tool])

    intersect_yaml = {'tools': intersection['tools']}

    with open(outfile, 'w') as out:
        yaml.dump(intersect_yaml, out, default_flow_style=False)

    if args.unionfile:
        union = []
        for tool in tools_union:
            union.append(tools_union[tool])

        union_yaml = {'tools': union}
        with open(args.unionfile, 'w') as uout:
            yaml.dump(union_yaml, uout, default_flow_style=False)

if __name__ == "__main__": main()
