"""APK evidence decoder and inert receipt archive tests, without Flutter builds."""
import struct
import tempfile
import unittest
from pathlib import Path

from verify_trainer_runtime_bundle import (
    DEPENDENCY_PROVENANCE_PATHS, GateError, StandardMessageDecoder,
    archive_dependency_provenance, decode_manifest, digest, read_json,
)


class ManifestDecoderTests(unittest.TestCase):
    def test_known_flutter_standard_message_manifest(self):
        # {"a": [{"asset": "a"}]} in the public StandardMessageCodec format.
        actual = decode_manifest(bytes.fromhex("0d010701610c010d0107056173736574070161"))
        self.assertEqual(actual, {"a": [{"asset": "a"}]})

    def test_manifest_resolution_variant_aligns_float64(self):
        prefix = bytes.fromhex("0d010701610c010d0207056173736574070161070364707206")
        payload = prefix + bytes((-len(prefix)) % 8) + struct.pack("<d", 2)
        self.assertEqual(decode_manifest(payload), {"a": [{"asset": "a", "dpr": 2.0}]})

    def test_expanded_string_length(self):
        value = "x" * 256
        data = bytes((7, 254)) + struct.pack("<H", 256) + value.encode()
        self.assertEqual(StandardMessageDecoder(data).decode(), value)

    def test_expanded_large_length(self):
        value = "x" * 65536
        data = bytes((7, 255)) + struct.pack("<I", len(value)) + value.encode()
        self.assertEqual(StandardMessageDecoder(data).decode(), value)

    def test_truncated_manifest_is_not_accepted(self):
        with self.assertRaises(GateError):
            decode_manifest(bytes.fromhex("0d010701610c010d01070561737365740701"))

    def test_trailing_bytes_are_not_accepted(self):
        with self.assertRaises(GateError):
            decode_manifest(bytes.fromhex("0d00ff"))

    def test_unexpected_or_invalid_manifest_is_not_accepted(self):
        for data in (bytes((127,)), bytes((0,)), bytes.fromhex("0d010701610c00")):
            with self.subTest(data=data), self.assertRaises(GateError):
                decode_manifest(data)

    def test_duplicate_manifest_keys_are_not_accepted(self):
        with self.assertRaises(GateError):
            decode_manifest(bytes.fromhex("0d020701610007016100"))


class DependencyArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ugk-runtime-provenance-")
        self.root = Path(self.temp.name).resolve()
        self.assertEqual(self.root.parent, Path(tempfile.gettempdir()).resolve())
        self.addCleanup(self.temp.cleanup)
        self.host = self.root / "host"
        self.destination = self.root / "proof/runtime"
        self.inputs = {}
        for relative in DEPENDENCY_PROVENANCE_PATHS:
            data = ("original=" + relative + "\r\nmissing-assets: [absent]\r\n").encode()
            path = self.host / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            self.inputs[relative] = data

    def test_configs_are_inert_snapshots_with_exact_original_byte_receipts(self):
        archive = archive_dependency_provenance(self.host, self.destination)
        receipt = read_json(archive / "receipt.json")
        self.assertEqual(receipt["sourceHost"], str(self.host))
        self.assertEqual({f["originalPath"] for f in receipt["files"]}, set(self.inputs))
        for file in receipt["files"]:
            original = file["originalPath"]
            self.assertEqual(file["snapshotPath"], original + ".snapshot")
            self.assertEqual((archive / file["snapshotPath"]).read_bytes(), self.inputs[original])
            self.assertEqual(file["bytes"], len(self.inputs[original]))
            self.assertEqual(file["sha256"], digest(self.inputs[original]))
            self.assertFalse((archive / original).exists())
        self.assertFalse(list(archive.rglob("pubspec.yaml")))
        self.assertFalse(list(archive.rglob("analysis_options.yaml")))

    def test_existing_original_archive_and_snapshots_are_not_overwritten(self):
        old = self.destination / "pubspec.yaml"
        old.parent.mkdir(parents=True)
        old.write_bytes(b"preserved original evidence\r\n")
        second = archive_dependency_provenance(self.host, self.destination)
        third = archive_dependency_provenance(self.host, self.destination)
        self.assertEqual(second.name, "runtime-2")
        self.assertEqual(third.name, "runtime-3")
        self.assertEqual(old.read_bytes(), b"preserved original evidence\r\n")
        self.assertEqual((second / "receipt.json").read_bytes(), (third / "receipt.json").read_bytes())

    def test_missing_input_does_not_create_a_partial_archive(self):
        (self.host / "pubspec.yaml").rename(self.host / "pubspec.yaml.absent")
        with self.assertRaisesRegex(GateError, "pubspec.yaml"):
            archive_dependency_provenance(self.host, self.destination)
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
