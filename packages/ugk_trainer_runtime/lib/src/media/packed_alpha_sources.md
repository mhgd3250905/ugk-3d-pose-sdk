# Packed alpha implementation notes

This is original SDK glue around Android, AVFoundation and Flutter APIs. No third-party
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
The Android adapter therefore uses MediaPlayer's rendering-start event
and Flutter SurfaceProducer without adding a decoder dependency. Unsupported
platforms/backends report failure to the existing ordinary-MP4 fallback.

The iOS 15+ adapter uses AVPlayerItemVideoOutput and FlutterTexture, sharing
one Swift implementation between Swift Package Manager and CocoaPods:

- FlutterTexture's supported pixel formats and raster-thread callback:
  https://api.flutter.dev/ios-embedder/protocol_flutter_texture-p.html
- Flutter plugin packaging (the directory and manifest layout was also checked
  against `flutter create --template=plugin --platforms=ios` in Flutter 3.44.7):
  https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-plugin-authors
- AVPlayerItemVideoOutput's pull-based CoreVideo buffers:
  https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput

CADisplayLink pulls new BGRA buffers only while playback is requested, active
and visible. CoreVideo performs the video-range-to-BGRA conversion; the alpha
plane is then sampled directly, without a second 16–235 range expansion.
The latest buffer and one-time first-frame flag are locked across platform and
raster threads. `first-frame` is sent after Flutter actually requests a buffer,
not when item metadata becomes ready. Loop seeks retain the last buffer.
The iOS shader uses the existing Metal path without the OpenGLES y flip.
Device checks remain required for range endpoints, orientation and edge color.

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
