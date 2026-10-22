# Changelog

## Unreleased — stage transitions r6

- Subtitle chip no longer jumps on page / phase changes: the bottom pendant (none / 下一个 preview / 完成本组) sits in a fixed 44 px slot, and the cross-fades lay out at the incoming child's size (the outgoing one is overlaid, takes no room), so the chip above keeps one position from its first frame instead of moving when the old pendant is removed. The clip slot was already a fixed square independent of media load.
- HUD chips on the clip (下一个 / 不舒服 tags, subtitle, next-up) no longer take a backdrop sample: they paint a stable dark fill (`TrainerGlassStyle.overMediaFill`, default `0xC71A1D22`), so their tone does not drift from light grey to dark while the new clip loads / cross-fades behind them. Other glass surfaces unchanged.
- New regression test `stage_transition_test.dart` (chip position identical mid-fade, settled and in prep with a media builder that changes on load; no `BackdropFilter` under on-media chips). Public API unchanged apart from the new optional style field.

## Unreleased — stage layout r5

- Top card: the close button is centred on the card's full height on the left; the move name, its muted line and the segmented progress now share one left edge, and the progress ends under the index's right edge (no longer card-edge to card-edge). Padding balanced (12 / 16).
- Liquid glass refined (both themes): one backdrop filter per surface, now blur + saturation / brightness boost composed into a single `ImageFilter` (light σ10 ×1.6, dark σ6 ×1.3); a crisp 1 px specular rim bright on the top edge fading down the sides; an inner top sheen; a faint inner bottom shade for thickness; a tight contact + soft ambient shadow painted only outside the shape so the glass stays clear. Applied to every `TrainerGlass` surface (card, chips / pendants, transport buttons, sheets).
- Light stage given colour for the glass to refract: low-saturation ambient pools (emerald top-left under the card, sky top-right, peach bottom-right under the transport, mint bottom-left), painted over clip and floor alike so the clip's backdrop edge stays seamless. Light glass is cooler / whiter with a stronger top rim and more shadow contrast. Dark: a faint emerald / indigo glow at the corners, softer rim.
- `TrainerGlassStyle` gains optional `saturation`, `brightness`, `innerShade`, `contactShadow`, `ambientShadow` and a `backdrop` getter (all defaulted; existing constructors keep working). Public API otherwise unchanged.

## Unreleased — stage layout r4

