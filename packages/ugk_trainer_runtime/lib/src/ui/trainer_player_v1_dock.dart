import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;

import 'trainer_theme.dart';

const _feedbackIn = Duration(milliseconds: 240);
const _feedbackStagger = Duration(milliseconds: 40);
const _feedbackStaggeredIn = Duration(milliseconds: 360);
const _feedbackOut = Duration(milliseconds: 160);
const _reducedFade = Duration(milliseconds: 150);
const _dockResize = Duration(milliseconds: 380);
const _shrinkDelay = Duration(milliseconds: 80);

/// Player V1's dock. The player supplies the existing controls and owns their
/// callbacks and session state.
class TrainerPlayerV1Dock extends StatefulWidget {
  const TrainerPlayerV1Dock({
    super.key,
    required this.theme,
    required this.minHeight,
    required this.bottomInset,
    required this.countdown,
    required this.previous,
    required this.primary,
    required this.next,
    this.optionalControls,
    this.restFeedback,
  });

  final TrainerTheme theme;
  final double minHeight;
  final double bottomInset;
  final Widget countdown;
  final Widget previous;
  final Widget primary;
  final Widget next;
  final Widget? optionalControls;
  final Widget? restFeedback;

  @override
  State<TrainerPlayerV1Dock> createState() => _TrainerPlayerV1DockState();
}

class _TrainerPlayerV1DockState extends State<TrainerPlayerV1Dock>
    with TickerProviderStateMixin {
  late final _enter = AnimationController(vsync: this, value: 1);
  late final _exit = AnimationController(vsync: this)..addListener(_onExitTick);
  Widget? _outgoingFeedback;
  double? _outgoingHeight;
  bool _collapseFeedback = false;
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = TrainerMotion.reduced(context);
    if (_reduced == reduced) return;
    _reduced = reduced;
    _enter.value = 1;
    if (_outgoingFeedback != null) _exit.value = 1;
  }

  @override
  void didUpdateWidget(TrainerPlayerV1Dock oldWidget) {
    super.didUpdateWidget(oldWidget);
    final feedback = widget.restFeedback;
    final previous = oldWidget.restFeedback;
    if (feedback == null && previous != null) {
      _enter.stop();
      _outgoingFeedback = previous;
      _outgoingHeight = oldWidget.minHeight;
      _collapseFeedback = false;
      _exit.duration = _reduced ? _reducedFade : _feedbackOut;
      _exit.forward(from: 0);
    } else if (feedback != null && previous == null) {
      _exit.stop();
      _outgoingFeedback = null;
      _outgoingHeight = null;
      _collapseFeedback = false;
      _enter.duration = _reduced
          ? _reducedFade
          : feedback is TrainerRestFeedbackPanel
          ? _feedbackStaggeredIn
          : _feedbackIn;
      _enter.forward(from: 0);
    }
  }

  void _onExitTick() {
    if (_outgoingFeedback == null) return;
    if (_exit.value == 1) {
      setState(() {
        _outgoingFeedback = null;
        _outgoingHeight = null;
        _collapseFeedback = false;
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
          ignoring: leaving,
          child: ExcludeSemantics(
            excluding: leaving,
            child: AnimatedBuilder(
              animation: Listenable.merge([_enter, _exit]),
              builder: (context, child) {
                final entered = stagger
                    ? 1.0
                    : Curves.easeOutCubic.transform(_enter.value);
                final exited = leaving
                    ? Curves.easeIn.transform(_exit.value)
                    : 0.0;
                return Opacity(
                  opacity: entered * (1 - exited),
                  child: _reduced
                      ? child
                      : Transform.translate(
                          offset: Offset(0, 12 * (1 - entered + exited)),
                          transformHitTests: false,
                          child: child,
                        ),
                );
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _RestFeedbackEntrance(
                    animation: stagger ? _enter : null,
                    child: feedback,
                  ),
                  const SizedBox(height: 12),
                  Divider(height: 1, thickness: 1, color: widget.theme.border),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _resize(Widget child) => _reduced
      ? child
      : AnimatedSize(
          alignment: Alignment.bottomCenter,
          duration: _dockResize,
          curve: Curves.easeInOutCubic,
          child: child,
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
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: height),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  20,
                  24,
                  16 + widget.bottomInset,
                ),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Column(
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
                  child: SizedBox(
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
        ],
      ),
    );
  }
}

class _RestFeedbackEntrance extends InheritedWidget {
  const _RestFeedbackEntrance({required this.animation, required super.child});

  final Animation<double>? animation;

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
      curve: Curves.easeOutCubic,
    );
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final value = progress.transform(animation.value);
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 12 * (1 - value)),
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

/// The host's selected response in the standard rest feedback panel.
enum TrainerRestFeedbackChoice { comfortable, tight, pain }

/// A host supplies option labels, callbacks and the current selection.
class TrainerRestFeedbackPanel extends StatelessWidget {
  const TrainerRestFeedbackPanel({
    super.key,
    required this.theme,
    required this.title,
    required this.description,
    this.recordedTitle,
    this.selected,
    this.comfortableLabel,
    this.onComfortable,
    this.tightLabel,
    this.onTight,
    this.painLabel,
    this.onPain,
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

  @override
  Widget build(BuildContext context) {
    final currentTitle = selected == null ? title : recordedTitle ?? title;
    final reduced = TrainerMotion.reduced(context);
    final options = [
      if (comfortableLabel case final label?)
        _option(
          TrainerRestFeedbackChoice.comfortable,
          label,
          theme.goodBg,
          theme.good,
          onComfortable,
        ),
      if (tightLabel case final label?)
        _option(
          TrainerRestFeedbackChoice.tight,
          label,
          theme.cautionBg,
          theme.caution,
          onTight,
        ),
      if (painLabel case final label?)
        _option(
          TrainerRestFeedbackChoice.pain,
          label,
          theme.dangerBg,
          theme.danger,
          onPain,
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
                duration: reduced
                    ? _reducedFade
                    : const Duration(milliseconds: 200),
                child: Text(
                  currentTitle,
                  key: ValueKey(currentTitle),
                  textAlign: TextAlign.center,
                  style: theme.title.copyWith(
                    fontSize: 17,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                textAlign: TextAlign.center,
                style: theme.label.copyWith(
                  color: theme.sub,
                  fontSize: 12,
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
        if (options.isNotEmpty) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              for (var i = 0; i < options.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: _RestFeedbackEntrance.stagger(
                    context,
                    i + 1,
                    options[i],
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
    TrainerRestFeedbackChoice choice,
    String label,
    Color background,
    Color foreground,
    VoidCallback? onPressed,
  ) => TrainerV1FeedbackButton(
    key: ValueKey('player-v1-rest-${choice.name}'),
    theme: theme,
    label: label,
    background: background,
    color: foreground,
    selected: selected == choice,
    scaleOnPress: true,
    onPressed: onPressed,
  );
}

/// Shared appearance for V1 rest and completion feedback.
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
    final duration = reduced
        ? Duration.zero
        : const Duration(milliseconds: 200);
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
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: button,
      ),
    );
  }
}
