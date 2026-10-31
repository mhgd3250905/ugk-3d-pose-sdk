# HipLab +24 all-block dose-search regression

The third real conversation turn requested replacing the plan and shortening it
to five minutes. The captured SDK `caa6817c` result is retained unchanged in
`captured-plan.json`: its card was 335 seconds and the real HipLab player's
voice-aware offline timeline was 349 seconds including 15 seconds of preparation.

`manifest.json` records the source capture, profile, catalog, voice manifest and
every fixture file's SHA-256. The exact source capture is in
`E:/AII-3D/hiplab-releases/coach-v2-plus24-20261031/live/results.json`, case 2;
the reproduction note beside it documents the original failure.

The source did **not** retain the raw `draft_plan` response body or a pre-draft
session snapshot. `state-before-reconstructed.json` therefore follows the
documented reconstruction: keep version 1, put planning back to current and
review/output to pending, reset the last delivered version/turn to 1, and retain
the remaining state fields. `draft-arguments.json` projects the captured title
and ordered block/action IDs. These files are controlled offline replay inputs,
not claims of a historically captured request or snapshot.

Catalog drill objects and metadata are unchanged. The projection retains all 21
drills needed by the session's seen/picks and plans. Profile, the bundled voice
manifest and action kits are exact byte copies; no rhythm, lead, dose limits,
voice duration, profile tolerance or player preparation setting was altered.
The two additional kits (`n-pelvis-circle`, `s-butterfly`) support generic
unilateral-free counting and timed warmup matrix cases. `h-hip-gate` covers
bilateral counting. Each is exercised at 5/10/20/30 minutes.

The Trainer tests build `Rhythm.fromActionKitJson`, `ManifestVoiceSource` and
`SessionScript.switchSecondsFor` exactly as HipLab's AI player/native metrics.
They sum every phase, then naturally finish the same `SessionEngine` and verify
its visits and completed occurrences. No model requests, audio playback,
application edits, device actions or recapture are involved.
