import 'dart:async';

import 'package:flutter/material.dart';
import 'models.dart';
import 'theme.dart';
import 'primitives.dart';

typedef CoachOptionBuilder =
    Widget Function(
      String messageId,
      int index,
      String label,
      bool chosen,
      bool dimmed,
      bool enabled,
      VoidCallback onTap,
    );

/// Bubble shape: round corners, a small one on the speaker's side.
BorderRadius bubbleRadius({required bool user}) => BorderRadius.only(
  topLeft: const Radius.circular(CoachRadius.lg),
  topRight: const Radius.circular(CoachRadius.lg),
  bottomLeft: Radius.circular(user ? CoachRadius.lg : CoachRadius.tail),
  bottomRight: Radius.circular(user ? CoachRadius.tail : CoachRadius.lg),
);

/// An opaque content bubble. Speaker colours and its quiet edge come from the
/// injected palette; elevated controls use the separate raised surface.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.user, required this.child, this.padding});
  final bool user;
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color:
          (user
                  ? CoachUiTheme.of(context).colors.userBubble
                  : CoachUiTheme.of(context).colors.assistantBubble)
              .withValues(alpha: 1),
      borderRadius: bubbleRadius(user: user),
      border: Border.all(color: CoachUiTheme.of(context).colors.outline),
      boxShadow: [
        BoxShadow(
          color: CoachUiTheme.of(context).colors.shadow,
          blurRadius: 4,
          offset: const Offset(0, 2),
        ),
      ],
    ),
    child: Padding(
      padding:
          padding ??
          const EdgeInsets.fromLTRB(CoachSpace.x4, 10, CoachSpace.x4, 11),
      child: child,
    ),
  );
}

class CoachMessageBubble extends StatelessWidget {
  const CoachMessageBubble({
    super.key,
    required this.message,
    required this.optionsActive,
    required this.onOption,
    this.optionBuilder,
  });

  final CoachBubbleData message;
  final bool optionsActive;
  final void Function(int index) onOption;
  final CoachOptionBuilder? optionBuilder;

  @override
  Widget build(BuildContext context) {
    final user = message.isUser;
    final maxW = MediaQuery.sizeOf(context).width * (user ? .78 : .86);
    final bubble = _Bubble(
      user: user,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (message.caption case final caption?) ...[
            Text(
              caption,
              style: CoachUiTheme.of(context).typography.caption.copyWith(
                color: CoachUiTheme.of(context).colors.muted,
                letterSpacing: .6,
                fontFeatures: CoachUiTypography.tabular,
              ),
            ),
            const SizedBox(height: 2),
          ],
          if (message.text.isNotEmpty)
            Text(
              message.text,
              style: CoachUiTheme.of(context).typography.body.copyWith(
                color: CoachUiTheme.of(context).colors.text,
              ),
            ),
          if (message.options.isNotEmpty) ...[
            const SizedBox(height: CoachSpace.x3),
            Wrap(
              spacing: CoachSpace.x2,
              runSpacing: CoachSpace.x2,
              children: [
                for (var i = 0; i < message.options.length; i++)
                  optionBuilder?.call(
                        message.id,
                        i,
                        message.options[i],
                        message.chosen == i,
                        message.chosen != null && message.chosen != i,
                        optionsActive,
                        () => onOption(i),
                      ) ??
                      CoachOptionPill(
                        key: ValueKey('option-${message.id}-$i'),
                        label: message.options[i],
                        chosen: message.chosen == i,
                        dimmed: message.chosen != null && message.chosen != i,
                        enabled: optionsActive,
                        onTap: () => onOption(i),
                      ),
              ],
            ),
            const SizedBox(height: 3),
          ],
        ],
      ),
    );
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW),
        child: bubble,
      ),
    );
  }
}

