"""Extract official vendor ZIPs while excluding protected targets before reading member data."""
from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath
import shutil
import stat
import zipfile


class ProtectedArchivePath(ValueError):
    def __init__(self, patterns):
        self.patterns = patterns
        super().__init__("protected archive path: " + patterns)


def archive_path(name: str) -> PurePosixPath:
    if "\\" in name or ":" in name or "\x00" in name:
        raise ValueError("unsafe archive path")
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise ValueError("archive path escapes the installation")
    previous = ""
    for part in path.parts:
        lower = part.lower()
        suffixes = {".env": "H01/W01", ".pem": "H04/W05", ".key": "H05/W06", ".p12": "H06/W07", ".pfx": "H07/W08", ".keystore": "H08/W09"}
        for suffix, patterns in suffixes.items():
            if lower.endswith(suffix):
                raise ProtectedArchivePath(patterns)
        if lower.startswith(".env."):
            raise ProtectedArchivePath("H02/W02")
        if lower == ".npmrc":
            raise ProtectedArchivePath("H03/W03")
        if lower.startswith("privatekey"):
            raise ProtectedArchivePath("H09/W10")
        if previous == ".git" and lower == "credentials":
            raise ProtectedArchivePath("H20/W04")
        if part.endswith((" ", ".")):
            raise ValueError("unsafe Windows archive path")
        reserved = {"con", "prn", "aux", "nul", *(f"com{i}" for i in range(1, 10)), *(f"lpt{i}" for i in range(1, 10))}
        if lower.split(".")[0] in reserved:
            raise ValueError("reserved Windows archive path")
        previous = lower
    return path


def inside(root: Path, target: Path) -> Path:
    root = root.resolve()
    target = target.resolve()
    if target == root or not target.is_relative_to(root):
        raise ValueError("target must remain beneath the intended directory")
    return target


def extract_zip(archive: Path, destination: Path) -> dict:
    destination = destination.resolve()
    excluded, plan, seen = [], [], set()
    with zipfile.ZipFile(archive) as source:
        # Complete metadata preflight precedes every member-content read or filesystem write.
        for member in source.infolist():
            if member.is_dir() and member.filename in {".", "./"}:
                continue
            try:
                relative = archive_path(member.filename)
            except ProtectedArchivePath as error:
                excluded.append({"path": member.filename, "patterns": error.patterns})
                continue
            if stat.S_ISLNK(member.external_attr >> 16):
                raise ValueError("archive links are not supported")
            key = str(relative).casefold()
            if key in seen:
                raise ValueError("duplicate or case-colliding archive destination")
            seen.add(key)
            target = inside(destination, destination.joinpath(*relative.parts))
            archive_path(target.relative_to(destination).as_posix())
            if not member.is_dir() and target.exists():
                raise ValueError("refusing to overwrite an existing vendor file")
            plan.append((member, target))
        destination.mkdir(parents=True, exist_ok=True)
        count = 0
        for member, target in plan:
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.open(member) as src, target.open("xb") as out:
                    shutil.copyfileobj(src, out)
                count += 1
    return {"extracted": count, "excluded_protected": excluded}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    print(json.dumps(extract_zip(args.archive, args.destination)))


if __name__ == "__main__":
    main()
