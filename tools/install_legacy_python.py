"""Install only catalog-pinned optional libraries in the existing toolbox Python.

Uses pip isolated mode so user pip configuration and PIP_* settings are ignored. The caller must perform the toolbox host-projection preflight first.
"""
from __future__ import annotations

import argparse
from importlib import metadata
import json
from pathlib import Path
import re
import subprocess
import sys

ALLOWED = frozenset(("capstone", "unicorn"))


def catalog_pin(catalog: Path, name: str) -> tuple[str, str]:
    if name not in ALLOWED:
        raise ValueError("not an approved optional legacy DOS Python library")
    tools = json.loads(catalog.read_text(encoding="utf-8-sig"))["tools"]
    matches = [item for item in tools if item["name"] == name]
    if len(matches) != 1:
        raise ValueError("catalog must contain one matching library")
    item = matches[0]
    if item["channel"] != "pip-toolbox" or item.get("binary") or item.get("register_manifest") is not False:
        raise ValueError("library must use the import-only pip-toolbox channel")
    requirement = item["id"]
    match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([A-Za-z0-9_.+-]+)", requirement)
    if not match or match[1].casefold() != name:
        raise ValueError("library requires a simple exact catalog version pin")
    return requirement, match[2]


def install_pinned(name: str, requirement: str, expected: str, *,
                   installed_version=metadata.version, execute=subprocess.run) -> dict:
    try:
        current = installed_version(name)
    except metadata.PackageNotFoundError:
        current = None
    changed = current != expected
    if changed:
        execute([sys.executable, "-X", "utf8", "-m", "pip", "--isolated",
                 "--disable-pip-version-check", "install", "--no-cache-dir",
                 requirement], check=True)
    actual = installed_version(name)
    if actual != expected:
        raise RuntimeError(f"{name} version mismatch after provisioning")
    return {"name": name, "version": actual, "requirement": requirement, "changed": changed}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name", choices=sorted(ALLOWED))
    parser.add_argument("--catalog", required=True, type=Path)
    args = parser.parse_args()
    requirement, version = catalog_pin(args.catalog, args.name)
    print(json.dumps(install_pinned(args.name, requirement, version)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
