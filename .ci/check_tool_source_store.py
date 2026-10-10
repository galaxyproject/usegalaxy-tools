#!/usr/bin/env python3
"""Sanity-check a tool source store bundle built by populate_store.py.

Fails when the manifest is missing, names a different store, the bundle
covers too few of the tools in the shed_tool_conf, or a SQLite journal was
left behind (which would mean the populator did not finish cleanly). Prints
a short summary for the run log.

Usage: check_tool_source_store.py [--built-after ISO8601] BUNDLE_DIR STORE_NAME SHED_TOOL_CONF
"""

import argparse
import json
import sys
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

# Tools missing from the bundle fall back to eager parsing in Galaxy, so a
# few parse failures are tolerable; a bundle this incomplete is not.
MIN_COVERAGE = 0.9


def count_conf_tools(conf: str) -> int:
    """Distinct tools in the conf: by guid for shed tools, by file otherwise."""
    tools = ET.parse(conf).getroot().iter("tool")
    return len({tool.get("guid") or tool.get("file") for tool in tools})


def parse_timestamp(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--built-after", type=parse_timestamp, help="fail unless the manifest was written after this time")
    parser.add_argument("bundle_dir", type=Path)
    parser.add_argument("store")
    parser.add_argument("conf")
    args = parser.parse_args()
    bundle_dir, store, conf = args.bundle_dir, args.store, args.conf
    database = bundle_dir / f"{store}.sqlite"
    manifest_path = Path(f"{database}.manifest.json")
    problems = []
    if not database.is_file():
        problems.append(f"missing database {database}")
    if not manifest_path.is_file():
        problems.append(f"missing manifest {manifest_path}")
    leftovers = sorted(p.name for p in list(bundle_dir.glob("*.sqlite-*")) + list(bundle_dir.glob(".*.manifest.json.*.tmp")))
    if leftovers:
        problems.append(f"SQLite journal files left behind: {leftovers}")
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1

    with manifest_path.open(encoding="utf-8") as fh:
        manifest = json.load(fh)
    conf_tools = count_conf_tools(conf)
    snapshot = manifest["tool_snapshot"]
    entries = snapshot["versioned_entry_count"]
    print(f"store:               {manifest['store']} (cohort {manifest['cohort']})")
    print(f"built_at:            {manifest['built_at']}")
    print(f"producer:            Galaxy {manifest['producer']['galaxy_version']}")
    print(f"index schema hash:   {manifest['tool_index_schema_hash']}")
    print(f"tools in conf:       {conf_tools}")
    print(f"indexed versions:    {entries}")
    print(f"indexed tool ids:    {snapshot['default_tool_count']}")
    print(f"snapshot digest:     {snapshot['digest']}")
    print(f"database size:       {database.stat().st_size // (1024 * 1024)} MiB")
    if manifest["store"] != store:
        print(f"manifest store {manifest['store']!r} != {store!r}", file=sys.stderr)
        return 1
    if args.built_after and parse_timestamp(manifest["built_at"]) < args.built_after:
        print(f"manifest built_at {manifest['built_at']} predates this build ({args.built_after.isoformat()})", file=sys.stderr)
        return 1
    if not conf_tools:
        print(f"no tools found in {conf}", file=sys.stderr)
        return 1
    if entries < MIN_COVERAGE * conf_tools:
        print(f"bundle covers {entries}/{conf_tools} tools, below {MIN_COVERAGE:.0%}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
