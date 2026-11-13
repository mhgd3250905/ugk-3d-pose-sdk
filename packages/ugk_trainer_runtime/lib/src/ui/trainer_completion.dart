import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../result/session_result.dart';
import 'trainer_player.dart' show TrainerDrill;
import 'trainer_player_motion.dart';
import 'trainer_player_v1_dock.dart' show TrainerV1FeedbackButton;
import 'trainer_stage.dart' show TrainerResultStage;
import 'trainer_strings.dart';
import 'trainer_theme.dart';

/// Presentation of a recorded session. Values are never inferred from the
/// planned dose; the player owns persistence, replay and optional feedback.
class TrainerCompletion extends StatefulWidget {
  const TrainerCompletion({
    super.key,
    required this.theme,
    required this.strings,
    required this.result,
    required this.drillOf,
    required this.feeling,
    required this.onFeelingChanged,
    this.onFinish,
    this.onReplay,
    this.feedback,
    this.error,
    this.streakDays,
    this.trainedAreas = const [],
    this.entryDockTop,
  });

  final TrainerTheme theme;
  final TrainerStrings strings;
  final SessionResult result;
  final TrainerDrill? Function(String exerciseId) drillOf;
  final TrainingFeeling? feeling;
  final ValueChanged<TrainingFeeling?> onFeelingChanged;
  final VoidCallback? onFinish;
  final VoidCallback? onReplay;
  final Widget? feedback;
  final Widget? error;
  final int? streakDays;
  final List<String> trainedAreas;

  /// Position of the previous dock top in the completion page's coordinates.
  final double? entryDockTop;

  @override
  State<TrainerCompletion> createState() => _TrainerCompletionState();
}

