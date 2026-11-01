import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart' show PlanFocusLabel;

import 'training_transition_activity.dart';
import 'measure_size.dart';
import '../theme/chat_tokens.dart';
import '../theme/chat_polish_tokens.dart';

import 'chat_widgets.dart';
import 'coach_ui_adapter.dart';

/// Owns the one menu timeline. Keyboard and menu occupy the same bottom slot,
/// so swapping them never adds their heights together.
class ChatComposerDock extends StatefulWidget {
  const ChatComposerDock({
    super.key,
    required this.panelOpen,
    required this.focusNode,
    required this.extent,
    required this.suggestions,
    required this.input,
    required this.panel,
    required this.activity,
    this.planFocusTitle,
    this.onClearPlanFocus,
  });

  final bool panelOpen;
  final FocusNode focusNode;
  final ValueNotifier<double> extent;
  final Widget suggestions, input;
  final ChatFeaturePanel panel;
  final TrainingTransitionActivity activity;
  final String? planFocusTitle;
  final VoidCallback? onClearPlanFocus;

  @override
  State<ChatComposerDock> createState() => _ChatComposerDockState();
}

class _ChatComposerDockState extends State<ChatComposerDock>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  TrainingTransitionActivity get _trainingActivity => widget.activity;
  late final _controller = AnimationController(
    vsync: this,
    duration: ChatDockPolishTokens.menuDuration,
  )..addListener(_publishExtent);
  late final _motion = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  final _metrics = ValueNotifier<int>(0);
  double _composerHeight = 112;
  double _inputHeight = ChatComposerTokens.inputHeight;
  double _keyboardHeight = 0, _lastKeyboardHeight = 0;
  double _safeBottom = 0, _panelHeight = 0, _preferredHeight = 0;
  double _handoffExtent = 0;
  double _settleFrom = 0, _settleTarget = 0, _settleProgress = 1;
  bool _settling = false;
  bool _openingCarry = false, _closingCarry = false;
  double _carryFrom = 0, _carryTarget = 0, _carryProgress = 0;
  bool _keyboardSizedPanel = false, _toKeyboard = false;
  bool _reduced = false;
  bool _extentScheduled = false;
  bool _trainingDirty = false;
  bool _trainingFlushScheduled = false;
  bool _flushingTrainingUpdates = false;
  MediaQueryData? _currentMedia, _pendingMedia;
  AnimationStatus? _pendingStatus;
  double? _pendingComposerHeight, _pendingInputHeight;

  double get _safe =>
      _keyboardHeight > 0 || _keyboardSizedPanel ? 0 : _safeBottom;
  double get _visiblePanel => _settling ? 0 : _panelHeight * _motion.value;
  double get _settlingExtent =>
      _settleTarget +
      (_settleFrom - _settleTarget) *
          (_motion.value / _settleProgress).clamp(0.0, 1.0);
  double get _carryExtent {
    if (_openingCarry) {
      final progress = ((_motion.value - _carryProgress) / (1 - _carryProgress))
          .clamp(0.0, 1.0);
      return _carryFrom + (_panelHeight + _safe - _carryFrom) * progress;
    }
    if (_closingCarry) {
      return _carryTarget +
          (_carryFrom - _carryTarget) *
              (_motion.value / _carryProgress).clamp(0.0, 1.0);
    }
    return 0;
  }

  double get _bottomExtent => math.max(
    _visiblePanel + _safe,
    math.max(
      _keyboardHeight,
      math.max(_carryExtent, _settling ? _settlingExtent : _handoffExtent),
    ),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.focusNode.addListener(_focusChanged);
    _controller.addStatusListener(_statusChanged);
    _trainingActivity.addListener(_trainingActivityChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    if (_trainingActivity.active && _currentMedia != null) {
      _pendingMedia = media;
      _trainingDirty = true;
      return;
    }
    _applyMedia(media);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _publishExtent();
    });
  }

  void _applyMedia(MediaQueryData media) {
    _currentMedia = media;
    _reduced = media.disableAnimations;
    _safeBottom = media.viewPadding.bottom;
    _preferredHeight = ChatFeaturePanel.heightFor(
      width: media.size.width,
      viewportHeight: media.size.height,
      textScaler: media.textScaler,
      actionCount: widget.panel.actions.length,
    );
    if (!_keyboardSizedPanel) _panelHeight = _preferredHeight;
    _readKeyboard();
  }

  @override
  void didUpdateWidget(ChatComposerDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.activity, widget.activity)) {
      oldWidget.activity.removeListener(_trainingActivityChanged);
      widget.activity.addListener(_trainingActivityChanged);
    }
    if (oldWidget.panelOpen == widget.panelOpen) return;
    if (widget.panelOpen) {
      final carriedExtent = _bottomExtent;
      final needsCarry = _settling || _closingCarry;
      _toKeyboard = false;
      if (needsCarry) {
        _carryFrom = carriedExtent;
        _carryProgress = _settling ? 0 : _motion.value;
        _openingCarry = true;
        _closingCarry = false;
      }
      if (_settling) {
        _settling = false;
        _controller.value = 0;
      }
      if (_keyboardHeight > 0) {
        _panelHeight = _lastKeyboardHeight;
        _keyboardSizedPanel = true;
        _handoffExtent = _keyboardHeight;
      } else if (_controller.isDismissed) {
        _keyboardSizedPanel = false;
        _panelHeight = _preferredHeight;
        _handoffExtent = 0;
      }
      widget.focusNode.unfocus(disposition: UnfocusDisposition.scope);
      if (_reduced) {
        _controller.value = 1;
      } else {
        _controller.forward();
      }
    } else {
      final carriedExtent = _bottomExtent;
      if (_openingCarry && _motion.value > 0) {
        _closingCarry = true;
        _carryFrom = carriedExtent;
        _carryTarget = _keyboardHeight > 0 ? _keyboardHeight : _safeBottom;
        _carryProgress = _motion.value;
      }
      _openingCarry = false;
      _toKeyboard = widget.focusNode.hasFocus;
      _handoffExtent = _toKeyboard ? carriedExtent : 0;
      if (_reduced) {
        _controller.value = 0;
      } else {
        _controller.reverse();
      }
    }
  }

  void _focusChanged() {
    if (_trainingActivity.active) {
      _trainingDirty = true;
      return;
    }
    if (!widget.focusNode.hasFocus && _toKeyboard) {
      _toKeyboard = false;
      _handoffExtent = 0;
      if (!_flushingTrainingUpdates) _metrics.value++;
      _publishExtent();
    }
  }

  void _statusChanged(AnimationStatus status) {
    if (_trainingActivity.active) {
      _trainingDirty = true;
      _pendingStatus = status;
      return;
    }
    if (status == AnimationStatus.completed) _openingCarry = false;
    if (status == AnimationStatus.dismissed) _closingCarry = false;
    if (status == AnimationStatus.completed && _keyboardHeight == 0) {
      _handoffExtent = 0;
    }
    if (status == AnimationStatus.dismissed && _settling) {
      _settling = false;
      _handoffExtent = 0;
      _keyboardSizedPanel = false;
    } else if (status == AnimationStatus.dismissed &&
        _toKeyboard &&
        _handoffExtent > _keyboardHeight) {
      // A different IME (or a hardware keyboard) can be shorter than the
      // remembered one. Reuse this timeline to retire only the spare slot;
      // the menu has already closed and never flashes back on screen.
      _settleFrom = _bottomExtent;
      _settleTarget = _keyboardHeight > 0 ? _keyboardHeight : _safeBottom;
      _settleProgress = 1;
      _settling = !_reduced;
      _handoffExtent = 0;
      if (_settling) {
        _controller.value = 1;
        _controller.reverse();
      } else {
        _keyboardSizedPanel = false;
      }
    } else if (status == AnimationStatus.dismissed && !_toKeyboard) {
      _keyboardSizedPanel = false;
    }
    _publishExtent();
  }

  void _readKeyboard() {
    final view = View.of(context);
    final previousExtent = _bottomExtent;
    _keyboardHeight = view.viewInsets.bottom / view.devicePixelRatio;
    if (_keyboardHeight > 0) _lastKeyboardHeight = _keyboardHeight;
    if (_settling && _motion.value > 0) {
      _settleFrom = previousExtent;
      _settleTarget = _keyboardHeight > 0 ? _keyboardHeight : _safeBottom;
      _settleProgress = _motion.value;
    }
    if (_closingCarry && _motion.value > 0) {
      _carryFrom = previousExtent;
      _carryTarget = _keyboardHeight > 0 ? _keyboardHeight : _safeBottom;
      _carryProgress = _motion.value;
    }
    if (_toKeyboard &&
        _keyboardHeight >= _handoffExtent &&
        _keyboardHeight > 0) {
      _handoffExtent = 0;
    }
  }

  @override
  void didChangeMetrics() {
    if (_trainingActivity.active) {
      _trainingDirty = true;
      return;
    }
    _readKeyboard();
    if (_controller.isCompleted && _keyboardHeight == 0) {
      _handoffExtent = 0;
    }
    _metrics.value++;
    _publishExtent();
  }

  void _publishExtent() {
    if (!mounted) return;
    if (_trainingActivity.active) {
      _trainingDirty = true;
      return;
    }
    if (_flushingTrainingUpdates) return;
    // Reduced motion can change the timeline synchronously in didUpdateWidget.
    // A sibling viewport cannot be marked dirty during that build phase.
    // Normal animation ticks publish before build and stay in the same frame.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (!_extentScheduled) {
        _extentScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _extentScheduled = false;
          _publishExtent();
        });
      }
      return;
    }
    if (!widget.panelOpen && _controller.isDismissed && _handoffExtent == 0) {
      _keyboardSizedPanel = false;
    }
    final next = _composerHeight + _bottomExtent;
    if ((widget.extent.value - next).abs() > .01) {
      widget.extent.value = next;
    }
  }

  void _trainingActivityChanged() {
    if (_trainingActivity.active || !_trainingDirty || !mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_trainingFlushScheduled) return;
      _trainingFlushScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _trainingFlushScheduled = false;
        _flushTrainingUpdates();
      });
      return;
    }
    _flushTrainingUpdates();
  }

  /// IME observers and size notifications do not flow through the chat model.
  /// Keep their published geometry unchanged throughout either training slide,
  /// then apply the latest environment once while the source is offscreen.
  void _flushTrainingUpdates() {
    if (!mounted || _trainingActivity.active || !_trainingDirty) return;
    _trainingDirty = false;
    _flushingTrainingUpdates = true;
    try {
      final media = _pendingMedia;
      _pendingMedia = null;
      if (media != null) {
        _applyMedia(media);
      } else {
        _readKeyboard();
      }
      _focusChanged();
      final status = _pendingStatus;
      _pendingStatus = null;
      if (status != null) _statusChanged(status);
      if (_controller.isCompleted && _keyboardHeight == 0) {
        _handoffExtent = 0;
      }
      if (_pendingComposerHeight case final height?) {
        _composerHeight = height;
      }
      _pendingComposerHeight = null;
      if (_pendingInputHeight case final height?) {
        _inputHeight = height;
        setState(() {});
      }
      _pendingInputHeight = null;
    } finally {
      _flushingTrainingUpdates = false;
    }
    _metrics.value++;
    _publishExtent();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _trainingActivity.removeListener(_trainingActivityChanged);
    widget.focusNode.removeListener(_focusChanged);
    _motion.dispose();
    _controller.dispose();
    _metrics.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_controller, _metrics]),
    child: _composer(),
    builder: (context, composer) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        composer!,
        ColoredBox(
          color: ChatDockPolishTokens.of(context).background,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRect(
                child: SizeTransition(
                  key: const ValueKey('chat-panel-transition'),
                  // Flutter 3.44's replacement for vertical axisAlignment: -1.
                  alignment: AlignmentDirectional.topStart,
                  sizeFactor: _motion,
                  child: SizedBox(
                    key: const ValueKey('chat-panel-fixed-content'),
                    height: _settling ? 0 : _panelHeight,
                    width: double.infinity,
                    child: IgnorePointer(
                      ignoring: !widget.panelOpen,
                      child: ExcludeSemantics(
                        excluding: !widget.panelOpen,
                        child: FadeTransition(
                          key: const ValueKey('chat-panel-fade'),
                          opacity: _motion,
                          child: AnimatedBuilder(
                            animation: _motion,
                            child: widget.panelOpen || !_controller.isDismissed
                                ? widget.panel
                                : const SizedBox.shrink(),
                            builder: (context, child) => Transform.translate(
                              key: const ValueKey('chat-panel-content-offset'),
                              offset: Offset(
                                0,
                                ChatDockPolishTokens.menuRise *
                                    (1 - _motion.value),
                              ),
                              child: child,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(height: math.max(0, _bottomExtent - _visiblePanel)),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _composer() => ChatMeasureSize(
    onSize: (size) {
      if (!mounted) return;
      if ((size.height - _composerHeight).abs() < .01) return;
      if (_trainingActivity.active) {
        _pendingComposerHeight = size.height;
        _trainingDirty = true;
        return;
      }
      _composerHeight = size.height;
      _publishExtent();
    },
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          right: 0,
          bottom: ChatComposerTokens.outerPadding.bottom,
          height: _inputHeight + ChatDockPolishTokens.fadeAboveInput,
          child: IgnorePointer(
            child: DecoratedBox(
              key: const ValueKey('chat-composer-dock'),
              decoration: BoxDecoration(
                gradient: ChatDockPolishTokens.of(context).gradient,
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: ChatComposerTokens.outerPadding.bottom,
          child: ColoredBox(color: ChatDockPolishTokens.of(context).background),
        ),
        SafeArea(
          top: false,
          bottom: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              widget.suggestions,
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: withCoachChatUi(
                    context,
                    PlanFocusLabel(
                      title: widget.planFocusTitle,
                      onClear: widget.onClearPlanFocus,
                      bottomGap: 8,
                      iconBuilder: chatPlanFocusIcon,
                      clearIconBuilder: chatPlanFocusClearIcon,
                    ),
                  ),
                ),
              ),
              ChatMeasureSize(
                onSize: (size) {
                  if (!mounted) return;
                  final height =
                      size.height - ChatComposerTokens.outerPadding.vertical;
                  if ((height - _inputHeight).abs() > .5) {
                    if (_trainingActivity.active) {
                      _pendingInputHeight = height;
                      _trainingDirty = true;
                      return;
                    }
                    setState(() => _inputHeight = height);
                  }
                },
                child: widget.input,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
