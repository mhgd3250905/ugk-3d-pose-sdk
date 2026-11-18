import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/services.dart';

import '../result/session_result.dart';
import 'trainer_player_motion.dart';
import 'trainer_strings.dart';
import 'trainer_theme.dart';

const _feedbackIn = PlayerMotion.medium;
const _feedbackStagger = PlayerMotion.phaseStagger;
const _feedbackOut = PlayerMotion.fast;
const _reducedFade = PlayerMotion.reducedFade;
const _dockResize = PlayerMotion.slow;
const _shrinkDelay = PlayerMotion.phaseShrinkDelay;
const _selectionHold = Duration(milliseconds: 300);
final _feedbackStaggeredIn = _feedbackIn + _feedbackStagger * 3;

typedef _RecordedFeedback = ({
  TrainerRestFeedbackChoice choice,
  String label,
  Color color,
  IconData icon,
});

/// Player V1's dock. The player supplies the existing controls and owns their
/// callbacks and session state.
class TrainerPlayerV1Dock extends StatefulWidget {
  const TrainerPlayerV1Dock({
    super.key,
    required this.theme,
    required this.strings,
    required this.minHeight,
    required this.compactMinHeight,
    required this.bottomInset,
    required this.countdown,
    required this.previous,
    required this.primary,
    required this.next,
    this.optionalControls,
    this.restFeedback,
    this.restIdentity,
    this.onRestFeedbackRecorded,
    this.completionFading = false,
  });

  final TrainerTheme theme;
  final TrainerStrings strings;
  final double minHeight;
  final double compactMinHeight;
  final double bottomInset;
  final Widget countdown;
  final Widget previous;
  final Widget primary;
  final Widget next;
  final Widget? optionalControls;
  final Widget? restFeedback;
  final Object? restIdentity;
  final ValueChanged<TrainerRestFeedbackChoice>? onRestFeedbackRecorded;

  /// Fade the controls and handle out while retaining the dock's layout.
  final bool completionFading;

  @override
  State<TrainerPlayerV1Dock> createState() => _TrainerPlayerV1DockState();
}

