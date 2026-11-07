"""Offline checks for bundle replacement and its read-only release gate."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from sync_bundled_pack import ASSETS, CHANNEL_BASE, LIBRARY, PUBSPEC, SyncError, sync
from bundled_standing import check_standing


class SyncBundledPackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ugk-bundled-pack-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        library = self.root / LIBRARY
        library.parent.mkdir(parents=True)
        library.write_text("\n".join([
            "abstract final class PoseHubActionLibrary {",
            "  static const assetRoot = 'packages/ugk_trainer/assets/pose_hub/app-pack-r2-v2/';",
            "  static const standingAssetRoot = 'packages/ugk_trainer/assets/pose_hub/app-pack-r2-v1/standing/';",
            f"  static const catalogSha256 = '{'0' * 64}';",
            "  static const packVersion = 'r2-v2';",
            "  static const catalogDownloadUri = 'https://media.example/pack/r2-v2/catalog.json';",
            "  static const mediaReleaseBaseUri = 'https://media.example/pack/r2-v1/';",
            "}",
        ]), encoding="utf-8")
        pubspec = self.root / PUBSPEC
        pubspec.parent.mkdir(parents=True)
        pubspec.write_text(
            "flutter:\n  assets:\n"
            "    - assets/pose_hub/app-pack-r2-v2/catalog.json\n"
            "    - assets/pose_hub/app-pack-r2-v2/catalog/catalog.json\n"
            "    - assets/pose_hub/app-pack-r2-v1/standing/\n",
            encoding="utf-8",
        )
        for relative in ("app-pack-r2-v2/catalog.json", "app-pack-r2-v2/catalog/catalog.json", "app-pack-r2-v1/standing/example.webp"):
            path = self.root / ASSETS / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"original")
        self.semantic = b'{"drills":[]}'
        self.video = b"verified packed video fixture"
        self.poster = (Path(__file__).parent / "fixtures/standing-alpha.webp").read_bytes()
        self.rendered = []
        self.catalog = json.dumps({
            "pack": "r2-v7",
            "actions": [{
                "id": "example", "files": {"video": {
                    "path": "media/example/r2-v7/example.rgb-alpha.mp4",
                    "downloadUrl": "https://media.example/pack/r2-v1/media/example/r2-v7/example.rgb-alpha.mp4",
                    "bytes": len(self.video), "sha256": hashlib.sha256(self.video).hexdigest(),
                }},
            }],
            "semanticCatalog": {
                "path": "catalog/catalog.json", "bytes": len(self.semantic),
                "sha256": hashlib.sha256(self.semantic).hexdigest(),
            },
            "mediaDistribution": {"baseUrl": "https://media.example/pack/r2-v1/"},
        }).encode()
        self.pointer = {
            "schema": 1, "pack": "r2-v7", "catalog": "https://media.example/pack/r2-v7/catalog.json",
            "catalog_sha256": hashlib.sha256(self.catalog).hexdigest(),
            "catalog_bytes": len(self.catalog), "min_sdk": "0.8.0",
            "published_at": "Sat 2026-11-07 12:45 AM CST (UTC+08:00)",
        }
        self.objects = {
            CHANNEL_BASE + "beta.json": json.dumps(self.pointer).encode(),
            self.pointer["catalog"]: self.catalog,
            "https://media.example/pack/r2-v7/catalog/catalog.json": self.semantic,
            "https://media.example/pack/r2-v1/media/example/r2-v7/example.rgb-alpha.mp4": self.video,
        }

    def render(self, source, ffmpeg):
        self.assertEqual(source, self.video)
        self.rendered.append(source)
        return self.poster

    def run_sync(self, **kwargs):
        return sync(self.root, "beta", fetch=self.objects.__getitem__, render=self.render, **kwargs)

    def snapshot(self):
        return {path.relative_to(self.root).as_posix(): path.read_bytes()
                for path in self.root.rglob("*") if path.is_file()}

    def test_sync_replaces_catalogues_and_standing_images_together(self):
        self.assertEqual(self.run_sync(), 0)
        target = self.root / ASSETS / "app-pack-r2-v7"
        self.assertEqual((target / "catalog.json").read_bytes(), self.catalog)
        self.assertEqual((target / "catalog/catalog.json").read_bytes(), self.semantic)
        self.assertFalse((self.root / ASSETS / "app-pack-r2-v2").exists())
        self.assertFalse((self.root / ASSETS / "app-pack-r2-v1/standing").exists())
        self.assertEqual((target / "standing/example.webp").read_bytes(), self.poster)
        index = json.loads((target / "standing/index.json").read_bytes())
        record = index["actions"]["example"]
        self.assertEqual(record["videoSha256"], hashlib.sha256(self.video).hexdigest())
        self.assertEqual(record["imageSha256"], hashlib.sha256(self.poster).hexdigest())
        self.assertEqual((index["frame"], index["width"], index["height"]), (0, 640, 640))
        self.assertIn("packVersion = 'r2-v7'", (self.root / LIBRARY).read_text(encoding="utf-8"))
        self.assertNotIn("app-pack-r2-v2", (self.root / PUBSPEC).read_text(encoding="utf-8"))
        self.assertEqual(self.run_sync(check=True), 0)

    def test_check_detects_stale_bundle_without_writing(self):
        before = self.snapshot()
        self.assertEqual(self.run_sync(check=True), 1)
        self.assertEqual(self.snapshot(), before)

    def test_corrupt_downloads_do_not_modify_existing_bundle(self):
        for url in (self.pointer["catalog"], "https://media.example/pack/r2-v7/catalog/catalog.json",
                    "https://media.example/pack/r2-v1/media/example/r2-v7/example.rgb-alpha.mp4"):
            with self.subTest(url=url):
                objects = {**self.objects, url: b"corrupt"}
                before = self.snapshot()
                with self.assertRaises(SyncError):
                    sync(self.root, "beta", fetch=objects.__getitem__, render=self.render)
                self.assertEqual(self.snapshot(), before)

    def test_catalogue_byte_drift_is_rejected_even_with_unchanged_constants(self):
        self.run_sync()
        path = self.root / ASSETS / "app-pack-r2-v7/catalog/catalog.json"
        path.write_bytes(b"outdated semantic catalogue")
        before = self.snapshot()
        self.assertEqual(self.run_sync(check=True), 1)
        self.assertEqual(self.snapshot(), before)

    def test_check_rejects_changed_media_identity_without_writing(self):
        self.run_sync()
        target = self.root / ASSETS / "app-pack-r2-v7/standing"
        index = json.loads((target / "index.json").read_bytes())
        index["actions"]["example"]["videoSha256"] = "f" * 64
        (target / "index.json").write_text(json.dumps(index), encoding="utf-8")
        before = self.snapshot()
        self.assertEqual(self.run_sync(check=True), 1)
        self.assertEqual(self.snapshot(), before)

    def test_check_rejects_missing_poster_and_incomplete_index(self):
        self.run_sync()
        target = self.root / ASSETS / "app-pack-r2-v7/standing"
        (target / "example.webp").unlink()
        before = self.snapshot()
        self.assertEqual(self.run_sync(check=True), 1)
        self.assertEqual(self.snapshot(), before)
        index = json.loads((target / "index.json").read_bytes())
        index["actions"].clear()
        (target / "index.json").write_text(json.dumps(index), encoding="utf-8")
        self.assertEqual(check_standing(target, json.loads(self.catalog), "r2-v7"),
                         [target / "index.json"])

    def test_valid_index_avoids_redecoding_and_poster_tampering_is_rejected(self):
        self.run_sync()
        self.run_sync()
        self.assertEqual(len(self.rendered), 1)
        target = self.root / ASSETS / "app-pack-r2-v7/standing/example.webp"
        target.write_bytes(b"corrupt poster")
        before = self.snapshot()
        self.assertEqual(self.run_sync(check=True), 1)
        self.assertEqual(self.snapshot(), before)

    def test_check_rejects_wrong_dimensions_even_if_digest_matches(self):
        self.run_sync()
        directory = self.root / ASSETS / "app-pack-r2-v7/standing"
        data = bytearray((directory / "example.webp").read_bytes())
        data[24:27] = (319).to_bytes(3, "little")
        (directory / "example.webp").write_bytes(data)
        index = json.loads((directory / "index.json").read_bytes())
        index["actions"]["example"]["imageSha256"] = hashlib.sha256(data).hexdigest()
        (directory / "index.json").write_text(json.dumps(index), encoding="utf-8")
        before = self.snapshot()
        self.assertEqual(self.run_sync(check=True), 1)
        self.assertEqual(self.snapshot(), before)

    def test_failed_frame_extraction_leaves_live_bundle_unchanged(self):
        def broken(source, ffmpeg):
            raise ValueError("frame extraction failed")
        before = self.snapshot()
        with self.assertRaises(SyncError):
            sync(self.root, "beta", fetch=self.objects.__getitem__, render=broken)
        # An optional source-video cache may be written, never the live assets.
        live = lambda files: {key: value for key, value in files.items()
                              if not key.startswith("build/")}
        self.assertEqual(live(self.snapshot()), live(before))


if __name__ == "__main__":
    unittest.main()
