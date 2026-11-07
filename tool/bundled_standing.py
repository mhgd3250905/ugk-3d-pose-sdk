"""Build frame-zero alpha WebP posters from verified packed RGB/alpha videos."""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import urljoin


SIDE = 640
FRAME = 0
QUALITY = 80


def image_size(data: bytes) -> tuple[int, int]:
    """Read the extended WebP dimensions and require an alpha channel."""
    if (len(data) < 30 or data[:4] != b"RIFF" or data[8:12] != b"WEBP"
            or int.from_bytes(data[4:8], "little") + 8 != len(data)
            or data[12:16] != b"VP8X" or not data[20] & 0x10):
        raise ValueError("Standing image must be an alpha WebP")
    return (1 + int.from_bytes(data[24:27], "little"),
            1 + int.from_bytes(data[27:30], "little"))


def checked_image(data: bytes) -> bytes:
    if image_size(data) != (SIDE, SIDE):
        raise ValueError(f"Standing image must be {SIDE}x{SIDE}")
    return data


def video_rows(catalog: dict) -> list[tuple[str, dict]]:
    rows = []
    seen = set()
    for action in catalog.get("actions", []):
        identity = action.get("id")
        if (not isinstance(identity, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", identity)
                or identity in seen):
            raise ValueError("Invalid or duplicate standing action ID")
        seen.add(identity)
        video = action.get("files", {}).get("video")
        if not isinstance(video, dict):
            raise ValueError(f"Missing video descriptor: {identity}")
        path = video.get("path")
        if (not isinstance(path, str) or "\\" in path or path.startswith("/")
                or any(part in ("", ".", "..") for part in path.split("/"))):
            raise ValueError(f"Invalid standing video path: {identity}")
        if (type(video.get("bytes")) is not int or video["bytes"] < 1
                or not isinstance(video.get("sha256"), str)
                or not re.fullmatch(r"[a-f0-9]{64}", video["sha256"])):
            raise ValueError(f"Invalid standing video integrity: {identity}")
        rows.append((identity, video))
    if not rows:
        raise ValueError("Cannot build standing images for an empty catalogue")
    return rows


def read_index(directory: Path) -> dict | None:
    try:
        index = json.loads((directory / "index.json").read_bytes())
        if (index.get("schema") == 1 and index.get("frame") == FRAME
                and index.get("width") == SIDE and index.get("height") == SIDE
                and isinstance(index.get("actions"), dict)):
            return index
    except (OSError, ValueError, AttributeError):
        pass
    return None


def cached_image(directory: Path, index: dict | None, identity: str,
                 video: dict) -> bytes | None:
    record = index["actions"].get(identity) if index else None
    if (not isinstance(record, dict) or record.get("videoPath") != video["path"]
            or record.get("videoSha256") != video["sha256"]):
        return None
    try:
        data = (directory / f"{identity}.webp").read_bytes()
        if (len(data) != record.get("imageBytes")
                or hashlib.sha256(data).hexdigest() != record.get("imageSha256")):
            return None
        return checked_image(data)
    except (OSError, ValueError):
        return None


def index_bytes(pack: str, images: dict[str, tuple[dict, bytes]]) -> bytes:
    index = {
        "schema": 1, "pack": pack, "frame": FRAME, "width": SIDE, "height": SIDE,
        "actions": {
            identity: {
                "videoPath": video["path"], "videoSha256": video["sha256"],
                "imageSha256": hashlib.sha256(data).hexdigest(), "imageBytes": len(data),
            }
            for identity, (video, data) in sorted(images.items())
        },
    }
    return (json.dumps(index, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def check_standing(directory: Path, catalog: dict, pack: str) -> list[Path]:
    """Verify media identity, every poster's digest/spec and exact ID coverage."""
    index = read_index(directory)
    rows = video_rows(catalog)
    if (index is None or index.get("pack") != pack
            or set(index["actions"]) != {identity for identity, _ in rows}):
        return [directory / "index.json"]
    return [directory / f"{identity}.webp" for identity, video in rows
            if cached_image(directory, index, identity, video) is None]


def decode_frame_zero(video: bytes, ffmpeg: str = "ffmpeg") -> bytes:
    # Decode exactly like audit_posehub_standing.py: top RGB, bottom RED as
    # straight alpha. Explicit RGB conversion avoids YUV-plane negotiation.
    # A seekable input also supports valid MP4s whose moov box is at the end.
    with tempfile.TemporaryDirectory(prefix="ugk-standing-") as work:
        source = Path(work) / "video.mp4"
        source.write_bytes(video)
        raw = subprocess.run([
            ffmpeg, "-v", "error", "-threads", "1", "-filter_threads", "1", "-i", str(source),
            "-vf", f"select=eq(n\\,{FRAME}),scale={SIDE}:{SIDE * 2}:flags=lanczos",
            "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
        ], capture_output=True, check=True).stdout
    pixels = SIDE * SIDE
    if len(raw) != pixels * 6:
        raise ValueError("Packed video did not decode one RGB/alpha frame")
    rgb, bottom = raw[:pixels * 3], raw[pixels * 3:]
    rgba = bytearray(pixels * 4)
    for channel in range(3):
        rgba[channel::4] = rgb[channel::3]
    rgba[3::4] = bottom[0::3]
    image = subprocess.run([
        ffmpeg, "-v", "error", "-threads", "1", "-filter_threads", "1", "-f", "rawvideo",
        "-pixel_format", "rgba", "-video_size", f"{SIDE}x{SIDE}", "-i", "pipe:0",
        "-frames:v", "1", "-c:v", "libwebp", "-quality", str(QUALITY),
        "-compression_level", "6", "-f", "webp", "pipe:1",
    ], input=rgba, capture_output=True, check=True).stdout
    return checked_image(image)


def verified_video(video: dict, media_base: str, media_roots: list[Path],
                   cache: Path, fetch) -> bytes:
    for root in media_roots:
        candidate = root / video["path"]
        if candidate.is_file():
            data = candidate.read_bytes()
            if len(data) == video["bytes"] and hashlib.sha256(data).hexdigest() == video["sha256"]:
                return data
    path = cache / f"{video['sha256']}.mp4"
    if path.is_file():
        data = path.read_bytes()
        if len(data) == video["bytes"] and hashlib.sha256(data).hexdigest() == video["sha256"]:
            return data
    url = video.get("downloadUrl") or urljoin(media_base, video["path"])
    data = fetch(url)
    if len(data) != video["bytes"] or hashlib.sha256(data).hexdigest() != video["sha256"]:
        raise ValueError(f"Standing video SHA-256/bytes mismatch: {video['path']}")
    cache.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return data


def build_standing(directory: Path, catalog: dict, pack: str, media_base: str,
                   media_roots: list[Path], cache: Path, fetch,
                   render=decode_frame_zero, ffmpeg: str = "ffmpeg") -> dict[str, bytes]:
    """Generate everything in memory before the caller changes live assets."""
    index = read_index(directory)
    rows = video_rows(catalog)

    def build(row):
        identity, video = row
        data = cached_image(directory, index, identity, video)
        if data is None:
            source = verified_video(video, media_base, media_roots, cache, fetch)
            try:
                data = checked_image(render(source, ffmpeg))
            except subprocess.CalledProcessError as error:
                raise ValueError(f"Standing frame extraction failed for {identity}: "
                                 f"{error.stderr.decode('utf-8', errors='replace')[:400]}") from error
        return identity, (video, data)

    # Keep extraction bounded; no media renderer or remote object is modified.
    with ThreadPoolExecutor(max_workers=1) as pool:
        images = dict(pool.map(build, rows))
    return {
        **{f"{identity}.webp": data for identity, (_, data) in images.items()},
        "index.json": index_bytes(pack, images),
    }
