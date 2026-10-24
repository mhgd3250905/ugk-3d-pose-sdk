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
import 'training_media_repository.dart';

class DrillMediaPlatformView extends StatefulWidget {
  const DrillMediaPlatformView({
    super.key,
    required this.media,
    required this.controller,
    required this.videoAsset,
    this.labels = const {},
    this.fit = 'contain',
    this.align = Alignment.center,
    this.resource,
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
  final TrainingMediaResource? resource;
  @override
  State<DrillMediaPlatformView> createState() => _MediaNativeState();
}

class _MediaNativeState extends State<DrillMediaPlatformView> {
  AssetServer? _server;
  WebViewController? _webView;
  MediaCommandSink? _sink;
  DrillMediaController? _owner;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(DrillMediaPlatformView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.videoAsset != widget.videoAsset ||
        oldWidget.resource != widget.resource) {
      _retire();
      _bind();
    }
  }

  void _bind() {
    final generation = ++_generation;
    final owner = widget.controller;
    _owner = owner;
    _sink = (command) {
      if (_current(generation, owner)) _send(command);
    };
    owner.attach(_sink!);
    if (!Platform.isAndroid && !Platform.isIOS) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_current(generation, owner)) owner.reportError();
      });
    } else {
      unawaited(_initialize(generation, owner, widget));
    }
  }

  bool _current(int generation, DrillMediaController owner) =>
      mounted && generation == _generation && identical(owner, _owner);

  Future<void> _initialize(
    int generation,
    DrillMediaController owner,
    DrillMediaPlatformView config,
  ) async {
    AssetServer? server;
    WebViewController? view;
    try {
      server = await AssetServer.start(resource: config.resource);
      if (!_current(generation, owner)) return;
      _server = server;
      final params = Platform.isIOS
          ? WebKitWebViewControllerCreationParams(
              allowsInlineMediaPlayback: true,
              mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
            )
          : const PlatformWebViewControllerCreationParams();
      view = WebViewController.fromPlatformCreationParams(
        params,
        onPermissionRequest: (request) => unawaited(request.deny()),
      );
      await view.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!_current(generation, owner)) return;
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
      if (!_current(generation, owner)) return;
      await view.setBackgroundColor(const Color(0x00000000));
      await view.enableZoom(false);
      await view.addJavaScriptChannel(
        'DrillMediaHost',
        onMessageReceived: (message) {
          if (!_current(generation, owner)) return;
          try {
            final value = jsonDecode(message.message);
            if (value is Map) owner.receive(value);
          } on FormatException {
            /* Ignore malformed platform events. */
          }
        },
      );
      await view.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            return _current(generation, owner) &&
                    uri != null &&
                    server!.permitsNavigation(uri)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            if (_current(generation, owner) && error.isForMainFrame == true) {
              owner.reportError();
            }
          },
        ),
      );
      if (!_current(generation, owner)) return;
      setState(() => _webView = view);
      await view.loadRequest(
        server.origin
            .resolve('/${AssetRouter.playerPrefix}player.html')
            .replace(
              queryParameters: {
                'id': config.media.id,
                'posterTime': config.media.posterTime.toString(),
                'labels': jsonEncode(config.labels),
                'active': owner.active.toString(),
                'fit': config.fit,
                'pos':
                    '${((config.align.x + 1) * 50).round()}% '
                    '${((config.align.y + 1) * 50).round()}%',
                'src': config.resource?.cachePath != null
                    ? AssetServer.verifiedMediaPath
                    : '/${config.videoAsset}',
              },
            ),
      );
    } catch (_) {
      if (_current(generation, owner)) owner.reportError();
      if (server != null) await server.close();
    } finally {
      if (!_current(generation, owner)) {
        if (view != null) {
          await view
              .removeJavaScriptChannel('DrillMediaHost')
              .catchError((_) {});
        }
        if (server != null) await server.close();
      }
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

  void _retire() {
    _send({'type': 'dispose'});
    ++_generation;
    if (_sink case final sink?) _owner?.detach(sink);
    _owner = null;
    _sink = null;
    final view = _webView;
    if (view != null) {
      unawaited(
        view.removeJavaScriptChannel('DrillMediaHost').catchError((_) {}),
      );
    }
    final server = _server;
    if (server != null) unawaited(server.close());
    _webView = null;
    _server = null;
  }

  @override
  void dispose() {
    _retire();
    super.dispose();
  }
}
