"""Pinned, optional vendor archives for the Windows toolbox. Python 3.11+, stdlib only.

Invoked by scripts/install-legacy-dos.ps1 after the host-projection preflight.
No installers, registry changes, persistent PATH edits, or recursive deletions.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tarfile
from urllib.parse import urlparse
from urllib.request import Request, urlopen
import uuid
import zipfile

VENDORS = {
    "watcom": ("github.com", "/open-watcom/open-watcom-v2/releases/download/"),
    "dosbox": ("github.com", "/joncampbell123/dosbox-x/releases/download/"),
}
from vendor_archive import ProtectedArchivePath, archive_path, inside


def load_spec(config: Path, component: str) -> dict:
    data = json.loads(config.read_text(encoding="utf-8-sig"))
    if data.get("schema_version") != 1 or component not in VENDORS:
        raise ValueError("unsupported optional vendor configuration")
    spec = data[component]
    host, prefix = VENDORS[component]
    parsed = urlparse(spec["url"])
    if parsed.scheme != "https" or parsed.netloc != host or not parsed.path.startswith(prefix):
        raise ValueError("only the named official vendor release repository is allowed")
    if parsed.query or parsed.fragment or not re.fullmatch(r"[A-Za-z0-9._-]+", spec["release"]):
        raise ValueError("invalid release URL or version")
    if not re.fullmatch(r"[0-9a-f]{64}", spec["sha256"]):
        raise ValueError("a pinned SHA-256 digest is required")
    if spec["format"] not in {"zip", "tar.xz"}:
        raise ValueError("unsupported archive format")
    for name in [spec["marker"], *spec["required"]]:
        archive_path(name)
    return spec


def download(spec: dict, destination: Path) -> None:
    if destination.exists():
        with destination.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        if digest == spec["sha256"]:
            return
        raise ValueError("cached archive hash differs; preserve it for inspection")
    temporary = destination.with_name(destination.name + ".part-" + uuid.uuid4().hex)
    # Failed partial archives are retained for inspection, never extracted.
    request = Request(spec["url"], headers={"User-Agent": "scripts-utilities"})
    with urlopen(request, timeout=120) as response, temporary.open("xb") as out:
        shutil.copyfileobj(response, out)
    with temporary.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    if digest != spec["sha256"]:
        raise ValueError("vendor archive SHA-256 mismatch")
    inside(destination.parent, temporary)
    inside(destination.parent, destination)
    os.replace(temporary, destination)


def extract(archive: Path, spec: dict, staging: Path) -> list[dict]:
    """Prevalidate the complete member list, then copy regular files without extractall."""
    source = None
    try:
        if spec["format"] == "zip":
            source = zipfile.ZipFile(archive)
            raw = source.infolist()
            entries = [(x.filename, x.is_dir(), x) for x in raw]
            for _, _, member in entries:
                if stat.S_ISLNK(member.external_attr >> 16):
                    raise ValueError("archive links are not supported")
            opener = source.open
        else:
            source = tarfile.open(archive, "r:xz")
            raw = source.getmembers()
            entries = [(x.name, x.isdir(), x) for x in raw]
            for _, _, member in entries:
                if not (member.isdir() or member.isfile()):
                    raise ValueError("archive links and special files are not supported")
            opener = source.extractfile
        checked = []
        excluded = []
        seen = set()
        for name, directory, member in entries:
            # Root directory entries carry no data and do not name a destination.
            if directory and name in {".", "./"}:
                continue
            try:
                path = archive_path(name)
            except ProtectedArchivePath as error:
                excluded.append({"path": name, "patterns": error.patterns})
                continue
            key = str(path).casefold()
            if key in seen:
                raise ValueError("duplicate or case-colliding archive destination")
            seen.add(key)
            checked.append((path, directory, member))
        marker = PurePosixPath(spec["marker"])
        matches = [p for p, is_dir, _ in checked if not is_dir and p.parts[-len(marker.parts):] == marker.parts]
        if len(matches) != 1:
            raise ValueError("archive must contain one unambiguous compiler/emulator root")
        prefix = matches[0].parts[:-len(marker.parts)]
        plan = []
        for path, directory, member in checked:
            if prefix and path.parts[:len(prefix)] != prefix:
                continue
            relative = PurePosixPath(*path.parts[len(prefix):])
            if str(relative) == ".":
                continue
            target = inside(staging, staging.joinpath(*relative.parts))
            plan.append((target, directory, member))
        present = {str(PurePosixPath(*p.parts[len(prefix):])) for p, d, _ in checked if not d and p.parts[:len(prefix)] == prefix}
        if not set(spec["required"]).issubset(present):
            raise ValueError("archive is missing required toolchain files")
        staging.mkdir(parents=True, exist_ok=False)
        for target, directory, member in plan:
            if directory:
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with opener(member) as src, target.open("xb") as out:
                    shutil.copyfileobj(src, out)
        return excluded
    finally:
        if source is not None:
            source.close()


def install(root: Path, config: Path, component: str) -> dict:
    spec = load_spec(config, component)
    root = root.resolve()
    native = inside(root, root / "native")
    downloads = inside(root, root / "downloads")
    target = inside(native, native / f"{component}-{spec['release']}")
    receipt = target / "toolbox-install.json"
    expected = {"component": component, "release": spec["release"], "url": spec["url"], "sha256": spec["sha256"]}
    if target.exists():
        if not receipt.is_file() or any(json.loads(receipt.read_text(encoding="utf-8")).get(k) != value for k, value in expected.items()):
            raise ValueError("existing installation has different or missing provenance; leaving it unchanged")
        for name in spec["required"]:
            if not target.joinpath(*archive_path(name).parts).is_file():
                raise ValueError("existing installation is incomplete; leaving it unchanged")
    else:
        downloads.mkdir(parents=True, exist_ok=True)
        native.mkdir(parents=True, exist_ok=True)
        extension = ".zip" if spec["format"] == "zip" else ".tar.xz"
        archive = inside(downloads, downloads / f"{component}-{spec['release']}{extension}")
        download(spec, archive)
        staging = inside(downloads, downloads / f"{component}-stage-{uuid.uuid4().hex}")
        excluded = extract(archive, spec, staging)
        (staging / "toolbox-install.json").write_text(json.dumps({**expected, "excluded_protected": excluded}, indent=2) + "\n", encoding="utf-8")
        # Both move endpoints were resolved and bounded above. Existing targets are never replaced.
        if target.exists():
            raise ValueError("installation target appeared concurrently; preserving staging")
        staging.rename(target)
    return {**expected, "root": str(target), "executable": str(target.joinpath(*archive_path(spec["marker"]).parts))}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("component", choices=sorted(VENDORS))
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(install(args.root, args.config, args.component)))


if __name__ == "__main__":
    main()
