import 'package:flutter/material.dart';

import 'primitives.dart';
import 'task_bubble_tokens.dart';
import 'task_bubble.dart';

// Ported from Sport-Helper@13c0bb4; retains its single visual timeline.
/// Keeps the completed preparation visible without delaying conversation data.
/// Only this wrapper changes height; the bubble owns its orb/check animation.
class CoachDeliveryTransition extends StatefulWidget {
  const CoachDeliveryTransition({
    super.key,
    required this.preparing,
    required this.child,
    this.successful = false,
    this.interrupted = false,
  });

  final bool preparing;
  final Widget child;

  /// A delivered, admitted plan or recommendation may show the success check.
  final bool successful;

  /// A new request immediately reveals a previous request's delivered content.
  final bool interrupted;

  @override
  State<CoachDeliveryTransition> createState() =>
      _CoachDeliveryTransitionState();
}

class _CoachDeliveryTransitionState extends State<CoachDeliveryTransition>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  Widget? _preparation;
  final _preparationTreeKey = GlobalKey();
  AnimationController? _sequence;
  bool _presentingCompletion = false;
  bool _legacyDelivery = false;
  bool _skipDelivery = false;
  bool _reduced = false;
  bool _tickersEnabled = true;
  bool _routeCurrent = true;
  bool _foreground = true;

  static Duration get _beforeCollapse =>
      CoachTaskBubbleTokens.completionVisual +
      CoachTaskBubbleTokens.completionHold;
  static Duration get _total =>
      _beforeCollapse + CoachTaskBubbleTokens.completionTransition;

  bool get _visible => _tickersEnabled && _routeCurrent && _foreground;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (widget.preparing) _preparation = widget.child;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = CoachMotion.reduced(context);
    _tickersEnabled = TickerMode.valuesOf(context).enabled;
    _routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    if (!_visible) _skipDelivery = true;
    if (_reduced || !_visible) _finish();
  }

  @override
  void didUpdateWidget(CoachDeliveryTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.preparing) {
      if (!oldWidget.preparing) {
        _finish();
        _skipDelivery = !_visible;
      }
      _preparation = widget.child;
    } else if (oldWidget.preparing) {
      if (!widget.interrupted &&
          !_skipDelivery &&
          !_reduced &&
          _visible &&
          _preparation != null) {
        if (widget.successful) {
          _startCompletion();
        } else {
          // Failure and ordinary text keep the original 300 ms crossfade.
          _legacyDelivery = true;
        }
      } else {
        _finish();
      }
    } else if (widget.interrupted || (!widget.successful && !_legacyDelivery)) {
      _finish();
    }
  }

  void _startCompletion() {
    if (_preparation case final CoachTaskBubble bubble) {
      _preparation = CoachTaskBubble(
        key: bubble.key,
        title: bubble.title,
        status: bubble.status,
        phase: bubble.phase,
        parameters: bubble.parameters,
        picks: bubble.picks,
        complete: bubble.complete,
        cutoutFor: bubble.cutoutFor,
        waiting: bubble.waiting,
        onCancel: bubble.onCancel,
        visualComplete: true,
      );
    }
    _presentingCompletion = true;
    _legacyDelivery = false;
    // One continuous clock keeps the hold live and needs no delayed callback.
    _sequence ??= (AnimationController(
      vsync: this,
      duration: _total,
      animationBehavior: AnimationBehavior.preserve,
    )..addListener(_sequenceTick));
    _sequence!.forward(from: 0);
  }

  void _sequenceTick() {
    // Flutter reports completed only after the endpoint and clears elapsed on
    // that later frame. Value reaches one at 890 ms and covers both cases.
    if (_presentingCompletion && (_sequence?.value ?? 0) >= 1 && mounted) {
      setState(_finish);
    }
  }

  void _finish() {
    _sequence?.stop();
    _presentingCompletion = false;
    _legacyDelivery = false;
    if (!widget.preparing) _preparation = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _skipDelivery = true;
    if (mounted) {
      setState(() {
        if (!_foreground) _finish();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sequence?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.preparing && !_presentingCompletion && !_legacyDelivery) {
      return widget.child;
    }
    final contents = AnimatedBuilder(
      animation: _sequence ?? kAlwaysDismissedAnimation,
      child: _preparation ?? widget.child,
      builder: (context, child) {
        final elapsed = _presentingCompletion
            ? _sequence?.lastElapsedDuration ?? Duration.zero
            : Duration.zero;
        final collapsing = (elapsed - _beforeCollapse).inMicroseconds.clamp(
          0,
          CoachTaskBubbleTokens.completionTransition.inMicroseconds,
        );
        final height =
            1 -
            Curves.easeOutCubic.transform(
              (collapsing /
                      CoachTaskBubbleTokens.completionTransition.inMicroseconds)
                  .clamp(0.0, 1.0),
            );
        final opacity =
            1 -
            Curves.easeInCubic.transform(
              (collapsing / CoachTaskBubbleTokens.completionFade.inMicroseconds)
                  .clamp(0.0, 1.0),
            );
        return ClipRect(
          child: Align(
            key: const ValueKey('coach-delivery-collapse'),
            alignment: Alignment.topLeft,
            widthFactor: 1,
            heightFactor: height,
            child: Opacity(
              key: const ValueKey('coach-delivery-opacity'),
              opacity: opacity,
              child: IgnorePointer(
                ignoring: !widget.preparing,
                child: TickerMode(
                  enabled:
                      _visible && (widget.preparing || _presentingCompletion),
                  child: child!,
                ),
              ),
            ),
          ),
        );
      },
    );
    // Reparent the entire preparation tree, preserving the bubble's State.
    // Success bypasses AnimatedSize completely: its clock alone changes height.
    final preparation = KeyedSubtree(key: _preparationTreeKey, child: contents);
    if (_presentingCompletion || _reduced || !_visible) return preparation;
    return AnimatedCrossFade(
      key: const ValueKey('coach-delivery-crossfade'),
      duration: CoachTaskBubbleTokens.completionTransition,
      sizeCurve: CoachMotion.standard,
      alignment: Alignment.topLeft,
      firstChild: preparation,
      secondChild: widget.preparing ? const SizedBox.shrink() : widget.child,
      crossFadeState: _legacyDelivery
          ? CrossFadeState.showSecond
          : CrossFadeState.showFirst,
    );
  }
}
