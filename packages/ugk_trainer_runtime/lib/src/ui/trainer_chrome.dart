part of 'trainer_player.dart';

/// The media and floor deliberately have no entry in this list.
enum _TrainerChromeLayer {
  info('info', 0, 200 / 280, -12),
  hud('hud', 20 / 280, 220 / 280, -8),
  cues('cues', 40 / 280, 240 / 280, 16),
  transportDigits('transport-digits', 60 / 280, 260 / 280, 16),
  transportControls('transport-controls', 60 / 280, 260 / 280, 16),
  previous('previous', 60 / 280, 260 / 280, 16),
  next('next', 60 / 280, 260 / 280, 16),
  pause('pause', 60 / 280, 1, 0),
  done('done', 0, 1, 12);

  const _TrainerChromeLayer(this.id, this.begin, this.end, this.offset);
  final String id;
  final double begin;
  final double end;
  final double offset;
}

extension _TrainerChrome on _TrainerPlayerState {
  Widget _chromeDone(Widget child) =>
      _exitSaveFailed ? child : _chromeLayer(child, _TrainerChromeLayer.done);

  Widget _chromeLayer(Widget child, _TrainerChromeLayer layer) {
    final animation = widget.chromeAnimation;
    // Keep the original tree for existing callers and for demonstration mode.
    if (animation == null || _preview) return child;
    final reduced = TrainerMotion.reduced(context);
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final value = animation.value.clamp(0.0, 1.0).toDouble();
        final interval = Interval(layer.begin, layer.end).transform(value);
        final reverse = animation.status == AnimationStatus.reverse;
        final curve = reverse ? Curves.easeInCubic : Curves.easeOutCubic;
        final opacity = curve.transform(interval).clamp(0.0, 1.0).toDouble();
        Widget visual = child!;
        if (!reduced) {
          if (layer == _TrainerChromeLayer.pause) {
            final scaleCurve = reverse
                ? Curves.easeInCubic
                : Curves.easeOutBack;
            visual = Transform.scale(
              scale: .85 + .15 * scaleCurve.transform(interval),
              child: visual,
            );
          } else {
            visual = Transform.translate(
              offset: Offset(0, layer.offset * (1 - opacity)),
              child: visual,
            );
          }
        }
        return IgnorePointer(
          key: ValueKey('trainer-chrome-${layer.id}'),
          ignoring: value < 1,
          child: ExcludeSemantics(
            excluding: value < 1,
            child: Opacity(opacity: opacity, child: visual),
          ),
        );
      },
    );
  }
}