- Top card calmed to two levels: the move name (17 semibold, one line) over a single short muted line — at most two parts (`第 2/3 组 · 左侧`, `左侧 · 30 秒`, or the block name `热身`; a rep set's dose lives at the transport, not here; prep / rest / switch: phase label · dose up next). Block names, round counters and the duplicated n / total text are gone. On the right a designed exercise index: a large light `4` with a small muted `/5` on one tabular baseline (semantics `4 / 5`). Hairline progress kept along the inside bottom; more padding, same ~73 px height.
- The counter ring left the card: the countdown is now a thin ring around the emerald pause / play button (remaining time for timed moves, prep, rest and side switches; rep progress for clock-counted sets; empty track for self-paced sets; fades with pause).
- The number sits just above the button on the same axis (new `TrainerCountdownDigits`: 32 px light tabular numeral, small muted unit `秒` / `/ 12 次`; self-paced sets show the dose). Last 3 s of a timed move take the accent and breathe once per second (reduced motion: colour only). Kept outside the button so the button keeps its one job and its 暂停训练 / 继续训练 label; the number has its own semantics label (e.g. `28 秒`).
- `TrainerRingPainter` gains optional `thickness` (default .05, unchanged). Pendants (完成本组, next-up, subtitle) now hang above the number slot, so nothing collides. Public API otherwise unchanged.

## Unreleased — stage layout r3

- Top card slimmed to one row (~71 px, was 172): small close, move name on one line, phase / block label · dose and n / total on a small second line, a 46 px counter ring (its caption kept as the ring's semantics label), and the workout progress as a 3 px hairline along the card's inside bottom.
- The demo clip now takes the whole stage between the card and the transport, as large as fits (up to 1.15× the screen width; its flat backdrop continues as the stage, so the sides run off seamlessly), sitting slightly above centre. No layout slots are reserved under it any more.
- Everything else is a small pendant over the stage, never on the body: paused / next / switch-side tag and 不舒服 as 32 px chips in the top corners under the card (不舒服 keeps a 44 px touch target and its label); next-up as a 36 px glass chip (round thumbnail, 下一个 · name) at the bottom-left; 完成本组 as a compact 44 px emerald pill centred just above the transport (same key and label); the coach subtitle as a small translucent chip (max two lines) above that; the host's rest feedback in the same bottom pendant slot.
- Prev / pause / skip row and the done view unchanged. Public API unchanged.

## Unreleased — stage layout r2

- Player re-laid out top → bottom: a glass title / count card at the top (close, block or phase label, move name, dose, counter ring 104), the square demo clip centred in the space left between it and the controls, and the prev / pause / skip row unchanged and fixed to the bottom safe area.
- Workout progress redesigned into the card's inside bottom edge: one slim segment per exercise (done = accent, now = tinted, upcoming = track; a single bar above 24 exercises) with n / total beside it. The old top progress bar and floating n / total pill are gone.
- HUD pills (paused / next / switch side, 不舒服) sit at the clip's top corners; coach subtitle is two centred lines under the clip; one fixed action slot above the controls holds the compact next-up card while working, 完成本组 for self-paced sets, or the host's rest feedback. Rest uses the same structure; the done view puts badge, title and the finished track in the same top card, stats in the middle, finish at the bottom.
- `TrainerStageFloor` gains optional `clipTop` (default 0) so the floor glow, grid and edge fades follow a centred clip; it also softens a centred clip's top edge. Public API otherwise unchanged. Reduced motion keeps segment / bar changes instant.

## Unreleased — immersive stage

- Player laid out as a 3D stage: the square demo clip sits edge-to-edge at the top (full width, under the status bar, no card frame or radius) and its own backdrop (`TrainerTheme.mediaStage`, the colour the clips are baked on) continues down the screen, so clip and stage read as one space. The clip narrows only on short / wide screens so the fixed slots never squeeze.
- New `TrainerStageFloor` (one static CustomPainter: pool of light / contact shadow under the figure, faint receding floor grid, soft depth fog, a fade over the clip's lower edge) and `TrainerHover` (soft contact shadow so glass panels hover above the floor). No extra blur.
- Controls float in that space as liquid glass: the close / block / count bar over the clip, HUD pills (paused / next / side, 不舒服) at the clip's lower corners, an info panel (label, name, dose, ring) overlapping the clip's lower edge, next-up card and transport buttons with hover shadows. The done view uses the same stage. Ring 120 (was 128).
- Built-in media is drawn with radius 0; `TrainerMediaRequest.theme` carries `radius: 0` so host media builders render edge-to-edge too. Public signatures unchanged; `TrainerGlassField` is kept but no longer drawn by the player.

## Unreleased — liquid-glass UI

- Player redesigned in SmartFit's clear liquid-glass language (feat/ui-polish): dependency-free `TrainerGlass` / `TrainerGlassButton` / `TrainerGlassField`, glass round transport controls with an emerald primary disc, glass HUD pills over media (40 px, legible at arm's length), glass next-up card and done-view stats, stadium primary buttons, rounded glass-edged discomfort sheet and close dialog, larger counter (128) and numerals.
- Calm motion: 500 ms `Curves.fastOutSlowIn` phase changes where the old content leaves before the new arrives; reduced motion keeps crossfades.
- Theme hook: `TrainerTheme.glassStyle` / `glass` and `TrainerTheme.copyWith`; dark background is now SmartFit's neutral sky. Public widget signatures unchanged.

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
