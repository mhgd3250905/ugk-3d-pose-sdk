# Pose Hub R1 semantic revision v2

Kai approved the supplied semantic revision for publication. The SDK bundles
the exact file `app-test-pack-r1-semantics-r1/catalog.json`:

- SHA256: `a1655e5c64055c14af35850b5468390d9d11161e53a87a0cbe7780ec7ed25dc0`
- Size: **2,770,221 bytes**; all **219** original action IDs and their order.
- **211 complete / 8 pending**. The original 142 definitions are unchanged;
  69 newly complete definitions come directly from the supplied catalogue.
- All 657 media files remain unchanged: **587,456,377 bytes**.

The original v1 Release, tags, descriptor and ZIP remain immutable. This is a
new version, `posehub-app-test-pack-r1-v2`, paired with SDK tags
`ugk_coach-v0.6.1` and `ugk_trainer-v0.4.1`. Coach UI remains 0.2.1. The training
layout, media player, no-flash controls and Morph Pulse are unchanged.

## APIs

```dart
final library = await PoseHubActionLibrary.load();
final all = library.allActions;                    // 219
final complete = library.semanticCompleteActions; // 211
final pending = library.pendingActions;           // 8
final aiCatalog = library.toAiCatalog();           // exactly 211
```

Existing browser and single-practice APIs do not change. The pending entries
remain labelled `训练说明待补` and are excluded from AI selection:

```text
h-bilateral-farmer-hold-native
h-db-shrug
h-floor-nordic-hand-reset
h-kneeling-thread-needle
h-pike-scapular-elevation
h-towel-isometric-curl
h-wall-palm-lift
o-supported-ankle-eversion
```

No training defaults are generated. The new 69 definitions retain their own
source dose/range/cues and raw metadata; the original 142 still use the original
canonical definitions. Missing fields on the eight pending actions remain
missing or null. Host-provided matching canonical catalogues continue to work;
no artificial limit of 142 is added to the general parser.

Source `availableForTraining` and historical review flags are preserved rather
than rewritten. The catalogue's full semantic snapshot identifies the approved
revision; exceptions for its retained availability/optional-unknown metadata
are limited to that exact snapshot. The Flutter loader also pins the exact
source byte hash. Changing semantic values, IDs, provenance or flags does not
silently grant access to the revision's additional AI definitions.

## Pack distribution and installation

- [v2 ZIP](https://github.com/mhgd3250905/ugk-3d-pose-sdk/releases/download/posehub-app-test-pack-r1-v2/posehub-app-test-pack-r1-v2.zip)
- [v2 descriptor](https://github.com/mhgd3250905/ugk-3d-pose-sdk/releases/download/posehub-app-test-pack-r1-v2/posehub-app-test-pack-r1-v2.descriptor.json)
- ZIP: **592,748,021 bytes**, 660 entries, SHA256
  `f59a699d6be905f5bf91bafdff7ca294c8d1a4e879ba792b794280a6e7559bdb`.

Comparing every archive entry with v1, only `catalog.json` changes. The original
`manifest.json` and `catalog/catalog.json` retain their exact bytes. In
particular, the frozen manifest still references the original v1 catalogue;
the v2 descriptor and fixed catalogue hash identify this approved overlay.
The pack tool checks its pinned source catalogue/manifest provenance instead
of rewriting the manifest. No media is stored in ordinary Git history.

Install v2 into a separate version directory and point `mediaBaseUri` there.
The installer rejects conflicting files and does not overwrite a v1 install.
The same original media may be hosted at the existing media base because every
media path and SHA256 is unchanged; the SDK ships the new root catalogue.

```powershell
python tool/posehub_pack.py install --archive <v2.zip> --destination <new-v2-dir> --sha256 f59a699d6be905f5bf91bafdff7ca294c8d1a4e879ba792b794280a6e7559bdb
python tool/posehub_pack.py verify --pack <new-v2-dir>
python tool/posehub_pack.py build --pack <new-v2-dir> --output <new-output-dir>/posehub-app-test-pack-r1-v2.zip
```

Use the explicit v2 output name. The tool retains its previous default filename
and refuses to overwrite any different existing archive. Exact v1 catalogues
remain supported with their original 142/77 counts and strict ID ordering.
There is no tiered downloading or playback change in this revision.

The source review flags are historical bytes of the supplied file. Publication
of this semantic revision follows Kai's explicit approval; it does not rewrite
those fields or extend the existing native-performance evidence. No simulator
or device operation is required for this catalogue-only change.

The [adoption audit](posehub-r1-semantics-v2-adoption-audit.md) records the review
of all 15 inherited changes, rejected behaviour changes and final verification.
