import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
/// [preparing] pins the first step throughout the preparation countdown.
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
  double _countWidth = 0;

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
      _move(1);
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
    fontWeight: FontWeight.w500,
    height: 1.5,
    color: widget.theme.text,
  );

  bool _fits(String text, double size, double width, BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: _bodyStyle(size)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 2,
    )..layout(maxWidth: width);
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
    void add(String text) {
      if (text.isEmpty) return;
      if (_fits(text, 16, width, context)) {
        pages.add(_CuePage(text, 16));
        return;
      }
      if (_fits(text, 14, width, context)) {
        pages.add(_CuePage(text, 14));
        return;
      }

      // Prefer a natural clause boundary. The longest fitting prefix keeps
      // adjacent short clauses together instead of making excessive slides.
      final commas = RegExp('[，,]').allMatches(text).toList();
      for (final comma in commas.reversed) {
        final prefix = _cleanCue(text.substring(0, comma.start));
        if (prefix.isNotEmpty && _fits(prefix, 14, width, context)) {
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
        if (_fits(characters.take(middle).join(), 14, width, context)) {
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
        pages.add(_CuePage(candidate, 14));
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
    final cues = normalizeTrainerCues(widget.cues);
    if (cues.isEmpty) return const SizedBox.shrink();
    final theme = widget.theme;
    final reduced = TrainerMotion.reduced(context);
    final textScaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Reserve the actual count width, including large accessibility text.
        // A second pass accommodates extra pages introduced by text splitting.
        final direction = Directionality.of(context);
        final locale = Localizations.maybeLocaleOf(context);
        if (_layoutWidth != constraints.maxWidth ||
            _layoutScaler != textScaler ||
            _layoutDirection != direction ||
            _layoutLocale != locale ||
            _layoutFont != theme.fontFamily ||
            !listEquals(_layoutCues, cues)) {
          var total = math.max(1, cues.length);
          for (var pass = 0; pass < 4; pass++) {
            final counter = TextPainter(
              text: TextSpan(
                text: '$total/$total',
                style: _counterStyle(theme),
              ),
              textDirection: direction,
              textScaler: textScaler,
            )..layout();
            _countWidth = counter.width;
            counter.dispose();
            _pages = _fitPages(
              cues,
              math.max(1, constraints.maxWidth - 32 - _countWidth - 12),
              context,
            );
            if (_pages.length == total) break;
            total = _pages.length;
          }
          _layoutWidth = constraints.maxWidth;
          _layoutScaler = textScaler;
          _layoutDirection = direction;
          _layoutLocale = locale;
          _layoutFont = theme.fontFamily;
          _layoutCues = cues;
        }
        _index = widget.preparing ? 0 : _index.clamp(0, _pages.length - 1);
        final page = _pages[_index];
        final body = Row(
          key: ValueKey('trainer-cue-page-$_index-${page.text}'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _countWidth,
              child: Padding(
                padding: EdgeInsets.only(top: textScaler.scale(3)),
                child: Text(
                  '${_index + 1}/${_pages.length}',
                  key: const ValueKey('trainer-cue-count'),
                  style: _counterStyle(theme),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                page.text,
                key: const ValueKey('trainer-cue-text'),
                style: _bodyStyle(page.size),
                maxLines: 2,
                // Every page has already been measured with the same scaler.
                // Visible overflow preserves the text in pathological bounds.
                overflow: TextOverflow.visible,
              ),
            ),
          ],
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
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
                color: theme.cardSurface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: theme.cardBorder),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: _expand,
                  child: Semantics(
                    label: widget.semanticLabel,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 14,
                        horizontal: 16,
                      ),
                      child: SizedBox(
                        height: textScaler.scale(16) * 1.5 * 2,
                        child: AnimatedSwitcher(
                          duration: reduced ? Duration.zero : _transition,
                          transitionBuilder: (child, animation) =>
                              AnimatedBuilder(
                                animation: animation,
                                builder: (context, _) => Transform.translate(
                                  offset: Offset(
                                    0,
                                    animation.status == AnimationStatus.reverse
                                        ? -8 * (1 - animation.value)
                                        : 0,
                                  ),
                                  child: Opacity(
                                    opacity: animation.value,
                                    child: child,
                                  ),
                                ),
                              ),
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.topLeft,
                            children: [...previous, ?current],
                          ),
                          child: body,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            ExcludeSemantics(
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < _pages.length; i++)
                    Container(
                      key: ValueKey('trainer-cue-dot-$i'),
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
