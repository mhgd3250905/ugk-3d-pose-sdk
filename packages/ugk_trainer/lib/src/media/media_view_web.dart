// Ported from 3D-Body@89bc7e8 app/lib/platform/drill_media/media_view_web.dart.
// Changes: this package's player page and the clip passed as `src`; fit /
// align as on native; transparent frame.
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'asset_router.dart';
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
  final String fit;
  final Alignment align;
  final TrainingMediaResource? resource;
  @override
  State<DrillMediaPlatformView> createState() => _MediaWebState();
}

class _MediaWebState extends State<DrillMediaPlatformView> {
  web.HTMLIFrameElement? _frame;
  late final JSFunction _listener;
  MediaCommandSink? _sink;
  DrillMediaController? _owner;
  int _generation = 0;
  String _session = '';
  @override
  void initState() {
    super.initState();
    _bind();
    _listener = _receive.toJS;
    web.window.addEventListener('message', _listener);
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
    _owner = widget.controller;
    _session = '$generation-${identityHashCode(_owner)}';
    _sink = (command) {
      if (mounted && generation == _generation) _send(command);
    };
    _owner!.attach(_sink!);
  }

  void _create(Object element, int generation, DrillMediaPlatformView config) {
    if (!mounted || generation != _generation) return;
    final frame = element as web.HTMLIFrameElement;
    _frame = frame;
    // Flutter web serves bundle assets under <base>/assets/<key>.
    final clip = Uri.base.resolve('assets/${config.videoAsset}').path;
    frame
      ..title = config.labels['title'] ?? ''
      ..src = Uri.base
          .resolve('assets/${AssetRouter.playerPrefix}player.html')
          .replace(
            queryParameters: {
              'id': config.media.id,
              'session': _session,
              'posterTime': config.media.posterTime.toString(),
              'labels': jsonEncode(config.labels),
              'active': config.controller.active.toString(),
              'fit': config.fit,
              'pos':
                  '${((config.align.x + 1) * 50).round()}% '
                  '${((config.align.y + 1) * 50).round()}%',
              'src': clip,
            },
          )
          .toString();
    frame.setAttribute('scrolling', 'no');
    frame.style
      ..border = '0'
      ..width = '100%'
      ..height = '100%'
      ..display = 'block'
      ..backgroundColor = 'transparent';
  }

  void _receive(web.Event event) {
    final frame = _frame;
    if (!mounted || frame?.contentWindow == null) return;
    final message = event as web.MessageEvent;
    if (message.origin != web.window.location.origin ||
        !message.source.strictEquals(frame!.contentWindow).toDart) {
      return;
    }
    final value = message.data.dartify();
    if (value is Map && value['session'] == _session) _owner?.receive(value);
  }

  void _send(Map<String, Object?> command) {
    _frame?.contentWindow?.postMessage(
      {'source': 'drill-media-host', 'command': command}.jsify(),
      web.window.location.origin.toJS,
    );
  }

  @override
  Widget build(BuildContext context) {
    final generation = _generation;
    final config = widget;
    return HtmlElementView.fromTagName(
      key: ValueKey(generation),
      tagName: 'iframe',
      onElementCreated: (element) => _create(element, generation, config),
    );
  }

  void _retire() {
    _send({'type': 'dispose'});
    ++_generation;
    if (_sink case final sink?) _owner?.detach(sink);
    _owner = null;
    _sink = null;
    _frame?.src = 'about:blank';
    _frame = null;
  }

  @override
  void dispose() {
    _retire();
    web.window.removeEventListener('message', _listener);
    super.dispose();
  }
}
