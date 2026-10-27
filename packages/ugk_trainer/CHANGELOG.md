# Changelog

## Unreleased

- Manual skip/previous announcements are leading-edge: a single switch, or the first switch of a burst, speaks immediately instead of after 150 ms. Further switches within 150 ms of the last one are merged, the window restarting on each tap; only the final stop speaks. Returning to the action the burst's first switch announced does not repeat that action's announcement (its `CuePriority.call` start line), and only when the voice output confirmed the line really started playing; its chimes, counts, coaching lines and every other cue play again as usual. A line that was only submitted or still waiting behind another (then cancelled by the next switch), a switch made while sound was off or paused, and an output that cannot confirm starts are never treated as announced; toggling sound clears the record. Disposal still cancels the pending window; the training clock, media handoff and other cues are unchanged.
- Voice start confirmation: new optional `StartReportingVoiceOutput.speakReportingStart` (implemented by `JustAudioVoiceOutput`), `VoiceLineController.speak(onStarted:)` (called when the platform player is told to play the line, after earlier lines and its load, never for a stopped or skipped line) and `VoiceQueue.onStarted`.
- `JustAudioVoiceOutput`: a line asked for while an earlier one still waits for the session no longer drops that earlier line; only a stop, interruption or end does, so lines asked for in the same turn all play in order. A line's wait now counts from when it was asked for, including time spent waiting for audio-session initialization: once the session is ready, a line more than `VoiceLineController.staleAfter` (3 s) late with a newer line already asked for behind it is skipped without playing or reporting a start (the controller's existing backlog rule), so a slow initialization no longer plays an outdated call before the current count. `VoiceLineController.speak` takes an optional `asked` time for this.

## 0.5.0 — 2026-10-26

- Remove the SDK preparation-page / clock gate from training. Keep original bundled standing images visible offline and dissolve them over 180 ms once a video frame is composed; failures retry quietly and do not interrupt timing or speech.
- Add session-scoped two-action preparation scheduling, preserving host ownership of download, byte/hash checks, cache and installed playback directories. Expose the shared queue through custom media requests; prioritize current/next actions through plan transitions and rest.
- Show only complete actions in a two-column Chinese image/name browser with combined equipment, body and type filters. Direct card taps use the shared one-action training player and catalogue doses; the old detail entry delegates there.
- Bundle 219 unchanged cover WebPs (5,316,554 bytes). Report 187 first-frame differences, including 183 visible complete actions, without altering assets. Require coach 0.7.0. Complete 22 px browser cards, square gradient image areas, mint selected filters, clear and empty states. No global palette redesign, emulator or device operation; Kai approved integration and tags. Full scope and evidence: repository `docs/feedback-r1-part1.md`.

## 0.4.2 — 2026-10-26

- Bundle the compressed v3 catalogue and require coach 0.6.2. Its 657 R2 media objects total 163,351,529 bytes, served from `https://media.uuugk.win/pack/r1-v3/` with original relative paths; GitHub retains the catalogue and full ZIP backup. 219 actions and 211/8 semantics are unchanged. Catalogue parsing no longer uses a fixed v2 hash gate.
- Add optional `mediaPreparer` to browsing/navigation, single practice and media playback. The host emits `PoseHubMediaProgress`, `PoseHubMediaReady(mediaBaseUri:)` or `PoseHubMediaFailed(reason:)`; it owns downloads, caching and integrity verification. Ready is required before starting single-practice time; failure offers a reason and retry. Plain browsing never invokes preparation.
- Keep local `mediaBaseUri` behaviour when no preparer is supplied. Use opaque light/dark theme surfaces for new states, preserving existing training layout, no-flash controls and Morph Pulse. New v3 URLs and event/cancellation contracts: repository `docs/posehub-app-test-pack-r1-v3.md`.

## 0.4.1 — 2026-10-26

- Load the reviewed R1 semantic revision: 211 complete / 8 pending / 219 total. Update the pinned catalogue checksum and whole-pack download to `posehub-app-test-pack-r1-v2`; v1 remains available unchanged.
- Require coach 0.6.1 for the approved supplemental AI catalogue. Catalogue bytes, raw unknown/review flags and all media identities remain intact; no playback, layout, manual-practice or training-state changes.

## 0.4.0 — 2026-10-26

