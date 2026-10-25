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
