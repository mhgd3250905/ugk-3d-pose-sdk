# Minimal runtime asset-bundle gate

The executable gate is `tool/verify_trainer_runtime_bundle.py`. It generates two
otherwise identical, disposable Flutter Android hosts under this SDK's ignored
`build/` directory. No real App, dependency pin, or device is changed.

The runtime variant declares only Flutter and `ugk_trainer_runtime`. Its single
action is `s-butterfly`, projected by the shared whitelist closure generator.
This manifest explicitly selects `pose-hub-delivery@1`, silent voice, and no
action-kit. It is an isolation proof for this real media capability, not a
production voice/kit manifest or a HipLab/Thomas approved allowlist.
The legacy variant substitutes `ugk_trainer`; all other inputs and build flags
remain identical. Workspace path dependencies are confined to these SDK tests.

`main.dart.template` exercises the shared media widget with verified original
poster/video assets. `asset_probe_test.dart.template` loads actual bundle bytes
and validates the closure hashes and old/new common resource keys. It does not
pretend that a widget test played a video or operated a phone.

The Android release gate decodes the APK's actual `AssetManifest.bin`, compares
every declared/packaged action resource and metadata reference with the allowed
closure, checks one native plugin registration and foreground service, and
reports APK bytes, uncompressed asset bytes and all file hashes. Release APKs
use the Flutter example's local debug signer and are not release candidates.

Run from the SDK checkout; the output directory must be new and remain under
the SDK's `build/` tree:

```powershell
python tool/verify_trainer_runtime_bundle.py --out build/runtime-split/gate-r1
```

Preparation downloads only the exact original media records of that one
allowed action and verifies their source SHA-256/size. To prepare inputs before
the runtime package is ready, add `--prepare-only`; resume the same owned run
with `--resume`. Logs from failed attempts are retained. No license acceptance,
global Flutter/Java configuration changes, or dependency-cache patches are made.
