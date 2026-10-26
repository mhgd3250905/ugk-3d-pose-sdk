"""Compare unchanged catalogue covers with decoded packed-video frame zero.

This is a read-only media audit: output images are evidence, never replacements.
Requires ffmpeg, Pillow and numpy. The packed RGB/alpha decoder follows the
catalogue's BT.709 limited-range / bottom-red straight-alpha protocol.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import subprocess

import numpy as np
from PIL import Image, ImageDraw


def decoded_frame(path: Path, index: int, side: int) -> Image.Image:
    command = [
        "ffmpeg", "-v", "error", "-threads", "1", "-i", str(path),
        "-vf", f"select=eq(n\\,{index}),scale={side}:{side * 2}:flags=lanczos",
        "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
    ]
    result = subprocess.run(command, capture_output=True, check=True)
    pixels = np.frombuffer(result.stdout, np.uint8).reshape(side * 2, side, 3)
    return Image.fromarray(np.dstack((pixels[:side], pixels[side:, :, 0])))


def compare(cover: Image.Image, frame: Image.Image) -> dict:
    left = np.asarray(cover, dtype=np.float32)
    right = np.asarray(frame, dtype=np.float32)
    left_mask = left[:, :, 3] >= 128
    right_mask = right[:, :, 3] >= 128
    union = left_mask | right_mask
    iou = float(np.count_nonzero(left_mask & right_mask) / max(1, union.sum()))
    alpha_left = left[:, :, 3:4] / 255
    alpha_right = right[:, :, 3:4] / 255
    differences = []
    for background in (255, 24):
        a = left[:, :, :3] * alpha_left + background * (1 - alpha_left)
        b = right[:, :, :3] * alpha_right + background * (1 - alpha_right)
        differences.append(float(np.abs(a - b)[union].mean()) if union.any() else 0)
    return {
        "silhouetteIoU": round(iou, 6),
        "foregroundCompositeMae": round(max(differences), 4),
    }


def audit(action: dict, root: Path, evidence: Path) -> dict:
    cover_path = root / action["files"]["cover"]["path"]
    video_path = root / action["files"]["video"]["path"]
    cover = Image.open(cover_path).convert("RGBA").resize((320, 320), Image.Resampling.LANCZOS)
    first = decoded_frame(video_path, 0, 320)
    metrics = compare(cover, first)
    # Lossy WebP and video are different encodings. Conservative thresholds
    # identify visible pose/framing differences, not byte/pixel identity.
    matches = metrics["silhouetteIoU"] >= 0.95 and metrics["foregroundCompositeMae"] <= 8
    reference_index = action.get("rhythm", {}).get("coverFrame")
    reference_metrics = None
    if reference_index is not None:
        reference = decoded_frame(video_path, reference_index, 320)
        reference_metrics = compare(cover, reference)
    sheet = Image.new("RGB", (640, 350), (245, 246, 248))
    sheet.paste(cover, (0, 28), cover)
    sheet.paste(first, (320, 28), first)
    draw = ImageDraw.Draw(sheet)
    draw.text((8, 8), f"{action['id']} - unchanged cover", fill=(20, 20, 20))
    draw.text((328, 8), "decoded video frame 0", fill=(20, 20, 20))
    sheet.save(evidence / f"{action['id']}.jpg", quality=88)
    return {
        "id": action["id"], "nameZh": action["nameZh"],
        "trainingDefinitionComplete": action["trainingDefinitionComplete"],
        "coverPath": action["files"]["cover"]["path"],
        "coverSha256": hashlib.sha256(cover_path.read_bytes()).hexdigest(),
        "declaredCoverFrame": reference_index,
        "matchesFirstFrameWithinLossyTolerance": matches,
        **metrics, "declaredCoverFrameMetrics": reference_metrics,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pack", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--workers", type=int, default=4)
    args = parser.parse_args()
    catalog_bytes = (args.pack / "catalog.json").read_bytes()
    catalog = json.loads(catalog_bytes)
    args.output.mkdir(parents=True, exist_ok=True)
    evidence = args.output / "comparisons"
    evidence.mkdir(exist_ok=True)
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        rows = list(pool.map(lambda a: audit(a, args.pack, evidence), catalog["actions"]))
    mismatches = [row for row in rows if not row["matchesFirstFrameWithinLossyTolerance"]]
    report = {
        "catalogSha256": hashlib.sha256(catalog_bytes).hexdigest(),
        "method": "Decode packed video frame 0; compare RGBA at 320 square against unchanged cover. Silhouette alpha >=128; IoU >=0.95 and foreground composite MAE <=8 on white/dark backgrounds. Lossy tolerance is an audit heuristic, not visual acceptance.",
        "total": len(rows), "mismatchCount": len(mismatches),
        "mismatchIds": [row["id"] for row in mismatches], "actions": rows,
    }
    (args.output / "standing-first-frame-audit.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    lines = [
        "# v3 standing-image / first-frame audit", "",
        f"Catalogue SHA256: `{report['catalogSha256']}`.", "",
        f"Compared {len(rows)} actions; **{len(mismatches)}** differ under the documented lossy tolerance. Original media were not changed.", "",
        report["method"], "",
        "The SDK bundles the original alpha WebP covers byte-for-byte. Where the cover differs from frame zero, a 180 ms fade preserves placement but cannot guarantee an identical pose; a source-media correction requires separate approval.", "",
        "| ID | Chinese name | Cover frame | Silhouette IoU | Foreground MAE |", "| --- | --- | ---: | ---: | ---: |",
    ]
    for row in mismatches:
        lines.append(f"| `{row['id']}` | {row['nameZh']} | {row['declaredCoverFrame']} | {row['silhouetteIoU']:.4f} | {row['foregroundCompositeMae']:.2f} |")
    (args.output / "standing-first-frame-audit.md").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(json.dumps({"total": len(rows), "mismatchCount": len(mismatches), "output": str(args.output)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
