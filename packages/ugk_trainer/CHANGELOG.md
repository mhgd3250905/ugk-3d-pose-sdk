# Changelog

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
