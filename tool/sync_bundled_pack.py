#!/usr/bin/env python3
"""Align the bundled Pose-Hub catalogues with a published release channel.

Only reads public HTTPS objects. --check does not write any local files.
Uses Python's standard library; run from any working directory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.parse import urljoin, urlsplit
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parent.parent
LIBRARY = Path("packages/ugk_trainer_runtime/lib/src/pose_hub/pose_hub_action_library.dart")
PUBSPEC = Path("packages/ugk_trainer/pubspec.yaml")
ASSETS = Path("packages/ugk_trainer/assets/pose_hub")
CHANNEL_BASE = "https://media.uuugk.win/pack/channels/"
PACK_PATTERN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
SHA_PATTERN = re.compile(r"[a-f0-9]{64}")


class SyncError(ValueError):
    """Invalid release data, or a local file that cannot be updated safely."""


def download(url: str) -> bytes:
    # The public CDN rejects urllib's default User-Agent.
    request = Request(url, headers={"User-Agent": "Mozilla/5.0 (UGK bundled-pack sync)"})
    with urlopen(request, timeout=60) as response:
        data = response.read(64 * 1024 * 1024 + 1)
    if len(data) > 64 * 1024 * 1024:
        raise SyncError(f"Object exceeds 64 MiB: {url}")
    return data


def is_json_url(value: object) -> bool:
    if not isinstance(value, str):
        return False
    parsed = urlsplit(value)
    return parsed.scheme == "https" and bool(parsed.hostname) and parsed.path.endswith(".json")


def validate_pointer(pointer: object) -> dict:
    if not isinstance(pointer, dict) or type(pointer.get("schema")) is not int or pointer["schema"] != 1:
        raise SyncError("pointer.schema must be 1")
    pack = pointer.get("pack")
    if not isinstance(pack, str) or len(pack) > 64 or not PACK_PATTERN.fullmatch(pack):
        raise SyncError("pointer.pack invalid")
    if not is_json_url(pointer.get("catalog")):
        raise SyncError("pointer.catalog must be an https JSON URL")
    sha = pointer.get("catalog_sha256")
    if not isinstance(sha, str) or not SHA_PATTERN.fullmatch(sha):
        raise SyncError("pointer.catalog_sha256 invalid")
    size = pointer.get("catalog_bytes")
    if type(size) is not int or not 1 <= size <= 64 * 1024 * 1024:
        raise SyncError("pointer.catalog_bytes invalid")
    if not isinstance(pointer.get("min_sdk"), str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", pointer["min_sdk"]):
        raise SyncError("pointer.min_sdk invalid")
    # published_at is descriptive metadata, not a catalogue admission gate.
    return pointer


def verify(data: bytes, sha: object, size: object, label: str) -> None:
    if type(size) is not int or len(data) != size:
        raise SyncError(f"{label}: byte length mismatch")
    if not isinstance(sha, str) or not SHA_PATTERN.fullmatch(sha) or hashlib.sha256(data).hexdigest() != sha:
        raise SyncError(f"{label}: SHA-256 mismatch")


def read_release(channel: str, fetch=download) -> tuple[dict, bytes, bytes, str]:
    pointer = validate_pointer(json.loads(fetch(f"{CHANNEL_BASE}{channel}.json")))
    catalog_bytes = fetch(pointer["catalog"])
    verify(catalog_bytes, pointer["catalog_sha256"], pointer["catalog_bytes"], "catalog.json")
    catalog = json.loads(catalog_bytes)
    if not isinstance(catalog, dict) or catalog.get("pack") != pointer["pack"]:
        raise SyncError("catalog.pack does not match the channel pointer")
    semantic = catalog.get("semanticCatalog")
    if not isinstance(semantic, dict) or semantic.get("path") != "catalog/catalog.json":
        raise SyncError("catalog.semanticCatalog.path must be catalog/catalog.json")
    semantic_bytes = fetch(urljoin(pointer["catalog"], semantic["path"]))
    verify(semantic_bytes, semantic.get("sha256"), semantic.get("bytes"), "catalog/catalog.json")
    distribution = catalog.get("mediaDistribution")
    media_base = distribution.get("baseUrl") if isinstance(distribution, dict) else None
    if not isinstance(media_base, str) or not media_base.startswith("https://") or not urlsplit(media_base).hostname:
        raise SyncError("catalog.mediaDistribution.baseUrl must be an https URL")
    return pointer, catalog_bytes, semantic_bytes, media_base


def replace_constant(source: str, name: str, value: str) -> str:
    pattern = rf"(static const {name}\s*=\s*)'[^']*'(;)"
    updated, count = re.subn(pattern, lambda match: f"{match[1]}'{value}'{match[2]}", source)
    if count != 1:
        raise SyncError(f"Expected one PoseHubActionLibrary.{name} constant")
    return updated


def pack_path(root: Path, pack: str) -> Path:
    assets = (root / ASSETS).resolve()
    target = (assets / f"app-pack-{pack}").resolve()
    if target.parent != assets or target.name != f"app-pack-{pack}":
        raise SyncError("Bundled pack path escapes the asset directory")
    return target


def sync(root: Path, channel: str, check: bool = False, fetch=download) -> int:
    pointer, catalog, semantic, media_base = read_release(channel, fetch)
    pack = pointer["pack"]
    library_path = root / LIBRARY
    source = library_path.read_text(encoding="utf-8")
    old_root = re.search(r"static const assetRoot\s*=\s*'packages/ugk_trainer/assets/pose_hub/app-pack-([a-z0-9-]+)/'", source)
    if old_root is None or not PACK_PATTERN.fullmatch(old_root[1]):
        raise SyncError("Cannot identify the existing bundled pack directory")
    old_pack = old_root[1]
    constants = {
        "assetRoot": f"packages/ugk_trainer/assets/pose_hub/app-pack-{pack}/",
        "catalogSha256": pointer["catalog_sha256"],
        "packVersion": pack,
        "catalogDownloadUri": pointer["catalog"],
        "mediaReleaseBaseUri": media_base,
    }
    for name, value in constants.items():
        source = replace_constant(source, name, value)
    pubspec_path = root / PUBSPEC
    pubspec, count = re.subn(
        r"(?m)^(    - assets/pose_hub/)app-pack-[a-z0-9-]+/(catalog(?:/catalog)?\.json)$",
        lambda match: f"{match[1]}app-pack-{pack}/{match[2]}",
        pubspec_path.read_text(encoding="utf-8"),
    )
    if count != 2:
        raise SyncError("Expected two bundled catalogue assets in ugk_trainer/pubspec.yaml")
    target = pack_path(root, pack)
    expected = {
        target / "catalog.json": catalog,
        target / "catalog/catalog.json": semantic,
        library_path: source.encode("utf-8"),
        pubspec_path: pubspec.encode("utf-8"),
    }
    differences = []
    for path, data in expected.items():
        actual = path.read_bytes() if path.is_file() else None
        # Catalogues are hashed as exact bytes; normalize only source line endings.
        if actual is not None and path in (library_path, pubspec_path):
            actual = actual.replace(b"\r\n", b"\n")
        if actual != data:
            differences.append(path)
    if check:
        for path in differences:
            print(f"Mismatch: {path.relative_to(root)}", file=sys.stderr)
        if differences:
            return 1
    else:
        # All downloads, hashes, paths and source replacements were checked
        # before writing. Remove only the previous catalogue files; preserve
        # standing images and any unrelated files under an older pack.
        for path, data in expected.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        if old_pack != pack:
            previous = pack_path(root, old_pack)
            for relative in ("catalog.json", "catalog/catalog.json"):
                path = previous / relative
                if path.is_file():
                    path.unlink()
            for directory in (previous / "catalog", previous):
                if directory.is_dir() and not any(directory.iterdir()):
                    directory.rmdir()
    print(f"{'Checked' if check else 'Synced'} {channel}: {pack} "
          f"sha256={pointer['catalog_sha256']} bytes={pointer['catalog_bytes']}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", choices=("beta", "stable"), required=True)
    parser.add_argument("--check", action="store_true", help="Compare only; exit 1 if the bundle differs")
    args = parser.parse_args()
    try:
        return sync(ROOT, args.channel, args.check)
    except (SyncError, OSError, ValueError) as error:
        print(f"Bundle sync failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
