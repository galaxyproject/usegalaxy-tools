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
    #parser.add_argument("-i", "--infiles", help="An array of yaml tool files to be intersected.")
    parser.add_argument("-o", "--outfile", help="The output file to write the intersection into.")
    parser.add_argument("--version", action='store_true')
    parser.add_argument("--verbose", action='store_true')
    parser.add_argument("infiles", nargs="+")

    args = parser.parse_args()

    if args.version:
        print("intersect_tool_yaml.py version: %.1f" % VERSION)
        return

    filenames = args.infiles
    outfile = args.outfile

    tools_count = defaultdict(int)
    tools_union = defaultdict(dict)

    for file in filenames:
        if args.verbose == True:
            print("Processing: %s" % file)
        a = yaml.safe_load(open(file, 'r'))
        these_tools = a['tools']
        for tool in these_tools:
            #print(tool['name'])
            if tools_count[tool['name']]:
                tools_count[tool['name']] += 1
            else:
                tools_count[tool['name']] = 1
                tools_union[tool['name']] = tool


    intersection = defaultdict(list)
    for tool in tools_count:
        if tools_count[tool] >= 2:
            #print("%s %i" % (tool,tools_count[tool]))
            intersection['tools'].append(tools_union[tool])
            intersect_yaml = {'tools': intersection['tools']}

    with open(outfile, 'w') as out:
        yaml.dump(intersect_yaml, out, default_flow_style=False)

if __name__ == "__main__": main()
