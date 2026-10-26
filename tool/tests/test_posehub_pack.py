import copy
import hashlib
import http.client
import importlib.util
import json
from pathlib import Path
import stat
import sys
import tempfile
import threading
import unittest
from unittest import mock
from urllib.parse import quote
import warnings
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "posehub_pack.py"
SPEC = importlib.util.spec_from_file_location("posehub_pack", SCRIPT)
pack = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = pack
SPEC.loader.exec_module(pack)
COUNTS = pack.ExpectedCounts(actions=2, complete=1, pending=1)


def encoded(obj):
    return (json.dumps(obj, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def write_metadata(root, actions):
    semantics = b'{"version":"fixture","note":"keep CRLF bytes"}\r\n'
    catalog = {
        "id": pack.PACK_ID,
        "format": "pose-hub-app-test-catalog@1",
        "status": "test-unreviewed",
        "reviewed": False,
        "releaseEligible": False,
        "sourceCommit": "fixture-source",
        "semanticCatalog": {
            "path": "catalog/catalog.json",
            "bytes": len(semantics),
            "sha256": pack.digest_bytes(semantics),
        },
        "actions": actions,
        "trainingSemantics": {
            "definitionCompleteCount": sum(a["trainingDefinitionComplete"] for a in actions),
            "definitionCompleteIds": [a["id"] for a in actions if a["trainingDefinitionComplete"]],
            "incompleteActionIds": [a["id"] for a in actions if not a["trainingDefinitionComplete"]],
        },
    }
    catalog_blob = encoded(catalog)
    manifest = {
        "id": pack.PACK_ID,
        "format": "pose-hub-stacked-alpha-delivery@1",
        "catalog": {
            "path": "catalog/snapshots/original.json",
            "bytes": len(catalog_blob),
            "sha256": pack.digest_bytes(catalog_blob),
        },
        "actions": [{"id": a["id"], "files": a["files"]} for a in actions],
    }
    blobs = {
        "catalog.json": catalog_blob,
        "manifest.json": encoded(manifest),
        "catalog/catalog.json": semantics,
    }
    for name, blob in blobs.items():
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(blob)
    return blobs


def make_fixture(root, action_flags=None):
    actions = []
    for action_id, complete in action_flags or [("demo-A", True), ("pending-B", False)]:
        files = {}
        for role, suffix in [("video", "rgb-alpha.mp4"), ("cover", "cover.webp"), ("thumbnail", "thumb.webp")]:
            name = f"media/{action_id}/{action_id}.{suffix}"
            blob = (action_id + "/" + role + "/0123456789").encode()
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(blob)
            files[role] = {"path": name, "bytes": len(blob), "sha256": pack.digest_bytes(blob)}
        actions.append({
            "id": action_id,
            "nameZh": "原样动作" if complete else "待补动作",
            "trainingDefinitionComplete": complete,
            "availableForTraining": complete,
            "availableForApp": True,
            "trainingSemantics": {
                "definitionComplete": complete,
                "status": "complete-unreviewed" if complete else "partial-unreviewed",
                "missingRequiredFields": [] if complete else ["level"],
                "unknownFields": [] if complete else [{"field": "level", "reason": "unknown"}],
            },
            "level": 1 if complete else None,
            "files": files,
        })
    write_metadata(root, actions)
    (root / "media/old-unused.mp4").write_bytes(b"historical media must stay outside ZIP")
    return actions


class PackToolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.source = self.base / "source"
        self.source.mkdir()
        self.actions = make_fixture(self.source)
        self.archive = self.base / "release/pack.zip"

    def tearDown(self):
        self.temp.cleanup()

    def build(self):
        return pack.build_pack(self.source, self.archive, counts=COUNTS)

    def semantic_overlay(self):
        """Keep the base manifest/canonical bytes and replace only the catalogue."""
        original = {name: (self.source / name).read_bytes() for name in pack.METADATA_PATHS}
        catalog = json.loads(original["catalog.json"])
        catalog["actions"][0]["availableForTraining"] = False
        catalog["actions"][0]["defaultDose"] = {
            "mode": "reps", "sets": 1, "reps": 6, "restSeconds": 10,
        }
        catalog["actions"][0]["trainingSemantics"]["unknownFields"] = [
            {"field": "contraindications", "reason": "optional, unreviewed"},
        ]
        catalog["trainingSemantics"]["sourceCatalog"] = {
            "bytes": len(original["catalog.json"]),
            "sha256": pack.digest_bytes(original["catalog.json"]),
        }
        catalog["trainingSemantics"]["sourceManifest"] = {
            "bytes": len(original["manifest.json"]),
            "sha256": pack.digest_bytes(original["manifest.json"]),
        }
        blob = encoded(catalog)
        (self.source / "catalog.json").write_bytes(blob)
        return pack.digest_bytes(blob), original

    def test_verify_counts_hashes_and_semantic_flags_without_defaults(self):
        index = pack.load_pack(self.source, COUNTS)
        self.assertEqual((index.complete_count, index.pending_count), (1, 1))
        self.assertEqual(index.catalog["actions"][1]["level"], None)
        self.assertEqual(index.summary()["mediaFiles"], 6)
        self.assertEqual(index.summary()["archiveEntries"], 9)
        self.assertFalse(index.catalog["reviewed"])

    def test_duplicate_ids_are_rejected_including_windows_case_aliases(self):
        for alias in ["demo-A", "DEMO-a"]:
            with self.subTest(alias=alias):
                changed = copy.deepcopy(self.actions)
                changed[1]["id"] = alias
                write_metadata(self.source, changed)
                with self.assertRaisesRegex(pack.PackError, "duplicate"):
                    pack.load_pack(self.source, COUNTS)

    def test_conflicting_semantic_flags_are_rejected(self):
        changed = copy.deepcopy(self.actions)
        changed[1]["availableForTraining"] = True
        write_metadata(self.source, changed)
        with self.assertRaisesRegex(pack.PackError, "flags disagree"):
            pack.load_pack(self.source, COUNTS)

    def test_only_exact_approved_catalogue_can_overlay_frozen_semantic_flags(self):
        trusted_sha, _ = self.semantic_overlay()
        with self.assertRaisesRegex(pack.PackError, "flags disagree"):
            pack.load_pack(self.source, COUNTS)
        with mock.patch.object(pack, "APPROVED_SEMANTICS_V2_SHA256", trusted_sha):
            index = pack.load_pack(self.source, COUNTS)
            self.assertEqual((index.complete_count, index.pending_count), (1, 1))
            self.assertFalse(index.catalog["actions"][0]["availableForTraining"])
            catalog = json.loads((self.source / "catalog.json").read_bytes())
            catalog["actions"][0]["nameZh"] += "tampered"
            (self.source / "catalog.json").write_bytes(encoded(catalog))
            with self.assertRaisesRegex(pack.PackError, "flags disagree"):
                pack.load_pack(self.source, COUNTS)

    def test_approved_overlay_keeps_and_verifies_the_original_manifest_bytes(self):
        trusted_sha, original = self.semantic_overlay()
        with mock.patch.object(pack, "APPROVED_SEMANTICS_V2_SHA256", trusted_sha):
            desc = self.build()
            with zipfile.ZipFile(self.archive) as archive:
                self.assertEqual(archive.read("manifest.json"), original["manifest.json"])
                self.assertEqual(archive.read("catalog/catalog.json"), original["catalog/catalog.json"])
                self.assertNotEqual(archive.read("catalog.json"), original["catalog.json"])
            dest = self.base / "installed-overlay"
            installed = pack.install_pack(self.archive, dest, desc["archive"]["sha256"], COUNTS)
            self.assertEqual(installed["installedFiles"], 9)
            self.assertEqual((dest / "manifest.json").read_bytes(), original["manifest.json"])
            (self.source / "manifest.json").write_bytes(original["manifest.json"] + b" ")
            with self.assertRaisesRegex(pack.PackError, "frozen source"):
                pack.load_pack(self.source, COUNTS)

    def test_overlay_rejects_wrong_base_reference_even_with_a_trusted_catalogue(self):
        self.semantic_overlay()
        catalog = json.loads((self.source / "catalog.json").read_bytes())
        catalog["trainingSemantics"]["sourceCatalog"]["sha256"] = "0" * 64
        blob = encoded(catalog)
        (self.source / "catalog.json").write_bytes(blob)
        with mock.patch.object(pack, "APPROVED_SEMANTICS_V2_SHA256", pack.digest_bytes(blob)):
            with self.assertRaisesRegex(pack.PackError, "frozen source"):
                pack.load_pack(self.source, COUNTS)

    def test_overlay_still_rejects_definition_disagreement_and_missing_numeric_dose(self):
        for mutation, message in (
            (lambda a: a["trainingSemantics"].update(definitionComplete=False), "flags disagree"),
            (lambda a: a["defaultDose"].update(reps=None), "invalid reps dose"),
            (lambda a: a["trainingSemantics"].update(missingRequiredFields=["level"]), "semantic gaps"),
        ):
            with self.subTest(message=message):
                write_metadata(self.source, self.actions)
                self.semantic_overlay()
                catalog = json.loads((self.source / "catalog.json").read_bytes())
                mutation(catalog["actions"][0])
                blob = encoded(catalog)
                (self.source / "catalog.json").write_bytes(blob)
                with mock.patch.object(pack, "APPROVED_SEMANTICS_V2_SHA256", pack.digest_bytes(blob)):
                    with self.assertRaisesRegex(pack.PackError, message):
                        pack.load_pack(self.source, COUNTS)

    def test_summary_id_order_duplicates_and_substitutions_are_rejected(self):
        actions = make_fixture(
            self.source,
            [("one", True), ("two", True), ("three", False), ("four", False)],
        )
        counts = pack.ExpectedCounts(actions=4, complete=2, pending=2)
        catalog = json.loads((self.source / "catalog.json").read_bytes())

        def load_changed():
            blob = encoded(catalog)
            (self.source / "catalog.json").write_bytes(blob)
            manifest = json.loads((self.source / "manifest.json").read_bytes())
            manifest["catalog"].update(bytes=len(blob), sha256=pack.digest_bytes(blob))
            (self.source / "manifest.json").write_bytes(encoded(manifest))
            return pack.load_pack(self.source, counts)

        self.assertEqual(load_changed().complete_count, 2)
        for field, expected_ids in (
            ("definitionCompleteIds", ["one", "two"]),
            ("incompleteActionIds", ["three", "four"]),
        ):
            for ids in (
                list(reversed(expected_ids)),
                [expected_ids[0], expected_ids[0]],
                [expected_ids[0], expected_ids[0].upper()],
                [expected_ids[0], "unrelated"],
            ):
                with self.subTest(field=field, ids=ids):
                    catalog["trainingSemantics"]["definitionCompleteIds"] = ["one", "two"]
                    catalog["trainingSemantics"]["incompleteActionIds"] = ["three", "four"]
                    catalog["trainingSemantics"][field] = ids
                    with self.assertRaisesRegex(pack.PackError, "duplicate or mismatched"):
                        load_changed()
        self.assertEqual(len(actions), 4)

    def test_default_counts_select_new_pack_and_recognize_the_exact_legacy_catalogue(self):
        self.assertEqual(pack.EXPECTED, pack.ExpectedCounts(actions=219, complete=211, pending=8))
        with self.assertRaisesRegex(pack.PackError, "approved exact catalogue"):
            pack.load_pack(self.source)
        with self.assertRaisesRegex(pack.PackError, "approved exact catalogue"):
            pack.load_pack(self.source, pack.EXPECTED)
        legacy_sha = pack.digest_file(self.source / "catalog.json")
        with mock.patch.object(pack, "LEGACY_CATALOG_SHA256", legacy_sha), mock.patch.object(
            pack, "LEGACY_EXPECTED", COUNTS
        ):
            self.assertEqual(pack.load_pack(self.source).complete_count, 1)
            desc = pack.build_pack(self.source, self.archive)
            dest = self.base / "installed-legacy"
            self.assertEqual(pack.install_pack(self.archive, dest, desc["archive"]["sha256"])["installedFiles"], 9)

    def test_missing_file_and_same_size_hash_corruption_are_rejected(self):
        video = self.source / self.actions[0]["files"]["video"]["path"]
        original = video.read_bytes()
        video.write_bytes(b"x" * len(original))
        with self.assertRaisesRegex(pack.PackError, "SHA256"):
            pack.load_pack(self.source, COUNTS)
        video.unlink()
        with self.assertRaisesRegex(pack.PackError, "missing"):
            pack.load_pack(self.source, COUNTS)

    def test_build_is_deterministic_stored_and_keeps_exact_metadata_bytes(self):
        first = self.build()
        other = self.base / "other.zip"
        second = pack.build_pack(self.source, other, counts=COUNTS)
        self.assertEqual(first["archive"]["sha256"], second["archive"]["sha256"])
        self.assertEqual(self.archive.read_bytes(), other.read_bytes())
        self.assertEqual(first["archive"]["entries"], 9)
        with zipfile.ZipFile(self.archive) as archive:
            self.assertEqual(archive.namelist(), sorted(archive.namelist()))
            self.assertNotIn("media/old-unused.mp4", archive.namelist())
            for info in archive.infolist():
                self.assertEqual(info.compress_type, zipfile.ZIP_STORED)
                self.assertEqual(info.date_time, pack.FIXED_ZIP_TIME)
                self.assertEqual(archive.read(info), (self.source / info.filename).read_bytes())
        self.assertEqual(self.build(), first)  # exact output is reusable

    def test_build_refuses_to_change_source_or_conflicting_outputs(self):
        with self.assertRaisesRegex(pack.PackError, "outside"):
            pack.build_pack(self.source, self.source / "pack.zip", counts=COUNTS)
        self.archive.parent.mkdir()
        self.archive.write_bytes(b"unrelated existing file")
        with self.assertRaisesRegex(pack.PackError, "conflicting output"):
            self.build()
        self.assertEqual(self.archive.read_bytes(), b"unrelated existing file")

    def test_install_verifies_all_and_reuses_existing_identical_files(self):
        desc = self.build()
        dest = self.base / "installed"
        first = pack.install_pack(self.archive, dest, desc["archive"]["sha256"], COUNTS)
        self.assertEqual((first["installedFiles"], first["reusedFiles"]), (9, 0))
        index = pack.load_pack(dest, COUNTS)
        times = {name: (dest / name).stat().st_mtime_ns for name in index.files}
        again = pack.install_pack(self.archive, dest, desc["archive"]["sha256"], COUNTS)
        self.assertEqual((again["installedFiles"], again["reusedFiles"]), (0, 9))
        self.assertEqual(times, {name: (dest / name).stat().st_mtime_ns for name in index.files})
        self.assertFalse((dest / "media/old-unused.mp4").exists())

    def test_install_wrong_archive_hash_does_not_create_target(self):
        self.build()
        dest = self.base / "installed"
        with self.assertRaisesRegex(pack.PackError, "archive SHA256"):
            pack.install_pack(self.archive, dest, "0" * 64, COUNTS)
        self.assertFalse(dest.exists())

    def test_install_conflict_is_detected_before_writing_any_missing_files(self):
        desc = self.build()
        dest = self.base / "installed"
        conflict = dest / self.actions[0]["files"]["video"]["path"]
        conflict.parent.mkdir(parents=True)
        conflict.write_bytes(b"user data")
        with self.assertRaises(pack.PackError):
            pack.install_pack(self.archive, dest, desc["archive"]["sha256"], COUNTS)
        self.assertEqual(conflict.read_bytes(), b"user data")
        self.assertFalse((dest / "catalog.json").exists())

    def test_install_rejects_unknown_duplicate_slip_and_link_entries(self):
        self.build()
        original = self.archive.read_bytes()
        variants = [
            ("../escape.txt", False),
            ("media/old-unused.mp4", False),
            ("catalog.json", False),
            ("media/symlink", True),
        ]
        for name, is_link in variants:
            with self.subTest(name=name):
                self.archive.write_bytes(original)
                info = zipfile.ZipInfo(name, pack.FIXED_ZIP_TIME)
                info.create_system = 3
                info.external_attr = ((stat.S_IFLNK if is_link else stat.S_IFREG) | 0o644) << 16
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    with zipfile.ZipFile(self.archive, "a") as archive:
                        archive.writestr(info, b"untrusted")
                dest = self.base / "installed"
                with self.assertRaises(pack.PackError):
                    pack.install_pack(self.archive, dest, pack.digest_file(self.archive), COUNTS)
                self.assertFalse(dest.exists())
                self.assertFalse((self.base / "escape.txt").exists())

    def test_install_rejects_valid_zip_crc_with_wrong_catalogue_file_hash(self):
        self.build()
        corrupt = self.base / "corrupt.zip"
        video = self.actions[0]["files"]["video"]["path"]
        with zipfile.ZipFile(self.archive) as source, zipfile.ZipFile(corrupt, "w") as target:
            for info in source.infolist():
                blob = source.read(info)
                target.writestr(info, b"x" * len(blob) if info.filename == video else blob)
        dest = self.base / "installed"
        with self.assertRaisesRegex(pack.PackError, "SHA256"):
            pack.install_pack(corrupt, dest, pack.digest_file(corrupt), COUNTS)
        self.assertFalse(dest.exists())

    def test_path_validation_rejects_windows_aliases(self):
        for value in ["/absolute", "../escape", "media/../escape", "media\\file", "C:/file", "media/CON.mp4", "media/x.", "media/%2e%2e/x"]:
            with self.subTest(value=value), self.assertRaises(pack.PackError):
                pack.checked_relative(value)


class PackServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.source = self.base / "source"
        self.source.mkdir()
        self.actions = make_fixture(self.source)
        self.web = self.base / "web"
        self.web.mkdir()
        (self.web / "index.html").write_bytes(b"existing Flutter build")
        (self.base / "outside-secret.txt").write_bytes(b"must not be served")
        self.log_patch = mock.patch.object(pack.BaseHTTPRequestHandler, "log_message", lambda *args: None)
        self.log_patch.start()
        self.server = pack.make_server(self.web, self.source, 0, COUNTS)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.log_patch.stop()
        self.temp.cleanup()

    def request(self, path, method="GET", headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        conn.request(method, path, headers=headers or {})
        response = conn.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        conn.close()
        return result

    def test_serves_existing_web_and_only_catalogue_pack_allowlist(self):
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        self.assertEqual(self.request("/")[2], b"existing Flutter build")
        for name in pack.METADATA_PATHS:
            result = self.request("/__posehub_pack__/" + quote(name))
            self.assertEqual(result[0], 200)
            self.assertEqual(result[2], (self.source / name).read_bytes())
        self.assertEqual(self.request("/__posehub_pack__/media/old-unused.mp4")[0], 404)
        self.assertEqual(self.request("/__posehub_pack__/manifest-secret.json")[0], 404)

    def test_get_head_and_single_ranges(self):
        name = self.actions[0]["files"]["video"]["path"]
        path = "/__posehub_pack__/" + quote(name)
        full = (self.source / name).read_bytes()
        status, headers, body = self.request(path)
        self.assertEqual((status, body), (200, full))
        self.assertEqual(headers["Content-Type"], "video/mp4")
        status, headers, body = self.request(path, method="HEAD")
        self.assertEqual((status, body), (200, b""))
        self.assertEqual(int(headers["Content-Length"]), len(full))
        for value, expected in [("bytes=2-5", full[2:6]), ("bytes=6-", full[6:]), ("bytes=-3", full[-3:])]:
            with self.subTest(range=value):
                status, headers, body = self.request(path, headers={"Range": value})
                self.assertEqual((status, body), (206, expected))
                self.assertEqual(int(headers["Content-Length"]), len(expected))
                self.assertEqual(headers["Accept-Ranges"], "bytes")
        status, headers, body = self.request(path, method="HEAD", headers={"Range": "bytes=2-5"})
        self.assertEqual((status, body), (206, b""))
        self.assertEqual(headers["Content-Range"], f"bytes 2-5/{len(full)}")
        self.assertEqual(headers["Content-Length"], "4")
        for value in ["bytes=999-", "bytes=4-2", "bytes=0-1,3-4", "items=1-2", "bytes=-0"]:
            with self.subTest(range=value):
                status, headers, body = self.request(path, headers={"Range": value})
                self.assertEqual((status, body), (416, b""))
                self.assertEqual(headers["Content-Range"], f"bytes */{len(full)}")

    def test_encoded_traversal_backslash_and_static_escape_are_rejected(self):
        for path in [
            "/__posehub_pack__/%2e%2e/outside-secret.txt",
            "/__posehub_pack__/media%5cfile",
            "/%2e%2e/outside-secret.txt",
            "/__posehub_pack__/C%3a/file",
        ]:
            with self.subTest(path=path):
                status, _, body = self.request(path)
                self.assertEqual(status, 400)
                self.assertNotEqual(body, b"must not be served")


if __name__ == "__main__":
    unittest.main()