- Add `PoseHubActionLibrary`, `PoseHubActionBrowser`, `PoseHubActionDetail` and manual `PoseHubSinglePracticePage` for all 219 original R1 IDs. Label 77 incomplete definitions `训练说明待补`; never synthesize training dose or timing. The coach 0.6.0 `toAiCatalog()` API exposes only the 142 complete definitions.
- Add whole-pack URI images and packed-alpha Web/Android playback. Covers remain selected poses, never fabricated frame-zero posters. Keep the existing trainer layout, no-flash button and Morph Pulse unchanged. Retain covers with explicit unsupported status on other platforms.
- Host media outside Git in one original-byte, hash-verified Release ZIP. No tiered downloads or new runtime dependency. The optional `PackedAlphaUriPlatform` capability preserves existing platform implementers.
- No new API removals. Require coach 0.6.0; the earlier 0.3.x glass migration remains applicable. See the repository's `docs/posehub-app-test-pack-r1.md` for APIs, pack installation and showcase commands.

## 0.3.1 — 2026-10-26（扁平实色收尾，main 待真机确认）

- Finalize the selected flat, opaque UI from `c4d251d`; keep runtime code, training layout, no-flash colour handover and Morph Pulse unchanged. Correct two stale README entries that still advertised deleted glass APIs.
- **Migration from 0.2.x:** `TrainerGlassStyle`, `TrainerGlass`, `TrainerGlassButton`, `TrainerGlassField`, `TrainerHover`, `TrainerTheme.glassStyle` / `glass` / `scrim` and `TrainerStageFloor.fadeClipEdge` are removed. Use `TrainerSurface` / `TrainerIconButton`; direct theme construction requires `border`, `shadow`, `ringKnob` and `accentSubtle`. These are the existing 0.3.0 breaking changes, with no additional API break in this patch.
- Recheck all tracked production sources/manifests for glass dependencies, background blur, optical shaders and switches. Keep negative regression assertions and historical migration records; the packed-alpha video shader remains a media compositor.
- Full final verification and the package tag receipt are recorded in `docs/flat-closeout-2026-10-26.md`. Main integration waits for Kai's device confirmation; the shelved micro-skeuomorphic candidate is not part of this release.

## 0.3.0 — 2026-10-26

- **Breaking:** remove `liquid_glass_widgets` and every optical/painted glass implementation. Delete `TrainerGlassStyle`, `TrainerGlass`, `TrainerGlassButton`, `TrainerGlassField` and `TrainerHover`, including all material flags and compatibility paths. Use `TrainerSurface` / `TrainerIconButton` and the `background`, `panel`, `control` surface levels instead; no aliases or glass toggle remain.
- **Breaking:** remove `TrainerTheme.glassStyle`, its constructor/copyWith argument and `glass` getter, plus the unused `scrim` token. Custom themes must provide `border`, `shadow`, `ringKnob` and `accentSubtle`; every token now supports `copyWith`. Remove the stage-only `fadeClipEdge` parameter. Imports of the deleted private optical surface files must be removed.
- Use three opaque theme-driven surface levels, a low-contrast 1px border and shallow fixed shadow. Remove background sampling, optical shaders, translucent surface stacks, specular gradients and decorative environment lights. Light/dark defaults are supplied; no app-global theme changes or new runtime dependencies are required.
- Keep the training page's control rectangles and media layout, the interruptible Morph Pulse glyph/colour waves/breath/ripple, gesture/state reconciliation and no-flash colour handover. The disc's base is now opaque; it no longer needs a material-opacity saveLayer. Keep the existing radial progress halo and the non-glass packed-alpha media shader.
- Refresh the SDK-only acceptance showcase and its evidence for solid surfaces. Full audit and API migration: `docs/solid-layered-audit.md`; checks and current captures: `docs/visual-review.md`. Tags are produced only after the scoped suites pass; main integration requires separate user approval.

## 0.2.10 — 2026-10-25（已批准版本提交并推进 main）

