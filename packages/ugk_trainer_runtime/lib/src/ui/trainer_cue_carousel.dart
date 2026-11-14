import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'trainer_player_motion.dart';
import 'trainer_theme.dart';

/// Cleans legacy semicolon-delimited copy without turning separate steps into
/// one paragraph. Punctuation inside a step (notably commas) is retained.
List<String> normalizeTrainerCues(Iterable<String> values) => [
  for (final value in values)
    for (final part in value.split(RegExp(r'[;；。\r\n]+')))
      if (_cleanCue(part) case final text when text.isNotEmpty) text,
];

String _cleanCue(String value) => value
    .trim()
    .replaceFirst(RegExp(r'^(?:[-•·]\s*|\d+[.、]\s*)'), '')
    .replaceAll(RegExp(r'^[\s,，;；。]+|[\s,，;；。]+$'), '')
    .trim();

/// One readable coaching step at a time, shared by demonstration and training.
///
/// During [preparing], Player V1 displays [prepCaption] and the legacy card
/// pins the first step.
/// [onExpandedChanged] lets the player pause for the half-height instruction
/// sheet and restore its previous playback state when the sheet is dismissed.
/// Cautions are supplied separately in [precautions] and never mixed into the
/// numbered instruction list. Empty copy renders no card.
class TrainerCueCarousel extends StatefulWidget {
  const TrainerCueCarousel({
    super.key,
    required this.cues,
    required this.theme,
    this.precautions = const [],
    this.preparing = false,
    this.prepCaption,
    this.onExpandedChanged,
    this.sheetTitle = '怎么做',
    this.precautionsTitle = '注意事项',
    this.semanticLabel = '动作要点',
    this.closeLabel = '收起',
    this.steps,
  });

  final List<String> cues;
  final List<String> precautions;
  final TrainerTheme theme;
  final bool preparing;

  /// The current voice subtitle for the Player V1 preparation countdown.
  final String? prepCaption;

  final ValueChanged<bool>? onExpandedChanged;
  final String sheetTitle;
  final String precautionsTitle;
  final String semanticLabel;
  final String closeLabel;

  /// Full instructions when a transient coaching message occupies the card.
  final List<String>? steps;

  @override
  State<TrainerCueCarousel> createState() => _TrainerCueCarouselState();
}

class _TrainerCueCarouselState extends State<TrainerCueCarousel> {
  static const _automaticDelay = Duration(milliseconds: 4500);
  static const _manualDelay = Duration(seconds: 8);
  static const _transition = Duration(milliseconds: 220);
  static const _playerV1CueSize = 17.0;