/// A choice inside an assistant bubble. Chosen: accent tint + accent text
/// (the selected segment); once answered the others go faint.
class CoachOptionPill extends StatelessWidget {
  const CoachOptionPill({
    super.key,
    required this.label,
    required this.onTap,
    this.chosen = false,
    this.dimmed = false,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onTap;
  final bool chosen;
  final bool dimmed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final fg = chosen
        ? CoachUiTheme.of(context).colors.accentText
        : dimmed
        ? CoachUiTheme.of(context).colors.faint
        : CoachUiTheme.of(context).colors.text;
    final bg = chosen
        ? CoachUiTheme.of(context).colors.accentSoft
        : CoachUiTheme.of(context).colors.isDark
        ? CoachUiTheme.of(context).colors.surfaceRaised
        : CoachUiTheme.of(context).colors.surface;
    // Preserve the established roomy dark control and compact answered rows.
    final idle =
        CoachUiTheme.of(context).colors.isDark && enabled && !chosen && !dimmed;
    return CoachPressable(
      semanticLabel: label,
      onTap: enabled ? onTap : null,
      haptic: CoachHaptic.selection,
      child: idle
          ? CoachControlFace(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 14,
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                ),
              ),
            )
          : Container(
              constraints: const BoxConstraints(minHeight: 36),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: ShapeDecoration(
                color: bg.withValues(alpha: 1),
                shadows: [
                  BoxShadow(
                    color: CoachUiTheme.of(context).colors.shadow,
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
                shape: StadiumBorder(
                  side: BorderSide(
                    color: CoachUiTheme.of(context).colors.outline,
                    strokeAlign: BorderSide.strokeAlignOutside,
                  ),
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 14,
                  height: 1.35,
                  fontWeight: chosen ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
    );
  }
}

/// The opening line without a bubble (§2.1): a greeting in large type
/// floating in the sky, the invitation under it in muted body text. It is
/// still a message: later ones push it up.
class CoachGreetingBlock extends StatelessWidget {
  const CoachGreetingBlock({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final i = text.indexOf('\n');
    final head = i < 0 ? text : text.substring(0, i);
    final rest = i < 0 ? '' : text.substring(i + 1);
    return Padding(
      key: const ValueKey('greeting'),
      padding: const EdgeInsets.fromLTRB(
        CoachSpace.x2,
        CoachSpace.x6,
        CoachSpace.x2,
        CoachSpace.x1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            head,
            style: CoachUiTheme.of(context).typography.greeting.copyWith(
              color: CoachUiTheme.of(context).colors.text,
            ),
          ),
          if (rest.isNotEmpty) ...[
            const SizedBox(height: CoachSpace.x1),
            Text(
              rest,
              style: CoachUiTheme.of(context).typography.body.copyWith(
                color: CoachUiTheme.of(context).colors.muted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A localized time label between sittings.
class CoachTimeMark extends StatelessWidget {
  const CoachTimeMark(this.at, {super.key, required this.now});
  final DateTime at;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final label = CoachUiTheme.of(context).strings.timeLabel(at, now);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: CoachSpace.x3),
      child: Center(
        child: Text(
          label,
          style: CoachUiTheme.of(context).typography.caption.copyWith(
            color: CoachUiTheme.of(context).colors.muted,
            letterSpacing: .4,
          ),
        ),
      ),
    );
  }
}

/// The visible phase of a coach turn. Phases are driven by real agent events;
/// a turn may skip phases when the model does not need the corresponding tool.
enum CoachTypingPhase { understanding, searching, planning, checking }

/// Presentation-only snapshot of an agent event. To keep this package
/// independent of ugk_coach, hosts map AgentEvent.kind.name and path here.
@immutable
class CoachTypingEvent {
  const CoachTypingEvent(this.kind, {this.path});
  final String kind;
  final String? path;
}

/// A compact progress indicator. [events] should be a stable stream for the
/// current turn; the host maps its CoachAgent events to [CoachTypingEvent].
/// A host may override the rotating phrases for any phase in [messages].
class CoachTypingBubble extends StatefulWidget {
  const CoachTypingBubble({
    super.key,
    this.onCancel,
    this.progressLabel,
    this.events,
    this.messages = const {},
    this.rotationInterval = const Duration(seconds: 6),
  });
  final VoidCallback? onCancel;

  /// Existing host-supplied label, if any, takes precedence over phase copy.
  final String? progressLabel;
  final Stream<CoachTypingEvent>? events;
  final Map<CoachTypingPhase, List<String>> messages;
  final Duration rotationInterval;
  @override
  State<CoachTypingBubble> createState() => _CoachTypingBubbleState();
}

class _CoachTypingBubbleState extends State<CoachTypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  static const _defaults = <CoachTypingPhase, List<String>>{
    CoachTypingPhase.understanding: ['正在理解需求', '整理你的训练目标'],
    CoachTypingPhase.searching: ['正在查动作库', '挑选合适的动作'],
    CoachTypingPhase.planning: ['正在编排计划', '安排动作和节奏'],
    CoachTypingPhase.checking: ['正在核对计划', '检查动作和训练安排'],
  };
  CoachTypingPhase _phase = CoachTypingPhase.understanding;
  bool _sawPlanContext = false;
  int _phrase = 0;
  StreamSubscription<CoachTypingEvent>? _subscription;
  Timer? _rotation;

  @override
  void initState() {
    super.initState();
    _listen();
    _scheduleRotation();
  }

  void _listen() {
    _subscription = widget.events?.listen(
      _onEvent,
      onError: (Object _, StackTrace _) {},
    );
  }

  void _onEvent(CoachTypingEvent event) {
    final path = event.path ?? '';
    CoachTypingPhase? next;
    if ((event.kind == 'reading' || event.kind == 'listing') &&
        (path == 'action-library' || path.startsWith('action-library/'))) {
      next = CoachTypingPhase.searching;
    } else if ((event.kind == 'reading' || event.kind == 'listing') &&
        (path == 'plan-training' || path.startsWith('plan-training/'))) {
      _sawPlanContext = true;
    } else if (event.kind == 'checking') {
      next = CoachTypingPhase.checking;
    } else if (event.kind == 'thinking' &&
        (_sawPlanContext ||
            _phase == CoachTypingPhase.searching ||
            _phase == CoachTypingPhase.checking)) {
      next = CoachTypingPhase.planning;
    }
    if (next != null && next != _phase && mounted) {
      setState(() {
        _phase = next!;
        _phrase = 0;
      });
      _scheduleRotation();
    }
  }

  List<String> get _phrases {
    final configured = widget.messages[_phase];
    return configured == null || configured.isEmpty
        ? _defaults[_phase]!
        : configured;
  }

  void _scheduleRotation() {
    _rotation?.cancel();
    if (widget.progressLabel != null ||
        _phrases.length < 2 ||
        widget.rotationInterval <= Duration.zero) {
      return;
    }
    _rotation = Timer.periodic(widget.rotationInterval, (_) {
      if (mounted) setState(() => _phrase = (_phrase + 1) % _phrases.length);
    });
  }

  @override
  void didUpdateWidget(covariant CoachTypingBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.events != widget.events) {
      _subscription?.cancel();
      _phase = CoachTypingPhase.understanding;
      _sawPlanContext = false;
      _phrase = 0;
      _listen();
    }
    if (oldWidget.events != widget.events ||
        oldWidget.messages != widget.messages ||
        oldWidget.progressLabel != widget.progressLabel ||
        oldWidget.rotationInterval != widget.rotationInterval) {
      _phrase = 0;
      _scheduleRotation();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _c.stop();
      _c.value = .5;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _rotation?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = CoachUiTheme.of(context);
    final label = widget.progressLabel ?? _phrases[_phrase % _phrases.length];
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        key: const ValueKey('typing-bubble-surface'),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .86,
        ),
        child: _Bubble(
          user: false,
          padding: const EdgeInsets.only(left: 14, right: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: _c,
                builder: (_, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < 3; i++) ...[
                      if (i > 0) const SizedBox(width: 3),
                      Opacity(
                        opacity: .35 + .65 * _pulse((_c.value - i * .18) % 1),
                        child: SizedBox.square(
                          dimension: 5,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: style.colors.accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: AnimatedSwitcher(
                  duration: reduce ? Duration.zero : CoachMotion.fast,
                  child: Text(
                    label,
                    key: ValueKey(label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style.typography.body.copyWith(
                      color: style.colors.text,
                    ),
                  ),
                ),
              ),
              if (widget.onCancel != null)
                IconButton(
                  key: const ValueKey('chat-cancel'),
                  tooltip: style.strings.cancel,
                  onPressed: widget.onCancel,
                  icon: Icon(
                    Icons.close_rounded,
                    size: 17,
                    color: style.colors.muted,
                  ),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  padding: EdgeInsets.zero,
                )
              else
                const SizedBox(width: 10, height: 44),
            ],
          ),
        ),
      ),
    );
  }

  static double _pulse(double t) => t < .5 ? t * 2 : (1 - t) * 2;
}
