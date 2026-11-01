// Ported from 3D-Body@89bc7e8 app/lib/platform/drill_media/media_view.dart
// (native WebView on Android / iOS, an iframe on the web).
export 'media_view_stub.dart'
    if (dart.library.io) 'media_view_native.dart'
    if (dart.library.js_interop) 'media_view_web.dart';
