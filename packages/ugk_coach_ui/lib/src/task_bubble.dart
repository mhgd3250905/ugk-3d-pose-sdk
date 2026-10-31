import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'primitives.dart';
import 'task_bubble_tokens.dart';
import 'theme.dart';

/// Preparation card driven only by ordinary presentation data.
///
/// Hosts may pass a summary from their domain layer without coupling this
/// package to a coaching SDK or exercise catalogue. [cutoutFor] supplies the
/// verified light/dark image for each picked action; null images use the orb.
class CoachTaskBubble extends StatefulWidget {
  const CoachTaskBubble({
    super.key,
    this.title,
    this.status,
    this.phase = 0,
    this.parameters = const <({String field, String label, bool user})>[],
    this.picks = const <String>[],
    this.complete = false,
    this.waiting = false,
    this.visualComplete = false,
    this.onCancel,
    this.cutoutFor,
  }) : assert(phase >= 0 && phase <= 4);

  /// Already formatted title and status; null uses the theme's default copy.
  final String? title, status;

  /// Four measured progress segments, from zero to four completed segments.
  final int phase;
  final List<({String field, String label, bool user})> parameters;
  final List<String> picks;
  final bool complete, waiting;

  /// Completes the orb while a delivery wrapper retains this card. It does
  /// not change the supplied phase, status sentence, or source completion.
  final bool visualComplete;
  final VoidCallback? onCancel;
  final ImageProvider? Function(String actionId)? cutoutFor;

  @override
  State<CoachTaskBubble> createState() => _CoachTaskBubbleState();
}

CoachTaskBubbleTokens _tokens(BuildContext context) => CoachTaskBubbleTokens(
  CoachUiTheme.of(context),
  letterSpacing: Theme.of(context).textTheme.bodyMedium?.letterSpacing ?? 0,
);