- Use the tuned Liquid Glass skill recipes for light/dark HUD and hints (thickness 30 / blur 2 / lightIntensity 0.18) and secondary controls (24 / 3 / 0.2), with `liquid_glass_widgets` 1.15.0 premium / clear and its brightness-aware tint. Nested controls share their platter's vibrancy; explicit host `glassStyle` retains its painted path. Preserve v0.2.9 positions, sizes, interactions, repaint boundaries and radial progress halo.
- Unify Cupertino symbols and hint typography, and show a next-action symbol when the 28px preview has no poster. Keep training, counting, voice, state-machine and public call contracts unchanged.
- Include the existing 0.2.4–0.2.9 still-only, media handoff, packed-alpha video and play/pause fixes when advancing main. Their historical branch/device records below do not establish performance for the new sampling material.
- Provide an offline Android/iOS/Web example and paired software layout evidence. The iOS helper requires iOS 15+; Web and unsupported renderers use the library fallback and do not preview native refraction. No host-wide initialization is required.
- Runtime source is unchanged from reviewed `4a843a7`: 253 trainer tests, 4 example tests, both analyses and Android debug build passed; 106 measured control frames match v0.2.9 with 0dp maximum offset. Integration/version checks are recorded in `docs/visual-review.md`. Native R4 appearance, transparent-video composition, device performance and iOS builds remain unverified. This version commit does not publish a new tag.

## 0.2.9 — 2026-10-25（测试分支，未合 main）

- Add opt-in RGB-over-alpha MP4 assets and a matching transparent frame-zero poster to `DrillMedia`. Render the full-height packed texture with an Android MediaPlayer/SurfaceProducer and GPU `ImageFilter.shader` composition, then apply output-height scaling; no new video-player dependency or per-frame Dart pixel readback.
- Gate the transparent path on Android/Impeller support and actual native rendering-start, retaining the existing ordinary-MP4/still fallback, 150ms final-target handoff and 120ms first-frame/poster transition. Document asset layout, theme fallbacks and stable builder keys.
- Add `bundledOnly` to keep App-verified local packed and fallback media out of an unrelated inherited repository. Do not show repository download UI for those local paths.
- Add `DrillMediaPlaybackHandle.capture()` and a one-shot decoder position protocol for App-owned issue reporting. Preserve the captured media identity across quick switches; missing or failed queries return null without failing playback or substituting the training clock.
- Buffer native ready/first-frame/state/error events until the EventChannel listener arrives, release textures on initialization failure and discard stale owners. Scope integration tests cover the loaded local path, failure fallback and absence of repository resolution/download UI. Preserve an alpha still when an unsupported backend has no ordinary MP4/poster.
- Android Impeller Vulkan profile validation: steady/switch Raster P99 was 8.427/8.312ms in light and 8.059/7.086ms in dark. The four measured windows had no Raster frame above 16.67ms; these are raster-thread timings, not hardware presentation-FPS claims.

## 0.2.8 — 2026-10-25（分支性能修复，待开哥最终 release 复测后合 main）

- Use the existing theme-driven `overMedia` fill for the training information card and close/previous/next controls, removing their live backdrop blur. Give the countdown and neighbouring controls independent repaint boundaries.
- Replace the progress-head mask blur with a radial-gradient halo. Preserve the public API, theme colours, dimensions, play/pause animation state machine, media and training clock behaviour.
- Targeted SDK tests: 22/22; SmartFit integration tests: 9/9; scoped analysis: no issues. Paint probes confirm that paused breathing no longer repaints previous/next controls, and media/progress paints remain isolated. No full-suite rerun for this patch.
- Reconnected-device `candidateResumeFull` profile: entry 187 valid frames over three seconds, UI maximum 13.246ms and raster maximum 21.407ms (within the 33ms entry limit); steady 907 frames, raster P99/max 9.054/10.258ms and zero above 16.67ms; button 1231 frames, 6.965/10.200ms and zero above; switching 988 frames, 8.286/19.573ms and one above. These samples meet the requested P99 limits. All 20 single/rapid-tap conservative `tap + 600ms` windows have zero raster frames above 16.67ms; the zero-overrun requirement applies to button animation, not every switching frame.
- The temporary ripple/glow-off control has 1248 frames, raster P99/max 7.297/14.185ms and zero above 16.67ms, showing no clear benefit over the complete button effects; keep those effects. The earlier 24.895ms button sample remains in the original report, so these results do not promise perpetual zero slow frames or hardware presentation at a fixed 60fps.
- Native frames were reviewed in the original VM full trace; DevTools UI import/review is still pending. Timeline retrieval now occurs after each measurement window because the original twice-per-second VM polling introduced UI spikes; those instrumentation effects must not be reported as code optimisation gains. Keep this work on its branch until the final release-device retest is confirmed.

## 0.2.7 — 2026-10-25（分支修复，待真机确认后合 main）

