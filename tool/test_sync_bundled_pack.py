"""Offline checks for bundle replacement and its read-only release gate."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from sync_bundled_pack import ASSETS, CHANNEL_BASE, LIBRARY, PUBSPEC, SyncError, sync


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
        self.catalog = json.dumps({
            "pack": "r2-v7",
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
        }

    def snapshot(self):
        return {str(path.relative_to(self.root)): path.read_bytes()
                for path in self.root.rglob("*") if path.is_file()}

    def test_sync_replaces_catalogues_and_keeps_referenced_standing_images(self):
        self.assertEqual(sync(self.root, "beta", fetch=self.objects.__getitem__), 0)
        target = self.root / ASSETS / "app-pack-r2-v7"
        self.assertEqual((target / "catalog.json").read_bytes(), self.catalog)
        self.assertEqual((target / "catalog/catalog.json").read_bytes(), self.semantic)
        self.assertFalse((self.root / ASSETS / "app-pack-r2-v2").exists())
        self.assertEqual((self.root / ASSETS / "app-pack-r2-v1/standing/example.webp").read_bytes(), b"original")
        self.assertIn("packVersion = 'r2-v7'", (self.root / LIBRARY).read_text(encoding="utf-8"))
        self.assertNotIn("app-pack-r2-v2", (self.root / PUBSPEC).read_text(encoding="utf-8"))
        self.assertEqual(sync(self.root, "beta", check=True, fetch=self.objects.__getitem__), 0)

    def test_check_detects_stale_bundle_without_writing(self):
        before = self.snapshot()
        self.assertEqual(sync(self.root, "beta", check=True, fetch=self.objects.__getitem__), 1)
        self.assertEqual(self.snapshot(), before)

    def test_corrupt_downloads_do_not_modify_existing_bundle(self):
        for url in (self.pointer["catalog"], "https://media.example/pack/r2-v7/catalog/catalog.json"):
            with self.subTest(url=url):
                objects = {**self.objects, url: b"corrupt"}
                before = self.snapshot()
                with self.assertRaises(SyncError):
                    sync(self.root, "beta", fetch=objects.__getitem__)
                self.assertEqual(self.snapshot(), before)

    def test_catalogue_byte_drift_is_rejected_even_with_unchanged_constants(self):
        sync(self.root, "beta", fetch=self.objects.__getitem__)
        path = self.root / ASSETS / "app-pack-r2-v7/catalog/catalog.json"
        path.write_bytes(b"outdated semantic catalogue")
        before = self.snapshot()
        self.assertEqual(sync(self.root, "beta", check=True, fetch=self.objects.__getitem__), 1)
        self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    unittest.main()
