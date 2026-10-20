// Ported from SmartFit@e8981ee lib/core/media/media_view_native.dart (3D-Body
// media_view_native + HipLab round-1 changes: transparent web view, fit /
// align passed to the page, iOS inline playback). Changes: the page is this
// package's player (packages/ugk_trainer/assets/media_player/) and the clip
// path is passed as `src` (any bundled asset), served by [AssetServer].
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'asset_router.dart';
import 'asset_server.dart';
import 'drill_media.dart';
import 'media_controller.dart';

class DrillMediaPlatformView extends StatefulWidget {
  const DrillMediaPlatformView({
    super.key,
    required this.media,
    required this.controller,
    required this.videoAsset,
    this.labels = const {},
    this.fit = 'contain',
    this.align = Alignment.center,
  });
  final DrillMedia media;
  final DrillMediaController controller;

  /// The clip to play (dark or light render of [media]).
  final String videoAsset;
  final Map<String, String> labels;

  /// CSS object-fit of the clip ('contain' | 'cover'); matches the poster's
  /// BoxFit so the poster → video hand-over does not jump.
  final String fit;
  final Alignment align;
  @override
  State<DrillMediaPlatformView> createState() => _MediaNativeState();
}

class _MediaNativeState extends State<DrillMediaPlatformView> {
  AssetServer? _server;
  WebViewController? _webView;
  late final MediaCommandSink _sink;
  @override
  void initState() {
    super.initState();
    _sink = _send;
    widget.controller.attach(_sink);
    if (!Platform.isAndroid && !Platform.isIOS) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.controller.reportError();
      });
    } else {
      unawaited(_initialize());
    }
  }

  Future<void> _initialize() async {
    AssetServer? server;
    try {
      server = await AssetServer.start();
      if (!mounted) {
        await server.close();
        return;
      }
      _server = server;
      final params = Platform.isIOS
          ? WebKitWebViewControllerCreationParams(
              allowsInlineMediaPlayback: true,
              mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
            )
          : const PlatformWebViewControllerCreationParams();
      final view = WebViewController.fromPlatformCreationParams(
        params,
        onPermissionRequest: (request) => unawaited(request.deny()),
      );
      await view.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!mounted) return;
      final platform = view.platform;
      if (platform is AndroidWebViewController) {
        await platform.setMediaPlaybackRequiresUserGesture(false);
      }
      if (platform is WebKitWebViewController) {
        // iOS: no edge-swipe history navigation inside the clip, and Safari
        // Web Inspector can attach to debug builds on the Mac.
        await platform.setAllowsBackForwardNavigationGestures(false);
        await platform.setInspectable(kDebugMode);
      }
      if (!mounted) return;
      await view.setBackgroundColor(const Color(0x00000000));
      await view.enableZoom(false);
      await view.addJavaScriptChannel(
        'DrillMediaHost',
        onMessageReceived: (message) {
          if (!mounted) return;
          try {
            final value = jsonDecode(message.message);
            if (value is Map) widget.controller.receive(value);
          } on FormatException {
            /* Ignore malformed platform events. */
          }
        },
      );
      await view.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            return mounted && uri != null && server!.permitsNavigation(uri)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            if (mounted && error.isForMainFrame == true) {
              widget.controller.reportError();
            }
          },
        ),
      );
      if (!mounted) return;
      setState(() => _webView = view);
      await view.loadRequest(
        server.origin
            .resolve('/${AssetRouter.playerPrefix}player.html')
            .replace(
              queryParameters: {
                'id': widget.media.id,
                'posterTime': widget.media.posterTime.toString(),
                'labels': jsonEncode(widget.labels),
                'active': widget.controller.active.toString(),
                'fit': widget.fit,
                'pos':
                    '${((widget.align.x + 1) * 50).round()}% '
                    '${((widget.align.y + 1) * 50).round()}%',
                'src': '/${widget.videoAsset}',
              },
            ),
      );
    } catch (_) {
      if (mounted) widget.controller.reportError();
      if (server != null) await server.close();
    }
  }

  void _send(Map<String, Object?> command) {
    final view = _webView;
    if (view == null) return;
    final json = jsonEncode(
      command,
    ).replaceAll('\u2028', r'\u2028').replaceAll('\u2029', r'\u2029');
    unawaited(
      view
          .runJavaScript('window.drillMediaCommand?.($json);')
          .catchError((_) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final view = _webView;
    if (view == null) return const SizedBox.expand();
    return WebViewWidget(controller: view);
  }

  @override
  void dispose() {
    _send({'type': 'dispose'});
    widget.controller.detach(_sink);
    final view = _webView;
    if (view != null) {
      unawaited(
        view.removeJavaScriptChannel('DrillMediaHost').catchError((_) {}),
      );
    }
    final server = _server;
    if (server != null) unawaited(server.close());
    super.dispose();
  }
}