class _CoachTaskBubbleState extends State<CoachTaskBubble>
    with TickerProviderStateMixin {
  late final AnimationController _rotation;
  late final AnimationController _shine;
  late final AnimationController _progress;
  late final AnimationController _images;
  late final AnimationController _breath;
  late final AnimationController _coreCollapse;
  late final AnimationController _completion;
  late final AnimationController _band;
  late final AnimationController _check;
  late final AnimationController _reveal;
  bool? _reduced;
  bool _tickersEnabled = true;
  bool _showingComplete = false;
  int _imageIndex = 0;
  double _lastImageValue = 0;
  int _progressPhase = 0;
  List<double> _progressFrom = List.filled(
    CoachTaskBubbleTokens.progressSegments,
    0,
  );

  @override
  void initState() {
    super.initState();
    _rotation = AnimationController(
      vsync: this,
      duration: CoachTaskBubbleTokens.rotation,
    );
    _shine = AnimationController(
      vsync: this,
      duration: CoachTaskBubbleTokens.shimmer,
    );
    _progress = AnimationController(
      vsync: this,
      duration: CoachTaskBubbleTokens.progressTransition,
      value: 1,
    );
    _images = AnimationController(
      vsync: this,
      duration:
          CoachTaskBubbleTokens.silhouetteHold +
          CoachTaskBubbleTokens.silhouetteFade,
    )..addListener(_advanceImage);
    _breath = AnimationController(
      vsync: this,
      duration: CoachTaskBubbleTokens.breath,
    );
    _coreCollapse = AnimationController(
      vsync: this,
      duration: CoachTaskBubbleTokens.coreCollapse,
    );
    _completion = AnimationController(
      vsync: this,
      duration: CoachTaskBubbleTokens.completionVisual,
    )..addListener(_completionFrame);
    _band = AnimationController(
      vsync: this,
      duration: CoachTaskBubbleTokens.progressBand,
    );
    _check = AnimationController(
      vsync: this,
      duration: CoachTaskBubbleTokens.checkTransition,
    );
    _reveal = AnimationController(
      vsync: this,
      duration:
          CoachTaskBubbleTokens.silhouetteRevealDelay +
          CoachTaskBubbleTokens.silhouetteFade,
    );
  }

  List<String> get _picks => widget.picks;
  List<({String id, ImageProvider image})> get _selected => [
    for (final id in _picks)
      if (widget.cutoutFor?.call(id) case final image?) (id: id, image: image),
  ];
  // Source output may finish before a reply is admitted. While waiting only
  // the delivery wrapper's successful marker may show the success check.
  bool get _visualComplete =>
      widget.visualComplete || (widget.complete && !widget.waiting);
  bool get _motionOff => _reduced == true || !_tickersEnabled;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = CoachMotion.reduced(context);
    final tickersEnabled = TickerMode.valuesOf(context).enabled;
    if (_reduced != reduced || _tickersEnabled != tickersEnabled) {
      _reduced = reduced;
      _tickersEnabled = tickersEnabled;
      _syncMotion(restartProgress: true);
    }
  }

  @override
  void didUpdateWidget(CoachTaskBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPicks = oldWidget.picks;
    if (!listEquals(oldPicks, _picks)) {
      _images.stop();
      _imageIndex = 0;
      _lastImageValue = 0;
      _images.value = 0;
    }
    _syncMotion(restartProgress: oldWidget.phase != widget.phase);
  }

  void _syncMotion({bool restartProgress = false}) {
    final complete = _visualComplete;
    final animate = !_motionOff && widget.waiting && !complete;
    if (_motionOff) {
      _completion.stop();
      _completion.value = complete ? 1 : 0;
      _check.stop();
      _check.value = complete ? 1 : 0;
    } else if (complete) {
      if (!_showingComplete) {
        _completion.forward(from: 0);
        _check.forward(from: 0);
      }
    } else {
      _completion.stop();
      _completion.value = 0;
      _check.stop();
      _check.value = 0;
    }
    _showingComplete = complete;

    // Prototype pauses the spin the moment it completes; the ring closes in
    // place.
    if (animate) {
      if (!_rotation.isAnimating) _rotation.repeat();
    } else {
      _rotation.stop();
      if (_reduced == true) _rotation.value = 0;
    }
    for (final controller in [_shine, _band]) {
      if (animate) {
        if (!controller.isAnimating) controller.repeat();
      } else {
        controller.stop();
      }
    }
    if (animate && _selected.length > 1) {
      if (!_images.isAnimating) _images.repeat();
    } else {
      _images.stop();
      if (_reduced == true) {
        _imageIndex = 0;
        _lastImageValue = 0;
        _images.value = 0;
      }
    }
    if (animate && _selected.isEmpty) {
      if (!_breath.isAnimating) _breath.repeat(reverse: true);
    } else {
      _breath.stop();
      if (_motionOff) _breath.value = 1;
    }
    if (_selected.isEmpty) {
      _coreCollapse.stop();
      _coreCollapse.value = 0;
      _reveal.stop();
      _reveal.value = 0;
    } else if (animate) {
      if (!_coreCollapse.isAnimating && !_coreCollapse.isCompleted) {
        _coreCollapse.forward();
      }
      if (!_reveal.isAnimating && !_reveal.isCompleted) _reveal.forward();
    } else {
      _coreCollapse.stop();
      _coreCollapse.value = 1;
      _reveal.stop();
      _reveal.value = 1;
    }
    _syncProgress(restart: restartProgress);
  }

  void _completionFrame() {
    if (_visualComplete && _completion.value >= 1) {
      _rotation.stop();
      // Flutter's interpolation reports its completed status after the exact
      // endpoint frame. Settle at value 1 so a long next frame cannot rotate
      // the already closed ring or keep the completion ticker alive.
      if (_completion.isAnimating) _completion.value = 1;
    }
  }

  double _segmentFill(int index) {
    final target = index < _progressPhase ? 1.0 : 0.0;
    final eased = Curves.easeOutCubic.transform(_progress.value);
    return _progressFrom[index] + (target - _progressFrom[index]) * eased;
  }

  void _syncProgress({required bool restart}) {
    final phase = widget.phase;
    final target = [
      for (
        var index = 0;
        index < CoachTaskBubbleTokens.progressSegments;
        index++
      )
        index < phase ? 1.0 : 0.0,
    ];
    if (_motionOff || !widget.waiting) {
      _progress.stop();
      _progressPhase = phase;
      _progressFrom = target;
      _progress.value = 1;
    } else if (restart) {
      final from = [
        for (
          var index = 0;
          index < CoachTaskBubbleTokens.progressSegments;
          index++
        )
          _segmentFill(index),
      ];
      _progress.stop();
      _progressPhase = phase;
      _progressFrom = from;
      if (listEquals(from, target)) {
        _progress.value = 1;
      } else {
        _progress.forward(from: 0);
      }
    }
  }

  void _advanceImage() {
    final count = _selected.length;
    if (_images.isAnimating &&
        count > 1 &&
        _images.value < _lastImageValue &&
        mounted) {
      setState(() => _imageIndex = (_imageIndex + 1) % count);
    }
    _lastImageValue = _images.value;
  }

  @override
  void dispose() {
    _rotation.dispose();
    _shine.dispose();
    _progress.dispose();
    _images.dispose();
    _breath.dispose();
    _coreCollapse.dispose();
    _completion.dispose();
    _band.dispose();
    _check.dispose();
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chips = widget.parameters;
    final title =
        widget.title ?? CoachUiTheme.of(context).strings.taskThinkingTitle;
    final staticDetails = _motionOff || _visualComplete || !widget.waiting;
    // Isolate the card's endless animations from the chat list's raster.
    return RepaintBoundary(
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: CoachTaskBubbleTokens.maxWidth,
          ),
          child: SizedBox(
            key: const ValueKey('generation-completion-size'),
            child: Container(
              key: const ValueKey('generation-card'),
              padding: CoachTaskBubbleTokens.cardPadding,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: _tokens(context).colors.taskCardSurface,
                borderRadius: BorderRadius.circular(
                  CoachTaskBubbleTokens.cardRadius,
                ),
                boxShadow: _tokens(context).cardShadow,
              ),
              // A foreground outline does not add half a pixel to the padding.
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  CoachTaskBubbleTokens.cardRadius,
                ),
                border: Border.all(
                  color: _tokens(context).cardEdge,
                  width: CoachTaskBubbleTokens.cardEdgeWidth,
                ),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Card-level glow centred on the orb: 320 px radial, clipped
                  // by the card, painted once (outside the orb's repaint).
                  Positioned(
                    left:
                        CoachTaskBubbleTokens.animationSize / 2 -
                        CoachTaskBubbleTokens.glowRadius,
                    top:
                        CoachTaskBubbleTokens.animationSize / 2 -
                        CoachTaskBubbleTokens.glowRadius,
                    width: CoachTaskBubbleTokens.glowRadius * 2,
                    height: CoachTaskBubbleTokens.glowRadius * 2,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        key: const ValueKey('generation-glow'),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              _tokens(context).glow,
                              _tokens(
                                context,
                              ).colors.taskAccent.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          RepaintBoundary(child: _animation()),
                          const SizedBox(
                            width: CoachTaskBubbleTokens.animationGap,
                          ),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  title,
                                  style: _tokens(context).title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(
                                  height: CoachTaskBubbleTokens.statusGap,
                                ),
                                RepaintBoundary(
                                  child: _StatusSentence(
                                    text:
                                        widget.status ??
                                        CoachUiTheme.of(
                                          context,
                                        ).strings.taskReadingStatus,
                                    shimmer: _shine,
                                    reduced: staticDetails,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(
                            width: CoachTaskBubbleTokens.animationGap,
                          ),
                          // Prototype: 44 px target with margin-right -10 px, so it
                          // overhangs the card padding and the title keeps 10 px.
                          SizedBox(
                            width:
                                CoachTaskBubbleTokens.cancelTouchSize -
                                CoachTaskBubbleTokens.cancelOutset,
                            height: CoachTaskBubbleTokens.cancelTouchSize,
                            child: OverflowBox(
                              alignment: Alignment.centerLeft,
                              minWidth: CoachTaskBubbleTokens.cancelTouchSize,
                              maxWidth: CoachTaskBubbleTokens.cancelTouchSize,
                              child: SizedBox.square(
                                key: const ValueKey('generation-cancel-target'),
                                dimension:
                                    CoachTaskBubbleTokens.cancelTouchSize,
                                child:
                                    widget.waiting &&
                                        !_visualComplete &&
                                        widget.onCancel != null
                                    ? _CancelButton(onCancel: widget.onCancel!)
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(
                        height: CoachTaskBubbleTokens.progressTopGap,
                      ),
                      RepaintBoundary(child: _progressBar()),
                      if (chips.isNotEmpty) ...[
                        const SizedBox(
                          height: CoachTaskBubbleTokens.chipsTopGap,
                        ),
                        Wrap(
                          spacing: CoachTaskBubbleTokens.chipGap,
                          runSpacing: CoachTaskBubbleTokens.chipGap,
                          children: [
                            for (var index = 0; index < chips.length; index++)
                              _ParameterChip(
                                key: ValueKey(
                                  'generation-chip-${chips[index].field}-'
                                  '${chips[index].label}-${chips[index].user}',
                                ),
                                data: chips[index],
                                index: index,
                                reduced: staticDetails,
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _animation() => SizedBox.square(
    key: const ValueKey('generation-animation'),
    dimension: CoachTaskBubbleTokens.animationSize,
    child: Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _tokens(context).orbFill,
            ),
          ),
        ),
        Positioned.fill(
          child: RotationTransition(
            key: const ValueKey('generation-rotation'),
            turns: _rotation,
            child: AnimatedBuilder(
              animation: _completion,
              builder: (context, _) {
                final closing = Curves.easeOutCubic.transform(
                  _completion.value,
                );
                return CustomPaint(
                  painter: _ArcPainter(
                    color: _tokens(context).colors.taskAccent,
                    sweep: _reduced == true
                        ? 360
                        : CoachTaskBubbleTokens.arcSweep +
                              (360 - CoachTaskBubbleTokens.arcSweep) * closing,
                    tailAlpha: _visualComplete
                        ? closing
                        : _reduced == true
                        ? .25
                        : 0,
                    headAlpha: _reduced == true ? 0 : 1 - _completionDetail,
                  ),
                );
              },
            ),
          ),
        ),
        AnimatedBuilder(
          animation: Listenable.merge([
            _breath,
            _coreCollapse,
            _images,
            _completion,
            _check,
            _reveal,
          ]),
          builder: (context, _) {
            final selected = _selected;
            final breath = _motionOff
                ? 1.0
                : CoachTaskBubbleTokens.sine.transform(_breath.value);
            final collapse = Curves.easeInCubic.transform(_coreCollapse.value);
            final coreScale =
                (CoachTaskBubbleTokens.breathInitialScale +
                    (1 - CoachTaskBubbleTokens.breathInitialScale) * breath) *
                (1 - collapse);
            final coreOpacity =
                (CoachTaskBubbleTokens.breathInitialOpacity +
                    (1 - CoachTaskBubbleTokens.breathInitialOpacity) * breath) *
                (1 - collapse) *
                (1 - _completionDetail);
            return Stack(
              alignment: Alignment.center,
              fit: StackFit.expand,
              children: [
                if (selected.isEmpty || collapse < 1)
                  Center(
                    child: Opacity(
                      opacity: coreOpacity,
                      child: Transform.scale(
                        scale: coreScale,
                        child: SizedBox.square(
                          dimension: CoachTaskBubbleTokens.haloSize,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Container(
                                key: const ValueKey('generation-halo'),
                                width: CoachTaskBubbleTokens.haloSize,
                                height: CoachTaskBubbleTokens.haloSize,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _tokens(context).colors.taskHalo,
                                ),
                              ),
                              Container(
                                key: const ValueKey('generation-core'),
                                width: CoachTaskBubbleTokens.coreSize,
                                height: CoachTaskBubbleTokens.coreSize,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _tokens(context).colors.taskAccent,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                if (selected.isNotEmpty) _thumbnails(selected),
                if (_visualComplete)
                  Center(
                    child: Opacity(
                      opacity: _checkOpacity,
                      child: Transform.scale(
                        scale:
                            CoachTaskBubbleTokens.checkInitialScale +
                            (1 - CoachTaskBubbleTokens.checkInitialScale) *
                                CoachTaskBubbleTokens.back.transform(
                                  _check.value,
                                ),
                        child: CustomPaint(
                          key: const ValueKey('generation-check'),
                          size: const Size.square(
                            CoachTaskBubbleTokens.checkSize,
                          ),
                          painter: _CheckPainter(
                            color: _tokens(context).colors.taskAccent,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    ),
  );

  // Opacity runs 120 ms linear inside the 260 ms scale (prototype .check).
  double get _checkOpacity =>
      (_check.value *
              CoachTaskBubbleTokens.checkTransition.inMicroseconds /
              CoachTaskBubbleTokens.checkFade.inMicroseconds)
          .clamp(0.0, 1.0);

  /// First silhouette: 180 ms wait, then 250 ms fade (linear) and .94 -> 1
  /// scale (ease-out). Later images use the crossfade below.
  double get _revealProgress {
    final elapsed =
        _reveal.value *
        (CoachTaskBubbleTokens.silhouetteRevealDelay +
                CoachTaskBubbleTokens.silhouetteFade)
            .inMicroseconds;
    return ((elapsed -
                CoachTaskBubbleTokens.silhouetteRevealDelay.inMicroseconds) /
            CoachTaskBubbleTokens.silhouetteFade.inMicroseconds)
        .clamp(0.0, 1.0);
  }

  double get _completionDetail =>
      (_completion.value *
              CoachTaskBubbleTokens.completionVisual.inMicroseconds /
              CoachTaskBubbleTokens.completionDetail.inMicroseconds)
          .clamp(0.0, 1.0);

  Widget _thumbnails(List<({String id, ImageProvider image})> selected) {
    final current = _reduced == true ? 0 : _imageIndex % selected.length;
    final next = (current + 1) % selected.length;
    final cycle =
        CoachTaskBubbleTokens.silhouetteHold +
        CoachTaskBubbleTokens.silhouetteFade;
    final elapsed = _images.value * cycle.inMicroseconds;
    final blend = _reduced == true || selected.length == 1
        ? 0.0
        : ((elapsed - CoachTaskBubbleTokens.silhouetteHold.inMicroseconds) /
                  CoachTaskBubbleTokens.silhouetteFade.inMicroseconds)
              .clamp(0.0, 1.0);
    return Padding(
      key: const ValueKey('generation-thumbnails'),
      padding: const EdgeInsets.all(CoachTaskBubbleTokens.thumbnailInset),
      child: Opacity(
        opacity: (1 - _completionDetail) * _revealProgress,
        child: ClipOval(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Opacity(
                opacity: 1 - blend,
                child: Transform.scale(
                  // Outgoing image eases back to .94 while fading (prototype
                  // drops .show, reversing both transitions).
                  scale:
                      1 -
                      (1 - CoachTaskBubbleTokens.imageInitialScale) *
                          Curves.easeOutCubic.transform(blend) -
                      (1 - CoachTaskBubbleTokens.imageInitialScale) *
                          (1 - Curves.easeOutCubic.transform(_revealProgress)),
                  child: _thumbnail(selected[current]),
                ),
              ),
              if (blend > 0)
                Opacity(
                  opacity: blend,
                  child: Transform.scale(
                    scale:
                        CoachTaskBubbleTokens.imageInitialScale +
                        (1 - CoachTaskBubbleTokens.imageInitialScale) *
                            Curves.easeOutCubic.transform(blend),
                    child: _thumbnail(selected[next]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumbnail(({String id, ImageProvider image}) selected) => Image(
    key: ValueKey('generation-thumbnail-${selected.id}'),
    image: selected.image,
    fit: BoxFit.contain,
    alignment: Alignment.center,
    excludeFromSemantics: true,
  );

  Widget _progressBar() => AnimatedBuilder(
    animation: Listenable.merge([_progress, _band]),
    builder: (context, _) {
      final phase = widget.phase;
      return Row(
        children: [
          for (
            var index = 0;
            index < CoachTaskBubbleTokens.progressSegments;
            index++
          ) ...[
            if (index > 0)
              const SizedBox(width: CoachTaskBubbleTokens.progressGap),
            Expanded(
              child: SizedBox(
                height: CoachTaskBubbleTokens.progressHeight,
                child: ClipRRect(
                  key: ValueKey('generation-progress-$index'),
                  borderRadius: BorderRadius.circular(
                    CoachTaskBubbleTokens.progressRadius,
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) => Stack(
                      fit: StackFit.expand,
                      children: [
                        ColoredBox(
                          color: index == phase
                              ? _tokens(
                                  context,
                                ).colors.taskAccent.withValues(alpha: .30)
                              : _tokens(context).progressTrack,
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            key: ValueKey('generation-progress-fill-$index'),
                            heightFactor: 1,
                            widthFactor: _segmentFill(index),
                            child: ColoredBox(
                              color: _tokens(context).colors.taskAccent,
                            ),
                          ),
                        ),
                        if (index == phase &&
                            !_motionOff &&
                            !_visualComplete &&
                            widget.waiting)
                          Positioned(
                            left:
                                constraints.maxWidth *
                                (-CoachTaskBubbleTokens.progressBandFraction +
                                    (1 +
                                            CoachTaskBubbleTokens
                                                .progressBandFraction) *
                                        CoachTaskBubbleTokens.sine.transform(
                                          _band.value,
                                        )),
                            top: 0,
                            bottom: 0,
                            width:
                                constraints.maxWidth *
                                CoachTaskBubbleTokens.progressBandFraction,
                            child: DecoratedBox(
                              key: ValueKey('generation-progress-band-$index'),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    _tokens(
                                      context,
                                    ).colors.taskAccent.withValues(alpha: 0),
                                    _tokens(context).colors.taskAccent,
                                    _tokens(
                                      context,
                                    ).colors.taskAccent.withValues(alpha: 0),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      );
    },
  );
}

typedef _ChipData = ({String field, String label, bool user});

class _ArcPainter extends CustomPainter {
  const _ArcPainter({
    required this.color,
    required this.sweep,
    required this.tailAlpha,
    required this.headAlpha,
  });
  final Color color;
  final double sweep;
  final double tailAlpha;
  final double headAlpha;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = (Offset.zero & size).deflate(
      CoachTaskBubbleTokens.arcStroke / 2,
    );
    final radians = sweep * math.pi / 180;
    const start = -math.pi / 2;
    canvas.drawArc(
      bounds,
      start,
      radians,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = CoachTaskBubbleTokens.arcStroke
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: radians,
          transform: const GradientRotation(start),
          colors: [
            color.withValues(alpha: tailAlpha),
            color,
          ],
        ).createShader(bounds),
    );
    if (headAlpha > 0) {
      final angle = start + radians;
      canvas.drawCircle(
        bounds.center +
            Offset(
              bounds.width / 2 * math.cos(angle),
              bounds.height / 2 * math.sin(angle),
            ),
        CoachTaskBubbleTokens.arcHeadSize / 2,
        Paint()..color = color.withValues(alpha: headAlpha),
      );
    }
  }

  @override
  bool shouldRepaint(_ArcPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.sweep != sweep ||
      oldDelegate.tailAlpha != tailAlpha ||
      oldDelegate.headAlpha != headAlpha;
}

/// Prototype check: 20x20 viewBox, path M5 10.5 l3.2 3.2 L15 6.8,
/// stroke 2.4, round caps and joins. Not a font glyph.
class _CheckPainter extends CustomPainter {
  const _CheckPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 20;
    final path = Path()
      ..moveTo(5 * unit, 10.5 * unit)
      ..lineTo(8.2 * unit, 13.7 * unit)
      ..lineTo(15 * unit, 6.8 * unit);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = CoachTaskBubbleTokens.checkStroke * unit
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter oldDelegate) => oldDelegate.color != color;
}

class _CancelButton extends StatefulWidget {
  const _CancelButton({required this.onCancel});
  final VoidCallback onCancel;

  @override
  State<_CancelButton> createState() => _CancelButtonState();
}

class _CancelButtonState extends State<_CancelButton> {
  bool _pressed = false;

  void _press(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => _press(true),
    onPointerUp: (_) => _press(false),
    onPointerCancel: (_) => _press(false),
    child: Opacity(
      opacity: _pressed ? .5 : 1,
      child: TextButton(
        onPressed: widget.onCancel,
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size.square(CoachTaskBubbleTokens.cancelTouchSize),
          foregroundColor: _tokens(context).colors.taskMuted,
          backgroundColor: Colors.transparent,
          side: BorderSide.none,
          overlayColor: Colors.transparent,
        ),
        child: Text(
          CoachUiTheme.of(context).strings.taskCancel,
          style: _tokens(context).cancel,
        ),
      ),
    ),
  );
}

class _StatusSentence extends StatefulWidget {
  const _StatusSentence({
    required this.text,
    required this.shimmer,
    required this.reduced,
  });
  final String text;
  final Animation<double> shimmer;
  final bool reduced;

  @override
  State<_StatusSentence> createState() => _StatusSentenceState();
}

class _StatusSentenceState extends State<_StatusSentence>
    with SingleTickerProviderStateMixin {
  late final AnimationController _transition;
  String? _previous;

  @override
  void initState() {
    super.initState();
    _transition = AnimationController(
      vsync: this,
      duration:
          CoachTaskBubbleTokens.statusDelay +
          CoachTaskBubbleTokens.statusTransition,
      value: 1,
    );
  }

  @override
  void didUpdateWidget(_StatusSentence oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reduced) {
      _transition.stop();
      _transition.value = 1;
      _previous = null;
    } else if (oldWidget.text != widget.text) {
      _previous = oldWidget.text;
      _transition.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _transition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = _tokens(context).status;
    final height =
        MediaQuery.textScalerOf(context).scale(style.fontSize!) * style.height!;
    return Semantics(
      label: widget.text,
      liveRegion: true,
      child: ExcludeSemantics(
        child: SizedBox(
          key: const ValueKey('generation-status'),
          height: height,
          child: AnimatedBuilder(
            animation: Listenable.merge([_transition, widget.shimmer]),
            builder: (context, _) {
              Widget text(String value) {
                final sentence = Text(
                  value,
                  style: style,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                );
                if (widget.reduced) return sentence;
                return ShaderMask(
                  shaderCallback: (bounds) {
                    // CSS: background-size 250%, background-position 100% ->
                    // -150%. Offset = (W - 2.5W) * p, so the band travels left
                    // to right and leaves a dark gap between passes.
                    final width = bounds.width;
                    const span = CoachTaskBubbleTokens.shimmerSpan;
                    final p = 1 + (-1.5 - 1) * widget.shimmer.value;
                    final left = (width - span * width) * p;
                    return LinearGradient(
                      colors: [
                        _tokens(context).colors.taskMuted,
                        _tokens(context).colors.taskMuted,
                        _tokens(context).highlight,
                        _tokens(context).colors.taskMuted,
                        _tokens(context).colors.taskMuted,
                      ],
                      stops: CoachTaskBubbleTokens.shimmerStops,
                    ).createShader(
                      Rect.fromLTWH(left, 0, span * width, bounds.height),
                    );
                  },
                  blendMode: BlendMode.srcIn,
                  child: sentence,
                );
              }

              if (widget.reduced) return text(widget.text);
              final elapsed =
                  _transition.value *
                  (CoachTaskBubbleTokens.statusDelay +
                          CoachTaskBubbleTokens.statusTransition)
                      .inMicroseconds;
              final outgoing = Curves.easeInCubic.transform(
                (elapsed / CoachTaskBubbleTokens.statusExit.inMicroseconds)
                    .clamp(0.0, 1.0),
              );
              final incoming = Curves.easeOutCubic.transform(
                ((elapsed - CoachTaskBubbleTokens.statusDelay.inMicroseconds) /
                        CoachTaskBubbleTokens.statusTransition.inMicroseconds)
                    .clamp(0.0, 1.0),
              );
              return ClipRect(
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    if (outgoing < 1 && _previous != null)
                      Opacity(
                        opacity: 1 - outgoing,
                        child: Transform.translate(
                          offset: Offset(
                            0,
                            -CoachTaskBubbleTokens.statusOffset * outgoing,
                          ),
                          child: text(_previous!),
                        ),
                      ),
                    Opacity(
                      opacity: incoming,
                      child: Transform.translate(
                        offset: Offset(
                          0,
                          CoachTaskBubbleTokens.statusOffset * (1 - incoming),
                        ),
                        child: text(widget.text),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ParameterChip extends StatefulWidget {
  const _ParameterChip({
    super.key,
    required this.data,
    required this.index,
    required this.reduced,
  });
  final _ChipData data;
  final int index;
  final bool reduced;

  @override
  State<_ParameterChip> createState() => _ParameterChipState();
}

class _ParameterChipState extends State<_ParameterChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _appearance;
  late final Animation<double> _entry;

  @override
  void initState() {
    super.initState();
    final delay = CoachTaskBubbleTokens.chipDelay * widget.index;
    final duration = delay + CoachTaskBubbleTokens.chipTransition;
    _appearance = AnimationController(
      vsync: this,
      duration: duration,
      value: widget.reduced ? 1 : 0,
    );
    _entry = _appearance.drive(
      CurveTween(
        curve: Interval(
          delay.inMicroseconds / duration.inMicroseconds,
          1,
          curve: Curves.easeOutCubic,
        ),
      ),
    );
    if (!widget.reduced) _appearance.forward();
  }

  @override
  void didUpdateWidget(_ParameterChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reduced) {
      _appearance.stop();
      _appearance.value = 1;
    }
  }

  @override
  void dispose() {
    _appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _entry,
    child: ScaleTransition(
      scale: Tween<double>(
        begin: CoachTaskBubbleTokens.chipInitialScale,
        end: 1,
      ).animate(_entry),
      child: Container(
        key: ValueKey('generation-chip-face-${widget.data.field}'),
        height: CoachTaskBubbleTokens.chipHeight,
        padding: CoachTaskBubbleTokens.chipPadding,
        decoration: BoxDecoration(
          color: _tokens(context).chipFill(widget.data.user),
          borderRadius: BorderRadius.circular(CoachTaskBubbleTokens.chipRadius),
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(CoachTaskBubbleTokens.chipRadius),
          border: widget.data.user
              ? null
              : Border.all(color: _tokens(context).chipEdge, width: 1),
        ),
        child: Center(
          widthFactor: 1,
          child: Text(
            widget.data.label,
            style: _tokens(context).chipText(widget.data.user),
          ),
        ),
      ),
    ),
  );
}
