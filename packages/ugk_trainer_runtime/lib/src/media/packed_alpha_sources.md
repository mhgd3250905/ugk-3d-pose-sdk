# Packed alpha implementation notes

This is original SDK glue around Android and Flutter APIs. No third-party
player or sampler implementation was copied. The design references are:

- Flutter 3.44.7 `ImageFilter.shader` (BSD-3-Clause):
  https://github.com/flutter/flutter/blob/3.44.7/engine/src/flutter/lib/ui/painting.dart
- Flutter's GPU runtime filter binds its input snapshot to sampler zero:
  https://github.com/flutter/flutter/blob/3.44.7/engine/src/flutter/impeller/entity/contents/filters/runtime_effect_filter_contents.cc
- Its outer matrix filter inversely maps output coverage to source coverage:
  https://github.com/flutter/flutter/blob/3.44.7/engine/src/flutter/impeller/entity/contents/filters/matrix_filter_contents.cc
- Official video_player Android texture lifecycle design (BSD-3-Clause):
  https://github.com/flutter/packages/tree/main/packages/video_player/video_player_android
- Android MediaPlayer `MEDIA_INFO_VIDEO_RENDERING_START`:
  https://developer.android.com/reference/android/media/MediaPlayer#MEDIA_INFO_VIDEO_RENDERING_START

`video_player` exposes initialization/play state, not a true first-frame event.
This Android-only adapter therefore uses MediaPlayer's rendering-start event
and Flutter SurfaceProducer without adding a decoder dependency. Unsupported
platforms/backends report failure to the existing ordinary-MP4 fallback.

The texture input remains width x 2*width. The shader samples RGB from the
upper half and alpha from the lower half and emits premultiplied RGBA at the
full input bounds. A matrix IMAGE FILTER halves the composed output height;
the packed texture is not first squashed into a square. Inverse source-bounds
mapping preserves the entire lower half even under the host's square clip.
Synthetic thin-line/boundary and alpha-plane checks on Android/Impeller remain
necessary; widget tests alone do not prove the hardware filter output.

No per-frame Dart image readback, position polling, canvas capture or timers
are used. A single bounded PNG snapshot may be requested explicitly by the
existing missing-poster handoff. Position is read only on an explicit command.

## Opt-in prepared, paused first frame

`TrainingActionMedia.showLoadingIndicator` defaults to true. A host may set it
to false to keep the bundled poster visible without a loading spinner or live
announcement while downloading/decoding. The real first-frame reveal and
failure/retry button are unchanged. Toggling this presentation option does not
restart downloads, replace the decoder or alter playback.

`TrainingActionMedia(playing: true, paused: true, prepareFirstFrame: true)`
downloads/prepares one demonstration as usual, then asks its existing native
player to decode the first frame and pause. This option defaults to false;
ordinary paused/poster-only hosts keep the old behavior. It does not reuse or
invoke return-to-start.

The `prime-first-frame` command temporarily starts normal-speed playback until
the existing `MEDIA_INFO_VIDEO_RENDERING_START` event, then pauses and replies.
Its native request is capped at 900ms and the Dart request at 1200ms. Only the
ordinary real first-frame event followed by Flutter composition sets
`hasFrame`; a successful command reply alone never fabricates visual readiness.
Unavailable/unsupported preparation returns false without failing healthy
playback. Timers and pending native results are cancelled on explicit playback,
pause, deactivation, surface loss or disposal.

After the first frame is ready, changing `paused` to false plays the same
controller/texture and changing it back to true holds the current pose. It does
not rewind or swap back to a poster. The host must keep this one media widget
mounted with the same action/policy to preserve that surface across a card
expansion. Action changes, covering routes, backgrounding and disposal still
follow the existing resource release rules. A fresh controller can prime again
when that demonstration becomes visible. A user resume/pause during initial
decode may retry preparation, but routine event/build notifications do not.

## Optional return-to-start handoff (compatible API)

`TrainingActionMedia.playbackControl` accepts a `DrillMediaPlaybackControl`.
This is deliberately separate from the existing read-only
`DrillMediaPlaybackHandle`; neither a training clock nor decoder ownership is
exposed. `returnToStart(duration: Duration(milliseconds: 400))` merges an
in-flight request and returns whether the first video frame was reached and
paused. It must run while the demonstration route is still current, before
popping that route. A paused preview can play temporarily for this operation.

The Android adapter temporarily disables looping, plays the remaining loop
forward at 1–12x, then handles completion by seeking to zero, waiting for
`OnSeekComplete`, restoring 1x/looping and pausing. Dart waits for a Flutter
composition before acknowledging success. This is forward playback through
the remaining poses, not a seek directly from an arbitrary current pose to
the first. The requested duration is a soft target (clamped to 80–800ms);
native work is capped at 1100ms and the Dart request at 1400ms. Long future
clips that cannot fit the bounded run at 12x return false before starting.

Unsupported speed/seek, timeout, explicit pause, unbinding, deactivation,
surface loss and disposal cancel the optional request with false. Native
clears the timer/listeners/result and restores normal speed/looping; this
optional failure does not report a healthy video as a decoder error. The
ordinary playback path is unchanged. Unsupported backends return false;
this does not add an iOS packed-video implementation.

An expanded-card host may opt into
`TrainingActionMedia.retainSurfaceDuringRouteExit` (default false). After
return-to-start succeeds, the host pauses and then pops. An already-created
surface remains present while that route's own primary animation reverses,
instead of being replaced by a fading-in poster when `isCurrent` changes.
Only animation status changes are observed; there is no per-frame rebuild.
A newly covering route, backgrounding, a different action/policy, and actual
disposal retain the ordinary release behavior. A video that had not loaded
before exit is not created for the sake of retaining it.

Official state-machine references:

- Android `setPlaybackParams` and non-negative `PlaybackParams.setSpeed`:
  https://developer.android.com/reference/android/media/MediaPlayer#setPlaybackParams(android.media.PlaybackParams)
  https://developer.android.com/reference/android/media/PlaybackParams#setSpeed(float)
- Temporarily disabling `setLooping` permits `OnCompletionListener` delivery:
  https://developer.android.com/reference/android/media/MediaPlayer#setOnCompletionListener(android.media.MediaPlayer.OnCompletionListener)
- Seeking while paused displays the requested valid video frame; completion
  is asynchronous:
  https://developer.android.com/reference/android/media/MediaPlayer#seekTo(long,int)
  https://developer.android.com/reference/android/media/MediaPlayer#setOnSeekCompleteListener(android.media.MediaPlayer.OnSeekCompleteListener)

Unit/fake-platform tests cover the contract and cancellation, not native frame
delivery. Real Android validation must still observe the fast-forwarded poses,
zero-position hold and the card's final handoff.