class _TrainerCompletionState extends State<TrainerCompletion>
    with SingleTickerProviderStateMixin {
  static const _legacyDuration = Duration(milliseconds: 1700);
  static const _heroHeight = 300.0;
  static const _checkDelay = 120;
  static const _titleDelay = 200;
  static const _statsDelay = 260;

  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: _legacyDuration,
    animationBehavior: AnimationBehavior.preserve,
  );
  late final _badgeSpring = SpringSimulation(PlayerMotion.spring, .6, 1, 0);
  bool _started = false;
  bool _reduced = false;

  TrainerTheme get _theme => widget.theme;
  TrainerStrings get _strings => widget.strings;

  int get _finishDelay => _statsDelay + PlayerMotion.count.inMilliseconds;
  Duration get _durationV1 => _reduced
      ? PlayerMotion.reducedFade
      : PlayerMotion.emphasis +
            Duration(milliseconds: _finishDelay) +
            PlayerMotion.finishGlow;
  double get _entryMs =>
      (_animation.value * _durationV1.inMicroseconds).round() / 1000;
  double get _contentMs => _entryMs - PlayerMotion.emphasis.inMilliseconds;

  double _portion(double elapsed, int delay, int duration) =>
      ((elapsed - delay) / duration).clamp(0.0, 1.0);

  void _beginEntry() {
    _animation.duration = _theme.usePlayerV1 ? _durationV1 : _legacyDuration;
    if (_reduced && !_theme.usePlayerV1) {
      _animation.value = 1;
    } else {
      _animation.forward(from: 0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = TrainerMotion.reduced(context);
    if (!_started) {
      _reduced = reduced;
      _beginEntry();
      _started = true;
    } else if (reduced != _reduced) {
      _reduced = reduced;
      if (reduced || _theme.usePlayerV1) _animation.value = 1;
    }
  }

  @override
  void didUpdateWidget(TrainerCompletion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result.sessionId != widget.result.sessionId ||
        oldWidget.theme.usePlayerV1 != _theme.usePlayerV1) {
      _beginEntry();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  TextStyle _text(double size, FontWeight weight, {Color? color}) => TextStyle(
    fontFamily: _theme.fontFamily,
    fontSize: size,
    fontWeight: weight,
    height: 1.35,
    color: color ?? _theme.text,
  );

  Widget _card({required Key key, required Widget child}) => DecoratedBox(
    key: key,
    decoration: BoxDecoration(
      color: _theme.usePlayerV1 ? _theme.card : _theme.cardSurface,
      borderRadius: BorderRadius.circular(20),
      border: _theme.usePlayerV1 ? null : Border.all(color: _theme.cardBorder),
    ),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );

  String _duration(int seconds) {
    if (!_theme.usePlayerV1) return _strings.durationLabel(seconds);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Widget _statistics() => _card(
    key: const ValueKey('completion-stats'),
    child: AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        final progress = !_theme.usePlayerV1
            ? (_animation.value * 1700 / 600).clamp(0.0, 1.0)
            : _reduced
            ? 1.0
            : PlayerMotion.enter.transform(
                _portion(
                  _contentMs,
                  _statsDelay,
                  PlayerMotion.count.inMilliseconds,
                ),
              );
        int roll(num value) => (value * progress).round();
        final result = widget.result;
        final reps = result.completedReps;
        final dividerColor = _theme.usePlayerV1
            ? _theme.track
            : _theme.cardBorder;
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _metric(
                'duration',
                _duration(roll(result.activeSeconds)),
                _strings.actualDuration,
              ),
              VerticalDivider(width: 1, thickness: 1, color: dividerColor),
              _metric(
                'exercises',
                '${roll(result.completedExercises)}/${result.totalExercises}',
                _strings.exercisesDone,
              ),
              VerticalDivider(width: 1, thickness: 1, color: dividerColor),
              if (_theme.usePlayerV1)
                _metric(
                  'streak',
                  widget.streakDays == null
                      ? '—'
                      : '${roll(widget.streakDays!)}',
                  _strings.streak,
                )
              else
                _metric(
                  'dose',
                  reps == null
                      ? _strings.durationLabel(roll(result.workSeconds))
                      : '${roll(reps)}',
                  reps == null ? _strings.totalWorkTime : _strings.totalReps,
                ),
            ],
          ),
        );
      },
    ),
  );

  Widget _metric(String id, String value, String label) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            key: ValueKey('completion-$id-value'),
            textAlign: TextAlign.center,
            style: _text(
              _theme.usePlayerV1 ? 22 : 26,
              FontWeight.w700,
            ).copyWith(fontFeatures: TrainerTheme.tabular),
          ),
          const SizedBox(height: 4),
          if (_theme.usePlayerV1)
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style: _text(12, FontWeight.w400, color: _theme.sub),
              ),
            )
          else
            Text(
              label,
              textAlign: TextAlign.center,
              style: _text(12, FontWeight.w400, color: _theme.muted),
            ),
        ],
      ),
    ),
  );

  Widget _thumbnail(TrainerDrill? drill) {
    final asset =
        drill?.thumbnailAsset ?? drill?.media?.posterFor(light: !_theme.isDark);
    final darkThumbnail = _theme.usePlayerV1 && _theme.isDark;
    Widget fallback() => Center(
      child: Icon(Icons.accessibility_new, size: 24, color: _theme.muted),
    );
    final thumbnail = SizedBox.square(
      dimension: 40,
      child: asset == null || asset.isEmpty
          ? fallback()
          : Image.asset(
              asset,
              fit: BoxFit.contain,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => fallback(),
              frameBuilder: darkThumbnail
                  ? (_, image, _, _) => ColorFiltered(
                      colorFilter: const ColorFilter.matrix([
                        1.15,
                        0,
                        0,
                        0,
                        0,
                        0,
                        1.15,
                        0,
                        0,
                        0,
                        0,
                        0,
                        1.15,
                        0,
                        0,
                        0,
                        0,
                        0,
                        1,
                        0,
                      ]),
                      child: image,
                    )
                  : null,
            ),
    );
    if (_theme.usePlayerV1) {
      return ClipOval(
        child: ColoredBox(
          color: darkThumbnail ? const Color(0xFF3A3D46) : _theme.ctrl,
          child: thumbnail,
        ),
      );
    }
    return ClipRRect(borderRadius: BorderRadius.circular(10), child: thumbnail);
  }

  Widget _item(ItemResult item, int index) {
    final drill = widget.drillOf(item.exerciseId);
    final skipped = item.status == ItemStatus.skipped;
    if (_theme.usePlayerV1) {
      return Opacity(
        key: ValueKey('completion-item-$index'),
        opacity: skipped ? .5 : 1,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              _thumbnail(drill),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  drill?.name ?? item.exerciseId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _text(15, FontWeight.w600),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                skipped
                    ? _strings.skipped
                    : _duration(item.activeSeconds.round()),
                textAlign: TextAlign.end,
                style: _text(13, FontWeight.w400, color: _theme.sub),
              ),
              if (item.status == ItemStatus.completed) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.check_rounded,
                  key: ValueKey('completion-item-check-$index'),
                  size: 20,
                  color: _theme.good,
                ),
              ],
            ],
          ),
        ),
      );
    }
    final amount = item.completedReps == null
        ? _strings.durationLabel(item.activeSeconds.round())
        : _strings.dose(
            reps: true,
            amount: item.completedReps!,
            perSide: false,
          );
    return Opacity(
      key: ValueKey('completion-item-$index'),
      opacity: skipped ? .5 : 1,
      child: Row(
        children: [
          _thumbnail(drill),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              drill?.name ?? item.exerciseId,
              style: _text(15, FontWeight.w400),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              skipped ? _strings.skipped : amount,
              textAlign: TextAlign.end,
              style: _text(13, FontWeight.w400, color: _theme.muted),
            ),
          ),
          if (item.status == ItemStatus.completed) ...[
            const SizedBox(width: 8),
            Icon(
              Icons.check_rounded,
              key: ValueKey('completion-item-check-$index'),
              size: 20,
              color: _theme.accent,
            ),
          ],
        ],
      ),
    );
  }

  Widget _items() => _card(
    key: const ValueKey('completion-items'),
    child: Column(
      children: [
        for (final (index, item) in widget.result.items.indexed) ...[
          if (index > 0 && !_theme.usePlayerV1) const SizedBox(height: 12),
          _item(item, index),
        ],
      ],
    ),
  );

  Widget _feelings() {
    final v1 = _theme.usePlayerV1;
    final buttons = Row(
      children: [
        for (final (index, feeling) in TrainingFeeling.values.indexed) ...[
          if (index > 0) const SizedBox(width: 8),
          if (v1)
            Expanded(child: _feeling(feeling, index))
          else
            _feeling(feeling, index),
        ],
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _strings.feelingPrompt,
          style: v1 ? _text(16, FontWeight.w700) : _text(14, FontWeight.w400),
        ),
        SizedBox(height: v1 ? 14 : 12),
        if (v1)
          buttons
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: buttons,
          ),
      ],
    );
  }

  Widget _feeling(TrainingFeeling feeling, int index) {
    final selected = widget.feeling == feeling;
    final label = index < _strings.feelingLabels.length
        ? _strings.feelingLabels[index]
        : TrainerStrings.en().feelingLabels[index];
    final key = ValueKey('completion-feeling-${feeling.name}');
    void select() => widget.onFeelingChanged(selected ? null : feeling);
    if (_theme.usePlayerV1) {
      final (color, background) = switch (feeling) {
        TrainingFeeling.easy ||
        TrainingFeeling.justRight => (_theme.good, _theme.goodBg),
        TrainingFeeling.tired => (_theme.caution, _theme.cautionBg),
        TrainingFeeling.uncomfortable => (_theme.danger, _theme.dangerBg),
      };
      return TrainerV1FeedbackButton(
        key: key,
        height: 44,
        theme: _theme,
        label: label,
        color: color,
        background: background,
        selected: selected,
        onPressed: select,
      );
    }
    return Semantics(
      selected: selected,
      child: SizedBox(
        height: 34,
        child: OutlinedButton(
          key: key,
          onPressed: select,
          style: OutlinedButton.styleFrom(
            backgroundColor: selected ? _theme.accent : _theme.cardSurface,
            foregroundColor: selected ? _theme.primaryForeground : _theme.text,
            side: BorderSide(
              color: selected ? _theme.accent : _theme.cardBorder,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(17),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            minimumSize: const Size(0, 34),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: _text(14, FontWeight.w400),
          ),
          child: Text(label),
        ),
      ),
    );
  }

  Widget _hero(
    BuildContext context,
    String title,
    String subtitle,
  ) => DecoratedBox(
    key: const ValueKey('completion-hero'),
    decoration: _heroDecoration,
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        TrainerSpace.gutter,
        math.max(20, MediaQuery.paddingOf(context).top + 12),
        TrainerSpace.gutter,
        68,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Transform.scale(
            scale: _badgeScale,
            child: SizedBox.square(
              key: const ValueKey('completion-badge'),
              dimension: 72,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
                child: Center(
                  child: _reduced
                      ? Icon(
                          Icons.check_rounded,
                          size: 42,
                          color: _theme.accent,
                        )
                      : CustomPaint(
                          key: const ValueKey('completion-check-draw'),
                          size: const Size.square(42),
                          painter: _CompletionCheck(
                            PlayerMotion.enter.transform(
                              _portion(
                                _contentMs,
                                _checkDelay,
                                PlayerMotion.checkDraw.inMilliseconds,
                              ),
                            ),
                            _theme.accent,
                          ),
                        ),
                ),
              ),
            ),
          ),
          const SizedBox(height: TrainerSpace.x4),
          Flexible(
            child: _enterContent(
              delay: _titleDelay,
              offset: PlayerMotion.normal,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    flex: 2,
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: _text(26, FontWeight.w700, color: Colors.white),
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: TrainerSpace.x1),
                    Flexible(
                      child: Text(
                        subtitle,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: _text(13, FontWeight.w400, color: Colors.white),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  BoxDecoration get _heroDecoration => BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [_theme.heroTop, _theme.heroBottom],
    ),
    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
  );

  double get _badgeScale {
    if (_reduced) return 1;
    final elapsed = math.max(0.0, _contentMs / 1000);
    return _badgeSpring.isDone(elapsed) ? 1 : _badgeSpring.x(elapsed);
  }

  Widget _enterContent({
    required Widget child,
    required int delay,
    Duration duration = PlayerMotion.medium,
    double offset = 0,
  }) {
    if (_reduced) return child;
    final progress = PlayerMotion.enter.transform(
      _portion(_contentMs, delay, duration.inMilliseconds),
    );
    return IgnorePointer(
      ignoring: progress == 0,
      child: ExcludeSemantics(
        excluding: progress == 0,
        child: Opacity(
          opacity: progress,
          child: Transform.translate(
            offset: Offset(0, offset * (1 - progress)),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _feedbackCard() => _card(
    key: const ValueKey('completion-feedback'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _feelings(),
        if (widget.feedback case final feedback?) ...[
          const SizedBox(height: TrainerSpace.x3),
          feedback,
        ],
      ],
    ),
  );

  Widget _trainedAreas() => _card(
    key: const ValueKey('completion-trained-areas'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_strings.trainedAreasLabel, style: _text(14, FontWeight.w600)),
        const SizedBox(height: TrainerSpace.x2),
        Wrap(
          spacing: TrainerSpace.x2,
          runSpacing: TrainerSpace.x2,
          children: [
            for (final area in widget.trainedAreas)
              DecoratedBox(
                decoration: ShapeDecoration(
                  color: _theme.tint,
                  shape: const StadiumBorder(),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: TrainerSpace.x3,
                    vertical: 6,
                  ),
                  child: Text(
                    area,
                    style: _text(13, FontWeight.w500, color: _theme.accentText),
                  ),
                ),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _v1Footer() {
    const radius = BorderRadius.all(Radius.circular(26));
    final pulse = _portion(
      _contentMs,
      _finishDelay,
      PlayerMotion.finishGlow.inMilliseconds,
    );
    final glow = _reduced || pulse == 1 ? 0.0 : .35 * math.sin(math.pi * pulse);
    return SafeArea(
      key: const ValueKey('completion-footer'),
      top: false,
      minimum: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: double.infinity,
            height: 52,
            child: DecoratedBox(
              key: const ValueKey('completion-finish-glow'),
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: [
                  if (widget.onFinish != null && glow > 0)
                    BoxShadow(
                      color: _theme.glow.withValues(alpha: glow),
                      offset: const Offset(0, 6),
                      blurRadius: 16,
                    ),
                ],
              ),
              child: FilledButton(
                key: const ValueKey('finish'),
                onPressed: widget.onFinish,
                style: FilledButton.styleFrom(
                  backgroundColor: _theme.accent,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: _theme.tint,
                  disabledForegroundColor: _theme.sub,
                  shape: const RoundedRectangleBorder(borderRadius: radius),
                  textStyle: _text(17, FontWeight.w700),
                ),
                child: Text(_strings.finish),
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('completion-replay'),
            onPressed: widget.onReplay,
            style: TextButton.styleFrom(
              foregroundColor: _theme.sub,
              disabledForegroundColor: _theme.sub,
              textStyle: _text(14, FontWeight.w400),
            ),
            child: Text(_strings.replay),
          ),
        ],
      ),
    );
  }

  Widget _v1Content(BuildContext context, String title, String subtitle) {
    const fadeHeight = 24.0;
    final background = _theme.background.withValues(alpha: 1);
    final cards = [
      _feedbackCard(),
      if (widget.trainedAreas.isNotEmpty) _trainedAreas(),
      if (widget.result.items.length > 1) _items(),
      ?widget.error,
    ];
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              SingleChildScrollView(
                key: const ValueKey('completion-scroll'),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: _heroHeight),
                  child: Stack(
                    children: [
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: _heroHeight,
                        child: _hero(context, title, subtitle),
                      ),
                      Padding(
                        // The footer occupies its own measured height. At
                        // the end of the scroll, this gap clears the fade.
                        padding: const EdgeInsets.fromLTRB(
                          20,
                          244,
                          20,
                          fadeHeight,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _enterContent(
                              delay: _statsDelay,
                              duration: PlayerMotion.slow,
                              offset: PlayerMotion.large,
                              child: _statistics(),
                            ),
                            for (final (index, card) in cards.indexed) ...[
                              const SizedBox(height: TrainerSpace.x4),
                              _enterContent(
                                delay:
                                    _statsDelay +
                                    (index + 1) *
                                        PlayerMotion.stagger.inMilliseconds,
                                child: card,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: fadeHeight,
                child: IgnorePointer(
                  child: DecoratedBox(
                    key: const ValueKey('completion-footer-fade'),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [background.withValues(alpha: 0), background],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        _enterContent(delay: _finishDelay, child: _v1Footer()),
      ],
    );
  }

  Widget _v1(BuildContext context, String title, String subtitle) =>
      TrainerResultStage(
        theme: _theme,
        child: AnimatedBuilder(
          animation: _animation,
          builder: (context, _) {
            final content = _v1Content(context, title, subtitle);
            if (_reduced) {
              final visible = _animation.value > 0;
              return IgnorePointer(
                ignoring: !visible,
                child: ExcludeSemantics(
                  excluding: !visible,
                  child: Opacity(opacity: _animation.value, child: content),
                ),
              );
            }
            final expansion = PlayerMotion.morph.transform(
              _portion(_entryMs, 0, PlayerMotion.emphasis.inMilliseconds),
            );
            return LayoutBuilder(
              builder: (context, box) {
                final dockTop = (widget.entryDockTop ?? box.maxHeight - 172)
                    .clamp(0.0, box.maxHeight);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    IgnorePointer(
                      ignoring: expansion < 1,
                      child: ExcludeSemantics(
                        excluding: expansion < 1,
                        child: Opacity(
                          opacity: expansion < 1 ? 0 : 1,
                          child: content,
                        ),
                      ),
                    ),
                    if (expansion < 1)
                      Positioned(
                        top: dockTop * (1 - expansion),
                        left: 0,
                        right: 0,
                        height: _heroHeight * expansion,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            key: const ValueKey('completion-hero-entry'),
                            decoration: _heroDecoration,
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final title = _strings.doneFull;
    final subtitle = result.planTitle.isNotEmpty
        ? result.planTitle
        : result.items.length == 1
        ? widget.drillOf(result.items.single.exerciseId)?.name ?? ''
        : '';
    if (_theme.usePlayerV1) {
      return _v1(context, _strings.completionTitle ?? title, subtitle);
    }
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey('completion-scroll'),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 144,
                    child: RepaintBoundary(
                      child: CustomPaint(
                        key: const ValueKey('completion-celebration'),
                        painter: _CompletionPainter(
                          animation: _animation,
                          theme: _theme,
                          reduced: _reduced,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: _text(24, FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: _text(14, FontWeight.w400, color: _theme.muted),
                  ),
                  const SizedBox(height: 24),
                  _statistics(),
                  if (result.items.length > 1) ...[
                    const SizedBox(height: 16),
                    _items(),
                  ],
                  const SizedBox(height: 24),
                  _feelings(),
                  if (widget.feedback case final feedback?) ...[
                    const SizedBox(height: 16),
                    feedback,
                  ],
                  if (widget.error case final error?) ...[
                    const SizedBox(height: 12),
                    error,
                  ],
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                key: const ValueKey('finish'),
                onPressed: widget.onFinish,
                style: FilledButton.styleFrom(
                  backgroundColor: _theme.accent,
                  foregroundColor: _theme.primaryForeground,
                  disabledBackgroundColor: _theme.accentSubtle,
                  disabledForegroundColor: _theme.primaryForeground,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                  textStyle: _text(16, FontWeight.w600),
                ),
                child: Text(_strings.finish),
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('completion-replay'),
            onPressed: widget.onReplay,
            style: TextButton.styleFrom(
              foregroundColor: _theme.accent,
              disabledForegroundColor: _theme.muted,
              textStyle: _text(14, FontWeight.w400),
            ),
            child: Text(_strings.replay),
          ),
        ],
      ),
    );
  }
}

class _CompletionCheck extends CustomPainter {
  const _CompletionCheck(this.progress, this.color);

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress == 0) return;
    final path = Path()
      ..moveTo(size.width * .21, size.height * .52)
      ..lineTo(size.width * .41, size.height * .7)
      ..lineTo(size.width * .79, size.height * .3);
    final metric = path.computeMetrics().single;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width / 10
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CompletionCheck oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}

/// A bounded, deterministic burst: 24 particles, no emitter and no repeat.
/// The circle completes at 500 ms; the check and burst begin together then.
class _CompletionPainter extends CustomPainter {
  _CompletionPainter({
    required this.animation,
    required this.theme,
    required this.reduced,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final TrainerTheme theme;
  final bool reduced;

  @override
  void paint(Canvas canvas, Size size) {
    final elapsed = animation.value * 1700;
    final circle = Curves.easeOut.transform((elapsed / 500).clamp(0, 1));
    final check = ((elapsed - 500) / 250).clamp(0.0, 1.0);
    final center = Offset(size.width / 2, size.height / 2);
    final stroke = Paint()
      ..color = theme.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: 42.5),
      -math.pi / 2,
      math.pi * 2 * circle,
      false,
      stroke,
    );
    if (check > 0) {
      final path = Path()
        ..moveTo(center.dx - 18, center.dy)
        ..lineTo(center.dx - 5, center.dy + 13)
        ..lineTo(center.dx + 20, center.dy - 14);
      final metric = path.computeMetrics().single;
      canvas.drawPath(metric.extractPath(0, metric.length * check), stroke);
    }
    final progress = (elapsed - 500) / 1200;
    if (reduced || progress <= 0 || progress >= 1) return;
    final seconds = progress * 1.2;
    final colors = [theme.accent, theme.accentSubtle, theme.caution];
    final opacity = 1 - progress;
    for (var i = 0; i < 24; i++) {
      final fraction = i / 23;
      final vx = (fraction - .5) * 160;
      final vy = -155 - (i % 5) * 9;
      final point =
          center + Offset(vx * seconds, vy * seconds + 165 * seconds * seconds);
      final paint = Paint()
        ..color = colors[i % colors.length].withValues(alpha: opacity);
      canvas.save();
      canvas.translate(point.dx, point.dy);
      canvas.rotate(i * .73 + seconds * (i.isEven ? 5 : -5));
      canvas.drawRect(const Rect.fromLTWH(-2, -3, 4, 6), paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_CompletionPainter oldDelegate) =>
      oldDelegate.animation != animation ||
      oldDelegate.theme != theme ||
      oldDelegate.reduced != reduced;
}