  Timer? _timer;
  int _index = 0;
  bool _sheetOpen = false;
  double _dragDistance = 0;
  List<_CuePage> _pages = const [];
  List<String> _layoutCues = const [];
  double? _layoutWidth;
  TextScaler? _layoutScaler;
  TextDirection? _layoutDirection;
  Locale? _layoutLocale;
  String? _layoutFont;
  bool? _layoutPlayerV1;
  bool? _layoutPrepCaption;
  double _countWidth = 0;
  List<double> _v1PageHeights = const [];

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(TrainerCueCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(widget.cues, oldWidget.cues) ||
        widget.preparing != oldWidget.preparing) {
      _index = 0;
      _schedule();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule([Duration delay = _automaticDelay]) {
    _timer?.cancel();
    if (widget.preparing || _sheetOpen || widget.cues.isEmpty) return;
    _timer = Timer(delay, () {
      if (!mounted) return;
      if (TickerMode.valuesOf(context).enabled) _move(1);
      _schedule();
    });
  }

  void _move(int delta, {bool manual = false}) {
    if (widget.preparing || _sheetOpen) return;
    if (_pages.length > 1) {
      setState(() => _index = (_index + delta) % _pages.length);
    }
    if (manual) _schedule(_manualDelay);
  }

  TextStyle _bodyStyle(double size) => TextStyle(
    inherit: false,
    fontFamily: widget.theme.fontFamily,
    fontSize: size,
    fontWeight: widget.theme.usePlayerV1 ? FontWeight.w700 : FontWeight.w500,
    height: widget.theme.usePlayerV1 ? 1.3 : 1.5,
    color: widget.theme.text,
  );

  TextPainter _measureCue(
    String text,
    double size,
    double width,
    BuildContext context, {
    bool ellipsis = false,
  }) => TextPainter(
    text: TextSpan(text: text, style: _bodyStyle(size)),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    locale: Localizations.maybeLocaleOf(context),
    maxLines: 2,
    ellipsis: ellipsis ? '…' : null,
  )..layout(maxWidth: width);

  bool _fits(String text, double size, double width, BuildContext context) {
    final painter = _measureCue(text, size, width, context);
    final fits = !painter.didExceedMaxLines && painter.width <= width;
    painter.dispose();
    return fits;
  }

  List<_CuePage> _fitPages(
    Iterable<String> cues,
    double width,
    BuildContext context,
  ) {
    final pages = <_CuePage>[];
    final playerV1 = widget.theme.usePlayerV1;
    final size = playerV1 ? _playerV1CueSize : 16.0;
    final splitSize = playerV1 ? size : 14.0;
    void add(String text) {
      if (text.isEmpty) return;
      if (_fits(text, size, width, context)) {
        pages.add(_CuePage(text, size));
        return;
      }
      if (!playerV1 && _fits(text, splitSize, width, context)) {
        pages.add(_CuePage(text, splitSize));
        return;
      }

      // Prefer a natural clause boundary. The longest fitting prefix keeps
      // adjacent short clauses together instead of making excessive slides.
      final commas = RegExp('[，,]').allMatches(text).toList();
      for (final comma in commas.reversed) {
        final prefix = _cleanCue(text.substring(0, comma.start));
        if (prefix.isNotEmpty && _fits(prefix, splitSize, width, context)) {
          add(prefix);
          add(_cleanCue(text.substring(comma.end)));
          return;
        }
      }

      // Unpunctuated or unusually long clauses must remain fully readable
      // too. Split at a word boundary when possible, otherwise at a grapheme
      // boundary (never inside an emoji or combining character).
      final characters = text.characters.toList();
      var low = 1;
      var high = characters.length;
      var count = 1;
      while (low <= high) {
        final middle = (low + high) ~/ 2;
        if (_fits(characters.take(middle).join(), splitSize, width, context)) {
          count = middle;
          low = middle + 1;
        } else {
          high = middle - 1;
        }
      }
      final candidate = characters.take(count).join();
      final lastSpace = candidate.lastIndexOf(RegExp(r'\s'));
      if (lastSpace > candidate.length ~/ 2) {
        add(candidate.substring(0, lastSpace));
        add(text.substring(lastSpace).trimLeft());
      } else {
        // The one-character fallback only applies to constraints narrower
        // than a single glyph. It still never replaces content with dots.
        pages.add(_CuePage(candidate, splitSize));
        add(characters.skip(count).join().trimLeft());
      }
    }

    for (final cue in cues) {
      add(cue);
    }
    return pages;
  }

  Future<void> _expand() async {
    if (_sheetOpen) return;
    _sheetOpen = true;
    _timer?.cancel();
    widget.onExpandedChanged?.call(true);
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: widget.theme.cardSurface,
        constraints: BoxConstraints.tightFor(
          height: MediaQuery.sizeOf(context).height * .5,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (context) => _CueSheet(
          cues: normalizeTrainerCues(widget.steps ?? widget.cues),
          precautions: normalizeTrainerCues(widget.precautions),
          theme: widget.theme,
          title: widget.sheetTitle,
          precautionsTitle: widget.precautionsTitle,
          closeLabel: widget.closeLabel,
        ),
      );
    } finally {
      _sheetOpen = false;
      if (mounted) {
        widget.onExpandedChanged?.call(false);
        _schedule();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final playerV1 = theme.usePlayerV1;
    final showPrepCaption = playerV1 && widget.preparing;
    final cues = showPrepCaption
        ? [
            if (widget.prepCaption?.trim() case final String text
                when text.isNotEmpty)
              text,
          ]
        : normalizeTrainerCues(widget.cues);
    if (cues.isEmpty) return const SizedBox.shrink();
    final reduced = TrainerMotion.reduced(context);
    final textScaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final direction = Directionality.of(context);
        final locale = Localizations.maybeLocaleOf(context);
        final stepGap = playerV1 ? 10.0 : 12.0;
        if (_layoutWidth != constraints.maxWidth ||
            _layoutScaler != textScaler ||
            _layoutDirection != direction ||
            _layoutLocale != locale ||
            _layoutFont != theme.fontFamily ||
            _layoutPlayerV1 != playerV1 ||
            _layoutPrepCaption != showPrepCaption ||
            !listEquals(_layoutCues, cues)) {
          final bodyWidth = math.max(1.0, constraints.maxWidth - 32);
          if (showPrepCaption ||
              (playerV1 &&
                  cues.length == 1 &&
                  _fits(cues.single, _playerV1CueSize, bodyWidth, context))) {
            _countWidth = 0;
            _pages = [_CuePage(cues.single, _playerV1CueSize)];
          } else {
            // Reserve the count's measured width. Another pass accounts for
            // extra digits introduced when text splits into more pages.
            var total = cues.length;
            for (var pass = 0; pass < 4; pass++) {
              final counter = TextPainter(
                text: TextSpan(
                  text: '$total/$total',
                  style: _counterStyle(theme),
                ),
                textDirection: direction,
                textScaler: textScaler,
              )..layout();
              _countWidth = playerV1
                  ? math.max(34, counter.width + 16)
                  : counter.width;
              counter.dispose();
              _pages = _fitPages(
                cues,
                math.max(1, bodyWidth - _countWidth - stepGap),
                context,
              );
              if (_pages.length == total) break;
              total = _pages.length;
            }
          }
          if (playerV1) {
            final textWidth = math.max(
              1.0,
              bodyWidth - (_pages.length > 1 ? _countWidth + stepGap : 0),
            );
            _v1PageHeights = _pages
                .map((page) {
                  final painter = _measureCue(
                    page.text,
                    page.size,
                    textWidth,
                    context,
                    ellipsis: showPrepCaption,
                  );
                  final height = math.max(32.0, painter.height.ceilToDouble());
                  painter.dispose();
                  return height;
                })
                .toList(growable: false);
          }
          _layoutWidth = constraints.maxWidth;
          _layoutScaler = textScaler;
          _layoutDirection = direction;
          _layoutLocale = locale;
          _layoutFont = theme.fontFamily;
          _layoutPlayerV1 = playerV1;
          _layoutPrepCaption = showPrepCaption;
          _layoutCues = cues;
        }
        _index = widget.preparing ? 0 : _index.clamp(0, _pages.length - 1);
        final page = _pages[_index];
        final counter = Text(
          '${_index + 1}/${_pages.length}',
          key: const ValueKey('trainer-cue-count'),
          style: _counterStyle(theme),
        );
        final cueText = Text(
          page.text,
          key: const ValueKey('trainer-cue-text'),
          style: _bodyStyle(page.size),
          textAlign: playerV1 ? TextAlign.center : null,
          maxLines: 2,
          // Instructions were measured with the same scaler.
          overflow: showPrepCaption
              ? TextOverflow.ellipsis
              : TextOverflow.visible,
        );
        final pageContent = playerV1
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    key: const ValueKey('trainer-cue-count-slot'),
                    width: _pages.length > 1 ? _countWidth + stepGap : 0,
                    height: 32,
                    child: _pages.length < 2
                        ? null
                        : Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: SizedBox(
                              key: const ValueKey('trainer-cue-step-pill'),
                              width: _countWidth,
                              height: 22,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(11),
                                  color: theme.tint,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: AnimatedSwitcher(
                                      duration: reduced
                                          ? Duration.zero
                                          : PlayerMotion.fast,
                                      layoutBuilder: (current, _) =>
                                          current ?? const SizedBox.shrink(),
                                      child: KeyedSubtree(
                                        key: ValueKey((_index, _pages.length)),
                                        child: counter,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                  Expanded(
                    child: _CuePush(
                      identity: (showPrepCaption, _index, page.text),
                      height: _v1PageHeights[_index],
                      reduced: reduced,
                      child: cueText,
                    ),
                  ),
                ],
              )
            : Row(
                key: ValueKey('trainer-cue-page-$_index-${page.text}'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: _countWidth,
                    child: Padding(
                      padding: EdgeInsets.only(top: textScaler.scale(3)),
                      child: counter,
                    ),
                  ),
                  SizedBox(width: stepGap),
                  Expanded(child: cueText),
                ],
              );
        final pageSwitcher = playerV1
            ? pageContent
            : AnimatedSwitcher(
                duration: reduced ? Duration.zero : _transition,
                transitionBuilder: (child, animation) => AnimatedBuilder(
                  animation: animation,
                  builder: (context, _) => Transform.translate(
                    offset: Offset(
                      0,
                      animation.status == AnimationStatus.reverse
                          ? -8 * (1 - animation.value)
                          : 0,
                    ),
                    child: Opacity(opacity: animation.value, child: child),
                  ),
                ),
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.topLeft,
                  children: [...previous, ?current],
                ),
                child: pageContent,
              );
        final radius = BorderRadius.circular(playerV1 ? 20 : 16);
        final card = GestureDetector(
          onHorizontalDragStart: (_) => _dragDistance = 0,
          onHorizontalDragUpdate: (details) =>
              _dragDistance += details.delta.dx,
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (_dragDistance.abs() < 24 && velocity.abs() < 100) return;
            final right = _dragDistance.abs() >= 24
                ? _dragDistance > 0
                : velocity > 0;
            final rtl = Directionality.of(context) == TextDirection.rtl;
            _move(right != rtl ? -1 : 1, manual: true);
          },
          child: Material(
            key: const ValueKey('trainer-cue-container'),
            color: playerV1
                ? theme.card.withValues(alpha: .92)
                : theme.cardSurface,
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(color: theme.cardBorder),
            ),
            child: InkWell(
              borderRadius: radius,
              onTap: _expand,
              child: Semantics(
                label: widget.semanticLabel,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: playerV1 ? 16 : 14,
                    horizontal: 16,
                  ),
                  child: playerV1
                      ? pageSwitcher
                      : SizedBox(
                          height: textScaler.scale(16) * 1.5 * 2,
                          child: pageSwitcher,
                        ),
                ),
              ),
            ),
          ),
        );
        if (playerV1) {
          return ClipRRect(
            borderRadius: radius,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: card,
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            card,
            const SizedBox(height: 6),
            ExcludeSemantics(
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < _pages.length; i++)
                    AnimatedContainer(
                      key: ValueKey('trainer-cue-dot-$i'),
                      duration: Duration.zero,
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _index ? theme.accent : theme.cardBorder,
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  TextStyle _counterStyle(TrainerTheme theme) => TextStyle(
    inherit: false,
    fontFamily: theme.fontFamily,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    height: 1.5,
    color: theme.accent,
  );
}

class _CuePush extends StatefulWidget {
  const _CuePush({
    required this.identity,
    required this.height,
    required this.reduced,
    required this.child,
  });

  final Object identity;
  final double height;
  final bool reduced;
  final Widget child;

  @override
  State<_CuePush> createState() => _CuePushState();
}

class _CuePushState extends State<_CuePush>
    with SingleTickerProviderStateMixin {
  static const _pushDuration = Duration(milliseconds: 320);
  late final _motion = AnimationController(
    vsync: this,
    value: 1,
    animationBehavior: AnimationBehavior.preserve,
  );
  _CuePush? _previous;

  Duration get _duration =>
      widget.reduced ? PlayerMotion.reducedFade : _pushDuration;

  @override
  void didUpdateWidget(_CuePush oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      // Only the last target becomes the departing line, even if a swipe
      // arrives before that target has reached its resting position.
      _previous = oldWidget;
      _motion.duration = _duration;
      _motion.forward(from: 0);
    } else if (oldWidget.reduced != widget.reduced) {
      _previous = null;
      _motion.value = 1;
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedSize(
      alignment: Alignment.topCenter,
      duration: widget.reduced ? Duration.zero : _pushDuration,
      curve: Curves.easeInOutCubic,
      clipBehavior: Clip.none,
      child: AnimatedBuilder(
        animation: _motion,
        builder: (context, _) {
          final t = _motion.value;
          final previous = _previous;
          final moving = previous != null && t < 1;
          // Both rows share the same moving edge. The incoming row starts
          // exactly at the bottom of the outgoing row, even with more lines.
          final distance = widget.reduced || !moving ? 0.0 : previous.height;
          final travelled = Curves.easeInOutCubic.transform(t) * distance;
          return SizedBox(
            height: widget.height,
            width: double.infinity,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (moving)
                  _layer(
                    previous,
                    offset: -travelled,
                    opacity: widget.reduced
                        ? 1 - t
                        : 1 - (2 * t - 1).clamp(0.0, 1.0),
                    outgoing: true,
                  ),
                _layer(
                  widget,
                  offset: distance - travelled,
                  opacity: widget.reduced ? t : (2 * t).clamp(0.0, 1.0),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );

  Widget _layer(
    _CuePush page, {
    required double offset,
    required double opacity,
    bool outgoing = false,
  }) => Positioned(
    top: 0,
    left: 0,
    right: 0,
    height: page.height,
    child: IgnorePointer(
      child: ExcludeSemantics(
        excluding: outgoing || opacity == 0,
        child: Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(0, offset),
            child: Center(child: page.child),
          ),
        ),
      ),
    ),
  );
}

class _CuePage {
  const _CuePage(this.text, this.size);
  final String text;
  final double size;
}

class _CueSheet extends StatelessWidget {
  const _CueSheet({
    required this.cues,
    required this.precautions,
    required this.theme,
    required this.title,
    required this.precautionsTitle,
    required this.closeLabel,
  });

  final List<String> cues;
  final List<String> precautions;
  final TrainerTheme theme;
  final String title;
  final String precautionsTitle;
  final String closeLabel;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Column(
      key: const ValueKey('trainer-cue-sheet'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
          child: Row(
            children: [
              Expanded(child: Text(title, style: theme.title)),
              IconButton(
                key: const ValueKey('trainer-cue-sheet-close'),
                tooltip: closeLabel,
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.close, color: theme.muted),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, cue) in cues.indexed) ...[
                  if (index > 0) const SizedBox(height: 12),
                  Row(
                    key: ValueKey('trainer-cue-step-$index'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${index + 1}.',
                        style: theme.body.copyWith(
                          fontSize: 16,
                          height: 1.5,
                          color: theme.accent,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          cue,
                          style: theme.body.copyWith(fontSize: 16, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ],
                if (precautions.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    key: const ValueKey('trainer-cue-precautions'),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.accentSubtle,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          precautionsTitle,
                          style: theme.callout.copyWith(
                            color: theme.accentText,
                          ),
                        ),
                        for (final precaution in precautions) ...[
                          const SizedBox(height: 6),
                          Text(
                            precaution,
                            style: theme.body.copyWith(
                              fontSize: 16,
                              height: 1.5,
                              color: theme.accentText,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
