# R1 v3: compressed media and host-owned preparation

> Historical 0.6.2 / 0.4.2 delivery contract. The feedback-r1-part1
> release supersedes the preparation UI / clock gate described below:
> training starts immediately with bundled unchanged covers and silent
> background preparation. R2 URLs, media hashes and host verification remain
> unchanged. See [current contract](feedback-r1-part1.md).

SDK tags: **`ugk_coach-v0.6.2` / `ugk_trainer-v0.4.2`**. Data tag:
**`posehub-app-test-pack-r1-v3`**. Coach UI remains 0.2.1. v1 and v2 Release
assets and tags are preserved.

## Media and catalogue

| Item | v2 | v3 |
| --- | ---: | ---: |
| Videos | 570,312,569 bytes | 156,838,427 bytes |
| Covers | 14,155,686 bytes | 5,316,554 bytes |
| Thumbnails | 2,988,122 bytes | 1,196,548 bytes |
| Total 657 media | 587,456,377 bytes | **163,351,529 bytes** |
| Average three-file action | 2,682,449 bytes | **745,897 bytes** |

This is a **72.19%** reduction, below the 200,000,000-byte budget. MB values
refer to decimal bytes. The catalogue is **2,896,158 bytes**, SHA256
`75881cf91621c967f80732f0219f23e85b35e8bde5d1a51ee75dec5f7c5edd36`.
This hash is a release receipt, not a hard-coded runtime acceptance gate.

Videos remain packed RGB-top/red-alpha-bottom H.264 High, 8-bit `yuv420p`,
`avc1`, original frame rate and frame count, no audio, `moov` before `mdat`
(`faststart`). The recipe uses x264 CRF 27 / slow, short edge at most 720;
the existing 720x1440 packed sources retain their dimensions. Covers are WebP
quality 80 up to 640x640; thumbnails are WebP quality 80 up to 192x192.
Transparency and the packing layout are retained. Actual platform decoding
capabilities still depend on the host/player/device; no simulator or device
hardware-decode result is claimed by the encoding checks.

All **219 IDs, 211 complete definitions, 8 pending definitions**, and every
non-media semantic field are identical to the approved v2 catalogue. Only
media receipts/dimensions/URLs and the `mediaDistribution` manifest change.
Every `action.files` entry exposes its original `path`, `bytes` (file size),
`sha256`, dimensions, `assetName` and `downloadUrl`.

## Stable per-file URL rule

```text
mediaBase = https://media.uuugk.win/pack/r1-v3/
media = mediaBase + files[role].path
catalog = https://github.com/mhgd3250905/ugk-3d-pose-sdk/releases/download/posehub-app-test-pack-r1-v3/catalog.json
backup = https://github.com/mhgd3250905/ugk-3d-pose-sdk/releases/download/posehub-app-test-pack-r1-v3/posehub-app-test-pack-r1-v3.zip
```

Examples:

```text
https://media.uuugk.win/pack/r1-v3/media/abs-A/abs-A-r2-alpha-r2/abs-A.rgb-alpha.mp4
```

The R2 bucket is **`posehub-media`**, exposed for anonymous reads only through
the custom domain **`media.uuugk.win`**. Object keys are `pack/r1-v3/` plus the
original nested `file.path`. Version directories are append-only: an existing
key with different bytes or metadata is a publication conflict, never replaced.
Use each file's `downloadUrl`; paths and action IDs are case-sensitive.
Objects carry `Content-Type: video/mp4` or `image/webp` and
`Cache-Control: public, max-age=31536000, immutable`. No App credential is
needed for public media reads. The apex and other subdomains are unchanged.

The v3 GitHub Release contains only `catalog.json` and the complete compressed
ZIP backup. The ZIP contains the catalogue and all 657 media at their original
relative paths. v1/v2 assets are preserved. The old
`PoseHubActionLibrary.downloadUri` remains the **legacy v2 ZIP** for existing
callers; v3 uses `catalogDownloadUri` and each file's nullable `downloadUri`.
Legacy v1/v2 metadata without per-file URLs remains readable.

