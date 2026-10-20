"""Merge main-worktree inventory with newly registered tools; never overwrite the baseline."""
import argparse
import json
from pathlib import Path
import os
import uuid


def merge_entries(baseline, current):
    merged = {}
    for entry in [*baseline, *current]:
        if not isinstance(entry, dict) or not isinstance(entry.get("name"), str) or not entry["name"]:
            raise ValueError("inventory contains an invalid tool entry")
        key = entry["name"].casefold()
        previous = merged.get(key, {})
        combined = {**previous, **entry}
        if previous.get("installed_by_toolbox") or entry.get("installed_by_toolbox"):
            combined["installed_by_toolbox"] = True
        merged[key] = combined
    return list(merged.values())


def read_inventory(path):
    data = json.loads(path.read_text(encoding="utf-8-sig"))
    return data if isinstance(data, list) else [data]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--current", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    baseline = args.base.resolve()
    output = args.output.resolve()
    if output == baseline:
        raise ValueError("the baseline manifest must remain unchanged")
    entries = merge_entries(read_inventory(baseline), read_inventory(args.current))
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".merge-" + uuid.uuid4().hex + ".tmp")
    temporary.write_text(json.dumps(entries, indent=2, ensure_ascii=True) + "\n", encoding="ascii")
    os.replace(temporary, output)
    print(f"Merged {len(entries)} inventory entries -> {output}")


if __name__ == "__main__":
    main()
