#!/usr/bin/env python3
"""Verify, package, install and locally serve the unchanged Pose Hub R1 pack.

Python 3.10+, standard library only. The catalogue is the media allowlist;
historical media on disk is deliberately excluded. No transcoding or semantic
defaults are performed here.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tempfile
from typing import BinaryIO
from urllib.parse import unquote, urlsplit
import zipfile


PACK_ID = "app-test-pack-r1"
METADATA_PATHS = ("catalog.json", "manifest.json", "catalog/catalog.json")
CHUNK = 1024 * 1024
MAX_METADATA_BYTES = 16 * CHUNK
FIXED_ZIP_TIME = (1980, 1, 1, 0, 0, 0)
DEFAULT_OUTPUT = (
    Path(__file__).resolve().parents[1]
    / ".review-artifacts/posehub219/release/posehub-app-test-pack-r1.zip"
)


class PackError(ValueError):
    """A pack fails an integrity, safety or no-overwrite contract."""


@dataclass(frozen=True)
class ExpectedCounts:
    actions: int = 219
    complete: int = 142
    pending: int = 77


EXPECTED = ExpectedCounts()


@dataclass(frozen=True)
class PackFile:
    path: str
    size: int
    sha256: str
    action_id: str | None = None
    role: str | None = None


@dataclass
class PackIndex:
    catalog: dict
    manifest: dict
    metadata: dict[str, bytes]
    files: dict[str, PackFile]
    complete_count: int
    pending_count: int

    def summary(self) -> dict:
        media = [row for row in self.files.values() if row.action_id is not None]
        return {
            "packId": PACK_ID,
            "actions": len(self.catalog["actions"]),
            "semanticComplete": self.complete_count,
            "semanticPending": self.pending_count,
            "mediaFiles": len(media),
            "mediaBytes": sum(row.size for row in media),
            "metadataFiles": len(self.metadata),
            "metadataBytes": sum(len(blob) for blob in self.metadata.values()),
            "archiveEntries": len(self.files),
            "catalogSha256": self.files["catalog.json"].sha256,
            "manifestSha256": self.files["manifest.json"].sha256,
            "semanticCatalogSha256": self.files["catalog/catalog.json"].sha256,
            "sourceStatus": self.catalog.get("status"),
            "sourceReviewed": self.catalog.get("reviewed"),
            "sourceReleaseEligible": self.catalog.get("releaseEligible"),
        }


def digest_bytes(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()


def digest_file(path: Path) -> str:
    with path.open("rb") as source:
        h = hashlib.sha256()
        for block in iter(lambda: source.read(CHUNK), b""):
            h.update(block)
        return h.hexdigest()


def checked_sha(value: object, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", value):
        raise PackError(f"{label}: expected a SHA256 hex digest")
    return value.lower()


def checked_relative(value: object) -> str:
    if not isinstance(value, str) or not value:
        raise PackError("empty or non-string pack path")
    if any(ch in value for ch in ("\\", ":", "\x00", "%")):
        raise PackError(f"unsafe pack path: {value!r}")
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise PackError(f"unsafe pack path: {value!r}")
    reserved = {"CON", "PRN", "AUX", "NUL"}
    reserved |= {f"{name}{n}" for name in ("COM", "LPT") for n in range(1, 10)}
    if any(
        part.endswith((" ", ".")) or part.split(".", 1)[0].upper() in reserved
        for part in parts
    ):
        raise PackError(f"ambiguous Windows pack path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or path.as_posix() != value:
        raise PackError(f"unsafe pack path: {value!r}")
    return value


def inside(root: Path, relative: str) -> Path:
    checked_relative(relative)
    root = root.resolve()
    path = root.joinpath(*relative.split("/"))
    if not path.resolve().is_relative_to(root):
        raise PackError(f"path escapes its root: {relative}")
    return path


def no_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    value = {}
    for key, item in pairs:
        if key in value:
            raise PackError(f"duplicate JSON object key: {key}")
        value[key] = item
    return value


def json_object(blob: bytes, label: str) -> dict:
    try:
        obj = json.loads(blob.decode("utf-8"), object_pairs_hook=no_duplicate_keys)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise PackError(f"invalid UTF-8 JSON in {label}: {error}") from error
    if not isinstance(obj, dict):
        raise PackError(f"{label}: expected an object")
    return obj


def index_from_metadata(
    metadata: dict[str, bytes], counts: ExpectedCounts = EXPECTED
) -> PackIndex:
    if set(metadata) != set(METADATA_PATHS):
        raise PackError("pack must contain exactly the three original metadata JSON files")
    catalog = json_object(metadata["catalog.json"], "catalog.json")
    manifest = json_object(metadata["manifest.json"], "manifest.json")
    json_object(metadata["catalog/catalog.json"], "catalog/catalog.json")
    if catalog.get("id") != PACK_ID or manifest.get("id") != PACK_ID:
        raise PackError("unexpected catalogue/manifest pack ID")
    if catalog.get("format") != "pose-hub-app-test-catalog@1":
        raise PackError("unsupported catalogue format")
    if manifest.get("format") != "pose-hub-stacked-alpha-delivery@1":
        raise PackError("unsupported manifest format")
    actions = catalog.get("actions")
    manifest_actions = manifest.get("actions")
    if not isinstance(actions, list) or len(actions) != counts.actions:
        raise PackError(f"catalogue must contain {counts.actions} actions")
    if not isinstance(manifest_actions, list) or len(manifest_actions) != counts.actions:
        raise PackError("manifest action count differs from catalogue")
    manifest_by_id = {}
    for action in manifest_actions:
        if not isinstance(action, dict) or not isinstance(action.get("id"), str):
            raise PackError("malformed manifest action")
        if action["id"] in manifest_by_id:
            raise PackError(f"duplicate manifest action ID: {action['id']}")
        manifest_by_id[action["id"]] = action
    files = {
        name: PackFile(name, len(blob), digest_bytes(blob))
        for name, blob in metadata.items()
    }
    seen_ids: set[str] = set()
    folded_ids: set[str] = set()
    folded_paths = {name.casefold() for name in files}
    complete_ids, pending_ids = [], []
    for action in actions:
        if not isinstance(action, dict):
            raise PackError("malformed catalogue action")
        action_id = action.get("id")
        if not isinstance(action_id, str) or not action_id:
            raise PackError("action ID must be a nonempty string")
        if action_id in seen_ids or action_id.casefold() in folded_ids:
            raise PackError(f"duplicate action ID: {action_id}")
        seen_ids.add(action_id)
        folded_ids.add(action_id.casefold())
        semantics = action.get("trainingSemantics")
        if not isinstance(semantics, dict):
            raise PackError(f"{action_id}: missing training semantics")
        flags = (
            action.get("trainingDefinitionComplete"),
            semantics.get("definitionComplete"),
            action.get("availableForTraining"),
        )
        if not all(isinstance(flag, bool) for flag in flags) or len(set(flags)) != 1:
            raise PackError(f"{action_id}: three semantic completeness flags disagree")
        if action.get("availableForApp") is not True:
            raise PackError(f"{action_id}: action is not marked available for browsing")
        complete = flags[0]
        expected_status = "complete-unreviewed" if complete else "partial-unreviewed"
        if semantics.get("status") != expected_status:
            raise PackError(f"{action_id}: semantic status and flags disagree")
        if complete and (
            semantics.get("missingRequiredFields") != []
            or semantics.get("unknownFields") != []
        ):
            raise PackError(f"{action_id}: complete action still declares semantic gaps")
        (complete_ids if complete else pending_ids).append(action_id)
        rows = action.get("files")
        if not isinstance(rows, dict) or set(rows) != {"video", "cover", "thumbnail"}:
            raise PackError(f"{action_id}: expected video, cover and thumbnail")
        if manifest_by_id.get(action_id, {}).get("files") != rows:
            raise PackError(f"{action_id}: manifest media differ from catalogue")
        for role, row in rows.items():
            if not isinstance(row, dict):
                raise PackError(f"{action_id}/{role}: malformed media record")
            name = checked_relative(row.get("path"))
            if not name.startswith("media/"):
                raise PackError(f"{action_id}/{role}: media must be under media/")
            if name.casefold() in folded_paths:
                raise PackError(f"duplicate media path: {name}")
            folded_paths.add(name.casefold())
            size = row.get("bytes")
            if isinstance(size, bool) or not isinstance(size, int) or size < 0:
                raise PackError(f"{action_id}/{role}: invalid byte count")
            files[name] = PackFile(
                name, size, checked_sha(row.get("sha256"), name), action_id, role
            )
    if len(complete_ids) != counts.complete or len(pending_ids) != counts.pending:
        raise PackError("semantic complete/pending counts differ from the expected pack")
    summary = catalog.get("trainingSemantics")
    if not isinstance(summary, dict):
        raise PackError("missing semantic summary")
    if (
        summary.get("definitionCompleteCount") != counts.complete
        or summary.get("definitionCompleteIds") != complete_ids
        or summary.get("incompleteActionIds") != pending_ids
    ):
        raise PackError("semantic summary differs from the per-action flags/order")
    for record, label, blob in (
        (catalog.get("semanticCatalog"), "semantic catalogue", metadata["catalog/catalog.json"]),
        (manifest.get("catalog"), "manifest catalogue", metadata["catalog.json"]),
    ):
        if not isinstance(record, dict):
            raise PackError(f"missing {label} digest")
        if record.get("bytes") != len(blob) or record.get("sha256") != digest_bytes(blob):
            raise PackError(f"{label} bytes/SHA256 do not match the original JSON")
    return PackIndex(catalog, manifest, metadata, files, len(complete_ids), len(pending_ids))


def verify_file(path: Path, expected: PackFile) -> None:
    if not path.is_file() or path.stat().st_size != expected.size:
        raise PackError(f"missing or wrong-sized file: {expected.path}")
    if digest_file(path) != expected.sha256:
        raise PackError(f"SHA256 mismatch: {expected.path}")


def load_pack(root: Path, counts: ExpectedCounts = EXPECTED) -> PackIndex:
    root = root.resolve()
    metadata = {}
    for name in METADATA_PATHS:
        path = inside(root, name)
        if not path.is_file() or path.stat().st_size > MAX_METADATA_BYTES:
            raise PackError(f"missing or oversized metadata: {name}")
        metadata[name] = path.read_bytes()
    index = index_from_metadata(metadata, counts)
    for row in index.files.values():
        verify_file(inside(root, row.path), row)
    return index


def copy_verified(source: BinaryIO, target: BinaryIO, expected: PackFile) -> None:
    digest, size = hashlib.sha256(), 0
    for block in iter(lambda: source.read(CHUNK), b""):
        size += len(block)
        if size > expected.size:
            raise PackError(f"entry exceeds catalogue byte count: {expected.path}")
        digest.update(block)
        target.write(block)
    if size != expected.size or digest.hexdigest() != expected.sha256:
        raise PackError(f"bytes/SHA256 mismatch: {expected.path}")


def publish_no_replace(temp: Path, destination: Path) -> None:
    """Publish a completed artifact without replacing an existing different file."""
    if destination.exists():
        if not destination.is_file() or digest_file(destination) != digest_file(temp):
            raise PackError(f"refusing to replace conflicting output: {destination}")
        return
    # Linking in the same output directory is atomic and fails if another writer
    # wins the filename. This never links to or changes an original source file.
    try:
        os.link(temp, destination)
    except FileExistsError as error:
        raise PackError(f"output appeared during publish: {destination}") from error


def build_pack(
    root: Path,
    output: Path,
    descriptor: Path | None = None,
    counts: ExpectedCounts = EXPECTED,
) -> dict:
    index = load_pack(root, counts)
    output = output.resolve()
    descriptor = (descriptor or output.with_suffix(".descriptor.json")).resolve()
    if output.is_relative_to(root.resolve()) or descriptor.is_relative_to(root.resolve()):
        raise PackError("build outputs must be outside the unchanged source pack")
    if output == descriptor:
        raise PackError("archive and descriptor output must be different files")
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary_name = tempfile.mkstemp(prefix=".posehub-build-", dir=output.parent)
    os.close(handle)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_STORED) as archive:
            for name in sorted(index.files):
                row = index.files[name]
                info = zipfile.ZipInfo(name, FIXED_ZIP_TIME)
                info.compress_type = zipfile.ZIP_STORED
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                info.file_size = row.size
                with inside(root, name).open("rb") as source, archive.open(info, "w") as target:
                    copy_verified(source, target, row)
        result = {
            "format": "ugk-posehub-pack-descriptor@1",
            **index.summary(),
            "archive": {
                "name": output.name,
                "format": "zip",
                "compression": "stored",
                "bytes": temporary.stat().st_size,
                "sha256": digest_file(temporary),
                "entries": len(index.files),
            },
            "sourceCommit": index.catalog.get("sourceCommit"),
            "files": {
                name: {"bytes": index.files[name].size, "sha256": index.files[name].sha256}
                for name in METADATA_PATHS
            },
        }
        publish_no_replace(temporary, output)
        blob = (json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
        descriptor_temp = None
        try:
            with tempfile.NamedTemporaryFile(
                prefix=".posehub-descriptor-", dir=descriptor.parent, delete=False
            ) as target:
                descriptor_temp = Path(target.name)
                target.write(blob)
            publish_no_replace(descriptor_temp, descriptor)
        finally:
            if descriptor_temp is not None:
                descriptor_temp.unlink(missing_ok=True)
        return result
    finally:
        temporary.unlink(missing_ok=True)


class NullWriter:
    def write(self, block: bytes) -> int:
        return len(block)


def inspect_zip(archive: zipfile.ZipFile, counts: ExpectedCounts) -> PackIndex:
    names, folded = set(), set()
    infos = archive.infolist()
    for info in infos:
        name = checked_relative(info.orig_filename)
        if name != info.filename or name in names or name.casefold() in folded:
            raise PackError(f"duplicate or altered ZIP entry: {name}")
        names.add(name)
        folded.add(name.casefold())
        file_type = stat.S_IFMT(info.external_attr >> 16)
        if info.is_dir() or file_type not in (0, stat.S_IFREG):
            raise PackError(f"non-regular ZIP entry: {name}")
        if info.flag_bits & 1 or info.compress_type != zipfile.ZIP_STORED:
            raise PackError(f"encrypted/compressed entry is not an original stored pack: {name}")
    metadata = {}
    for name in METADATA_PATHS:
        if name not in names or archive.getinfo(name).file_size > MAX_METADATA_BYTES:
            raise PackError(f"missing or oversized archive metadata: {name}")
        metadata[name] = archive.read(name)
    index = index_from_metadata(metadata, counts)
    unknown, missing = names - index.files.keys(), index.files.keys() - names
    if unknown or missing:
        raise PackError(f"ZIP allowlist mismatch; unknown={sorted(unknown)[:5]}, missing={sorted(missing)[:5]}")
    # Verify every entry before creating or touching the install target.
    for info in infos:
        expected = index.files[info.filename]
        if info.file_size != expected.size:
            raise PackError(f"ZIP entry size mismatch: {info.filename}")
        with archive.open(info) as source:
            copy_verified(source, NullWriter(), expected)
    return index


def install_target(root: Path, name: str) -> Path:
    path = inside(root, name)
    # A cached pack is a directory of regular files, never an alias into another
    # install. Refuse symbolic links/junctions even when they point inside root.
    for part in (path, *path.parents):
        if part == root.resolve().parent:
            break
        if part.is_symlink() or (hasattr(part, "is_junction") and part.is_junction()):
            raise PackError(f"install path contains a link/junction: {name}")
    return path


def install_pack(
    archive_path: Path,
    destination: Path,
    expected_sha256: str,
    counts: ExpectedCounts = EXPECTED,
) -> dict:
    expected_sha256 = checked_sha(expected_sha256, "archive")
    if digest_file(archive_path) != expected_sha256:
        raise PackError("archive SHA256 mismatch; nothing installed")
    destination = destination.absolute()
    if destination.is_symlink() or (
        hasattr(destination, "is_junction") and destination.is_junction()
    ):
        raise PackError("install target must not be a link/junction")
    if destination.exists() and not destination.is_dir():
        raise PackError("install target exists and is not a directory")
    reused, missing = [], []
    with zipfile.ZipFile(archive_path) as archive:
        index = inspect_zip(archive, counts)
        for name in sorted(index.files):
            path = install_target(destination, name)
            if path.exists():
                verify_file(path, index.files[name])
                reused.append(name)
            else:
                missing.append(name)
        if not missing:
            return {**index.summary(), "installedFiles": 0, "reusedFiles": len(reused)}
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".posehub-install-", dir=destination.parent) as folder:
            staging = Path(folder).resolve()
            if not staging.is_relative_to(destination.parent.resolve()):
                raise PackError("unexpected install staging location")
            for name in missing:
                target = inside(staging, name)
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(name) as source, target.open("xb") as output:
                    copy_verified(source, output, index.files[name])
            installed = 0
            destination.mkdir(parents=True, exist_ok=True)
            for name in missing:
                target = install_target(destination, name)
                target.parent.mkdir(parents=True, exist_ok=True)
                try:
                    output = target.open("xb")
                except FileExistsError:
                    verify_file(target, index.files[name])
                    reused.append(name)
                    continue
                try:
                    with output, inside(staging, name).open("rb") as source:
                        copy_verified(source, output, index.files[name])
                except BaseException:
                    # Only this newly-created file is removed, never preexisting
                    # content; already-installed verified files remain reusable.
                    target.unlink(missing_ok=True)
                    raise
                installed += 1
        return {**index.summary(), "installedFiles": installed, "reusedFiles": len(reused)}


def byte_range(header: str | None, size: int) -> tuple[int, int] | None:
    if header is None:
        return None
    match = re.fullmatch(r"bytes=(\d*)-(\d*)", header.strip())
    if match is None or size <= 0:
        raise PackError("only one valid bytes range is supported")
    first, last = match.groups()
    if not first:
        if not last or int(last) <= 0:
            raise PackError("invalid suffix range")
        return max(0, size - int(last)), size - 1
    start = int(first)
    end = min(int(last), size - 1) if last else size - 1
    if start >= size or end < start:
        raise PackError("range is unsatisfiable")
    return start, end


def make_server(
    web_root: Path, pack_root: Path, port: int = 7362, counts: ExpectedCounts = EXPECTED
) -> ThreadingHTTPServer:
    web_root, pack_root = web_root.resolve(), pack_root.resolve()
    if not (web_root / "index.html").is_file():
        raise PackError("web root must contain the existing Flutter build index.html")
    index = load_pack(pack_root, counts)
    prefix = "/__posehub_pack__/"

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self) -> None:
            self.respond(False)

        def do_HEAD(self) -> None:
            self.respond(True)

        def respond(self, head: bool) -> None:
            try:
                parsed = urlsplit(self.path)
                if parsed.scheme or parsed.netloc or not parsed.path.startswith("/"):
                    raise PackError("expected an origin-relative path")
                request_path = unquote(parsed.path, errors="strict")
                expected = None
                if request_path.startswith(prefix):
                    name = checked_relative(request_path[len(prefix):])
                    expected = index.files.get(name)
                    if expected is None:
                        self.send_error(404, "Not in catalogue allowlist")
                        return
                    path = inside(pack_root, name)
                else:
                    name = request_path.lstrip("/") or "index.html"
                    path = inside(web_root, checked_relative(name))
                if not path.is_file():
                    self.send_error(404, "File not found")
                    return
                with path.open("rb") as source:
                    file_stat = os.fstat(source.fileno())
                    size = file_stat.st_size
                    if expected is not None and size != expected.size:
                        self.send_error(409, "Pack changed; restart after verification")
                        return
                    etag = '"' + (expected.sha256 if expected else f"{file_stat.st_mtime_ns:x}-{size:x}") + '"'
                    range_headers = self.headers.get_all("Range", [])
                    if len(range_headers) > 1:
                        raise PackError("multiple Range headers are unsupported")
                    header = range_headers[0] if range_headers else None
                    if self.headers.get("If-Range") not in (None, etag):
                        header = None
                    try:
                        selected = byte_range(header, size)
                    except PackError:
                        self.send_response(416)
                        self.send_header("Content-Range", f"bytes */{size}")
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    start, end = selected if selected else (0, size - 1)
                    length = end - start + 1
                    self.send_response(206 if selected else 200)
                    content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
                    if path.suffix in (".json", ".js", ".html", ".css"):
                        content_type += "; charset=utf-8"
                    self.send_header("Content-Type", content_type)
                    self.send_header("Content-Length", str(length))
                    self.send_header("Accept-Ranges", "bytes")
                    self.send_header("ETag", etag)
                    self.send_header("X-Content-Type-Options", "nosniff")
                    self.send_header("Cache-Control", "no-cache")
                    if selected:
                        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                    self.end_headers()
                    if head:
                        return
                    source.seek(start)
                    remaining = length
                    while remaining:
                        block = source.read(min(CHUNK, remaining))
                        if not block:
                            break
                        self.wfile.write(block)
                        remaining -= len(block)
            except (PackError, UnicodeError, ValueError):
                self.send_error(400, "Unsafe or malformed path/request")
            except (BrokenPipeError, ConnectionResetError):
                pass
            except OSError:
                self.send_error(404, "File unavailable")

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    server.pack_index = index
    return server


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    verify = commands.add_parser("verify", help="verify the catalogue's exact 657 media files")
    verify.add_argument("--pack", type=Path, required=True)
    build = commands.add_parser("build", help="write the deterministic stored whole-pack ZIP")
    build.add_argument("--pack", type=Path, required=True)
    build.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    build.add_argument("--descriptor", type=Path)
    install = commands.add_parser("install", help="verify and install without replacing existing files")
    install.add_argument("--archive", type=Path, required=True)
    install.add_argument("--destination", type=Path, required=True)
    install.add_argument("--sha256", required=True, help="trusted expected SHA256 of the archive")
    serve = commands.add_parser("serve", help="serve the existing Flutter build and same-origin pack")
    serve.add_argument("--web-root", type=Path, required=True)
    serve.add_argument("--pack", type=Path, required=True)
    serve.add_argument("--port", type=int, default=7362)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "verify":
            result = load_pack(args.pack).summary()
        elif args.command == "build":
            result = build_pack(args.pack, args.output, args.descriptor)
        elif args.command == "install":
            result = install_pack(args.archive, args.destination, args.sha256)
        else:
            server = make_server(args.web_root, args.pack, args.port)
            print(json.dumps({"url": f"http://127.0.0.1:{server.server_port}/", **server.pack_index.summary()}, ensure_ascii=False), flush=True)
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
            finally:
                server.server_close()
            return 0
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (PackError, OSError, zipfile.BadZipFile) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
