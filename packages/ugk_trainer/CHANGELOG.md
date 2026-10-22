# Changelog

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