- Add the theme-driven UgkPlayPauseButton and use it in TrainerPlayer: continuous two-polygon icon morph, interrupted colour waves, release spring and touch-only ripple/haptics.
- Preserve the 76/96px disc/ring geometry and progress source; pause breath and ring opacity transition without repainting the video.
- Reconcile optimistic taps with real playback state, preserve keyboard/localized semantics, and support the 150ms reduced-motion branch.

## 0.2.6 — 2026-10-25（分支修复，待真机确认后合 main）

- Replace retained live media cross-fades with an 150ms final-target handoff and a first-composited-frame-gated 120ms reveal over the target poster. Keep the pre-frame surface compositing at a nonzero alpha; disable native video controls.
- When a target has no poster, pause and capture the previous video's current decoded frame with a bounded request/reply before disposing that player. Never reuse dark snapshots as light frames; preserve mirrored orientation.
- Bind native/Web callbacks and command sinks to their controller generation. Recreate iframe elements and validate page sessions so retired pages cannot ready or reveal the next target.
- Coalesce navigation voice cues without pausing the training clock. Standalone/manual demonstrations keep immediate play/pause behaviour. Custom training media builders must use stable keys; see README.
- Targeted media/player/navigation regressions: 63/63, including 13 new handoff tests. Player protocol tests: 8/8. Scoped analysis: no issues. Per the latest user instruction, this patch does not rerun the full suite.

## 0.2.5 — 2026-10-24（分支修复，待真机确认后合 main）

- Move the next-exercise preview below the information bar at the top left, alongside the safety control. Constrain and wrap its text without shrinking the font; preserve the preview while paused.
- Remove the redundant paused HUD tag. Add optional host-supplied `TrainerTheme.pausedColor` / `onPaused` tokens for the central resume button; resuming restores the existing accent colours and accessible button labels.
- Preserve timer, voice, interruption, discomfort and training completion behaviour. No engine or media changes in this patch.
- Full trainer tests: 216/216; analysis: no issues. Added light/dark 320px / 1.5x HUD, pause-colour, resume-colour and accessible-label regressions.

## 0.2.4 — 2026-10-24（分支修复，待真机确认后合 main）

- Add `DrillMedia.videoAvailable` (default true) and `DrillMediaView.unavailableLabel` for intentional still-only demonstrations. Missing videos do not start downloads or players; real transport and decode failures remain errors.
- Retire the previous player and frame when selection, explicit theme, asset path or availability changes. Start only after inherited repository/theme inputs are known.
- Full trainer tests: 213/213; analysis: no issues. Existing dark/light manifest resources are verified offline without remote mirrors. No coach or coach_ui runtime changes.

## 0.2.3 — 2026-10-24（待审，未发布）

- Align the coach version constraint to `^0.5.0` and the Git dependency to the proposed `ugk_coach-v0.5.0` tag, so hosts can adopt `CoachConversationController` without incompatible transitive package sources.
- No trainer runtime changes. Publish `ugk_trainer-v0.2.3` only after approval, together with the coach release; existing tags remain unchanged.

## 0.2.2 — 2026-10-24（已批准合入并发布 tag）

- `ugk_trainer-v0.2.2` is fixed at `3302d6235a39e2c2b4b51fa196cc32b37c31b54c`.

- Use an ASCII-only package manifest so Windows Pub can read Git metadata with the system encoding. Pin the equally corrected `ugk_coach-v0.4.2` manifest. No trainer runtime changes from 0.2.1.

## 0.2.1 — 2026-10-24（已批准合入并发布 tag）

- `ugk_trainer-v0.2.1` is published at `f0ea0647586913b205fc6dbb75fc9f97cedc55ce`.

- Pin the coach dependency to `ugk_coach-v0.4.1`. A relative dependency from a Git subpackage resolves to a commit ref and conflicts with a host that explicitly pins the coach release tag, even when both refs identify the same commit. Hosts can now pin coach and trainer release tags together without dependency overrides.
- No trainer runtime changes from 0.2.0.

## 0.2.0 — 2026-10-23（已合入并推送 main）

- Documentation closeout on 2026-10-24: verified remote main at `8b60032c2f43fd8e91f8802c8f054a8ecb7cc110`, containing accepted source `64a54874307449c8685577f8eeb913296b207a7c`. No package version increment. FlareLab will pin the delivered main commit and perform device acceptance; SmartFit/HipLab upgrades remain deferred.

