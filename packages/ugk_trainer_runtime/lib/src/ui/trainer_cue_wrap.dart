part of 'trainer_cue_carousel.dart';

// Match a spoken dose as one fragment before considering its internal spaces.
final _cueBreak = RegExp(
  r'((?:每侧\s*|每边\s*)?\d+(?:\.\d+)?\s*(?:秒|分钟|次|组)'
  r'|\b\d+(?:\.\d+)?\s+(?:seconds?|minutes?|reps?|sets?)(?:\s+per\s+side)?\b)'
  r'|\s+|[，。、；：！？,;:!?]',
  caseSensitive: false,
);

extension _TrainerCueWrap on _TrainerCueCarouselState {
  _CuePage _wrapV1(String original, double width, BuildContext context) {
    const minimum = 15.0;
    final text = original.trim();
    final breaks = <int>[0];
    for (final match in _cueBreak.allMatches(text)) {
      // A matched dose may follow another fragment without a space.
      if (match.group(1) != null) breaks.add(match.start);
      breaks.add(match.end);
    }
    breaks.add(text.length);
    final points = breaks.toSet().toList()..sort();
    final measurers = <double, _CueLineMeasure>{};
    _CueLineMeasure measure(double size) => measurers.putIfAbsent(
      size,
      () => _CueLineMeasure(
        TextPainter(
          textDirection: Directionality.of(context),
          locale: Localizations.maybeLocaleOf(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        ),
        _bodyStyle(size),
      ),
    );
    try {
      for (
        var size = _TrainerCueCarouselState._playerV1CueSize;
        size >= minimum;
        size--
      ) {
        final fit = _balanceCue(text, points, width, 2, measure(size));
        if (fit != null) return _CuePage(fit, size);
      }
      final atMinimum = measure(minimum);
      final fit = _balanceCue(text, points, width, 3, atMinimum);
      if (fit != null) return _CuePage(fit, minimum, maxLines: 3);

      // Only add character breaks inside a fragment which cannot fit one line.
      final extra = <int>{...points};
      for (var i = 0; i < points.length - 1; i++) {
        final start = points[i];
        final fragment = text.substring(start, points[i + 1]);
        if (fragment.trim().isEmpty ||
            atMinimum.width(fragment.trim()) <= width) {
          continue;
        }
        var offset = start;
        for (final grapheme in fragment.characters) {
          offset += grapheme.length;
          extra.add(offset);
        }
      }
      final withCharacters = extra.toList()..sort();
      final characterBreaks = extra.difference(points.toSet());
      for (final lines in [2, 3]) {
        final balanced = _balanceCue(
          text,
          withCharacters,
          width,
          lines,
          atMinimum,
          characterBreaks: characterBreaks,
        );
        if (balanced != null) {
          return _CuePage(balanced, minimum, maxLines: lines);
        }
      }
      return _CuePage(
        _truncateCue(text, withCharacters, width, atMinimum),
        minimum,
        maxLines: 3,
      );
    } finally {
      for (final measurer in measurers.values) {
        measurer.painter.dispose();
      }
    }
  }
}

String _truncateCue(
  String text,
  List<int> points,
  double width,
  _CueLineMeasure measure,
) {
  final rows = <String>[];
  var start = 0;
  for (var row = 0; row < 3; row++) {
    final suffix = row == 2 ? '…' : '';
    String? fit;
    var next = start;
    for (var end = start + 1; end < points.length; end++) {
      final line = text.substring(points[start], points[end]).trim();
      if (measure.width('$line$suffix') > width) break;
      if (line.isEmpty) continue;
      fit = line;
      next = end;
    }
    if (fit == null) {
      rows.add('…');
      break;
    }
    rows.add('$fit$suffix');
    if (next == points.length - 1) break;
    start = next;
  }
  return rows.join('\n');
}

class _CueLineMeasure {
  _CueLineMeasure(this.painter, this.style);

  final TextPainter painter;
  final TextStyle style;
  final _widths = <String, double>{};

  double width(String text) => _widths.putIfAbsent(text, () {
    painter.text = TextSpan(text: text, style: style);
    painter.layout();
    return painter.didExceedMaxLines ? double.infinity : painter.width;
  });
}

String? _balanceCue(
  String text,
  List<int> points,
  double width,
  int maxLines,
  _CueLineMeasure measure, {
  Set<int> characterBreaks = const {},
}) {
  if (measure.width(text) <= width) return text;
  final end = points.length - 1;
  for (var lineCount = 2; lineCount <= maxLines; lineCount++) {
    double bestSpread = double.infinity;
    List<String>? best;
    final lines = <String>[];
    void visit(int start, double shortest, double longest) {
      final remaining = lineCount - lines.length;
      final first = remaining == 1 ? end : start + 1;
      final last = end - remaining + 1;
      for (var next = first; next <= last; next++) {
        final line = text.substring(points[start], points[next]).trim();
        if (line.isEmpty) continue;
        final length = measure.width(line);
        if (length > width) break;
        if (remaining == 1 &&
            characterBreaks.contains(points[start]) &&
            line.characters
                    .where((character) => character.trim().isNotEmpty)
                    .length <
                3) {
          continue;
        }
        final minWidth = math.min(shortest, length);
        final maxWidth = math.max(longest, length);
        final spread = maxWidth - minWidth;
        if (spread >= bestSpread) continue;
        lines.add(line);
        if (remaining == 1) {
          bestSpread = spread;
          best = [...lines];
        } else {
          visit(next, minWidth, maxWidth);
        }
        lines.removeLast();
      }
    }

    visit(0, double.infinity, 0);
    if (best != null) return best!.join('\n');
  }
  return null;
}
