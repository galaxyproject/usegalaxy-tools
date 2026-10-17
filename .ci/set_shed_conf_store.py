#!/usr/bin/env python3
"""Point a shed_tool_conf.xml at a named Galaxy tool source store.

Sets ``store="<name>"`` on the ``<toolbox>`` root element, editing only that
tag so the rest of the (large) file is byte-identical. Idempotent. Galaxy
ignores the attribute unless ``use_cached_toolbox`` is on and the name is
declared under ``tool_source_stores`` in galaxy.yml, and Galaxy preserves it
when it rewrites the conf during tool installation.

Usage: set_shed_conf_store.py SHED_TOOL_CONF STORE_NAME
"""

import re
import sys
import xml.etree.ElementTree as ET

# Comments are matched so a commented-out <toolbox> ahead of the root is skipped.
ROOT_OR_COMMENT = re.compile(r"<!--.*?-->|<toolbox\b[^>]*>", re.DOTALL)
STORE_ATTR = re.compile(r"\bstore\s*=\s*([\"'])(.*?)\1")


def main() -> int:
    path, store = sys.argv[1:3]
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    match = next((m for m in ROOT_OR_COMMENT.finditer(text) if not m.group(0).startswith("<!--")), None)
    if match is None:
        print(f"{path}: no <toolbox> root element found", file=sys.stderr)
        return 1
    tag = match.group(0)
    current = STORE_ATTR.search(tag)
    if current is not None and current.group(2) == store:
        print(f"{path}: store={store!r} already set")
        return 0
    if current is not None:
        new_tag = tag[: current.start(2)] + store + tag[current.end(2) :]
    else:
        terminator = "/>" if tag.endswith("/>") else ">"
        new_tag = f'{tag[: -len(terminator)].rstrip()} store="{store}"{terminator}'
    new_text = text[: match.start()] + new_tag + text[match.end() :]
    root = ET.fromstring(new_text)
    if root.tag != "toolbox" or root.get("store") != store:
        print(f"{path}: edited root is {root.tag!r} with store={root.get('store')!r}, not writing", file=sys.stderr)
        return 1
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(new_text)
    print(f"{path}: set store={store!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