class _TrainerPlayerV1DockState extends State<TrainerPlayerV1Dock>
    with TickerProviderStateMixin {
  late final AnimationController _enter;
  late final AnimationController _exit;
  late final AnimationController _expand;
  late final AnimationController _recorded;
  // Keep controls and host feedback state when switching resize wrappers.
  final _dockContentKey = GlobalKey();
  Widget? _outgoingFeedback;
  double? _outgoingHeight;
  bool _collapseFeedback = false;
  bool _waitingForExpansion = false;
  bool _reduced = false;
  Timer? _selectionHoldTimer;
  _RecordedFeedback? _recordedFeedback;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(vsync: this, value: 1);
    _exit = AnimationController(vsync: this)..addListener(_onExitTick);
    _expand = AnimationController(vsync: this, duration: _dockResize)
      ..addStatusListener(_onExpandTick);
    _recorded = AnimationController(vsync: this, duration: PlayerMotion.medium);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = TrainerMotion.reduced(context);
    if (_reduced == reduced) return;
    _reduced = reduced;
    _cancelExpansion();
    _enter.value = 1;
    if (_outgoingFeedback != null) _exit.value = 1;
    if (reduced && _recordedFeedback != null) {
      final pending = _selectionHoldTimer != null;
      _selectionHoldTimer?.cancel();
      _selectionHoldTimer = null;
      _recorded.value = pending || _recorded.isForwardOrCompleted ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(TrainerPlayerV1Dock oldWidget) {
    super.didUpdateWidget(oldWidget);
    final feedback = widget.restFeedback;
    final previous = oldWidget.restFeedback;
    if (feedback == null && previous != null) {
      _selectionHoldTimer?.cancel();
      _selectionHoldTimer = null;
      _recorded.stop();
      final wasWaiting = _waitingForExpansion;
      _cancelExpansion();
      _enter.stop();
      // A rest skipped during expansion never exposed its feedback.
      if (wasWaiting) return;
      _outgoingFeedback = previous;
      _outgoingHeight = oldWidget.minHeight;
      _collapseFeedback = false;
      _exit.duration = _reduced ? _reducedFade : _feedbackOut;
      _exit.forward(from: 0);
    } else if (feedback != null && previous == null) {
      _clearRecordedFeedback();
      _exit.stop();
      _outgoingFeedback = null;
      _outgoingHeight = null;
      _collapseFeedback = false;
      _enter.value = 0;
      if (_reduced) {
        _startEntrance(feedback);
      } else {
        _waitingForExpansion = true;
        _expand.forward(from: 0);
      }
    } else if (widget.restIdentity != oldWidget.restIdentity) {
      _clearRecordedFeedback();
    }
  }

  void _clearRecordedFeedback() {
    _selectionHoldTimer?.cancel();
    _selectionHoldTimer = null;
    _recordedFeedback = null;
    _recorded.value = 0;
  }

  void _onFeedbackSelected(_RecordedFeedback feedback) {
    if (widget.restFeedback == null) return;
    widget.onRestFeedbackRecorded?.call(feedback.choice);
    _selectionHoldTimer?.cancel();
    setState(() => _recordedFeedback = feedback);
    if (_reduced) {
      _recorded.value = 1;
      return;
    }
    _selectionHoldTimer = Timer(_selectionHold, () {
      _selectionHoldTimer = null;
      _recorded.animateTo(1, curve: Curves.easeOutCubic);
    });
  }

  void _editFeedback() {
    if (_reduced) {
      _recorded.value = 0;
    } else {
      _recorded.animateBack(0, curve: Curves.easeOutCubic);
    }
  }

  void _cancelExpansion() {
    _waitingForExpansion = false;
    _expand.stop();
  }

  void _startEntrance(Widget feedback) {
    _enter.duration = _reduced
        ? _reducedFade
        : feedback is TrainerRestFeedbackPanel
        ? _feedbackStaggeredIn
        : _feedbackIn;
    _enter.forward(from: 0);
  }

  void _onExpandTick(AnimationStatus status) {
    if (status != AnimationStatus.completed || !_waitingForExpansion) return;
    final feedback = widget.restFeedback;
    if (feedback == null) return;
    // AnimatedSize can retarget and settle without an onEnd notification.
    setState(() => _waitingForExpansion = false);
    _startEntrance(feedback);
  }

  void _onExitTick() {
    if (_outgoingFeedback == null) return;
    if (_exit.value == 1) {
      setState(() {
        _outgoingFeedback = null;
        _outgoingHeight = null;
        _collapseFeedback = false;
        _clearRecordedFeedback();
      });
    } else if (!_reduced &&
        !_collapseFeedback &&
        _exit.value >=
            _shrinkDelay.inMilliseconds / _feedbackOut.inMilliseconds) {
      setState(() => _collapseFeedback = true);
    }
  }

  @override
  void dispose() {
    _selectionHoldTimer?.cancel();
    _recorded.dispose();
    _expand.dispose();
    _enter.dispose();
    _exit.dispose();
    super.dispose();
  }

  Widget _feedbackSlot(Widget feedback) {
    final leaving = _outgoingFeedback != null;
    final stagger = !_reduced && feedback is TrainerRestFeedbackPanel;
    return SizedBox(
      height: _collapseFeedback ? 0 : null,
      // Give the space back to the dock after 80 ms. Bottom alignment keeps
      // the remaining 80 ms of the fade above the anchored countdown.
      child: OverflowBox(
        alignment: Alignment.bottomCenter,
        minHeight: 0,
        maxHeight: double.infinity,
        fit: OverflowBoxFit.deferToChild,
        child: IgnorePointer(
          ignoring: leaving || _waitingForExpansion,
          child: ExcludeSemantics(
            excluding: leaving || _waitingForExpansion,
            child: AnimatedBuilder(
              animation: Listenable.merge([_enter, _exit]),
              builder: (context, child) {
                final entered = stagger
                    ? 1.0
                    : PlayerMotion.enter.transform(_enter.value);
                final exited = leaving
                    ? Curves.easeIn.transform(_exit.value)
                    : 0.0;
                return Opacity(
                  key: const ValueKey('player-v1-rest-feedback-opacity'),
                  opacity: _waitingForExpansion ? 0 : entered * (1 - exited),
                  child: _reduced
                      ? child
                      : Transform.translate(
                          offset: Offset(
                            0,
                            PlayerMotion.small * (1 - entered) +
                                PlayerMotion.normal * exited,
                          ),
                          transformHitTests: false,
                          child: child,
                        ),
                );
              },
              child: AnimatedBuilder(
                animation: _recorded,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _RestFeedbackEntrance(
                      animation: stagger ? _enter : null,
                      onSelected: _onFeedbackSelected,
                      child: feedback,
                    ),
                    const SizedBox(height: 12),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: widget.theme.border,
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
                builder: (context, expanded) {
                  final progress = _recorded.value;
                  final recorded = _recordedFeedback;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _feedbackExtent(1 - progress, expanded!),
                      if (recorded != null && progress > 0)
                        _feedbackExtent(progress, _recordedCapsule(recorded)),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _feedbackExtent(double fraction, Widget child) => Offstage(
    offstage: fraction == 0,
    child: ExcludeFocus(
      excluding: fraction < 1,
      child: ExcludeSemantics(
        excluding: fraction < 1,
        child: IgnorePointer(
          ignoring: fraction < 1,
          child: ClipRect(
            child: Align(
              alignment: Alignment.bottomCenter,
              heightFactor: fraction,
              child: Opacity(opacity: fraction, child: child),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _recordedCapsule(_RecordedFeedback feedback) {
    final theme = widget.theme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SizedBox(
        height: 32,
        child: TextButton(
          key: const ValueKey('player-v1-rest-feedback-edit'),
          onPressed: _editFeedback,
          style: TextButton.styleFrom(
            backgroundColor: feedback.color.withValues(alpha: .08),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            minimumSize: const Size(0, 32),
            shape: const StadiumBorder(),
            side: BorderSide.none,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.standard,
            animationDuration: Duration.zero,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(feedback.icon, size: 16, color: feedback.color),
                const SizedBox(width: 6),
                Text(
                  widget.strings.restFeedbackRecorded(feedback.label),
                  style: theme.body.copyWith(
                    color: feedback.color,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  widget.strings.restFeedbackEdit,
                  style: theme.body.copyWith(color: theme.muted, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _resize(double height, Widget child) => AnimatedBuilder(
    animation: _recorded,
    child: child,
    builder: (context, child) {
      final content = ConstrainedBox(
        key: _dockContentKey,
        constraints: BoxConstraints(
          minHeight:
              height + (widget.compactMinHeight - height) * _recorded.value,
        ),
        child: child,
      );
      if (_reduced ||
          (_recordedFeedback != null && widget.restFeedback != null)) {
        return content;
      }
      return AnimatedSize(
        alignment: Alignment.bottomCenter,
        duration: _dockResize,
        curve: PlayerMotion.morph,
        child: content,
      );
    },
  );

  Widget _fadeForCompletion(Widget child, {Key? key}) => IgnorePointer(
    ignoring: widget.completionFading,
    child: ExcludeSemantics(
      excluding: widget.completionFading,
      child: AnimatedOpacity(
        key: key,
        opacity: widget.completionFading ? 0 : 1,
        duration: _reduced ? _reducedFade : PlayerMotion.actionOut,
        child: child,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final feedback = widget.restFeedback ?? _outgoingFeedback;
    final height = _collapseFeedback
        ? widget.minHeight
        : _outgoingHeight ?? widget.minHeight;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.card.withValues(alpha: 1),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _resize(
            height,
            Padding(
              padding: EdgeInsets.fromLTRB(24, 20, 24, 16 + widget.bottomInset),
              child: Align(
                alignment: Alignment.bottomCenter,
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: _fadeForCompletion(
                    key: const ValueKey('player-v1-dock-content-opacity'),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          key: const ValueKey('player-v1-rest-feedback-slot'),
                          child: feedback == null
                              ? null
                              : _feedbackSlot(feedback),
                        ),
                        ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 52),
                          child: Align(
                            alignment: Alignment.center,
                            heightFactor: 1,
                            child: widget.countdown,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Center(
                          child: SizedBox(
                            width: 240,
                            child: OverflowBar(
                              alignment: MainAxisAlignment.spaceBetween,
                              overflowSpacing: 8,
                              children: [
                                widget.previous,
                                widget.primary,
                                widget.next,
                              ],
                            ),
                          ),
                        ),
                        ?widget.optionalControls,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Center(
                  child: _fadeForCompletion(
                    SizedBox(
                      key: const ValueKey('player-v1-dock-handle'),
                      width: 40,
                      height: 4,
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: theme.border,
                          shape: const StadiumBorder(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RestFeedbackEntrance extends InheritedWidget {
  const _RestFeedbackEntrance({
    required this.animation,
    required this.onSelected,
    required super.child,
  });

  final Animation<double>? animation;
  final ValueChanged<_RecordedFeedback> onSelected;

  static Widget stagger(BuildContext context, int index, Widget child) {
    final animation = context
        .dependOnInheritedWidgetOfExactType<_RestFeedbackEntrance>()
        ?.animation;
    if (animation == null) return child;
    final total = _feedbackStaggeredIn.inMilliseconds;
    final start = index * _feedbackStagger.inMilliseconds;
    final progress = Interval(
      start / total,
      (start + _feedbackIn.inMilliseconds) / total,
      curve: PlayerMotion.enter,
    );
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final value = progress.transform(animation.value);
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, PlayerMotion.small * (1 - value)),
            transformHitTests: false,
            child: child,
          ),
        );
      },
    );
  }

  @override
  bool updateShouldNotify(_RestFeedbackEntrance oldWidget) =>
      animation != oldWidget.animation;
}

enum TrainerRestFeedbackTone { positive, neutral, negative }

/// A rest feedback option with optional host-defined styling.
class TrainerRestFeedbackOption {
  const TrainerRestFeedbackOption({
    required this.choice,
    required this.label,
    this.onPressed,
    this.tone,
    this.icon,
  });

  final TrainerRestFeedbackChoice choice;
  final String label;
  final VoidCallback? onPressed;
  final TrainerRestFeedbackTone? tone;
  final IconData? icon;
}

/// A host supplies option labels, callbacks and the current selection.
class TrainerRestFeedbackPanel extends StatelessWidget {
  const TrainerRestFeedbackPanel({
    super.key,
    required this.theme,
    required this.title,
    this.description = '选一个，下一组帮你调整',
    this.recordedTitle,
    this.selected,
    this.comfortableLabel,
    this.onComfortable,
    this.tightLabel,
    this.onTight,
    this.painLabel,
    this.onPain,
    this.options,
  });

  final TrainerTheme theme;
  final String title;
  final String description;
  final String? recordedTitle;
  final TrainerRestFeedbackChoice? selected;
  final String? comfortableLabel;
  final VoidCallback? onComfortable;
  final String? tightLabel;
  final VoidCallback? onTight;
  final String? painLabel;
  final VoidCallback? onPain;

  /// When supplied, replaces the three individually configured options.
  final List<TrainerRestFeedbackOption>? options;

  @override
  Widget build(BuildContext context) {
    final currentTitle = selected == null ? title : recordedTitle ?? title;
    final reduced = TrainerMotion.reduced(context);
    final onSelected = context
        .dependOnInheritedWidgetOfExactType<_RestFeedbackEntrance>()
        ?.onSelected;
    final choices =
        options ??
        [
          if (comfortableLabel case final label?)
            TrainerRestFeedbackOption(
              choice: TrainerRestFeedbackChoice.comfortable,
              label: label,
              onPressed: onComfortable,
            ),
          if (tightLabel case final label?)
            TrainerRestFeedbackOption(
              choice: TrainerRestFeedbackChoice.tight,
              label: label,
              onPressed: onTight,
            ),
          if (painLabel case final label?)
            TrainerRestFeedbackOption(
              choice: TrainerRestFeedbackChoice.pain,
              label: label,
              onPressed: onPain,
            ),
        ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RestFeedbackEntrance.stagger(
          context,
          0,
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedSwitcher(
                duration: reduced ? _reducedFade : PlayerMotion.controlsFade,
                child: Text(
                  currentTitle,
                  key: ValueKey(currentTitle),
                  textAlign: TextAlign.center,
                  style: theme.title.copyWith(
                    color: theme.feedbackText,
                    fontSize: 16,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                textAlign: TextAlign.center,
                style: theme.label.copyWith(
                  color: const Color(0xFF8A9499),
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
        if (choices.isNotEmpty) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              for (var i = 0; i < choices.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(
                  child: _RestFeedbackEntrance.stagger(
                    context,
                    i + 1,
                    _option(
                      choices[i],
                      i == 0
                          ? TrainerRestFeedbackTone.positive
                          : i == choices.length - 1
                          ? TrainerRestFeedbackTone.negative
                          : TrainerRestFeedbackTone.neutral,
                      onSelected,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _option(
    TrainerRestFeedbackOption option,
    TrainerRestFeedbackTone fallbackTone,
    ValueChanged<_RecordedFeedback>? onSelected,
  ) {
    final (color, icon) = switch (option.tone ?? fallbackTone) {
      TrainerRestFeedbackTone.positive => (
        theme.feedbackPositive,
        Icons.sentiment_satisfied_alt_rounded,
      ),
      TrainerRestFeedbackTone.neutral => (
        theme.feedbackNeutral,
        Icons.sentiment_neutral_rounded,
      ),
      TrainerRestFeedbackTone.negative => (
        theme.feedbackNegative,
        Icons.sentiment_dissatisfied_rounded,
      ),
    };
    final resolvedIcon = option.icon ?? icon;
    return _RestFeedbackCard(
      key: ValueKey('player-v1-rest-${option.choice.name}'),
      option: option,
      icon: resolvedIcon,
      color: color,
      theme: theme,
      selected: selected == option.choice,
      dimmed: selected != null && selected != option.choice,
      onSelected: onSelected == null
          ? null
          : () => onSelected((
              choice: option.choice,
              label: option.label,
              color: color,
              icon: resolvedIcon,
            )),
    );
  }
}

class _RestFeedbackCard extends StatefulWidget {
  const _RestFeedbackCard({
    super.key,
    required this.option,
    required this.icon,
    required this.color,
    required this.theme,
    required this.selected,
    required this.dimmed,
    required this.onSelected,
  });

  final TrainerRestFeedbackOption option;
  final IconData icon;
  final Color color;
  final TrainerTheme theme;
  final bool selected;
  final bool dimmed;
  final VoidCallback? onSelected;

  @override
  State<_RestFeedbackCard> createState() => _RestFeedbackCardState();
}

class _RestFeedbackCardState extends State<_RestFeedbackCard>
    with SingleTickerProviderStateMixin {
  static const _ease = Curves.easeOut;
  static final _bounce = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 1.04).chain(CurveTween(curve: _ease)),
      weight: 1,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.04, end: 1.0).chain(CurveTween(curve: _ease)),
      weight: 1,
    ),
  ]);
  late final AnimationController _selection;
  bool _pressed = false;
  bool _reduced = false;

  @override
  void initState() {
    super.initState();
    _selection = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: 1,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = TrainerMotion.reduced(context);
    if (_reduced) _selection.value = 1;
  }

  @override
  void didUpdateWidget(_RestFeedbackCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_reduced && widget.selected && !oldWidget.selected) {
      _selection.forward(from: 0);
    } else if (!widget.selected && oldWidget.selected) {
      _selection.value = 1;
    }
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  void _highlight(bool pressed) {
    if (!_reduced && _pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final duration = _reduced
        ? _reducedFade
        : const Duration(milliseconds: 200);
    final color = widget.color;
    final selected = widget.selected;
    final radius = BorderRadius.circular(18);
    final onPressed = widget.option.onPressed;
    final card = Semantics(
      selected: selected,
      button: true,
      child: AnimatedOpacity(
        duration: duration,
        curve: _ease,
        opacity: widget.dimmed ? .45 : 1,
        child: AnimatedContainer(
          duration: duration,
          curve: _ease,
          height: 84,
          decoration: BoxDecoration(
            color: color.withValues(alpha: selected ? .16 : .08),
            border: Border.all(
              color: color.withValues(alpha: selected ? 1 : .22),
              width: selected ? 1.5 : 1,
            ),
            borderRadius: radius,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: radius,
              enableFeedback: false,
              onHighlightChanged: _highlight,
              onTap: onPressed == null
                  ? null
                  : () {
                      widget.onSelected?.call();
                      if (!widget.selected) {
                        unawaited(HapticFeedback.selectionClick());
                        onPressed();
                      }
                    },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 8,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(widget.icon, size: 26, color: color),
                            const SizedBox(height: 6),
                            Text(
                              widget.option.label,
                              maxLines: 1,
                              textAlign: TextAlign.center,
                              style: widget.theme.body.copyWith(
                                color: widget.theme.feedbackText,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  PositionedDirectional(
                    top: 8,
                    end: 8,
                    child: AnimatedSwitcher(
                      duration: _reduced
                          ? _reducedFade
                          : const Duration(milliseconds: 220),
                      layoutBuilder: (current, _) =>
                          current ?? const SizedBox.shrink(),
                      transitionBuilder: (child, animation) => _reduced
                          ? FadeTransition(opacity: animation, child: child)
                          : ScaleTransition(
                              scale: animation.drive(
                                CurveTween(curve: Curves.easeOutBack),
                              ),
                              child: child,
                            ),
                      child: selected
                          ? SizedBox.square(
                              key: const ValueKey('player-v1-rest-badge'),
                              dimension: 18,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                ),
                                child: const Center(
                                  child: Icon(
                                    Icons.check_rounded,
                                    color: Colors.white,
                                    size: 12,
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (_reduced) return card;
    return ScaleTransition(
      scale: _selection.drive(_bounce),
      child: AnimatedScale(
        scale: _pressed ? .96 : 1,
        duration: const Duration(milliseconds: 100),
        curve: _ease,
        child: card,
      ),
    );
  }
}

/// Shared appearance for V1 completion feedback.
class TrainerV1FeedbackButton extends StatefulWidget {
  const TrainerV1FeedbackButton({
    super.key,
    required this.theme,
    required this.label,
    required this.color,
    required this.background,
    required this.onPressed,
    this.selected = false,
    this.height = 46,
    this.scaleOnPress = false,
  });

  final TrainerTheme theme;
  final String label;
  final Color color;
  final Color background;
  final VoidCallback? onPressed;
  final bool selected;
  final double height;
  final bool scaleOnPress;

  @override
  State<TrainerV1FeedbackButton> createState() =>
      _TrainerV1FeedbackButtonState();
}

class _TrainerV1FeedbackButtonState extends State<TrainerV1FeedbackButton> {
  bool _pressed = false;

  void _highlight(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final selected = widget.selected;
    final color = widget.color;
    final background = widget.background;
    final height = widget.height;
    final foreground = selected
        ? theme.isDark
              ? const Color(0xFF111214)
              : Colors.white
        : color;
    final reduced = TrainerMotion.reduced(context);
    final duration = reduced ? Duration.zero : PlayerMotion.controlsFade;
    final button = Semantics(
      selected: selected,
      child: TextButton(
        onPressed: widget.onPressed,
        style: TextButton.styleFrom(
          minimumSize: Size(0, height),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(height / 2),
          ),
          side: BorderSide(
            color: color.withValues(alpha: theme.isDark ? .3 : .2),
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          backgroundColor: selected ? color : background,
          disabledBackgroundColor: selected ? color : background,
          foregroundColor: foreground,
          disabledForegroundColor: foreground,
          animationDuration: duration,
          textStyle: theme.body.copyWith(
            fontSize: 15,
            height: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedSwitcher(
              duration: duration,
              child: selected
                  ? const Padding(
                      padding: EdgeInsetsDirectional.only(end: 4),
                      child: Icon(Icons.check_rounded, size: 14),
                    )
                  : const SizedBox.shrink(),
            ),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  widget.label,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (!widget.scaleOnPress || reduced || widget.onPressed == null) {
      return button;
    }
    return Listener(
      onPointerDown: (_) => _highlight(true),
      onPointerUp: (_) => _highlight(false),
      onPointerCancel: (_) => _highlight(false),
      child: AnimatedScale(
        scale: _pressed ? .96 : 1,
        duration: PlayerMotion.press,
        curve: PlayerMotion.enter,
        child: button,
      ),
    );
  }
}
