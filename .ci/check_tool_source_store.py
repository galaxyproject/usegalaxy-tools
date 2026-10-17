#!/usr/bin/env python3
"""Check a tool source store bundle built by populate_store.py before it is published.

A Galaxy that loads the bundle's index does not load tools missing from it at all, so the bundle has to cover every
tool in the shed_tool_conf. Fails when the database or manifest is missing or stale, a SQLite journal was left behind
(the populator did not finish cleanly), the database is corrupt, the manifest disagrees with the index, an index
entry references a source row that does not exist, or a tool in the conf is not in the index. Prints a short summary
for the run log, and the missing tools by name.

Usage: check_tool_source_store.py [--built-after ISO8601] BUNDLE_DIR STORE_NAME SHED_TOOL_CONF
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import sqlite3
import sys
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path


def conf_tool_identities(conf: str) -> set[str]:
    """What the index keys each conf tool by: its guid for shed tools, its path otherwise."""
    root = ET.parse(conf).getroot()
    tool_path = root.get("tool_path") or ""
    return {tool.get("guid") or os.path.join(tool_path, tool.get("file", "")) for tool in root.iter("tool")}


def read_index(database: Path) -> tuple[dict, set[str]]:
    """The decoded index payload and the hashes of the stored sources, read without writing to the database."""
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    try:
        result = connection.execute("PRAGMA integrity_check").fetchall()
        if result != [("ok",)]:
            raise ValueError(f"integrity check failed: {result[:5]}")
        row = connection.execute("SELECT data FROM tool_index ORDER BY id DESC LIMIT 1").fetchone()
        if row is None:
            raise ValueError("no tool index in the database")
        source_hashes = {hash for (hash,) in connection.execute("SELECT DISTINCT hash FROM tool_source")}
    finally:
        connection.close()
    return json.loads(gzip.decompress(row[0])), source_hashes


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
    try:
        payload, source_hashes = read_index(database)
    except (sqlite3.Error, ValueError, OSError) as e:
        print(f"cannot read the index from {database}: {e}", file=sys.stderr)
        return 1
    versions = [entry for by_version in payload["index"]["entries_by_version"].values() for entry in by_version.values()]
    indexed = {entry["id"] for entry in versions} | {entry["source_path"] for entry in versions if entry.get("source_path")}
    conf_tools = conf_tool_identities(conf)
    missing = sorted(conf_tools - indexed)
    dangling = sorted(entry["id"] for entry in versions if entry["source_hash"] not in source_hashes)

    snapshot = manifest["tool_snapshot"]
    print(f"store:               {manifest['store']} (cohort {manifest['cohort']})")
    print(f"built_at:            {manifest['built_at']}")
    print(f"producer:            Galaxy {manifest['producer']['galaxy_version']}")
    print(f"index schema hash:   {manifest['tool_index_schema_hash']}")
    print(f"tools in conf:       {len(conf_tools)}")
    print(f"indexed versions:    {len(versions)}")
    print(f"indexed tool ids:    {snapshot['default_tool_count']}")
    print(f"snapshot digest:     {snapshot['digest']}")
    print(f"database size:       {database.stat().st_size // (1024 * 1024)} MiB")
    print(f"missing from index:  {len(missing)}")
    for tool in missing:
        print(f"  {tool}")

    if manifest["store"] != store:
        problems.append(f"manifest store {manifest['store']!r} != {store!r}")
    if args.built_after and parse_timestamp(manifest["built_at"]) < args.built_after:
        problems.append(f"manifest built_at {manifest['built_at']} predates this build ({args.built_after.isoformat()})")
    if payload["schema_hash"] != manifest["tool_index_schema_hash"]:
        problems.append(f"index schema hash {payload['schema_hash']} != manifest {manifest['tool_index_schema_hash']}")
    if len(versions) != snapshot["versioned_entry_count"]:
        problems.append(f"index has {len(versions)} versions, manifest claims {snapshot['versioned_entry_count']}")
    if not conf_tools:
        problems.append(f"no tools found in {conf}")
    if missing:
        problems.append(f"{len(missing)} tools in {conf} are missing from the index, Galaxy would not load them")
    if dangling:
        problems.append(f"{len(dangling)} index entries reference sources missing from the database: {dangling[:10]}")
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
