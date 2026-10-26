import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'media_controller.dart';
import 'packed_alpha_platform.dart';

export 'packed_alpha_platform.dart';

/// Android/Impeller packed RGB-over-alpha demonstration. Unsupported backends
/// report the existing media error so the host can use its ordinary MP4.
class UgkPackedAlphaVideo extends StatefulWidget {
  const UgkPackedAlphaVideo({
    super.key,
    required this.asset,
    required this.controller,
  }) : sourceUri = null;

  /// A complete installed pack keeps its original media outside the bundle.
  /// The host must verify the pack before supplying this trusted source URI.
  const UgkPackedAlphaVideo.source({
    super.key,
    required Uri this.sourceUri,
    required this.controller,
  }) : asset = '';
  final String asset;
  final Uri? sourceUri;
  final DrillMediaController controller;

  static final _defaultPlatform = MethodChannelPackedAlphaPlatform();
  static Future<ui.FragmentProgram>? _program;
  static const shaderAsset = 'packages/ugk_trainer/shaders/packed_alpha.frag';

  @visibleForTesting
  static PackedAlphaPlatform? debugPlatform;
  @visibleForTesting
  static Widget Function(Widget packedInput)? debugFilterBuilder;

  static bool get isSupported =>
      (debugPlatform ?? _defaultPlatform).isSupported;

  @override
  State<UgkPackedAlphaVideo> createState() => _UgkPackedAlphaVideoState();
}

