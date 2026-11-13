import 'package:flutter/material.dart';

import 'trainer_theme.dart';

/// Switches the visible phase while retaining the current child for tick
/// updates. A new phase replaces any older outgoing child immediately.
class TrainerPhaseSwitcher extends StatefulWidget {
  const TrainerPhaseSwitcher({
    super.key,
    required this.identity,
    required this.child,
    this.enterDuration = const Duration(milliseconds: 240),
    this.exitDuration = const Duration(milliseconds: 240),
    this.enterOffset = 8,
    this.exitOffset = 8,
    this.enterDelay = Duration.zero,
    this.enterCurve = Curves.easeInOutCubic,
    this.exitCurve = Curves.easeInOutCubic,
    this.enterScale = 1,
    this.exitScale = 1,
    this.reserveOutgoingSpace = true,
    this.alignment = Alignment.center,
  });

  final Object identity;
  final Widget child;
  final Duration enterDuration;
  final Duration exitDuration;
  final double enterOffset;
  final double exitOffset;
  final Duration enterDelay;
  final Curve enterCurve;
  final Curve exitCurve;
  final double enterScale;
  final double exitScale;
  final bool reserveOutgoingSpace;
  final AlignmentGeometry alignment;

  @override
  State<TrainerPhaseSwitcher> createState() => _TrainerPhaseSwitcherState();
}

class _TrainerPhaseSwitcherState extends State<TrainerPhaseSwitcher>
    with SingleTickerProviderStateMixin {
  static const _reducedDuration = Duration(milliseconds: 150);

  late final _motion = AnimationController(vsync: this, value: 1);
  Widget? _outgoing;
  int _currentRevision = 0;
  double _outgoingOpacity = 1;
  double _outgoingOffset = 0;
  double _outgoingScale = 1;
  bool _reduced = false;

  Duration get _enter => _reduced ? _reducedDuration : widget.enterDuration;
  Duration get _exit => _reduced ? _reducedDuration : widget.exitDuration;
  Duration get _delay => _reduced ? Duration.zero : widget.enterDelay;
  Duration get _total => _enter + _delay > _exit ? _enter + _delay : _exit;

  double _segment(Duration duration, {Duration delay = Duration.zero}) {
    final elapsed = _motion.value * (_motion.duration ?? _total).inMicroseconds;
    if (duration == Duration.zero) {
      return elapsed >= delay.inMicroseconds ? 1 : 0;
    }
    return ((elapsed - delay.inMicroseconds) / duration.inMicroseconds).clamp(
      0.0,
      1.0,
    );
  }

  double get _incoming => (_reduced ? Curves.linear : widget.enterCurve)
      .transform(_segment(_enter, delay: _delay));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = TrainerMotion.reduced(context);
    if (_reduced == reduced) return;
    _reduced = reduced;
    if (_motion.isAnimating) {
      // A preference change during a transition leaves the latest phase in
      // place. Subsequent transitions use the new motion preference.
      _outgoing = null;
      _motion.value = 1;
    }
  }

  @override
  void didUpdateWidget(TrainerPhaseSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity == widget.identity) return;
    final oldEnter = _reduced ? _reducedDuration : oldWidget.enterDuration;
    final oldDelay = _reduced ? Duration.zero : oldWidget.enterDelay;
    final oldCurve = _reduced ? Curves.linear : oldWidget.enterCurve;
    final incoming = oldCurve.transform(_segment(oldEnter, delay: oldDelay));
    _outgoing = oldWidget.child;
    _outgoingOpacity = incoming;
    _outgoingOffset = _reduced ? 0 : (1 - incoming) * oldWidget.enterOffset;
    _outgoingScale = _reduced
        ? 1
        : 1 + (1 - incoming) * (oldWidget.enterScale - 1);
    _currentRevision++;
    if (_total == Duration.zero) {
      _outgoing = null;
      _motion.value = 1;
      return;
    }
    _motion.duration = _total;
    _motion.forward(from: 0);
  }

  Widget _position({
    required int revision,
    required double opacity,
    required double dy,
    required double scale,
    required bool outgoing,
    required Widget child,
  }) => KeyedSubtree(
    key: ValueKey(revision),
    child: IgnorePointer(
      ignoring: outgoing || opacity == 0,
      child: ExcludeSemantics(
        excluding: outgoing,
        child: TickerMode(
          enabled: !outgoing,
          child: Opacity(
            opacity: opacity,
            child: Transform.translate(
              offset: Offset(0, dy),
              child: Transform.scale(scale: scale, child: child),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _motion,
    builder: (_, child) {
      final exit = (_reduced ? Curves.linear : widget.exitCurve).transform(
        _segment(_exit),
      );
      final incoming = _incoming;
      final outgoing = _outgoing;
      final Widget? leaving =
          outgoing == null || exit == 1 || _outgoingOpacity == 0
          ? null
          : _position(
              revision: _currentRevision - 1,
              opacity: _outgoingOpacity * (1 - exit),
              dy: _reduced ? 0 : _outgoingOffset - widget.exitOffset * exit,
              scale: _reduced
                  ? 1
                  : _outgoingScale + (widget.exitScale - 1) * exit,
              outgoing: true,
              child: outgoing,
            );
      return ClipRect(
        child: Stack(
          alignment: widget.alignment,
          children: [
            if (leaving != null && widget.reserveOutgoingSpace) leaving,
            if (leaving != null && !widget.reserveOutgoingSpace)
              Positioned.fill(
                key: ValueKey('outgoing-${_currentRevision - 1}'),
                child: Align(alignment: widget.alignment, child: leaving),
              ),
            _position(
              revision: _currentRevision,
              opacity: incoming,
              dy: _reduced ? 0 : (1 - incoming) * widget.enterOffset,
              scale: _reduced
                  ? 1
                  : 1 + (1 - incoming) * (widget.enterScale - 1),
              outgoing: false,
              child: child!,
            ),
          ],
        ),
      );
    },
    child: widget.child,
  );

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }
}
