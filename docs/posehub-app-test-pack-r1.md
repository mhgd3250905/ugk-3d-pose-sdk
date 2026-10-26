# Pose Hub R1: 219-action integration

This release adds the original `app-test-pack-r1` catalogue and a separate, whole
media pack. Action IDs, media bytes and training definitions are unchanged.
All 219 actions can be listed, searched, inspected and used for manual single
practice. Exactly 142 have complete training definitions; the other 77 display
`训练说明待补` and have no inferred dose, duration, set count or counting rhythm.

## Flutter integration

Pin `ugk_coach-v0.6.0` and `ugk_trainer-v0.4.0`. The trainer's Git dependency
already pins the matching coach tag. `ugk_coach_ui` remains at `0.2.1`.

```dart
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

final library = await PoseHubActionLibrary.load();
final all = library.allActions;                    // 219, original ID/order
final complete = library.semanticCompleteActions; // 142
final pending = library.pendingActions;           // 77
final action = library.tryGet(all.first.id)!;

// Supply ONLY this catalogue to AI selection / CoachTools / CoachProfile.
final Catalog aiCatalog = library.toAiCatalog(); // 142; excludes all 77

// The host downloads, verifies and installs the whole pack first.
final mediaBase = Uri.directory('/app/private/posehub-r1/');
final browser = PoseHubActionBrowser(
  catalog: library,
  mediaBaseUri: mediaBase,
  theme: TrainerTheme.light, // or dark / host tokens
  onPracticeFinished: (result) {
    // original actionId, actual activeDuration, trainingDefinitionComplete
  },
);
final practice = PoseHubSinglePracticePage(
  action: action,
  mediaBaseUri: mediaBase,
);
```

Use `Uri.directory(absolutePath, windows: true)` on Windows, or an HTTP(S)
directory URI ending in `/`. File paths are relative to that directory and
remain exactly as recorded in the source. Resolve an AI-selected original ID
with `library.tryGet(id)` for R1 playback; the legacy `Catalog` asset resolver
does not install or resolve this separate pack.

Pure Dart hosts can read the original `catalog.json` and `catalog/catalog.json`
and call `PoseHubAppTestCatalog.fromBytes(catalogBytes,
semanticCatalogBytes: canonicalBytes)`. The canonical byte length and SHA256
are verified. `toAiCatalog()` requires this bound canonical catalogue (or an
explicit matching `Catalog`); it never builds AI training definitions from
partial entries. Each projection is independent of caller mutations. The
bundled Flutter loader additionally verifies the fixed R1 root catalogue hash.

Manual practice starts, pauses, resumes and ends by user input and records
actual active time. Complete entries show the source dose as a suggestion;
pending entries never receive an automatic target. Existing `TrainerPlayer`,
no-flash playback controls and Morph Pulse are unchanged.

## Whole-pack distribution and integrity

The repository already keeps production media outside ordinary Git. No LFS
dependency is introduced. Git contains the three original JSON files
(4,575,219 bytes), a small descriptor, source code and tests. It contains no
new MP4, WebP or ZIP media payload.

- [Whole ZIP](https://github.com/mhgd3250905/ugk-3d-pose-sdk/releases/download/posehub-app-test-pack-r1-v1/posehub-app-test-pack-r1.zip)
- [Descriptor](https://github.com/mhgd3250905/ugk-3d-pose-sdk/releases/download/posehub-app-test-pack-r1-v1/posehub-app-test-pack-r1.descriptor.json)
- Media: **657 files / 587,456,377 bytes**; 219 videos, 219 covers, 219 thumbnails.
- Archive: **592,170,694 bytes**, 660 entries (657 media + 3 original metadata).
- Archive SHA256: `2ec6331499ed723a843cb620f52b250f5ee3310ea39566a58fdf546f3f771d97`.
- Root catalogue SHA256: `c5f090aa06e2743904a3f0c1f9193c87955242b1aa7f054a14a9f6e7c824be54`.

The original directory includes 97 historical media files not referenced by the
catalogue. They are excluded from the release; the authoritative 657 files are
verified individually. The source's `test-unreviewed`, `reviewed: false` and
`releaseEligible: false` metadata remain unchanged. Semantic completeness is
not a new safety, clinical or content-review certification. Existing legacy
media repository review gates are unchanged.

Download once as a whole pack; tiered/on-demand downloading is not implemented.
The SDK exports `PoseHubActionLibrary.downloadUri` for the host downloader.
The host is responsible for network credentials, storage location, persistence
and verifying the descriptor/whole ZIP before exposing local media URIs.
Python 3.10+ tooling provides a reference install and local demonstration:

```powershell
python tool/posehub_pack.py verify --pack F:\PoseHub-v2-production\app-test-pack-r1
python tool/posehub_pack.py build --pack F:\PoseHub-v2-production\app-test-pack-r1
python tool/posehub_pack.py install --archive <downloaded.zip> --destination <pack-dir> --sha256 2ec6331499ed723a843cb620f52b250f5ee3310ea39566a58fdf546f3f771d97
```

The installer verifies the whole archive and all entries before writing,
rejects traversal, symlinks, unknown/duplicate entries and conflicting files,
and only reuses an existing file when its bytes match. It does not overwrite
source media. The deterministic ZIP stores original bytes without transcoding.

## SDK acceptance showcase

```powershell
cd packages/ugk_trainer/example
flutter build web --release --no-wasm-dry-run
cd ../../..
python tool/posehub_pack.py serve --web-root packages/ugk_trainer/example/build/web --pack <installed-pack-dir> --port 7362
```

Open `http://127.0.0.1:7362/?page=library&theme=light#/library` (or
`theme=dark`). The existing training showcase remains available at
`http://127.0.0.1:7362/#/showcase`. The local server exposes only the catalogue's
allowlisted pack files under `/__posehub_pack__/`, supports MP4 byte ranges,
and binds to loopback. A hosted Web deployment must serve the whole pack from
the same origin; pass `--dart-define=POSEHUB_MEDIA_BASE=/your-pack/` when building
the example to change its media directory.

R1 videos are packed RGB-over-red-alpha 720x1440 H.264 sources, displayed as
720x720. Covers are selected poses, usually not frame zero. The dedicated
`PoseHubPackMedia` keeps the cover until the first decoded frame and never
mislabels a cover as a frame-zero poster. Web uses a GPU WebGL compositor and
Android uses the existing Impeller packed-alpha compositor with an additive
file/HTTP URI capability. No background blur or media rewriting is used.
`PoseHubPackMedia.supportsPlayback` exposes platform support; unsupported
platforms keep the cover and explicit status while manual practice remains
available. iOS packed-alpha decoding is not added by this release.

These checks establish source integrity, API/UI behaviour and Web playback.
They do not establish native Raster P99 or new device acceptance for this pack.
Exact test counts, original-layout comparison and actual light/dark Web
captures are in the [verification receipt](posehub219-verification-2026-10-26.md).

## Compatibility

The R1 catalogue/browser/manual practice and URI media capability are additive.
Existing `PackedAlphaPlatform` implementers need no new methods; the optional
`PackedAlphaUriPlatform` capability is separate. There is no additional API
removal beyond the already published trainer 0.3.x / coach_ui 0.2.x flat-surface
migration. Trainer now depends on coach 0.6.0. See the package changelogs for the
previous glass API removals.
