# 219-action R1 verification — 2026-10-26

Base: approved flat release `c6e261e75dc8647ccc2767bc253af664957c516b`,
integrated and pushed to main before creating `codex/posehub-219-assets`.
Original checkout stays on `fix/phone-feedback-media-20261024` / `159dadf`;
micro-skeuomorphic stash stays `fcda16df8feb2f5546fe7818efc40391c6140ade`.

Release refs: `ugk_coach-v0.6.0`, `ugk_trainer-v0.4.0`,
`posehub-app-test-pack-r1-v1`. Coach UI remains `ugk_coach_ui-v0.2.1`.
No existing tag is moved. [API and pack guide](posehub-app-test-pack-r1.md).

| Check | Result |
| --- | --- |
| Pure Dart coach full suite | 482 passed |
| Flutter trainer full suite, concurrency 2 | 269 passed |
| Flutter coach_ui full suite | 33 passed |
| Existing showcase full suite | 4 passed |
| Whole-pack tool tests | 15 passed |
| Existing media protocol / R1 WebGL protocol | 8 / 11 passed |
| Trainer / coach_ui / example analysis | No issues |
| New coach catalogue model and tests analysis | No issues |
| Full coach analysis | 5 pre-existing `unawaited_return_in_try_block` warnings in unchanged agent/assistant/session code; no new diagnostic |
| Web release build | Passed |
| Android debug APK build (no install/run) | Passed |
| Original media file sizes and hashes | All 657 match; 587,456,377 bytes |
| Whole release ZIP install | 660 verified entries, no replacement of source files |
| HTTP from installed ZIP | All 657 whole files loaded, size and SHA256 match |
| Four training states × light/dark geometry | 8/8 JSON layouts identical to flat closeout baseline |

The new automated cases cover all 219 original IDs/file references, duplicate ID
rejection, 142 complete / 77 pending, exact canonical-byte integrity, deep
immutability, AI projection isolation and exclusion of all pending entries,
browser search/filter/detail and manual practice, first-frame gating,
pause/resume/dispose, legacy native asset compatibility and source-URI checks.

Actual in-app-browser checks at a 430×932 CSS viewport cover light/dark browsing,
complete `abs-A` and pending `g-cable-hip-abduction` transparent playback, stable
paused video time, resume, end/decoder removal, and searching the last original
ID `w-wall-sit`. The source video reports 720×1440, readyState 4 and no decode
error. The cover disappears only after a successfully GPU-composed frame.
The pending entry retains its label and has no synthesized dose.

Real WebGL validation found that `packed` is a GLSL reserved word; changing only
the player's uniform name to `uPackedVideo` fixed compilation. Regression tests
now cover the declaration/binding and compile/link diagnostics. Original video
bytes and packing math are unchanged. Final browser error log is empty.

Actual Web captures (not device screenshots):

- [Light action library](media/library-light.png)
- [Dark action library](media/library-dark.png)
- [Complete action playback, light](media/practice-complete-light.png)
- [Pending action playback, dark](media/practice-pending-dark.png)

The Git payload contains three original metadata JSON files totaling 4,575,219
bytes. `.gitattributes` disables text conversion for these integrity-pinned
files. The whole media ZIP is an independent GitHub Release asset:
592,170,694 bytes, SHA256
`2ec6331499ed723a843cb620f52b250f5ee3310ea39566a58fdf546f3f771d97`.
97 non-catalogue historical media files are excluded. Source review/release
eligibility flags are preserved; completeness does not imply content review.

No simulator, device installation or native playback was performed. Android
compilation is not new native performance acceptance. Native Raster P99 and
iOS packed-alpha decoding remain outside the evidence; unsupported platforms
show the cover and allow manual practice. The prior flat UI device approval
does not certify this new media pack.