class _UgkPackedAlphaVideoState extends State<UgkPackedAlphaVideo>
    with WidgetsBindingObserver {
  final _captureKey = GlobalKey();
  final _pendingEvents = <Map<Object?, Object?>>[];
  StreamSubscription<Map<Object?, Object?>>? _events;
  PackedAlphaPlatform? _platform;
  DrillMediaController? _owner;
  MediaCommandSink? _sink;
  ui.FragmentShader? _shader;
  ui.ImageFilter? _filter;
  int? _playerId;
  int? _textureId;
  int _generation = 0;
  bool _nativeFrame = false;
  bool _frameAnnounced = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bind();
  }

  @override
  void didUpdateWidget(UgkPackedAlphaVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset != widget.asset ||
        oldWidget.sourceUri != widget.sourceUri ||
        oldWidget.controller != widget.controller) {
      _retire();
      _bind();
    }
  }

  bool _current(int generation, DrillMediaController owner) =>
      mounted && generation == _generation && identical(owner, _owner);

  void _bind() {
    final generation = ++_generation;
    final owner = widget.controller;
    final platform =
        UgkPackedAlphaVideo.debugPlatform ??
        UgkPackedAlphaVideo._defaultPlatform;
    _owner = owner;
    _platform = platform;
    _sink = (command) {
      if (_current(generation, owner)) {
        unawaited(_command(command, generation, owner));
      }
    };
    owner.attach(_sink!);
    unawaited(
      _initialize(platform, generation, owner, widget.asset, widget.sourceUri),
    );
  }

  Future<void> _initialize(
    PackedAlphaPlatform platform,
    int generation,
    DrillMediaController owner,
    String asset,
    Uri? sourceUri,
  ) async {
    try {
      if (!platform.isSupported) throw UnsupportedError('Packed alpha backend');
      if (UgkPackedAlphaVideo.debugFilterBuilder == null) {
        final program = await (UgkPackedAlphaVideo._program ??=
            ui.FragmentProgram.fromAsset(UgkPackedAlphaVideo.shaderAsset));
        if (!_current(generation, owner)) return;
        _shader = program.fragmentShader();
        // Keep the full 2h packed input BEFORE composition. An outer matrix
        // IMAGE FILTER (not a Texture transform) maps output h back to input
        // 2h during source-coverage calculation, preserving both source halves.
        _filter = ui.ImageFilter.compose(
          outer: ui.ImageFilter.matrix(
            Matrix4.diagonal3Values(1, .5, 1).storage,
            filterQuality: FilterQuality.low,
          ),
          inner: ui.ImageFilter.shader(_shader!),
        );
      }
      if (!_current(generation, owner)) return;
      _events = platform.events.listen(
        (event) {
          if (!_current(generation, owner)) return;
          if (_playerId == null) {
            if (_pendingEvents.length < 12) _pendingEvents.add(event);
          } else if (event['playerId'] == _playerId) {
            _receive(event, generation, owner);
          }
        },
        onError: (Object _) {
          if (_current(generation, owner)) owner.reportError();
        },
      );
      if (sourceUri != null && platform is! PackedAlphaUriPlatform) {
        throw UnsupportedError('External packed source');
      }
      final created = sourceUri == null
          ? await platform.create(asset)
          : await (platform as PackedAlphaUriPlatform).createUri(sourceUri);
      if (!_current(generation, owner)) {
        await platform.command(created.playerId, 'dispose');
        return;
      }
      setState(() {
        _playerId = created.playerId;
        _textureId = created.textureId;
      });
      final pending = List.of(_pendingEvents);
      _pendingEvents.clear();
      for (final event in pending) {
        if (event['playerId'] == created.playerId) {
          _receive(event, generation, owner);
        }
      }
    } catch (_) {
      if (_current(generation, owner)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_current(generation, owner)) owner.reportError();
        });
        WidgetsBinding.instance.scheduleFrame();
      }
    }
  }

  void _receive(
    Map<Object?, Object?> event,
    int generation,
    DrillMediaController owner,
  ) {
    if (!_current(generation, owner)) return;
    if (event['type'] == 'first-frame') {
      if (_frameAnnounced) return;
      _nativeFrame = true;
      _frameAnnounced = true;
      // Native rendering-start is distinct from metadata/STATE_READY. Allow
      // one Flutter composition under the host's poster before its fade.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_current(generation, owner)) {
          owner.receive({'source': 'drill-media', 'type': 'first-frame'});
        }
      });
      WidgetsBinding.instance.scheduleFrame();
    } else {
      owner.receive({...event, 'source': 'drill-media'});
    }
  }

  Future<void> _command(
    Map<String, Object?> command,
    int generation,
    DrillMediaController owner,
  ) async {
    final id = _playerId;
    final platform = _platform;
    if (id == null || platform == null) return;
    final type = command['type'];
    try {
      if (type == 'capture-and-pause') {
        await platform.command(id, 'pause');
        final frame = _nativeFrame ? await _capture(generation, owner) : null;
        if (_current(generation, owner)) {
          owner.receive({
            'source': 'drill-media',
            'type': 'frame',
            'captureId': command['captureId'],
            'frame': frame,
          });
        }
      } else if (type == 'position') {
        final time = await platform.command(id, 'position');
        if (_current(generation, owner)) {
          owner.receive({
            'source': 'drill-media',
            'type': 'position',
            'requestId': command['requestId'],
            'time': time,
          });
        }
      } else if (type is String &&
          const ['play', 'pause', 'active', 'dispose'].contains(type)) {
        await platform.command(id, type, command['value']);
      }
    } catch (_) {
      if (_current(generation, owner)) {
        if (type == 'position') {
          // Inspection is read-only: an unavailable native time must not
          // fail/replace otherwise healthy demonstration playback.
          owner.receive({
            'source': 'drill-media',
            'type': 'position',
            'requestId': command['requestId'],
            'time': null,
          });
        } else {
          owner.reportError();
        }
      }
    }
  }

  Future<String?> _capture(int generation, DrillMediaController owner) async {
    // Explicit handoff only: never used from a video frame callback or timer.
    // The host's existing bounded capture request discards any late response.
    ui.Image? image;
    try {
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(milliseconds: 40),
      );
      if (!_current(generation, owner)) return null;
      final boundary = _captureKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary || !boundary.hasSize) return null;
      image = await boundary.toImage(
        pixelRatio: math.min(1.0, 480 / boundary.size.width),
      );
      if (!_current(generation, owner)) return null;
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null || bytes.lengthInBytes > 256 * 1024) return null;
      return base64Encode(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final id = _playerId;
    if (id != null) {
      unawaited(
        _platform!
            .command(id, 'visible', state == AppLifecycleState.resumed)
            .catchError((_) => null),
      );
    }
  }

  void _retire() {
    ++_generation;
    if (_sink case final sink?) _owner?.detach(sink);
    unawaited(_events?.cancel());
    final id = _playerId;
    if (id != null) {
      unawaited(_platform!.command(id, 'dispose').catchError((_) => null));
    }
    _events = null;
    _playerId = null;
    _textureId = null;
    _owner = null;
    _sink = null;
    _pendingEvents.clear();
    _shader?.dispose();
    _shader = null;
    _filter = null;
    _nativeFrame = false;
    _frameAnnounced = false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retire();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final id = _textureId;
        if (id == null) return const SizedBox.expand();
        final width = constraints.maxWidth;
        final input = SizedBox(
          key: const ValueKey('packed-alpha-full-input'),
          width: width,
          height: width * 2,
          child: Texture(textureId: id, filterQuality: FilterQuality.low),
        );
        final builder = UgkPackedAlphaVideo.debugFilterBuilder;
        final filtered = builder != null
            ? builder(input)
            : ImageFiltered(
                key: const ValueKey('packed-alpha-gpu-filter'),
                imageFilter: _filter!,
                child: input,
              );
        return RepaintBoundary(
          key: _captureKey,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: width,
              maxWidth: width,
              minHeight: width * 2,
              maxHeight: width * 2,
              child: filtered,
            ),
          ),
        );
      },
    ),
  );
}
