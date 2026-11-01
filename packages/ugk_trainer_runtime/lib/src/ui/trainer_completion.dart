import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../result/session_result.dart';
import 'trainer_player.dart' show TrainerDrill;
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

  @override
  State<TrainerCompletion> createState() => _TrainerCompletionState();
}

class _TrainerCompletionState extends State<TrainerCompletion>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  );
  bool _started = false;
  bool _reduced = false;

  TrainerTheme get _theme => widget.theme;
  TrainerStrings get _strings => widget.strings;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = TrainerMotion.reduced(context);
    if (!_started || reduced != _reduced) {
      _reduced = reduced;
      if (reduced) {
        _animation.value = 1;
      } else if (!_started) {
        _animation.forward();
      }
      _started = true;
    }
  }

  @override
  void didUpdateWidget(TrainerCompletion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result.sessionId != widget.result.sessionId) {
      if (_reduced) {
        _animation.value = 1;
      } else {
        _animation.forward(from: 0);
      }
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
      color: _theme.cardSurface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _theme.cardBorder),
    ),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );

  Widget _statistics() => _card(
    key: const ValueKey('completion-stats'),
    child: AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        final progress = (_animation.value * 1700 / 600).clamp(0.0, 1.0);
        int roll(num value) => (value * progress).round();
        final result = widget.result;
        final reps = result.completedReps;
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _metric(
                'duration',
                _strings.durationLabel(roll(result.activeSeconds)),
                _strings.actualDuration,
              ),
              VerticalDivider(width: 1, thickness: 1, color: _theme.cardBorder),
              _metric(
                'exercises',
                '${roll(result.completedExercises)}/${result.totalExercises}',
                _strings.exercisesDone,
              ),
              VerticalDivider(width: 1, thickness: 1, color: _theme.cardBorder),
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
              26,
              FontWeight.w700,
            ).copyWith(fontFeatures: TrainerTheme.tabular),
          ),
          const SizedBox(height: 4),
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
    Widget fallback() => Center(
      child: Icon(Icons.accessibility_new, size: 24, color: _theme.muted),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox.square(
        dimension: 40,
        child: asset == null || asset.isEmpty
            ? fallback()
            : Image.asset(
                asset,
                fit: BoxFit.contain,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => fallback(),
              ),
      ),
    );
  }

  Widget _item(ItemResult item, int index) {
    final drill = widget.drillOf(item.exerciseId);
    final skipped = item.status == ItemStatus.skipped;
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
          if (index > 0) const SizedBox(height: 12),
          _item(item, index),
        ],
      ],
    ),
  );

  Widget _feelings() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(_strings.feelingPrompt, style: _text(14, FontWeight.w400)),
      const SizedBox(height: 12),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final (index, feeling) in TrainingFeeling.values.indexed) ...[
              if (index > 0) const SizedBox(width: 8),
              _feeling(feeling, index),
            ],
          ],
        ),
      ),
    ],
  );

  Widget _feeling(TrainingFeeling feeling, int index) {
    final selected = widget.feeling == feeling;
    final label = index < _strings.feelingLabels.length
        ? _strings.feelingLabels[index]
        : TrainerStrings.en().feelingLabels[index];
    return Semantics(
      selected: selected,
      child: SizedBox(
        height: 34,
        child: OutlinedButton(
          key: ValueKey('completion-feeling-${feeling.name}'),
          onPressed: () => widget.onFeelingChanged(selected ? null : feeling),
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

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final title = _strings.doneFull;
    final subtitle = result.planTitle.isNotEmpty
        ? result.planTitle
        : result.items.length == 1
        ? widget.drillOf(result.items.single.exerciseId)?.name ?? ''
        : '';
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