The backup ZIP is **166,386,567 bytes**, SHA256
`6e5637d40d28281032fda810c68b2d3f91d199fab7eb6702a5ceb9d54c005756`.
It contains 658 entries and excludes local receipts, tooling and source media.
Public R2 CORS allows GET/HEAD and Range requests for host Web downloaders;
prepared Web playback still uses the host's same-origin cache directory.

```dart
final library = await PoseHubActionLibrary.load();
final action = library.tryGet('abs-A')!;
for (final file in action.files.values) {
  final Uri? url = file.downloadUri; // v3: stable independent R2 URL
  final int expectedBytes = file.bytes;
  final String expectedSha256 = file.sha256;
  final String installRelativePath = file.path;
  // Pass these receipts to the App's own downloader/cache.
}
final ai = library.toAiCatalog(); // 211; excludes all eight pending entries
```

The SDK validates the declared catalogue format/version and self-consistent
file manifest: unique identities, safe paths/URLs, valid sizes and digest
formats, counts, total bytes and complete planning definitions. It does not
pin a particular root catalogue SHA or release version. If canonical bytes
are provided, their path/size/SHA are checked against the catalogue's own
reference; shared definitions are checked for agreement. A self-contained
catalogue can supply its complete actions without a separate canonical file.
For a host-provided future catalogue, use `PoseHubAppTestCatalog.fromBytes`
with the bytes fetched by the host; the SDK itself does not fetch catalogues.
The original bundled manifest/legacy ZIP tool describe v1/v2 and are not the
v3 per-file delivery manifest.

## Media preparation interface

```dart
abstract interface class PoseHubMediaPreparer {
  Stream<PoseHubMediaPreparationEvent> prepareAction(PoseHubPackAction action);
}

const PoseHubMediaProgress({
  double? fraction,
  int? receivedBytes,
  int? totalBytes,
});
const PoseHubMediaReady({required Uri mediaBaseUri});
const PoseHubMediaFailed({required String reason});
```

The host implements this interface with its own downloader/cache. For each
`action.files` entry it follows `downloadUri`, verifies the received byte count
and SHA256, and atomically installs the verified file under `file.path`.
Only after the required action files are installed should it emit **Ready**.
The SDK does not download, cache, choose storage policy or verify file contents
on behalf of the host. Declared file sizes/hashes are public API inputs.

Pass the same optional preparer through the desired public entry point:

```dart
PoseHubActionBrowser(
  catalog: library,
  mediaBaseUri: existingLocalDirectory,
  mediaPreparer: appMediaPreparer,
);
PoseHubSinglePracticePage(
  action: action,
  mediaBaseUri: existingLocalDirectory,
  mediaPreparer: appMediaPreparer,
);
PoseHubPackMedia(
  action: action,
  baseUri: existingLocalDirectory,
  playing: requestedPlayback,
  mediaPreparer: appMediaPreparer,
);
```

Contract and timing:

1. Listing, searching, filtering and opening details do **not** invoke the
   preparer. Entering single practice prepares that action. Direct media
   widgets prepare only when `playing` is requested; still covers do not.
2. Emit zero or more Progress events, then one terminal Ready or Failed.
   `fraction` must be finite in 0..1; byte counts must be nonnegative and
   received must not exceed a known positive total. Unknown totals render an
   indeterminate indicator. A progress value of 100% is **not** Ready.
3. While preparing or failed, the single-practice start button is disabled
   and its clock does not start. Ready enables the button; the user still
   explicitly starts. A standalone media widget creates no decoder before
   Ready. Existing hosts' external session clocks must likewise wait for the
   preparation result before starting their session.