- Count unique sets only after all required sides and segments finish. Replayed visits accumulate time without replacing an unfinished set. Item and session completion share the original phase requirements; phase-end comparison absorbs floating-point error.
- Missing reps rhythms now use public `RhythmDefaults` (3 seconds per rep, per-category overrides, hold duration when provided), with automatic counts and group completion. Explicit catalog `self_paced` and existing App-authored self-paced rhythms remain supported. Video loop duration is never a rep duration.
- Support `PlanItem.segments` from ugk_coach 0.4.1: ordered media/rhythm/dose per segment, one parent item in UI and results, skipped segments are partial. Existing plans and constructor calls remain supported.
- Optional player controls: extend rest by 15 seconds, complete a timed work phase early, toggle sound, and skip a segment. Interruptions pause until the user resumes; unsupported voice languages fall back to App-provided chimes.
- Full contract, platform setup, compatibility limits and verification evidence: [0.2.0 integration](../../docs/trainer-020-integration.md). Root 0.4.0's previously added `AgentEventKind.askUser` requires old exhaustive switches to add a branch; this trainer change does not repair App chat code automatically.

## 0.1.7 — 2026-10-23

- Integrate the immersive trainer stage and liquid-glass controls from [PR #6](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/6). The reviewed head is `b84881f58c035b1fce2ff929cdb207e465821c92`; main merge `eb29c749a52c1b226841726a3fba8e9f62e9e6be` has the same tree.
- Keep the self-paced target dose visible alongside 完成本组 during work, pause and subsequent sets, including the host's `doseLabel`. Scale the top card, subtitle and countdown slots with system text size; restore Tab / Enter / Space and visible focus for glass controls.
- Add glass/stage widgets, `TrainerCountdownDigits` and optional `TrainerTheme` glass customization while preserving existing player constructor parameters. Built-in media and the theme passed to host media builders use radius 0 on the stage. Retain 0.1.5 / 0.1.6 media caching and internal preview policy.
- Validation on the reviewed source: 170 trainer Flutter tests (including 17 r9 regressions), 377 root Dart tests, and no issues from `flutter analyze --no-pub`. Physical-device frame rate, native playback and host full-session acceptance remain unverified.
- This closeout changes package metadata from 0.1.6 to 0.1.7 and aligns documentation; root `ugk_coach` stays at 0.3.3. `publish_to: none` remains in effect.

### Development iterations (history)

The following notes preserve the intermediate r1–r9 designs. Positions, dimensions and API statements describe those iterations; the final 0.1.7 behavior and verification scope are summarized above and in the README.

#### stage review fixes r9

- Self-paced sets keep their target visible: the top card's muted line now leads with the set's dose (e.g. `8 次 · 第 2/3 组`, or the host's `doseLabel`) for the whole set — working, paused and on the next set — while 完成本组 holds the transport slot above the pause button.
- Large system text: the top card, the stage space reserved under it, the subtitle slot and the countdown number slot now size from `MediaQuery.textScalerOf` (never below their 1× sizes), so 1.5× / 2× text no longer overflows the card or clips the countdown; the number slot also scales down instead of clipping if a host theme's numerals run taller, and 完成本组 has a 44 px minimum instead of a fixed height. Slots stay fixed within one screen, so the r6–r8 no-jump guarantees hold.
- `TrainerGlassButton` (close, previous, pause / resume, skip) is keyboard-operable again: Tab focuses it, Enter / Space activate it, and keyboard focus shows a 2.5 px accent ring; disabled buttons are skipped. Semantics gain the focus action.
- New `stage_r9_test.dart`: target reps visible in work / paused / next set and with a host `doseLabel`; no overflow and an unclipped countdown / 完成本组 at 1 / 1.5 / 2× in portrait and landscape; Tab + Enter / Space on a glass button and on the player's pause button. Public API unchanged.

#### stage 完成本组 r8

- 完成本组 is no longer a pendant over the clip: on a self-paced set it takes the transport's number slot, centred right above the pause button (the dose it replaces is already on the top card). It now sits below the clip's bottom edge, so the demo is never covered; 44 px tap target, emerald pill as before. The number slot grows 36 → 44 px for every phase, so nothing moves between timed and self-paced sets.
- The over-stage pendant slot (next-up preview / host rest feedback) shrinks 44 → 36 px, the next-up chip's height, keeping it low just above the subtitle chip; still fixed slots, bottom-anchored.
- `stage_transition_test` asserts on 360×780 and 390×844 that 完成本组 sits below the clip and above the pause button, ≥ 44 px, and keeps the same rect from one set to the next; `trainer_player_test` layout checks updated. Public API unchanged.

#### stage chips r7

- The coach subtitle chip (e.g. 收紧臀部) is now the lowest thing on the stage, just above the transport — below the clip's bottom edge wherever the stage leaves room — so it covers as little of the demo as possible. The next-up / 完成本组 / rest-feedback pendant hangs above it. Both sit in fixed slots (pendant 44 px, subtitle two lines), so neither moves across pages, phases, clip loading or one- vs two-line subtitles; `stage_transition_test` still asserts no jump and now also that the subtitle sits below the pendant slot.
- On-media chips (下一个 / 不舒服 / paused / switch-side tags, subtitle, next-up preview) follow the theme: light mode paints a white frost (`TrainerGlassStyle.light.overMediaFill` `0xE6FBFCFE`) with ink text / icons, the light glass hairline, rim and soft shadow, and the light caution amber; dark mode keeps the dark smoke `0xC71A1D22` with white text. Still a fixed fill with no backdrop sample, so the tone is stable from the first frame while the clip loads.
- `TrainerGlassStyle` gains an `overMediaIsLight` getter (from the fill's luminance); `TrainerGlass(overMedia: true)` now uses the theme's own glass instead of always the dark preset. Custom styles without `overMediaFill` keep the dark default. Public API otherwise unchanged.

#### stage transitions r6

- Subtitle chip no longer jumps on page / phase changes: the bottom pendant (none / 下一个 preview / 完成本组) sits in a fixed 44 px slot, and the cross-fades lay out at the incoming child's size (the outgoing one is overlaid, takes no room), so the chip above keeps one position from its first frame instead of moving when the old pendant is removed. The clip slot was already a fixed square independent of media load.
- HUD chips on the clip (下一个 / 不舒服 tags, subtitle, next-up) no longer take a backdrop sample: they paint a stable dark fill (`TrainerGlassStyle.overMediaFill`, default `0xC71A1D22`), so their tone does not drift from light grey to dark while the new clip loads / cross-fades behind them. Other glass surfaces unchanged.
- New regression test `stage_transition_test.dart` (chip position identical mid-fade, settled and in prep with a media builder that changes on load; no `BackdropFilter` under on-media chips). Public API unchanged apart from the new optional style field.

#### stage layout r5

- Top card: the close button is centred on the card's full height on the left; the move name, its muted line and the segmented progress now share one left edge, and the progress ends under the index's right edge (no longer card-edge to card-edge). Padding balanced (12 / 16).
- Liquid glass refined (both themes): one backdrop filter per surface, now blur + saturation / brightness boost composed into a single `ImageFilter` (light σ10 ×1.6, dark σ6 ×1.3); a crisp 1 px specular rim bright on the top edge fading down the sides; an inner top sheen; a faint inner bottom shade for thickness; a tight contact + soft ambient shadow painted only outside the shape so the glass stays clear. Applied to every `TrainerGlass` surface (card, chips / pendants, transport buttons, sheets).
- Light stage given colour for the glass to refract: low-saturation ambient pools (emerald top-left under the card, sky top-right, peach bottom-right under the transport, mint bottom-left), painted over clip and floor alike so the clip's backdrop edge stays seamless. Light glass is cooler / whiter with a stronger top rim and more shadow contrast. Dark: a faint emerald / indigo glow at the corners, softer rim.
- `TrainerGlassStyle` gains optional `saturation`, `brightness`, `innerShade`, `contactShadow`, `ambientShadow` and a `backdrop` getter (all defaulted; existing constructors keep working). Public API otherwise unchanged.

#### stage layout r4

- Top card calmed to two levels: the move name (17 semibold, one line) over a single short muted line — at most two parts (`第 2/3 组 · 左侧`, `左侧 · 30 秒`, or the block name `热身`; a rep set's dose lives at the transport, not here; prep / rest / switch: phase label · dose up next). Block names, round counters and the duplicated n / total text are gone. On the right a designed exercise index: a large light `4` with a small muted `/5` on one tabular baseline (semantics `4 / 5`). Hairline progress kept along the inside bottom; more padding, same ~73 px height.
- The counter ring left the card: the countdown is now a thin ring around the emerald pause / play button (remaining time for timed moves, prep, rest and side switches; rep progress for clock-counted sets; empty track for self-paced sets; fades with pause).
- The number sits just above the button on the same axis (new `TrainerCountdownDigits`: 32 px light tabular numeral, small muted unit `秒` / `/ 12 次`; self-paced sets show the dose). Last 3 s of a timed move take the accent and breathe once per second (reduced motion: colour only). Kept outside the button so the button keeps its one job and its 暂停训练 / 继续训练 label; the number has its own semantics label (e.g. `28 秒`).
- `TrainerRingPainter` gains optional `thickness` (default .05, unchanged). Pendants (完成本组, next-up, subtitle) now hang above the number slot, so nothing collides. Public API otherwise unchanged.

#### stage layout r3

- Top card slimmed to one row (~71 px, was 172): small close, move name on one line, phase / block label · dose and n / total on a small second line, a 46 px counter ring (its caption kept as the ring's semantics label), and the workout progress as a 3 px hairline along the card's inside bottom.
- The demo clip now takes the whole stage between the card and the transport, as large as fits (up to 1.15× the screen width; its flat backdrop continues as the stage, so the sides run off seamlessly), sitting slightly above centre. No layout slots are reserved under it any more.
- Everything else is a small pendant over the stage, never on the body: paused / next / switch-side tag and 不舒服 as 32 px chips in the top corners under the card (不舒服 keeps a 44 px touch target and its label); next-up as a 36 px glass chip (round thumbnail, 下一个 · name) at the bottom-left; 完成本组 as a compact 44 px emerald pill centred just above the transport (same key and label); the coach subtitle as a small translucent chip (max two lines) above that; the host's rest feedback in the same bottom pendant slot.
- Prev / pause / skip row and the done view unchanged. Public API unchanged.

#### stage layout r2

- Player re-laid out top → bottom: a glass title / count card at the top (close, block or phase label, move name, dose, counter ring 104), the square demo clip centred in the space left between it and the controls, and the prev / pause / skip row unchanged and fixed to the bottom safe area.
- Workout progress redesigned into the card's inside bottom edge: one slim segment per exercise (done = accent, now = tinted, upcoming = track; a single bar above 24 exercises) with n / total beside it. The old top progress bar and floating n / total pill are gone.
- HUD pills (paused / next / switch side, 不舒服) sit at the clip's top corners; coach subtitle is two centred lines under the clip; one fixed action slot above the controls holds the compact next-up card while working, 完成本组 for self-paced sets, or the host's rest feedback. Rest uses the same structure; the done view puts badge, title and the finished track in the same top card, stats in the middle, finish at the bottom.
- `TrainerStageFloor` gains optional `clipTop` (default 0) so the floor glow, grid and edge fades follow a centred clip; it also softens a centred clip's top edge. Public API otherwise unchanged. Reduced motion keeps segment / bar changes instant.

#### immersive stage

- Player laid out as a 3D stage: the square demo clip sits edge-to-edge at the top (full width, under the status bar, no card frame or radius) and its own backdrop (`TrainerTheme.mediaStage`, the colour the clips are baked on) continues down the screen, so clip and stage read as one space. The clip narrows only on short / wide screens so the fixed slots never squeeze.
- New `TrainerStageFloor` (one static CustomPainter: pool of light / contact shadow under the figure, faint receding floor grid, soft depth fog, a fade over the clip's lower edge) and `TrainerHover` (soft contact shadow so glass panels hover above the floor). No extra blur.
- Controls float in that space as liquid glass: the close / block / count bar over the clip, HUD pills (paused / next / side, 不舒服) at the clip's lower corners, an info panel (label, name, dose, ring) overlapping the clip's lower edge, next-up card and transport buttons with hover shadows. The done view uses the same stage. Ring 120 (was 128).
- Built-in media is drawn with radius 0; `TrainerMediaRequest.theme` carries `radius: 0` so host media builders render edge-to-edge too. Public signatures unchanged; `TrainerGlassField` is kept but no longer drawn by the player.

#### liquid-glass UI

- Player redesigned in SmartFit's clear liquid-glass language (feat/ui-polish): dependency-free `TrainerGlass` / `TrainerGlassButton` / `TrainerGlassField`, glass round transport controls with an emerald primary disc, glass HUD pills over media (40 px, legible at arm's length), glass next-up card and done-view stats, stadium primary buttons, rounded glass-edged discomfort sheet and close dialog, larger counter (128) and numerals.
- Calm motion: 500 ms `Curves.fastOutSlowIn` phase changes where the old content leaves before the new arrives; reduced motion keeps crossfades.
- Theme hook: `TrainerTheme.glassStyle` / `glass` and `TrainerTheme.copyWith`; dark background is now SmartFit's neutral sky. Public widget signatures unchanged.

## 0.1.6

- Export the shared compile-time `TrainingMediaPreviewPolicy.enabled` so hosts and the repository use the same pending-media preview gate. Preserve the existing debug behavior; release/profile require both the `internal` Flutter flavor and `UGK_INTERNAL_MEDIA_PREVIEW=true`.
- Keep pending actions hidden by default, including internal builds: callers must still explicitly request `allowPending: true`. Ordinary production builds and either opt-in alone remain blocked. The policy does not change platform cleartext settings; hosts must separately isolate any LAN HTTP allowance to their internal flavor.
- Add a standalone AOT compilation matrix for all debug/profile/release, absent/production/internal flavor and preview-flag combinations, plus a Flutter build-mode agreement test. Host release APK and physical-device acceptance are separate validation steps.

## 0.1.5

- Add a shared `TrainingMediaRepository` for the three apps: bundled assets first, versioned native cache second, then ordered HTTP(S) mirrors. Download to temporary files and verify declared length and SHA-256 before publishing; verify persistent cache again before reuse.
- Resolve submanifests through the bundled main index, verify their hashes and action/file indexes, and fetch additional render manifests with their packages. Only release-eligible actions are visible outside an explicit debug-only pending-action gate.
- Default downloads to Wi-Fi, resume policy-blocked actions/packages when the connection permits, expose progress and cache usage, and cancel/join transfers before cache deletion. A failed HTTP response or digest remains failed until an explicit retry.
- Report and clear every version under the app-owned `training-media` cache root while preserving unrelated app caches; tolerate files/directories disappearing during size scans.
- Keep the poster and a loading/failure label while media is unavailable; training timing and voice remain independent. Native WebViews stream verified cache files through one fixed loopback capability route with bounded byte ranges; existing bundled-only constructors remain compatible.
- Add local HTTP fault-injection tests for offline playback, stalled bodies, mirror fallback, invalid digests/manifests, startup corruption, Wi-Fi changes, cache-clear races, range handling, and nonblocking view fallback. Native device playback acceptance remains the host app's responsibility.

## 0.1.4

- Add an explicit media-playback owner mode to the existing Android training service, with one framework MediaSession and a MediaStyle token. Generic self-check holds do not advertise media playback.
- Synchronize the session's playing/paused state with the trainer and release it at finish, destruction, task removal or the native safety cap. Preserve stale-owner isolation and do not add continuous audio focus or another service.
- Native 0.1.3 testing still reproduced Xiaomi Greeze freezing after about five minutes despite an unmuted all-zero track. Media-session integration is a further candidate, not a guarantee of OEM background compatibility; host device acceptance remains required.

## 0.1.3

- Play the digital-silence keep-alive at normal player volume on Android. Android excludes client-volume-muted tracks from active playback, and Xiaomi Greeze still froze a 0.1.2 session after about five minutes with the service and track present. iOS retains zero player volume.
- The bundled asset decodes to all-zero PCM samples, so this changes playback activity classification without adding audible sound or continuously holding audio focus. Interruption, owner cap, completion and replay release behavior is unchanged; host real-device acceptance is still required.

## 0.1.2

- Keep Android training audio active across coaching gaps with the bundled silent loop, without continuously holding audio focus. This addresses an observed Xiaomi Greeze freeze despite an active mediaPlayback service and wake lock.
- Pause the loop for interruptions and output disconnection, stop it at session end, and cap each owner at two hours without extending the cap on reactivation.
- Release audio after completion cues even when the player remains on its result page; cancel the old completion release on immediate replay.
- Real-device verification remains required for each host's supported devices; the silent loop alone is not a device acceptance result.

## 0.1.1

- Add app-specific session builders and voice script factories, authored dose labels, discomfort phase replacement, response clips/subtitles, rest feedback, and in-place replay slots.
- Allow silent discomfort dialogs without changing ordinary pause/resume announcements; audio reactivation and keep-alive renewal still run on resume.
- Exclude skipped exercises from result completion counts and preserve unequal per-side planned/completed set counts in optional result fields.
- Preserve accessible discomfort button labels/actions and fit countdown text inside its fixed dial.
- Keep existing player defaults and result JSON readable. Native device acceptance remains the host application's responsibility.
