import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../media/media_controller.dart';

bool get supportsPoseHubPackPlayback => true;

/// The browser decodes the original 2h clip. One WebGL texture composes RGB/alpha
/// on the GPU; the player never sends pixels or frame timers through Dart.
class PoseHubPackSurface extends StatefulWidget {
  const PoseHubPackSurface({
    super.key,
    required this.sourceUri,
    required this.controller,
  });
  final Uri sourceUri;
  final DrillMediaController controller;
  @override
  State<PoseHubPackSurface> createState() => _PackWebSurfaceState();
}

class _PackWebSurfaceState extends State<PoseHubPackSurface> {
  static const player =
      'packages/ugk_trainer/assets/pose_hub_player/player.html';
  web.HTMLIFrameElement? _frame;
  late final JSFunction _listener;
  DrillMediaController? _owner;
  MediaCommandSink? _sink;
  var _generation = 0;
  var _session = '';

  @override
  void initState() {
    super.initState();
    _bind();
    _listener = _receive.toJS;
    web.window.addEventListener('message', _listener);
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

  @override
  void didUpdateWidget(PoseHubPackSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceUri != widget.sourceUri ||
        oldWidget.controller != widget.controller) {
      _retire();
      _bind();
    }
  }

  void _create(Object element, int generation, Uri sourceUri) {
    if (!mounted || generation != _generation) return;
    final source = Uri.base.resolveUri(sourceUri);
    if (!['http', 'https'].contains(source.scheme) ||
        source.origin != Uri.base.origin ||
        source.userInfo.isNotEmpty ||
        source.hasQuery ||
        source.hasFragment) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _generation) _owner?.reportError();
      });
      return;
    }
    final frame = element as web.HTMLIFrameElement;
    _frame = frame;
    frame
      ..title = '动作透明示范'
      ..src = Uri.base
          .resolve('assets/$player')
          .replace(
            queryParameters: {'src': source.toString(), 'session': _session},
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
    if (value is Map &&
        value['source'] == 'pose-hub-pack' &&
        value['session'] == _session) {
      _owner?.receive({...value, 'source': 'drill-media'});
    }
  }

  void _send(Map<String, Object?> command) =>
      _frame?.contentWindow?.postMessage(
        {
          'source': 'pose-hub-pack-host',
          'session': _session,
          'command': command,
        }.jsify(),
        web.window.location.origin.toJS,
      );

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
  Widget build(BuildContext context) {
    final generation = _generation;
    final source = widget.sourceUri;
    return HtmlElementView.fromTagName(
      key: ValueKey(generation),
      tagName: 'iframe',
      onElementCreated: (element) => _create(element, generation, source),
    );
  }

  @override
  void dispose() {
    _retire();
    web.window.removeEventListener('message', _listener);
    super.dispose();
  }
}
