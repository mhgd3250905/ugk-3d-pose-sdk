"""Small real-codec checks plus source/catalogue integrity regressions.

The synthetic fixtures are independent of the local F: production pack. Codec
tests explicitly skip when FFmpeg/ffprobe are absent; Pillow is a documented
dependency of the compression tool rather than of the Dart/Flutter SDK.
"""
import argparse
from fractions import Fraction
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

try:
    from PIL import Image, ImageDraw
except ImportError as error:
    raise unittest.SkipTest("compression checks require Pillow") from error


SCRIPT = Path(__file__).resolve().parents[1] / "posehub_compress.py"
SPEC = importlib.util.spec_from_file_location("posehub_compress", SCRIPT)
compress = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = compress
SPEC.loader.exec_module(compress)

RECIPE = {
    "crf": 27,
    "preset": "slow",
    "videoShortMax": 720,
    "coverMax": 640,
    "thumbnailMax": 192,
    "webpQuality": 80,
    "encoderThreads": 2,
    "packing": "rgb-top-red-alpha-bottom",
}


class _MediaFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.source = self.base / "source"
        self.output = self.base / "compressed"
        self.source.mkdir()
        self.output.mkdir()

    def make_image(self, role="cover"):
        path = self.source / f"media/demo-A/demo-A.{role}.webp"
        path.parent.mkdir(parents=True, exist_ok=True)
        image = Image.new("RGBA", (720, 720), (0, 0, 0, 0))
        ImageDraw.Draw(image).rectangle((160, 160, 560, 560), fill=(40, 120, 220, 255))
        image.save(path, "WEBP", lossless=True)
        return self.media_record(path)

    def media_record(self, path):
        return {
            "path": path.relative_to(self.source).as_posix(),
            "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }

    def receipt_path(self, record):
        key = hashlib.sha256(record["path"].encode()).hexdigest()
        return self.output / ".receipts" / f"{key}.json"


class CompressionTests(_MediaFixture):
    def test_real_webp_resizes_for_both_display_roles_without_losing_transparency(self):
        for role, expected in (("cover", 640), ("thumbnail", 192)):
            with self.subTest(role=role):
                original = self.make_image(role)
                source = self.source / original["path"]
                before = source.read_bytes()
                receipt = compress.encode_file(
                    self.source, self.output, "demo-A", role, original, dict(RECIPE)
                )
                target = self.output / original["path"]
                with Image.open(target) as decoded:
                    decoded.load()
                    self.assertEqual(decoded.format, "WEBP")
                    self.assertEqual(decoded.size, (expected, expected))
                    self.assertEqual(decoded.getchannel("A").getextrema(), (0, 255))
                    center = decoded.getpixel((expected // 2, expected // 2))
                    self.assertTrue(all(abs(actual - wanted) <= 8
                                        for actual, wanted in zip(center[:3], (40, 120, 220))))
                self.assertEqual(source.read_bytes(), before)
                self.assertEqual(receipt["bytes"], target.stat().st_size)
                self.assertEqual(receipt["sha256"], hashlib.sha256(target.read_bytes()).hexdigest())

    def test_existing_valid_receipt_reuses_output_without_reencoding(self):
        original = self.make_image()
        first = compress.encode_file(self.source, self.output, "demo-A", "cover", original, dict(RECIPE))
        target = self.output / original["path"]
        before = target.read_bytes(), target.stat().st_mtime_ns
        with mock.patch.object(Image.Image, "save", side_effect=AssertionError("unexpected re-encode")):
            again = compress.encode_file(self.source, self.output, "demo-A", "cover", original, dict(RECIPE))
        self.assertEqual(again, first)
        self.assertEqual((target.read_bytes(), target.stat().st_mtime_ns), before)

    def test_changed_output_or_recipe_cannot_be_silently_reused(self):
        original = self.make_image()
        compress.encode_file(self.source, self.output, "demo-A", "cover", original, dict(RECIPE))
        target = self.output / original["path"]
        before = target.read_bytes()
        changed_recipe = {**RECIPE, "crf": 28}
        with self.assertRaises(compress.MediaError):
            compress.encode_file(self.source, self.output, "demo-A", "cover", original, changed_recipe)
        self.assertEqual(target.read_bytes(), before)
        target.write_bytes(before + b"corrupt")
        with self.assertRaises(compress.MediaError):
            compress.encode_file(self.source, self.output, "demo-A", "cover", original, dict(RECIPE))

    def test_receipt_dimensions_cannot_override_the_real_image_dimensions(self):
        original = self.make_image()
        compress.encode_file(self.source, self.output, "demo-A", "cover", original, dict(RECIPE))
        receipt_path = self.receipt_path(original)
        receipt = json.loads(receipt_path.read_bytes())
        receipt["details"]["width"] = 1
        receipt_path.write_bytes(json.dumps(receipt).encode())
        with self.assertRaises(compress.MediaError):
            compress.encode_file(self.source, self.output, "demo-A", "cover", original, dict(RECIPE))

    def test_unreceipted_existing_output_is_preserved_and_rejected(self):
        original = self.make_image()
        target = self.output / original["path"]
        target.parent.mkdir(parents=True)
        target.write_bytes(b"not-owned-output")
        with self.assertRaises(compress.MediaError):
            compress.encode_file(self.source, self.output, "demo-A", "cover", original, dict(RECIPE))
        self.assertEqual(target.read_bytes(), b"not-owned-output")

    def test_wrong_source_hash_is_rejected_before_creating_output(self):
        original = self.make_image()
        original["sha256"] = "0" * 64
        source_bytes = (self.source / original["path"]).read_bytes()
        with self.assertRaises(compress.MediaError):
            compress.encode_file(self.source, self.output, "demo-A", "cover", original, dict(RECIPE))
        self.assertFalse((self.output / "media").exists())
        self.assertEqual((self.source / original["path"]).read_bytes(), source_bytes)

    def test_original_catalogue_hash_gate_runs_before_parsing_semantics(self):
        path = self.source / "catalog.json"
        original = b'{"actions":[]}'
        path.write_bytes(original)
        with self.assertRaisesRegex(compress.MediaError, "exact approved v2"):
            compress.source_catalog(self.source)
        self.assertEqual(path.read_bytes(), original)

    def test_escaping_and_ambiguous_paths_are_rejected(self):
        for value in ("", "../outside.webp", "/outside.webp", "media/../outside.webp",
                      r"media\demo.webp", "media//demo.webp", "media/.private/demo.webp",
                      "https://example.test/demo.webp", "media/%2e%2e/demo.webp",
                      "media/demo.webp?token=secret", "media/demo.webp#fragment"):
            with self.subTest(value=value), self.assertRaises(compress.MediaError):
                compress.inside(self.output, value)
        expected = self.output / "media/demo-A/demo-A.cover.webp"
        self.assertEqual(compress.inside(self.output, "media/demo-A/demo-A.cover.webp"), expected)

    def test_source_output_must_be_disjoint_even_before_any_encode(self):
        for output in (self.source, self.source / "nested", self.base):
            with self.subTest(output=output), self.assertRaises(compress.MediaError):
                compress.run(argparse.Namespace(source=self.source, output=output))

    def upload_fixture(self):
        files = {
            role: {"path": f"media/demo-A/demo-A.{role}.{extension}", "bytes": 1, "sha256": "1" * 64}
            for role, extension in (("video", "mp4"), ("cover", "webp"), ("thumbnail", "webp"))
        }
        catalog = {"actions": [{"id": "demo-A", "files": files}]}
        rows = [{"name": Path(f["path"]).name, "path": str(self.output / f["path"]),
                 "bytes": None, "sha256": None} for f in files.values()]
        rows.append({"name": "catalog.json", "path": str(self.output / "catalog.json"),
                     "bytes": None, "sha256": None})
        ready = rows[1]
        path = Path(ready["path"])
        path.parent.mkdir(parents=True)
        path.write_bytes(b"ready")
        ready.update(bytes=5, sha256=hashlib.sha256(b"ready").hexdigest())
        plan = {"repo": compress.REPO, "tag": compress.TAG, "assets": rows}
        plan_path = self.base / "upload-plan.json"
        compress.write_json(plan_path, plan)
        args = argparse.Namespace(source=self.source, output=self.output, crf=27, workers=2,
                                  ids="demo-A", videos_only=False, plan=plan_path, decode_check=False)
        return catalog, plan, args

    def test_resuming_upload_plan_never_reverts_a_ready_receipt_to_pending(self):
        catalog, plan, args = self.upload_fixture()
        expected = {k: plan["assets"][1][k] for k in ("bytes", "sha256")}
        writes = []
        write_json = compress.write_json

        def watch_plan(path, value):
            if path == args.plan:
                row = value["assets"][1]
                self.assertEqual({k: row[k] for k in expected}, expected)
                writes.append(True)
            write_json(path, value)

        def existing_or_encoded(source, output, action_id, role, record, recipe, count_frames=False):
            target = output / record["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists():
                target.write_bytes(b"ready")
            return {"path": record["path"], "bytes": 5,
                    "sha256": hashlib.sha256(b"ready").hexdigest(), "sourceBytes": 1}

        with mock.patch.object(compress, "source_catalog", return_value=catalog), \
                mock.patch.object(compress, "encode_file", side_effect=existing_or_encoded), \
                mock.patch.object(compress, "write_json", side_effect=watch_plan), \
                mock.patch("sys.stdout", new=io.StringIO()):
            compress.run(args)
        self.assertGreaterEqual(len(writes), 2)

    def test_resuming_rejects_changed_upload_identity_or_ready_bytes(self):
        catalog, plan, args = self.upload_fixture()
        for change in ("name", "sha256"):
            with self.subTest(change=change):
                changed = json.loads(json.dumps(plan))
                changed["assets"][1][change] = "unrelated.webp" if change == "name" else "0" * 64
                compress.write_json(args.plan, changed)
                with mock.patch.object(compress, "source_catalog", return_value=catalog), \
                        mock.patch.object(compress, "encode_file", side_effect=AssertionError("unexpected encode")), \
                        self.assertRaises(compress.MediaError):
                    compress.run(args)

    def test_catalogue_generation_preserves_all_non_media_values_and_pending_nulls(self):
        catalog = {
            "id": "synthetic-approved-source",
            "trainingSemantics": {"definitionCompleteCount": 211, "incompleteActionIds": []},
            "untouched": {"null": None, "sequence": ["retain", "order"]},
            "actions": [],
        }
        for number in range(219):
            action_id = f"demo-{number:03}"
            complete = number < 211
            files = {}
            for role, extension in (("video", "mp4"), ("cover", "webp"), ("thumbnail", "webp")):
                old = f"{action_id}:{role}:source".encode()
                files[role] = {"path": f"media/{action_id}/{action_id}.{role}.{extension}",
                               "bytes": len(old), "sha256": hashlib.sha256(old).hexdigest(),
                               "width": 720, "height": 1440 if role == "video" else 720}
            catalog["actions"].append({"id": action_id, "trainingDefinitionComplete": complete,
                "defaultDose": {"mode": "time", "sets": 1 if complete else None,
                                "seconds": 12 if complete else None},
                "cues": {"zh": ["original cue"] if complete else []}, "files": files})
            if not complete:
                catalog["trainingSemantics"]["incompleteActionIds"].append(action_id)
        original = json.dumps(catalog, ensure_ascii=False).encode()
        (self.source / "catalog.json").write_bytes(original)

        def fake_codec(source, output, action_id, role, record, recipe, count_frames=False):
            target = output / record["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            blob = f"{action_id}:{role}:compressed".encode()
            target.write_bytes(blob)
            return {"path": record["path"], "bytes": len(blob), "sha256": hashlib.sha256(blob).hexdigest(),
                    "sourceBytes": record["bytes"], "details": {
                        "width": 720 if role == "video" else (640 if role == "cover" else 192),
                        "height": 1440 if role == "video" else (640 if role == "cover" else 192)}}

        args = argparse.Namespace(source=self.source, output=self.output, crf=27, workers=2,
                                  ids=None, videos_only=False, plan=None, decode_check=False)
        with mock.patch.object(compress, "SOURCE_SHA", hashlib.sha256(original).hexdigest()), \
                mock.patch.object(compress, "encode_file", side_effect=fake_codec), \
                mock.patch("sys.stdout", new=io.StringIO()):
            compress.run(args)
        revised = json.loads((self.output / "catalog.json").read_bytes())
        self.assertEqual((self.source / "catalog.json").read_bytes(), original)
        self.assertEqual(revised["trainingSemantics"], catalog["trainingSemantics"])
        self.assertEqual(revised["untouched"], catalog["untouched"])
        self.assertEqual(len(revised["actions"]), 219)
        self.assertEqual(sum(a["trainingDefinitionComplete"] for a in revised["actions"]), 211)
        for before, after in zip(catalog["actions"], revised["actions"]):
            self.assertEqual({k: v for k, v in before.items() if k != "files"},
                             {k: v for k, v in after.items() if k != "files"})
            for role in before["files"]:
                file = after["files"][role]
                self.assertEqual(file["path"], before["files"][role]["path"])
                actual = (self.output / file["path"]).read_bytes()
                self.assertEqual((file["bytes"], file["sha256"]),
                                 (len(actual), hashlib.sha256(actual).hexdigest()))
                self.assertEqual(file["assetName"], Path(file["path"]).name)
                self.assertEqual(file["downloadUrl"], compress.BASE_URL + file["path"])


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg/ffprobe unavailable")
class RealVideoCodecTests(_MediaFixture):
    @classmethod
    def setUpClass(cls):
        encoders = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, check=True)
        if b"libx264" not in encoders.stdout:
            raise unittest.SkipTest("FFmpeg lacks libx264")

    def test_real_h264_preserves_fractional_fps_and_frames_removes_audio_and_faststarts(self):
        source = self.source / "media/demo-A/demo-A.rgb-alpha.mp4"
        source.parent.mkdir(parents=True)
        subprocess.run([
            "ffmpeg", "-hide_banner", "-v", "error", "-nostdin", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=96x96:rate=30000/1001",
            "-f", "lavfi", "-i", "color=white:size=96x96:rate=30000/1001",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
            "-filter_complex_threads", "1", "-filter_complex", "[0:v][1:v]vstack=inputs=2[v]",
            "-map", "[v]", "-map", "2:a", "-frames:v", "8", "-shortest",
            "-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high",
            "-threads", "1", "-pix_fmt", "yuv420p", "-c:a", "aac", str(source),
        ], capture_output=True, check=True)
        record = self.media_record(source)
        source_bytes = source.read_bytes()
        before = compress.probe(source, count_frames=True)
        self.assertEqual(before["audioStreams"], 1)
        receipt = compress.encode_file(self.source, self.output, "demo-A", "video",
                                       record, dict(RECIPE), count_frames=True)
        target = self.output / record["path"]
        after = compress.probe(target, count_frames=True)
        self.assertEqual(after["codec_name"], "h264")
        self.assertEqual(after["profile"], "High")
        self.assertEqual(after["codec_tag_string"], "avc1")
        self.assertEqual(after["pix_fmt"], "yuv420p")
        self.assertEqual(after["audioStreams"], 0)
        self.assertEqual((after["width"], after["height"]), (96, 192))
        self.assertEqual(int(after["nb_read_frames"]), 8)
        self.assertEqual(Fraction(after["avg_frame_rate"]), Fraction(30000, 1001))
        self.assertEqual(Fraction(after["r_frame_rate"]), Fraction(before["r_frame_rate"]))
        self.assertAlmostEqual(float(after["duration"]), float(before["duration"]), places=5)
        target_bytes = target.read_bytes()
        self.assertLess(target_bytes.index(b"moov"), target_bytes.index(b"mdat"))
        self.assertEqual(source.read_bytes(), source_bytes)
        self.assertEqual(receipt["sha256"], hashlib.sha256(target_bytes).hexdigest())
