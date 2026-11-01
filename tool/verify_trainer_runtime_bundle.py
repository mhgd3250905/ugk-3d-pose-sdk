#!/usr/bin/env python3
"""Build and audit two real Android APKs without changing any host App.

Only Python's standard library is used. AssetManifest.bin is decoded according
to Flutter's StandardMessageCodec; no AssetManifest JSON or filename-only proxy
is accepted as the packaged-manifest evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time
import urllib.request
import zipfile


class GateError(RuntimeError):
    """A concrete build or evidence failure; never a successful skipped gate."""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8", newline="\n")


def read_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


class StandardMessageDecoder:
    """Strict little-endian StandardMessageCodec decoder for Flutter assets.

    Android's host byte order is little endian. Integer sizes are unaligned;
    float and typed-array payloads align their absolute buffer offsets, matching
    flutter/lib/src/foundation/serialization.dart. Unknown/trailing bytes fail.
    """

    def __init__(self, data: bytes):
        self.data = data
        self.offset = 0

    def take(self, size: int) -> bytes:
        if size < 0 or self.offset + size > len(self.data):
            raise GateError("Truncated AssetManifest.bin")
        result = self.data[self.offset:self.offset + size]
        self.offset += size
        return result

    def number(self, code: str, align: int = 1):
        self.offset = (self.offset + align - 1) // align * align
        return struct.unpack("<" + code, self.take(struct.calcsize(code)))[0]

    def size(self) -> int:
        first = self.take(1)[0]
        return self.number("H") if first == 254 else self.number("I") if first == 255 else first

    def value(self):
        tag = self.take(1)[0]
        if tag in (0, 1, 2):
            return (None, True, False)[tag]
        if tag == 3:
            return self.number("i")
        if tag == 4:
            return self.number("q")
        if tag == 6:
            return self.number("d", 8)
        if tag in (5, 7):
            return self.take(self.size()).decode("utf-8")
        if tag == 8:
            return self.take(self.size())
        if tag in (9, 10, 11, 14):
            size = self.size()
            code, alignment = {9: ("i", 4), 10: ("q", 8), 11: ("d", 8), 14: ("f", 4)}[tag]
            self.offset = (self.offset + alignment - 1) // alignment * alignment
            return [self.number(code) for _ in range(size)]
        if tag == 12:
            return [self.value() for _ in range(self.size())]
        if tag == 13:
            result = {}
            for _ in range(self.size()):
                key = self.value()
                if not isinstance(key, (str, int, float, bool, type(None))):
                    raise GateError("Unsupported manifest map key")
                if key in result:
                    raise GateError("Duplicate manifest map key")
                result[key] = self.value()
            return result
        raise GateError(f"Unknown StandardMessageCodec tag {tag}")

    def decode(self):
        result = self.value()
        if self.offset != len(self.data):
            raise GateError("Trailing bytes in AssetManifest.bin")
        return result


def decode_manifest(data: bytes) -> dict:
    result = StandardMessageDecoder(data).decode()
    if not isinstance(result, dict) or not all(isinstance(key, str) for key in result):
        raise GateError("Packaged asset manifest is not a string-keyed map")
    for key, variants in result.items():
        if not isinstance(variants, list) or not variants:
            raise GateError(f"Invalid manifest variants for {key}")
        if not all(isinstance(item, dict) and isinstance(item.get("asset"), str) for item in variants):
            raise GateError(f"Invalid manifest entry for {key}")
    return result


def source_fingerprint(sdk: Path) -> str:
    files = []
    for prefix in ("lib", "packages/ugk_trainer/lib", "packages/ugk_trainer_runtime/lib",
                   "packages/ugk_trainer_runtime/android"):
        directory = sdk / prefix
        if not directory.exists():
            raise GateError(f"Runtime source is not ready: {prefix}")
        files.extend(path for path in directory.rglob("*") if path.is_file() and
                     not any(part in {"build", ".gradle"} for part in path.relative_to(directory).parts))
    files.extend(sdk / path for path in ("packages/ugk_trainer/pubspec.yaml",
                                        "packages/ugk_trainer_runtime/pubspec.yaml"))
    return digest("\n".join(f"{p.relative_to(sdk).as_posix()}:{digest(p.read_bytes())}"
                            for p in sorted(files)).encode())


def command(args: list[str], cwd: Path, logs: Path, label: str, env: dict) -> None:
    logs.mkdir(parents=True, exist_ok=True)
    attempt = 1
    while (logs / f"{label}-{attempt}.log").exists():
        attempt += 1
    path = logs / f"{label}-{attempt}.log"
    launch = args
    if os.name == "nt" and args[0].lower().endswith((".bat", ".cmd")):
        # The gate refuses CMD metacharacters in paths rather than treating JSON
        # or Windows argv quoting as shell escaping.
        if any(re.search(r"[&|<>^%!\r\n]", item) for item in args):
            raise GateError("Unsupported shell metacharacter in tool arguments")
        # Pass CMD its raw command line: Popen's list conversion would escape
        # this outer quoted payload and make CMD treat it as one executable.
        launch = (subprocess.list2cmdline([os.environ.get("COMSPEC", "cmd.exe")]) +
                  ' /d /s /c "' + subprocess.list2cmdline(args) + '"')
    print(f"[{label}] running; log={path}", flush=True)
    started = time.monotonic()
    with path.open("wb") as log:
        process = subprocess.Popen(launch, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        code = process.wait()
    write_json(logs / f"{label}-{attempt}.json", {
        "command": args, "workingDirectory": str(cwd), "exitCode": code,
        "elapsedMs": round((time.monotonic() - started) * 1000), "logSha256": digest(path.read_bytes()),
    })
    if code:
        print(path.read_text(encoding="utf-8", errors="replace")[-7000:], flush=True)
        raise GateError(f"{label} failed with exit {code}; original log retained")
    print(f"[{label}] passed in {round(time.monotonic() - started, 1)}s", flush=True)


def prepare_inputs(sdk: Path, out: Path) -> Path:
    pack = sdk / "packages/ugk_trainer/assets/pose_hub/app-test-pack-r1"
    source = out / "source"
    source.mkdir(parents=True, exist_ok=True)
    catalog_path = pack / "catalog.json"
    catalog = read_json(catalog_path)
    action = next(a for a in catalog["actions"] if a["id"] == "s-butterfly")
    copied = ["catalog.json", "catalog/catalog.json", "standing/s-butterfly.webp"]
    for relative in copied:
        path = source / relative
        data = (pack / relative).read_bytes()
        if path.exists() and path.read_bytes() != data:
            raise GateError(f"Refusing changed prepared input: {relative}")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    downloads = []
    for kind in ("video", "cover", "thumbnail"):
        record = action["files"][kind]
        relative = Path(record["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise GateError("Invalid original media path")
        path = source / relative
        if not path.exists():
            print(f"Downloading original allowed {kind}: {relative.as_posix()}", flush=True)
            request = urllib.request.Request(record["downloadUrl"], headers={"User-Agent": "UGK-SDK-runtime-bundle-gate/1"})
            with urllib.request.urlopen(request, timeout=90) as response:
                data = response.read()
            if len(data) != record["bytes"] or digest(data) != record["sha256"]:
                raise GateError(f"Downloaded {kind} fails source SHA/size")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        data = path.read_bytes()
        if len(data) != record["bytes"] or digest(data) != record["sha256"]:
            raise GateError(f"Prepared {kind} fails source SHA/size")
        downloads.append({"kind": kind, "path": relative.as_posix(), "bytes": len(data), "sha256": digest(data)})
    standing = (source / "standing/s-butterfly.webp").read_bytes()
    manifest = {
        "schemaVersion": 1, "appId": "runtime-bundle-gate", "allowedActionIds": ["s-butterfly"],
        "adapter": "pose-hub-delivery@1", "voicePolicy": "silent", "kitPolicy": "none",
        "catalog": "catalog.json", "catalogSha256": digest(catalog_path.read_bytes()),
        "sourceRoots": [str(source)], "includeStanding": True,
        "integrity": {"standing/s-butterfly.webp": {"bytes": len(standing), "sha256": digest(standing)}},
    }
    write_json(out / "scope.json", manifest)
    write_json(out / "source-provenance.json", {
        "scope": "One SF-authorized action, not a HipLab/Thomas production manifest",
        "adapter": "pose-hub-delivery@1", "voicePolicy": "silent", "kitPolicy": "none",
        "sourceCatalogSha256": digest(catalog_path.read_bytes()),
        "sourceCatalogBytes": catalog_path.stat().st_size, "downloads": downloads,
        "voiceConfigured": False, "actionKitsConfigured": False,
        "standing": manifest["integrity"]["standing/s-butterfly.webp"],
    })
    return out / "scope.json"


def generate_host(sdk: Path, out: Path, variant: str, flutter: str, env: dict) -> Path:
    host = out / variant
    logs = out / "logs"
    package = "ugk_trainer_runtime" if variant == "runtime" else "ugk_trainer"
    if not host.exists():
        command([flutter, "create", "--no-pub", "--platforms=android", "--project-name", "trainer_runtime_gate",
                 "--org", "dev.ugk", str(host)], sdk, logs, f"{variant}-create", env)
    # Bound only these disposable hosts. The Flutter template otherwise gives
    # its long-lived daemon 8 GiB heap + 4 GiB metaspace, which exhausted this
    # workstation's commit while unrelated SDK checks were running. Versions,
    # targets, release flags and all validation assertions stay unchanged.
    properties = host / "android/gradle.properties"
    bounded = {
        "org.gradle.jvmargs": "-Xmx2G -XX:MaxMetaspaceSize=1G -XX:ReservedCodeCacheSize=256m "
                              "-XX:ActiveProcessorCount=4 -XX:+HeapDumpOnOutOfMemoryError -Dfile.encoding=UTF-8",
        "org.gradle.daemon": "false", "org.gradle.workers.max": "2", "org.gradle.parallel": "false",
        "kotlin.compiler.execution.strategy": "in-process",
    }
    original = properties.read_text(encoding="utf-8").splitlines()
    kept = [line for line in original if line.partition("=")[0].strip() not in bounded]
    properties.write_text("\n".join([*kept, "# SDK bundle gate: task-local resource bounds only.",
                                    *(f"{key}={value}" for key, value in bounded.items())]) + "\n",
                          encoding="utf-8", newline="\n")
    dependency = (sdk / "packages" / package).as_posix()
    pubspec = f"""name: trainer_runtime_gate
