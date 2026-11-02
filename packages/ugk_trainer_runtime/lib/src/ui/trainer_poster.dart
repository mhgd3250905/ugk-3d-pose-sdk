import 'dart:async';

import 'package:flutter/material.dart';

/// Uses the same bundle and screen-width decode key for warming and painting.
abstract final class TrainingPosterImages {
  static int decodeWidth(BuildContext context) =>
      (MediaQuery.sizeOf(context).width *
              MediaQuery.devicePixelRatioOf(context))
          .round()
          .clamp(1, 0x7fffffff);

  static ImageProvider<Object> provider(
    String asset,
    int width, {
    AssetBundle? bundle,
  }) => ResizeImage.resizeIfNeeded(
    width,
    null,
    AssetImage(asset, bundle: bundle),
  );

  static TrainingPosterLease retain(
    String asset,
    int width, {
    required AssetBundle bundle,
    required ImageConfiguration configuration,
  }) => TrainingPosterLease._(
    provider(asset, width, bundle: bundle).resolve(configuration),
  );

  static Future<bool> prepareAsset(
    BuildContext context,
    String asset, {
    Duration timeout = const Duration(milliseconds: 150),
  }) async {
    final lease = retain(
      asset,
      decodeWidth(context),
      bundle: DefaultAssetBundle.of(context),
      configuration: createLocalImageConfiguration(context),
    );
    try {
      return await lease.ready.timeout(timeout, onTimeout: () => false);
    } finally {
      lease.dispose();
    }
  }
}

/// Keeps a decoded first poster alive until its shared training route closes.
class TrainingPosterLease {
  TrainingPosterLease._(this._stream) {
    _listener = ImageStreamListener(
      (info, _) {
        _info?.dispose();
        _info = info;
        if (!_ready.isCompleted) _ready.complete(true);
      },
      onError: (Object _, StackTrace? stack) {
        if (!_ready.isCompleted) _ready.complete(false);
      },
    );
    _stream.addListener(_listener);
  }

  final ImageStream _stream;
  final _ready = Completer<bool>();
  late final ImageStreamListener _listener;
  ImageInfo? _info;
  bool _disposed = false;
  Future<bool> get ready => _ready.future;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stream.removeListener(_listener);
    _info?.dispose();
    _info = null;
  }
}

/// The actual contain-fitted poster, without a second decode-time fade.
class TrainerPoster extends StatefulWidget {
  const TrainerPoster({
    super.key,
    required this.asset,
    this.mirrored = false,
    this.radius = 0,
    this.stageColor = Colors.transparent,
    this.bundle,
    this.decodeWidth,
    this.fallback,
  });

  final String asset;
  final bool mirrored;
  final double radius;
  final Color stageColor;
  final AssetBundle? bundle;
  final int? decodeWidth;

  /// Existing handover still, used while this target asset decodes or fails.
  final Widget? fallback;

  @override
  State<TrainerPoster> createState() => _TrainerPosterState();
}

class _TrainerPosterState extends State<TrainerPoster> {
  ImageProvider<Object>? _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _info;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(TrainerPoster oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolve();
  }

  void _resolve() {
    final provider = TrainingPosterImages.provider(
      widget.asset,
      widget.decodeWidth ?? TrainingPosterImages.decodeWidth(context),
      bundle: widget.bundle ?? DefaultAssetBundle.of(context),
    );
    if (_provider == provider) return;
    _provider = provider;
    if (_listener != null) _stream?.removeListener(_listener!);
    _info?.dispose();
    _info = null;
    final stream = _stream = provider.resolve(
      createLocalImageConfiguration(context),
    );
    _listener = ImageStreamListener(
      (info, synchronous) {
        if (!mounted || !identical(_stream, stream)) {
          info.dispose();
          return;
        }
        void update() {
          _info?.dispose();
          _info = info;
        }

        if (synchronous) {
          update();
        } else {
          setState(update);
        }
      },
      onError: (Object _, StackTrace? stack) {
        if (mounted && identical(_stream, stream)) {
          setState(() {
            _info?.dispose();
            _info = null;
          });
        }
      },
    );
    stream.addListener(_listener!);
  }

  @override
  void dispose() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _info?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(widget.radius),
    child: ColoredBox(
      color: widget.stageColor,
      child: Transform.flip(
        flipX: widget.mirrored,
        child: RepaintBoundary(
          child: _info == null
              ? widget.fallback ?? const SizedBox.expand()
              : RawImage(
                  image: _info!.image,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                ),
        ),
      ),
    ),
  );
}
