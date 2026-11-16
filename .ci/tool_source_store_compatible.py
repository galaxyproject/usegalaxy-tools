#!/usr/bin/env python3
"""Check whether the tool source store bundle in BUNDLE_DIR is compatible with this Galaxy.

Runs with a Galaxy image's own interpreter and library, so the verdict is the manifest check a Galaxy server of that
version applies when it selects a bundle. Only the manifest is checked: the database must exist, but is not opened.
Prints the reasons a bundle is incompatible on one line.

Exits 0 if the bundle is compatible, 1 if it is not or does not exist, and 2 if the check itself could not run.

Usage: tool_source_store_compatible.py BUNDLE_DIR STORE_NAME
"""

import sys
from pathlib import Path

INCOMPATIBLE = 1
CHECK_FAILED = 2


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return CHECK_FAILED
    bundle_dir, store = Path(sys.argv[1]), sys.argv[2]
    from galaxy.tools.source_store.manifest import (
        manifest_compatibility_errors,
        read_manifest,
    )

    database = bundle_dir / f"{store}.sqlite"
    manifest_path = Path(f"{database}.manifest.json")
    if not database.is_file() or not manifest_path.is_file():
        print(f"no bundle in {bundle_dir}")
        return INCOMPATIBLE
    try:
        manifest = read_manifest(manifest_path)
    except Exception as e:
        print(f"invalid manifest {manifest_path}: {e}")
        return INCOMPATIBLE
    errors = manifest_compatibility_errors(manifest, store)
    if errors:
        print("; ".join(errors))
        return INCOMPATIBLE
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        # Includes an image whose Galaxy lacks this module: rebuilding with it would not help either
        print(f"check failed: {e!r}")
        sys.exit(CHECK_FAILED)