publish_to: none
version: 1.0.0+1
environment:
  sdk: ^3.12.0
dependencies:
  flutter:
    sdk: flutter
  {package}:
    path: '{dependency}'
dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
  crypto: 3.0.7
dependency_overrides:
  ugk_coach:
    path: '{sdk.as_posix()}'
  ugk_trainer_runtime:
    path: '{(sdk / 'packages/ugk_trainer_runtime').as_posix()}'
flutter:
  uses-material-design: true
"""
    fragment = (out / "closure/pubspec-assets.yaml").read_text(encoding="utf-8")
    # The closure fragment is a complete `flutter: assets:` stanza.
    lines = fragment.splitlines()
    asset_headers = [index for index, line in enumerate(lines) if line.strip() == "assets:"]
    if len(asset_headers) != 1:
        raise GateError("Closure generator did not provide explicit Flutter assets")
    lines = lines[asset_headers[0]:]
    pubspec += "\n".join(lines) + "\n"
    (host / "pubspec.yaml").write_text(pubspec, encoding="utf-8", newline="\n")
    for item in read_json(out / "closure/asset-closure.json")["files"]:
        source = out / "closure" / item["path"]
        target = host / item["assetKey"]
        if not target.resolve().is_relative_to(host.resolve()):
            raise GateError("Generated asset escapes the owned host")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source.read_bytes())
    shutil.copyfile(out / "closure/asset-closure.json", host / "asset-closure.json")
    templates = sdk / "examples/trainer_runtime_minimal"
    for template, target in (("main.dart.template", "lib/main.dart"),
                             ("asset_probe_test.dart.template", "test/asset_probe_test.dart")):
        text = (templates / template).read_text(encoding="utf-8")
        text = text.replace("__TRAINER_PACKAGE__", package).replace("__VARIANT__", variant)
        (host / target).parent.mkdir(parents=True, exist_ok=True)
        (host / target).write_text(text, encoding="utf-8", newline="\n")
    # Flutter's generated counter test belongs to the replaced template, so keep
    # its original bytes as evidence and run only the actual asset contract.
    generated_test = host / "test/widget_test.dart"
    if generated_test.exists() and not (host / "test/widget_test.dart.template-original").exists():
        generated_test.rename(host / "test/widget_test.dart.template-original")
    return host


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, dict):
        for key, item in value.items():
            yield str(key)
            yield from strings(item)


DEPENDENCY_PROVENANCE_PATHS = (
    "pubspec.yaml", "pubspec.lock", "analysis_options.yaml", ".dart_tool/package_config.json",
    ".flutter-plugins-dependencies", "android/gradle/wrapper/gradle-wrapper.properties",
    "android/settings.gradle.kts", "android/app/build.gradle.kts", "android/gradle.properties",
)


def archive_dependency_provenance(host: Path, destination: Path) -> Path:
    """Preserve raw build receipts without creating another analyzable package.

    The original filenames remain in the receipt, not as active configuration
    files. An existing archive is immutable; retries use a numbered directory.
    """
    inputs = []
    for relative in DEPENDENCY_PROVENANCE_PATHS:
        source = host / relative
        if not source.is_file():
            raise GateError(f"Build dependency provenance missing: {relative}")
        inputs.append((relative, source.read_bytes()))
    archive = destination
    attempt = 2
    while archive.exists():
        archive = destination.with_name(f"{destination.name}-{attempt}")
        attempt += 1
    archive.mkdir(parents=True, exist_ok=False)
    files = []
    for relative, data in inputs:
        archived = relative + ".snapshot"
        target = archive / archived
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as output:
            output.write(data)
        files.append({"originalPath": relative, "snapshotPath": archived,
                      "bytes": len(data), "sha256": digest(data)})
    write_json(archive / "receipt.json", {
        "schemaVersion": 1, "kind": "raw-dependency-snapshots",
        "sourceHost": str(host.resolve()), "files": files,
    })
    return archive


def audit_apk(sdk: Path, out: Path, host: Path, variant: str, env: dict) -> dict:
    apk = host / "build/app/outputs/flutter-apk/app-release.apk"
    proof = read_json(out / "closure/asset-closure.json")
    allowed = set(proof["allowedActionIds"])
    full_catalog = read_json(sdk / "packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json")
    outside = {a["id"] for a in full_catalog["actions"]} - allowed
    with zipfile.ZipFile(apk) as archive:
        infos = archive.infolist()
        names = [item.filename for item in infos]
        if len(names) != len(set(names)):
            raise GateError("APK has duplicate filenames")
        prefix = "assets/flutter_assets/"
        assets = {item.filename[len(prefix):]: item for item in infos if item.filename.startswith(prefix) and not item.is_dir()}
        manifest_bytes = archive.read(prefix + "AssetManifest.bin")
        manifest = decode_manifest(manifest_bytes)
        manifest_keys = set(manifest)
        for variants in manifest.values():
            for item in variants:
                if item["asset"] not in assets:
                    raise GateError("Packaged AssetManifest references an absent file")
        expected = {item["assetKey"]: item for item in proof["files"]}
        for key, spec in expected.items():
            if key not in manifest_keys or key not in assets:
                raise GateError(f"Closure asset absent from actual APK/manifest: {key}")
            data = archive.read(prefix + key)
            if digest(data) != spec["sha256"] or len(data) != spec["bytes"]:
                raise GateError(f"APK closure asset differs from validated input: {key}")
        emitted = {key for key in assets if key.startswith("assets/trainer/")}
        if emitted != set(expected):
            raise GateError("Actual scoped asset files differ from exact closure")
        if variant == "runtime":
            if any(key.startswith("packages/ugk_trainer/") for key in assets):
                raise GateError("Runtime-only APK contains legacy package assets")
            for key in assets:
                parts = set(key.split("/"))
                basename = key.rsplit("/", 1)[-1]
                if any(action_id in parts or basename.startswith(action_id + ".")
                       for action_id in outside):
                    raise GateError(f"Runtime APK contains an outside action resource: {key}")
            for key in assets:
                if key.endswith(".json"):
                    value = json.loads(archive.read(prefix + key))
                    leaked = set(strings(value)) & outside
                    if leaked:
                        raise GateError(f"Runtime APK metadata exposes outside action IDs in {key}")
        old_standing = {key for key in assets if key.startswith("packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/standing/")}
        old_standing_ids = {Path(key).stem for key in old_standing if key.endswith(".webp")}
        legacy_files_verified = 0
        if variant == "legacy":
            if old_standing_ids != {a["id"] for a in full_catalog["actions"]}:
                raise GateError("Legacy comparison differs from the full historical standing ID set")
            # Include index.json/index.sha256 and every historically declared
            # non-shader resource. Do not count these two indexes as actions.
            legacy_root = sdk / "packages/ugk_trainer/assets"
            historical = {"packages/ugk_trainer/" + path.relative_to(legacy_root.parent).as_posix(): path
                          for path in legacy_root.rglob("*") if path.is_file()}
            actual = {key for key in assets if key.startswith("packages/ugk_trainer/assets/")}
            if actual != set(historical):
                raise GateError("Legacy comparison differs from the complete historical asset set")
            for key, source in historical.items():
                if archive.read(prefix + key) != source.read_bytes():
                    raise GateError(f"Legacy APK changed historical resource bytes: {key}")
            legacy_files_verified = len(historical)
        runtime_resources = sorted(key for key in assets if key.startswith("packages/ugk_trainer_runtime/"))
        permitted_runtime = {
            "packages/ugk_trainer_runtime/assets/silence.m4a",
            *["packages/ugk_trainer_runtime/assets/media_player/" + name for name in ("player.html", "player.js", "player.css")],
            *["packages/ugk_trainer_runtime/assets/pose_hub_player/" + name for name in ("player.html", "player.js")],
            "packages/ugk_trainer_runtime/shaders/packed_alpha.frag",
        }
        if set(runtime_resources) != permitted_runtime:
            raise GateError("Runtime contains absent or unexpected non-common resources")
        write_json(out / f"{variant}-asset-manifest.json", manifest)
        write_json(out / f"{variant}-apk-files.json", [{"path": i.filename, "bytes": i.file_size,
                                                       "compressedBytes": i.compress_size, "crc32": i.CRC}
                                                      for i in infos])
        write_json(out / f"{variant}-asset-sha256.json", {
            key: digest(archive.read(prefix + key)) for key in sorted(assets)})
        metrics = {
            "variant": variant, "apk": str(apk), "apkBytes": apk.stat().st_size,
            "apkSha256": digest(apk.read_bytes()), "uncompressedFlutterAssetBytes": sum(i.file_size for i in assets.values()),
            "compressedFlutterAssetBytes": sum(i.compress_size for i in assets.values()), "assetFileCount": len(assets),
            "assetManifestBytes": len(manifest_bytes), "assetManifestSha256": digest(manifest_bytes),
            "assetManifestDecoded": True, "manifestKeyCount": len(manifest_keys),
            "allowedActionIds": sorted(allowed), "scopedFileCount": len(expected),
            "legacyStandingActionCount": len(old_standing_ids),
            "legacyStandingAuxiliaryFileCount": len(old_standing) - len(old_standing_ids),
            "legacyHistoricalAssetFilesVerified": legacy_files_verified,
            "runtimeCommonResources": runtime_resources, "outsideScopedResourceCount": 0,
            "runtimeMetadataOutsideIdCount": 0 if variant == "runtime" else None,
            "voiceConfigured": False, "actionKitsConfigured": False,
        }
    plugins = read_json(host / ".flutter-plugins-dependencies")["plugins"]["android"]
    trainer_plugins = [p for p in plugins if p["name"] in {"ugk_trainer", "ugk_trainer_runtime"}]
    if len(trainer_plugins) != 1 or trainer_plugins[0]["name"] != "ugk_trainer_runtime":
        raise GateError("Trainer plugin is not registered exactly once by runtime")
    registrants = list((host / "android").rglob("GeneratedPluginRegistrant.java"))
    if len(registrants) != 1:
        raise GateError("Expected one Android GeneratedPluginRegistrant")
    registrations = registrants[0].read_text(encoding="utf-8").count("new com.ugk.trainer.UgkTrainerPlugin()")
    if registrations != 1:
        raise GateError("Native trainer registration class count is not one")
    android = Path(env.get("ANDROID_SDK_ROOT", env.get("ANDROID_HOME", "")))
    aapt = android / "build-tools/36.0.0/aapt2.exe"
    if not aapt.exists():
        raise GateError("Android build-tools 36.0.0 aapt2 unavailable for manifest audit")
    result = subprocess.run([str(aapt), "dump", "xmltree", str(apk), "--file", "AndroidManifest.xml"],
                            check=True, capture_output=True, text=True, encoding="utf-8", env=env)
    (out / f"{variant}-android-manifest.txt").write_text(result.stdout, encoding="utf-8", newline="\n")
    service_lines = [line for line in result.stdout.splitlines() if "android:name" in line and
                     "com.ugk.trainer.TrainingSessionService" in line]
    if len(service_lines) != 1:
        raise GateError("APK foreground service component is not declared once")
    metrics.update({"trainerPluginRegistrations": registrations, "trainerServiceDeclarations": len(service_lines)})
    provenance = archive_dependency_provenance(host, out / "dependency-provenance" / variant)
    metrics["dependencyProvenance"] = provenance.relative_to(out).as_posix()
    write_json(out / f"{variant}-metrics.json", metrics)
    return metrics


def run(args) -> None:
    sdk = Path(__file__).resolve().parents[1]
    out = Path(args.out).absolute().resolve()
    if not out.is_relative_to((sdk / "build").resolve()):
        raise GateError("Gate outputs must stay in this SDK checkout's build directory")
    marker = out / "gate-owned-run.json"
    if out.exists() and not args.resume:
        raise GateError("Output already exists; choose a new directory or explicit --resume")
    if args.resume:
        if not marker.exists() or read_json(marker).get("sdkRoot") != str(sdk):
            raise GateError("Refusing to resume a directory not owned by this gate")
    else:
        out.mkdir(parents=True)
        write_json(marker, {"sdkRoot": str(sdk), "startedUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
    manifest = prepare_inputs(sdk, out)
    if args.prepare_only:
        print(f"Verified source inputs prepared: {manifest}", flush=True)
        return
    env = dict(os.environ)
    jbr = Path(r"E:\Android\Android Studio\jbr")
    if os.name == "nt" and not env.get("JAVA_HOME") and (jbr / "bin/java.exe").exists():
        env["JAVA_HOME"] = str(jbr)  # Child build environment only, no global tool config.
    flutter = shutil.which("flutter")
    dart = shutil.which("dart")
    if not flutter or not dart:
        raise GateError("Flutter and Dart must already be installed")
    command([flutter, "--version", "--machine"], sdk, out / "logs", "flutter-toolchain", env)
    command([dart, "--version"], sdk, out / "logs", "dart-toolchain", env)
    if env.get("JAVA_HOME"):
        command([str(Path(env["JAVA_HOME"]) / "bin/java.exe"), "-version"],
                sdk, out / "logs", "java-toolchain", env)
    closure = out / "closure"
    if not closure.exists():
        command([dart, "run", "tool/trainer_asset_closure.dart", "--manifest", str(manifest), "--out", str(closure)],
                sdk, out / "logs", "asset-closure", env)
    proof = read_json(closure / "asset-closure.json")
    if proof["allowedActionIds"] != ["s-butterfly"]:
        raise GateError("Prepared proof is not this gate's frozen single-action scope")
    fingerprint = source_fingerprint(sdk)
    write_json(out / "production-source-fingerprint.json", {
        "sha256": fingerprint,
        "scope": "root Coach lib, both Trainer libs, runtime Android source and both pubspecs",
        "checkedBeforeBuildAndAfterEachVariant": True,
    })
    results = []
    for variant in ("runtime", "legacy"):
        host = generate_host(sdk, out, variant, flutter, env)
        command([flutter, "pub", "get", "--offline"], host, out / "logs", f"{variant}-pub-get", env)
        command([flutter, "test", "--no-pub", "--reporter", "expanded", "test/asset_probe_test.dart"],
                host, out / "logs", f"{variant}-asset-probe", env)
        command([flutter, "build", "apk", "--release", "--target-platform", "android-arm64", "--no-pub"],
                host, out / "logs", f"{variant}-apk-build", env)
        results.append(audit_apk(sdk, out, host, variant, env))
        if source_fingerprint(sdk) != fingerprint:
            raise GateError("SDK source changed during the comparison; both variants need a fresh gate")
    runtime, legacy = results
    summary = {
        "schemaVersion": 1, "gatePassed": True, "sdkRoot": str(sdk), "productionSourceSha256": fingerprint,
        "sourceUnchangedAcrossVariants": True, "platform": "Android arm64 release",
        "signing": "Flutter example debug signer; not a release candidate", "deviceOperated": False,
        "realAppChanged": False, "newModelCalls": 0, "allowedActionIds": ["s-butterfly"],
        "voiceConfigured": False, "actionKitsConfigured": False,
        "closureProofSha256": digest((closure / "asset-closure.json").read_bytes()),
        "variants": results, "apkBytesSaved": legacy["apkBytes"] - runtime["apkBytes"],
        "uncompressedAssetBytesSaved": legacy["uncompressedFlutterAssetBytes"] - runtime["uncompressedFlutterAssetBytes"],
    }
    write_json(out / "summary.json", summary)
    print(json.dumps({"gatePassed": True, "runtimeApkBytes": runtime["apkBytes"], "legacyApkBytes": legacy["apkBytes"],
                      "apkBytesSaved": summary["apkBytesSaved"], "report": str(out / "summary.json")}), flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, help="New directory inside this SDK checkout's build/")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    try:
        run(args)
        return 0
    except (GateError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Runtime bundle gate failed: {type(error).__name__}: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