4. Failed displays the supplied safe, user-facing `reason` and a retry button.
   Retry starts a new stream. Do not put credentials or raw transport traces
   in the reason. Unexpected stream errors and completion without a terminal
   result become a safe generic failure; no false Ready is inferred.
5. Native Ready results use an absolute `file:` directory URI ending in `/`.
   Web uses a directory on the page's own origin, backed by the host's cache
   or local server. Release/CDN URLs are download URLs, not prepared playback
   directories. The existing WebGL player requires same-origin playback.
6. Retry, changed input and disposal retire/cancel the old subscription and
   ignore late events. Cancellation means this consumer no longer needs the
   result; the host decides whether shared downloads should continue.

Without `mediaPreparer`, the existing `mediaBaseUri` playback and single-practice
behaviour remain unchanged. The new progress/error states use existing opaque
light/dark `TrainerTheme` surfaces. No existing training layout, no-flash button
or Morph Pulse is changed.

## Reproducible tooling and verification

`tool/posehub_compress.py` reads the specifically audited v2 input, writes a
separate directory, limits CPU/memory concurrency, verifies every output and
keeps per-file recovery receipts. Its input-source audit SHA is not a runtime
catalogue gate. `tool/posehub_r2_assets.py` uses the official S3-compatible R2
API through boto3 and existing host credentials. Conditional creation with
`If-None-Match: *` prevents overwriting an existing object, including a racing
writer. Existing objects are reused only after size, SHA256 and HTTP metadata
match; conflicts stop. Per-file receipts remain outside Git. The backup ZIP
is built from and checked against every catalogue entry. GitHub uploads
are limited to the final catalogue and ZIP; old per-file draft assets were
removed before publication.

For maintainers, install Pillow and boto3 in an isolated Python environment.
Wrangler manages the bucket/domain with the host's Cloudflare login. The
uploader uses the existing `CLOUDFLARE_API_TOKEN` only in memory; it does not
create tokens or save credentials. Supply the approved catalogue SHA explicitly:

```text
python tool/posehub_r2_assets.py verify --root <compressed-pack-root> --catalog-sha256 <approved-sha256>
python tool/posehub_r2_assets.py upload --root <compressed-pack-root> --catalog-sha256 <approved-sha256> --journal <outside-git>/r2-upload-receipts.json --workers 4
```

SDK/host integration is independent of this maintainer environment. Public
media downloads require no token. Anonymous HTTP checks identify themselves as
`UGK-PoseHub-Release-Verification/1.0`; no cookies or authorization are sent.
Five files (three videos, a cover and a thumbnail) return HTTP 200 with matching
catalogue SHA256, MIME type, immutable cache directives and public GET CORS.
The [anonymous download receipts](media/v3-quality/r2-anonymous-verification.json)
list the exact URLs, sizes and hashes. Native Dart and okhttp client signatures
also returned HTTP 200 on the sampled public media.

| Automated validation | Passing tests |
| --- | ---: |
| coach | 497 |
| trainer | 298 |
| coach_ui | 33 |
| Python pack/compression/R2 tooling | 50 |

Static analysis of the changed catalog/UI files reports no issues. The media
preparation regressions include cancellation reentry, stale events, retry,
readiness gating and resetting a started clock when the host provider changes.

The five quality comparisons include whole-body and enlarged detail crops:

- [abs-A](media/v3-quality/abs-A.png)
- [chest-B](media/v3-quality/chest-B.png)
- [h-lateral-step-lunge](media/v3-quality/h-lateral-step-lunge.png)
- [forearms-C](media/v3-quality/forearms-C.png)
- [h-towel-isometric-curl](media/v3-quality/h-towel-isometric-curl.png)

The compared encoded files retain visible joints, hands and equipment edges;
no obvious new blocking was observed in these samples. All 219 output videos
are fully decoded and checked for unchanged frame count/rate, packed dimensions,
profile/pixel format, no audio and faststart. These are source/codec checks,
not native hardware or Raster P99 measurements.
