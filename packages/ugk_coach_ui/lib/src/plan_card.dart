import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'models.dart';
import 'theme.dart';
import 'primitives.dart';
import 'paint_reveal.dart';

/// The assistant's plan reply: a compact, fixed-height card (like a link
/// share in a messenger), raised on a static glass-like face;
/// the media inside stays opaque and rounded.
///
/// * one move → [_ExerciseBody], 130 px at default text size: a square preview on the left,
///   name · dose · one cue on the right, tags on the bottom line;
/// * a set → [_SetBody], 240 px: the first move as the hero with title,
///   duration and move count over it, one bottom row with the other moves
///   as thumbnails (as many as fit, then +N).
///
/// The one start control is an icon-only round ▶ (Semantics 「start training」)
/// anchored to the card's bottom-right corner: at the end of the bottom
/// row when compact, on the save row when unfolded; there is never a
/// second start.
///
/// Unfolding ([_Timeline]): one clip grows the card; the visible strip
/// thumbnails fly on straight lines into their rows (transform only,
/// ~40 ms apart, one curve with the height), moves hidden behind +N fade
/// in place, each row's text rises in once its thumbnail is nearly home
/// and nothing will cross it; ▶ / save retract and reveal
/// at their slots instead of travelling. Animated cutouts hold their still
/// cover during the move. Collapsing mirrors it. Reduced motion: a plain
/// bounded paint reveal.
class CoachPlanCard extends StatefulWidget {
  const CoachPlanCard({
    super.key,
    required this.plan,
    required this.library,
    required this.saved,
    required this.onStart,
    required this.onSave,
    required this.onOpen,
    this.landing = false,
    this.cutoutTopInset,
  }) : assert(
         cutoutTopInset == null ||
             (cutoutTopInset >= 0 && cutoutTopInset < double.infinity),
       );

  final CoachRoutine plan;

  /// A card that just arrived: its cover settles from 1.04 to 1 (M7).
  final bool landing;

  /// Optional cutout image top in outer-card coordinates. Null preserves the
  /// original placement. Zero allows a host-cropped figure to reach the card's
  /// top through its existing padding, without moving text or controls.
  final double? cutoutTopInset;
  final CoachExerciseLibrary library;
  final bool saved;

  /// start training; [from] says where the card is, for the grow-into-player move.
  final void Function(CoachOriginRect from) onStart;
  final VoidCallback onSave;

  /// Details (the plan page: preview, every move, swaps).
  final VoidCallback onOpen;

  /// Compact card heights at the default text size.
  static const exerciseHeight = 130.0;
  static const setHeight = 240.0;

  @override
  State<CoachPlanCard> createState() => _PlanCardState();
}

/// Timeline of the unfold on one linear controller value t ∈ [0, 1]
/// (expand 550 ms; collapse 450 ms with its own, mirrored choreography,
/// so folding is not a rewind at the wrong speed).
///
/// Everything that moves (card height, hero → row 1, strip → rows) rides
/// one curve, [motion], so the image and the clip travel together.
///
/// Expand (ms of 550):
/// * 0–100 ▶ / +N fade out; 0–120 folded title out;
/// * 0–420 height and the hero's morph into row 1's thumbnail;
/// * strip thumbnails follow ~40 ms apart, 380 ms each (all down by 500);
/// * the header fades in (180 ms) as soon as the hero has left its band;
/// * each row's text fades + rises 8 px (200 ms) once its own thumbnail is
///   ~80 % landed and no flyer will cross it again ([_Timeline.new]
///   samples the paths, so nothing ever overlaps), row by row;
/// * 370–550 ▶ / save / note fade in at their slots.
/// Collapse (ms of 450): text, header, ▶, save out in the first 110 ms; then
/// height, hero and strip return on the same curve (110–450, strip ~15 ms
/// apart); the folded title and ▶ come back over the last 150 ms.
class _Timeline {
  _Timeline({
    required this.flyers,
    required this.rows,
    Rect Function(int k, double e)? flyerRect,
    List<Rect> Function(int row)? rowText,
    Rect? headerBand,
  }) {
    final own = <double>[];
    for (var i = 0; i < rows; i++) {
      // A row's own thumbnail ~80 % landed (rows behind +N: mid fade).
      own.add(
        i < flyers ? _landMs(i, .8) : (flyers == 0 ? 160.0 + 40 * i : 260.0),
      );
    }
    double clearAfter(List<Rect> zones) {
      if (flyerRect == null || flyers == 0) return 0;
      var last = -1.0;
      for (var ms = 0.0; ms <= expandMs; ms += 2) {
        for (var k = 0; k < flyers; k++) {
          final r = flyerRect(k, _e(k, ms)).inflate(1);
          if (zones.any(r.overlaps)) last = ms;
        }
      }
      return last + 2;
    }

    _textMs = [
      for (var i = 0; i < rows; i++)
        math.min(
          expandMs.toDouble(),
          math.max(own[i], rowText == null ? 0 : clearAfter(rowText(i))),
        ),
    ];
    _headerMs = headerBand == null
        ? 0
        : math.min(expandMs.toDouble(), clearAfter([headerBand]));
  }

  final int flyers;
  final int rows;
  late final List<double> _textMs;
  late final double _headerMs;

  static const expandMs = 550;
  static const collapseMs = 450;

  /// The one curve for size and position: a smooth standard decelerate.
  static const Curve motion = Curves.fastOutSlowIn;
  static const Curve _fade = Curves.easeInOut;

  static const _heroMs = 420.0;
  static const _flightMs = 380.0;
  static const _textFadeMs = 200.0;

  /// Expand: strip flyers' stagger (flyer 0 is the hero).
  double get _stagger => flyers <= 1 ? 0 : math.min(40.0, 120.0 / (flyers - 1));
  double _start(int k) => k * _stagger;
  double _dur(int k) => k == 0 ? _heroMs : _flightMs;
  double _p(int k, double ms) => ((ms - _start(k)) / _dur(k)).clamp(0.0, 1.0);
  double _e(int k, double ms) => motion.transform(_p(k, ms));
  double _landMs(int k, double e) {
    for (var ms = 0.0; ms <= expandMs; ms += 2) {
      if (_e(k, ms) >= e) return ms;
    }
    return expandMs.toDouble();
  }

  /// Collapse: everything but text waits [_holdMs]; strip ~15 ms apart.
  static const _holdMs = 110.0;
  static const _backMs = collapseMs - _holdMs;
  double get _backStagger =>
      flyers <= 1 ? 0 : math.min(15.0, 45.0 / (flyers - 1));

  static double _in(double ms, double a, double d, [Curve c = _fade]) =>
      c.transform(((ms - a) / d).clamp(0.0, 1.0));

  static double _fwd(double t) => t * expandMs;
  static double _bk(double t) => (1 - t) * collapseMs;

  /// Card height / clip progress.
  static double height(double t, bool back) => back
      ? 1 - motion.transform(((_bk(t) - _holdMs) / _backMs).clamp(0.0, 1.0))
      : motion.transform((_fwd(t) / _heroMs).clamp(0.0, 1.0));

  /// Flyer [k]'s eased position (0 at its folded slot, 1 in its row).
  double fly(int k, double t, bool back) {
    if (!back) return _e(k, _fwd(t));
    final st = k * _backStagger;
    final d = _backMs - _backStagger * (flyers - 1);
    final p = ((_bk(t) - _holdMs - st) / d).clamp(0.0, 1.0);
    return 1 - motion.transform(p);
  }

  /// The folded title (and the hero's scrim): 1 folded.
  static double title(double t, bool back) =>
      back ? _in(_bk(t), collapseMs - 140, 140) : 1 - _in(_fwd(t), 0, 120);

  /// ▶ / +N at their folded slots: 1 folded.
  static double folded(double t, bool back) => back
      ? _in(_bk(t), collapseMs - 150, 150)
      : 1 - _in(_fwd(t), 0, 100, Curves.easeIn);

  /// ▶ / save / note at their open slots.
  static double open(double t, bool back) => back
      ? 1 - _in(_bk(t), 0, 100, Curves.easeIn)
      : _in(_fwd(t), 370, 180, Curves.easeOut);

  /// Rows whose move hid behind +N: their thumbnail fades in place.
  static double inPlace(double t, bool back) =>
      back ? 1 - _in(_bk(t), _holdMs, 150) : _in(_fwd(t), 160, 240);

  /// The unfolded header (title + meta).
  double header(double t, bool back) => back
      ? 1 - _in(_bk(t), 0, _holdMs, Curves.easeIn)
      : _appearAfter(_fwd(t), _headerMs, 180);

  /// Row [i]'s number, name and dose.
  double text(int i, double t, bool back) => back
      ? 1 - _in(_bk(t), 0, _holdMs, Curves.easeIn)
      : _appearAfter(_fwd(t), _textMs[i], _textFadeMs);

  /// A taller row can keep media in its text band later than the old fixed
  /// layout. Do not reveal text before that band is clear just to reserve a
  /// fixed fade duration. At the endpoint flyers are replaced by row media.
  static double _appearAfter(double ms, double start, double duration) {
    if (start >= expandMs) return ms >= expandMs ? 1 : 0;
    return _in(ms, start, math.min(duration, expandMs - start), Curves.easeOut);
  }
}

/// An animatable from a plain function of t (read at evaluation time).
class _Fn extends Animatable<double> {
  const _Fn(this.f);
  final double Function(double t) f;
  @override
  double transform(double t) => f(t);
}

/// Reduced motion: the height jumps at once (the content cross-fades).
class _AboveZero extends Animatable<double> {
  const _AboveZero();
  @override
  double transform(double t) => t > 0 ? 1 : 0;
}

/// Lays its child out at its natural height and takes
/// lerp([from], natural, [k]) itself, clipping the rest: the set card's
/// single animated size/clip (the child is not rebuilt per frame).
class _LerpHeight extends SingleChildRenderObjectWidget {
  const _LerpHeight({
    required this.from,
    required this.k,
    this.topOverflow = 0,
    super.child,
  });
  final double from;
  final double k;
  final double topOverflow;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLerpHeight(from, k, topOverflow);

  @override
  void updateRenderObject(BuildContext context, _RenderLerpHeight r) => r
    ..from = from
    ..k = k
    ..topOverflow = topOverflow;
}

class _RenderLerpHeight extends RenderProxyBox {
  _RenderLerpHeight(this._from, this._k, this._topOverflow);
  double _from;
  double _k;
  double _topOverflow;
  set from(double v) {
    if (v == _from) return;
    _from = v;
    markNeedsLayout();
  }

  set k(double v) {
    if (v == _k) return;
    _k = v;
    markNeedsLayout();
  }

  set topOverflow(double value) {
    if (_topOverflow == value) return;
    _topOverflow = value;
    markNeedsPaint();
  }

  final _clip = LayerHandle<ClipRectLayer>();

  BoxConstraints _inner(BoxConstraints c) =>
      c.copyWith(minHeight: 0, maxHeight: double.infinity);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final c = child;
    if (c == null) return constraints.smallest;
    final s = c.getDryLayout(_inner(constraints));
    return constraints.constrain(
      Size(s.width, lerpDouble(_from, s.height, _k)!),
    );
  }

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = constraints.smallest;
      return;
    }
    c.layout(_inner(constraints), parentUsesSize: true);
    size = constraints.constrain(
      Size(c.size.width, lerpDouble(_from, c.size.height, _k)!),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final c = child;
    if (c == null) return;
    if (c.size.height > size.height + .01) {
      _clip.layer = context.pushClipRect(
        needsCompositing,
        offset,
        Rect.fromLTRB(0, -_topOverflow, size.width, size.height),
        super.paint,
        oldLayer: _clip.layer,
      );
    } else {
      _clip.layer = null;
      super.paint(context, offset);
    }
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}

/// 1 only once the controller rests at 1: the rows' own thumbnails take
/// over from the flyers when they have landed.
class _AtEnd extends Animatable<double> {
  const _AtEnd();
  @override
  double transform(double t) => t >= 1 ? 1 : 0;
}

/// 1 only at rest folded: the strip's own thumbnails.
class _AtStart extends Animatable<double> {
  const _AtStart();
  @override
  double transform(double t) => t <= 0 ? 1 : 0;
}

class _PlanCardState extends State<CoachPlanCard>
    with SingleTickerProviderStateMixin {
  final _card = GlobalKey();
  static const _inset = 6.0;

  late final AnimationController _expand = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _Timeline.expandMs),
    reverseDuration: const Duration(milliseconds: _Timeline.collapseMs),
  )..addStatusListener(_onStatus);
  late final Animation<double> _height = _expand.drive(
    _Fn((t) => _Timeline.height(t, _back)),
  );
  bool _expanded = false;

  /// Which choreography is playing: the collapse has its own (chosen when
  /// a fold starts from rest; an interrupted move just plays back).
  bool _back = false;

  /// True while the card unfolds / folds: animated cutouts show their still
  /// cover meanwhile (no WebP frame decoding during the move).
  bool _moving = false;
  bool _precached = false;

  void _onStatus(AnimationStatus s) {
    final moving = s == AnimationStatus.forward || s == AnimationStatus.reverse;
    if (moving != _moving && mounted) setState(() => _moving = moving);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_precached) return;
    _precached = true;
    // Decode every thumbnail (and the still cutouts) up front, so the first
    // unfold never decodes an image mid-flight.
    for (final i in widget.plan.items) {
      final e = widget.library.tryGet(i.exerciseId);
      if (e == null) continue;
      final paths = [
        e.poster,
        if ((e.cutout != null)) e.stillCutout ?? e.cutout!,
      ];
      for (final a in paths) {
        precacheImage(AssetImage(a), context, onError: (_, _) {});
      }
    }
  }

  @override
  void dispose() {
    _expand.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (!_expand.isAnimating) _back = !_expanded;
    if (CoachMotion.reduced(context)) {
      _expand.animateTo(
        _expanded ? 1 : 0,
        duration: const Duration(milliseconds: 200),
      );
    } else if (_expanded) {
      _expand.forward();
    } else {
      _expand.reverse();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final preferredWidth = (MediaQuery.sizeOf(context).width - 32).clamp(
        280.0,
        400.0,
      );
      // All measurements and painted media paths use the width the parent
      // actually grants, including hosts that embed the card in a narrow pane.
      final width = constraints.hasBoundedWidth
          ? math.min(preferredWidth, constraints.maxWidth)
          : preferredWidth;
      return _buildCard(context, width);
    },
  );

  Widget _buildCard(BuildContext context, double width) {
    final p = widget.plan;
    final lib = widget.library;
    final items = p.items.toList();
    final moves = [
      for (final i in items) lib.tryGet(i.exerciseId),
    ].whereType<CoachExercise>().toList();
    final gearText = p.gearLabel;
    final duration = p.durationLabel;
    final single = items.length == 1;
    // Keep the compact design at the default size, but leave enough vertical
    // room for system text scaling. The preview keeps its original width so
    // a taller card cannot squeeze the text column off a narrow phone.
    final textScale = math.max(
      1.0,
      MediaQuery.textScalerOf(context).scale(16) / 16,
    );
    final height = single
        ? CoachPlanCard.exerciseHeight * textScale
        : CoachPlanCard.setHeight;
    final reduced = CoachMotion.reduced(context);
    final compactH = height - _inset * 2;
    final innerW = width - _inset * 2;

    // The strip: the moves after the hero, as many as fit before the ▶.
    final rest = [for (var i = 1; i < items.length; i++) i];
    final fit = _SetBody.fitCount(innerW);
    final shownCount = single
        ? 0
        : (rest.length <= fit ? rest.length : fit - 1);
    final more = rest.length - shownCount;
    final cues = single
        ? (moves.firstOrNull?.cues ?? const <String>[])
        : const <String>[];
    final cover = single
        ? null
        : (lib.tryGet(items.first.exerciseId) ?? moves.firstOrNull);
    final fused = (cover?.cutout != null);
    final stage = cover?.stage ?? CoachUiTheme.of(context).colors.stage;
    // The unfolded set's header: title + meta on the left, collapse on the right.
    final headerH = math.max(_Header.minHeight, textScale * 40 + 16);
    final meta = p.metaLabel;

    // Resolve text exactly as the rows paint it. The same row measurements
    // determine natural height, thumbnail destinations and no-crossing bands.
    final rowType = _MoveRowTypography.of(context);
    var indexWidth = _MoveRow.indexWidth;
    for (var i = 0; i < items.length; i++) {
      indexWidth = math.max(
        indexWidth,
        rowType.measure('${i + 1}', rowType.index).width.ceilToDouble() + 4,
      );
    }
    final rowLayouts = [
      for (var i = 0; i < items.length; i++)
        _MoveRowLayout.measure(
          type: rowType,
          index: '${i + 1}',
          name: lib.tryGet(items[i].exerciseId)?.name ?? items[i].exerciseId,
          dose: items[i].detailDose,
          width: innerW - _Details.pad * 2,
          indexWidth: indexWidth,
        ),
    ];
    final rowTops = <double>[];
    var nextRowTop = headerH;
    for (final row in rowLayouts) {
      rowTops.add(nextRowTop);
      nextRowTop += row.height;
    }

    // Flyers: strip slot → row thumbnail, in card-content coords; each one
    // is a fixed-size row thumbnail moved only by a transform (no layout).
    Offset stripSlot(int k) => Offset(
      rowType.direction == TextDirection.ltr
          ? CoachSpace.x1 + k * (_SetBody.thumb + _SetBody.gap)
          : innerW - _SetBody.thumb - k * (_SetBody.thumb + _SetBody.gap),
      compactH -
          _SetBody.stripHeight +
          _SetBody.stripTop +
          (_SetBody.stripHeight - _SetBody.stripTop - _SetBody.thumb) / 2,
    );
    Offset rowSlot(int i) => Offset(
      _Details.pad + rowLayouts[i].thumbLeft,
      rowTops[i] + rowLayouts[i].thumbTop,
    );
    // The hero's folded frame (the cutout's box, or the boxed cover) and
    // its landing slot, row 1's thumbnail.
    final heroH = compactH - _SetBody.stripHeight;
    var heroFrom = fused
        ? Rect.fromLTWH(
            CoachSpace.x4,
            CoachSpace.x1,
            innerW - 2 * CoachSpace.x4,
            heroH - CoachSpace.x1 - _SetBody.fusedTitleRoom,
          )
        : Rect.fromLTWH(0, 0, innerW, heroH);
    final cutoutTop = widget.cutoutTopInset == null
        ? null
        : widget.cutoutTopInset! - _inset;
    if (fused && cutoutTop != null) {
      heroFrom = Rect.fromLTRB(
        heroFrom.left,
        math.min(cutoutTop, heroFrom.bottom),
        heroFrom.right,
        heroFrom.bottom,
      );
    }
    final heroTo = rowSlot(0) & const Size.square(_MoveRow.thumbSize);
    Rect flyerRect(int k, double e) {
      if (k == 0) return Rect.lerp(heroFrom, heroTo, e)!;
      final o = Offset.lerp(stripSlot(k - 1), rowSlot(rest[k - 1]), e)!;
      const s0 = _SetBody.thumb / _MoveRow.thumbSize;
      return o & Size.square(_MoveRow.thumbSize * (s0 + (1 - s0) * e));
    }

    // Flyers: on a set the hero is flyer 0 (into row 1), the visible strip
    // thumbnails are flyers 1…shown (into rows 2…). Each row's text and the
    // header wait until no flyer will cross them.
    final timeline = single
        ? _Timeline(flyers: 0, rows: cues.length)
        : _Timeline(
            flyers: shownCount + 1,
            rows: items.length,
            flyerRect: flyerRect,
            rowText: (i) {
              final row = rowLayouts[i];
              final offset = Offset(_Details.pad, rowTops[i]);
              return [row.indexBand.shift(offset), row.textBand.shift(offset)];
            },
            headerBand: Rect.fromLTWH(0, 0, innerW, headerH - 2),
          );
    Animation<double> anim(double Function(double t, bool back) f) =>
        _expand.drive(_Fn((t) => f(t, _back)));

    final stripThumbs = reduced
        ? ReverseAnimation(
            CurvedAnimation(parent: _expand, curve: const Interval(0, .45)),
          )
        : _expand.drive(const _AtStart());
    // Over the hero only while the card rests folded (its scrim pill);
    // the plain pill once the hero has started to fly.
    final toggleOnMedia = !single && !fused;
    final toggle = AnimatedBuilder(
      animation: _expand,
      builder: (context, _) => _ExpandToggle(
        key: ValueKey('plan-expand-${p.id}'),
        expanded: _expanded,
        turns: _height,
        onMedia: toggleOnMedia && _expand.value < .15,
        onTap: _toggle,
      ),
    );
    final Widget body = single
        ? _ExerciseBody(
            exercise: moves.firstOrNull,
            item: items.first,
            fallbackName: p.title,
            duration: duration,
            tags: [
              gearText,
              if (moves.firstOrNull case final e?) e.categoryLabel,
              p.levelLabel,
            ],
            landing: widget.landing,
            still: _moving,
            cutoutTop: cutoutTop,
          )
        : _SetBody(
            cover: cover,
            shown: [
              for (final i in rest.take(shownCount))
                lib.tryGet(items[i].exerciseId),
            ],
            more: more,
            landing: widget.landing,
            still: _moving,
            cutoutBounds: fused && cutoutTop != null ? heroFrom : null,
            thumbs: stripThumbs,
            // The hero leaves its place at once: a flyer carries it into
            // row 1 (reduced motion: it fades with the rest of the body).
            hero: stripThumbs,
            // The +N chip fades in place (its moves fade into their rows).
            chip: reduced ? stripThumbs : anim(_Timeline.folded),
          );

    final atEnd = _expand.drive(const _AtEnd());
    Animation<double> textOf(int i) =>
        reduced ? _expand : anim((t, b) => timeline.text(i, t, b));
    final arrive = reduced ? _expand : anim(_Timeline.open);
    final details = _Details(
      t: _expand,
      height: _height,
      fade: arrive,
      reduced: reduced,
      clip: single,
      topPad: single ? _Details.pad : 0,
      header: single
          ? null
          // The header is overlaid with the toggle in one Row, so the text
          // gives the button its actual width at every system text size.
          : SizedBox(height: headerH),
      rows: [
        if (single)
          for (final (i, c) in cues.indexed)
            _CueRow(index: i + 1, text: c, anim: textOf(i), reduced: reduced)
        else
          for (var i = 0; i < items.length; i++)
            _MoveRow(
              key: ValueKey('plan-row-$i'),
              index: i + 1,
              layout: rowLayouts[i],
              item: CoachRoutineItem(
                exerciseId: items[i].exerciseId,
                dose: items[i].detailDose,
              ),
              exercise: lib.tryGet(items[i].exerciseId),
              text: textOf(i),
              // Row 1 receives the hero, rows 2…shown+1 a strip flyer: each
              // shows its own thumbnail once its flyer has landed; rows
              // hidden behind +N fade in place.
              thumb: reduced
                  ? _expand
                  : i <= shownCount
                  ? atEnd
                  : anim(_Timeline.inPlace),
              reduced: reduced,
            ),
      ],
      note: p.adjustmentsLabel,
      footer: Row(
        children: [
          CoachTextAction(
            key: ValueKey('plan-save-${p.id}'),
            icon: CoachGlyph.bookmark,
            iconFilled: widget.saved,
            color: widget.saved
                ? CoachUiTheme.of(context).colors.accentText
                : CoachUiTheme.of(context).colors.text,
            label: widget.saved
                ? CoachUiTheme.of(context).strings.saved
                : CoachUiTheme.of(context).strings.save,
            onPressed: widget.saved ? null : widget.onSave,
            boxed: true,
          ),
          const Spacer(),
          // The ▶ appears here (it is laid over the card, anchored bottom-right).
          const SizedBox(width: CoachStartButton.size),
        ],
      ),
    );

    final start = CoachStartButton(
      key: ValueKey('plan-start-${p.id}'),
      onTap: () => widget.onStart(() => coachRectOf(_card.currentContext)),
    );

    final flyerThumbs = [
      for (var k = 0; k < shownCount; k++)
        RepaintBoundary(
          child: _MoveRow.thumbFor(lib.tryGet(items[rest[k]].exerciseId)),
        ),
    ];

    // ▶ never travels over the rows: it clips / shrinks out at its folded
    // slot, and back in at the open one (and the reverse on fold).
    final play = AnimatedBuilder(
      animation: _expand,
      builder: (context, child) {
        final t = _expand.value;
        final open = t >= .5;
        final double o = reduced
            ? (t < .5 ? 1 - 2 * t : 2 * t - 1).clamp(0.0, 1.0)
            : open
            ? _Timeline.open(t, _back)
            : _Timeline.folded(t, _back);
        final face = IgnorePointer(
          ignoring: o < .5,
          child: PaintReveal.fixed(
            key: const ValueKey('plan-start-fade'),
            fraction: o,
            child: reduced || o == 1
                ? child
                : Transform.scale(scale: .7 + .3 * o, child: child),
          ),
        );
        if (open) {
          return Positioned(
            right: _Details.pad,
            bottom: _Details.footerBottom,
            child: face,
          );
        }
        // Folded slot, from the top: the card's height moves meanwhile.
        return single
            ? Positioned(
                right: 0,
                top: compactH - CoachStartButton.size,
                child: face,
              )
            : Positioned(
                right: CoachSpace.x1,
                top: compactH - 1 - CoachStartButton.size,
                child: face,
              );
      },
      child: start,
    );

    final compact = CoachPressable(
      key: ValueKey('plan-open-${p.id}'),
      semanticLabel: CoachUiTheme.of(context).strings.planDetails(p.title),
      scale: 1,
      haptic: CoachHaptic.selection,
      onTap: widget.onOpen,
      child: RepaintBoundary(child: body),
    );

    final Widget content;
    if (single) {
      content = Stack(
        clipBehavior: cutoutTop != null && moves.firstOrNull?.cutout != null
            ? Clip.none
            : Clip.hardEdge,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The compact card: fixed height by type. The whole of it
              // opens the plan page; the toggle sits on top as its own
              // button (own semantics node).
              SizedBox(
                height: compactH,
                child: Stack(
                  fit: StackFit.expand,
                  clipBehavior:
                      cutoutTop != null && moves.firstOrNull?.cutout != null
                      ? Clip.none
                      : Clip.hardEdge,
                  children: [
                    Positioned.fill(child: compact),
                    Positioned(right: 0, top: 0, child: toggle),
                  ],
                ),
              ),
              details,
            ],
          ),
          play,
        ],
      );
    } else {
      // A set unfolds into header + list: the folded body leaves (its hero
      // flies into row 1, the strip into rows 2…), and one lerped height
      // clips the whole card; nothing in the rows is rebuilt per frame.
      final heroLayer = reduced
          ? const SizedBox.shrink()
          : AnimatedBuilder(
              animation: _expand,
              builder: (context, _) {
                final t = _expand.value;
                if (t <= 0 || t >= 1) return const SizedBox.shrink();
                return _heroFlyer(
                  cover: cover,
                  fused: fused,
                  stage: stage,
                  from: heroFrom,
                  to: heroTo,
                  e: timeline.fly(0, t, _back),
                  scrim: _Timeline.title(t, _back),
                );
              },
            );
      final titleLayer = AnimatedBuilder(
        animation: _expand,
        builder: (context, child) {
          final t = _expand.value;
          final o = reduced ? stripThumbs.value : _Timeline.title(t, _back);
          if (o <= 0) return const SizedBox.shrink();
          return Positioned(
            left: CoachSpace.x4,
            right: CoachSpace.x4,
            top: 0,
            height: heroH,
            child: IgnorePointer(
              child: PaintReveal.fixed(
                key: const ValueKey('plan-hero-title'),
                fraction: o,
                child: child,
              ),
            ),
          );
        },
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: const EdgeInsets.only(bottom: CoachSpace.x3),
            child: _HeroTitle(
              title: p.title,
              meta: meta,
              titleColor: fused
                  ? CoachUiTheme.of(context).colors.text
                  : stage.onStage,
              metaColor: fused
                  ? CoachUiTheme.of(context).colors.muted
                  : stage.onStageMuted,
            ),
          ),
        ),
      );
      final stripLayer = reduced || shownCount == 0
          ? const SizedBox.shrink()
          : Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _expand,
                    builder: (context, _) {
                      final t = _expand.value;
                      if (t <= 0 || t >= 1) return const SizedBox.shrink();
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (var k = 0; k < shownCount; k++)
                            _flyer(
                              key: ValueKey('fly-$k'),
                              child: flyerThumbs[k],
                              from: stripSlot(k),
                              to: rowSlot(rest[k]),
                              e: timeline.fly(k + 1, t, _back),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            );
      final k = reduced ? _expand.drive(const _AboveZero()) : _height;
      content = AnimatedBuilder(
        animation: k,
        builder: (context, child) => _LerpHeight(
          from: compactH,
          k: k.value,
          topOverflow: fused && cutoutTop != null ? math.max(0, -cutoutTop) : 0,
          child: child,
        ),
        child: Stack(
          fit: StackFit.passthrough,
          clipBehavior: Clip.none,
          children: [
            SizedBox(height: compactH),
            AnimatedBuilder(
              animation: _expand,
              builder: (context, child) =>
                  _expand.value == 0 ? const SizedBox.shrink() : child!,
              child: details,
            ),
            AnimatedBuilder(
              animation: _expand,
              builder: (context, child) {
                final t = _expand.value;
                return Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  height: compactH,
                  child: Offstage(
                    offstage: t >= 1,
                    child: ExcludeFocus(
                      excluding: t > 0,
                      child: IgnorePointer(
                        ignoring: t > 0,
                        child: ExcludeSemantics(
                          excluding: t > 0,
                          child: child!,
                        ),
                      ),
                    ),
                  ),
                );
              },
              child: compact,
            ),
            heroLayer,
            titleLayer,
            stripLayer,
            Positioned(
              left: 0,
              right: CoachSpace.x1,
              top: 0,
              child: _Header(
                key: const ValueKey('plan-header'),
                height: headerH,
                title: p.title,
                meta: meta,
                openKey: ValueKey('plan-open-${p.id}'),
                onOpen: widget.onOpen,
                progress: _expand,
                fade: reduced ? _expand : anim(timeline.header),
                reduced: reduced,
                toggle: toggle,
              ),
            ),
            play,
          ],
        ),
      );
    }

    Widget card = CoachCardSurface(
      radius: CoachRadius.lg,
      width: width,
      padding: const EdgeInsets.all(_inset),
      child: content,
    );

    // Landing: the glass rim's highlight settles as the card arrives.
    // (The Stack is always there so the glass subtree keeps its identity
    // when the landing flag clears.)
    {
      card = Stack(
        children: [
          card,
          // The figure can paint in the original padding. Keep that visible
          // strip tappable without covering controls, whose top is _inset.
          if (cutoutTop != null &&
              cutoutTop < 0 &&
              (fused || (single && moves.firstOrNull?.cutout != null)))
            AnimatedBuilder(
              animation: _expand,
              builder: (context, _) => _expand.value != 0
                  ? const SizedBox.shrink()
                  : Positioned(
                      left: single ? _inset : _inset + heroFrom.left,
                      right: single
                          ? width - _inset - (CoachPlanCard.exerciseHeight - 12)
                          : width - _inset - heroFrom.right,
                      top: widget.cutoutTopInset!,
                      height: -cutoutTop,
                      child: GestureDetector(
                        key: const ValueKey('plan-cutout-padding-hit'),
                        behavior: HitTestBehavior.translucent,
                        excludeFromSemantics: true,
                        onTap: widget.onOpen,
                        child: const SizedBox.expand(),
                      ),
                    ),
            ),
          if (widget.landing && !reduced)
            Positioned.fill(
              child: IgnorePointer(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 1, end: 0),
                  duration: const Duration(milliseconds: 700),
                  curve: CoachMotion.standard,
                  builder: (_, k, _) => k == 0
                      ? const SizedBox.shrink()
                      : DecoratedBox(
                          decoration: ShapeDecoration(
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(
                                CoachRadius.lg,
                              ),
                              side: BorderSide(
                                color: CoachUiTheme.of(context)
                                    .colors
                                    .landingHighlight
                                    .withValues(alpha: .45 * k),
                                width: 1.2,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            ),
        ],
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: RepaintBoundary(
        key: const ValueKey('plan-card-paint-boundary'),
        child: SizedBox(key: _card, width: width, child: card),
      ),
    );
  }

  /// The hero at flight progress [p]: its frame shrinks on a straight line
  /// from the folded hero to row 1's thumbnail (rect and corner radius
  /// lerp together). It shows the still cover throughout; a cutout, framed
  /// differently from the row's boxed poster, reveals exactly that
  /// thumbnail over the last ~60 ms, so the hand-off is seamless.
  Widget _heroFlyer({
    required CoachExercise? cover,
    required bool fused,
    required CoachMediaPalette stage,
    required Rect from,
    required Rect to,
    required double e,
    required double scrim,
  }) {
    final r = Rect.lerp(from, to, e)!;
    final radius = lerpDouble(
      fused ? 0 : CoachRadius.lg - 6,
      _MoveRow.radius,
      e,
    )!;
    final poster = fused ? ((e - .6) / .4).clamp(0.0, 1.0) : 1.0;
    return Positioned.fromRect(
      key: const ValueKey('fly-hero'),
      rect: r,
      child: RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (poster > 0)
                ClipRect(
                  clipper: MediaSliceClipper(0, poster),
                  child: _Media(exercise: cover),
                ),
              if (fused && poster < 1 && cover != null)
                ClipRect(
                  clipper: MediaSliceClipper(poster, 1),
                  child: _mediaImage(
                    context,
                    CoachMediaRequest(
                      exercise: cover,
                      asset: cover.stillCutout ?? cover.cutout!,
                      cutout: true,
                      still: true,
                      landing: false,
                      fit: BoxFit.contain,
                      alignment: widget.cutoutTopInset == null
                          ? Alignment.center
                          : Alignment.topCenter,
                    ),
                  ),
                ),
              if (!fused && scrim > 0) _heroScrim(stage, strength: scrim),
            ],
          ),
        ),
      ),
    );
  }

  /// One flying thumbnail at flight progress [p]: a straight line on the
  /// emphasized curve, growing from the strip size to the row size. Moved
  /// by a transform only.
  Widget _flyer({
    required Key key,
    required Widget child,
    required Offset from,
    required Offset to,
    required double e,
  }) {
    const s0 = _SetBody.thumb / _MoveRow.thumbSize;
    final o = Offset.lerp(from, to, e)!;
    final s = s0 + (1 - s0) * e;
    return Positioned(
      key: key,
      left: 0,
      top: 0,
      width: _MoveRow.thumbSize,
      height: _MoveRow.thumbSize,
      child: Transform(
        transform: Matrix4.translationValues(o.dx, o.dy, 0)
          ..scaleByDouble(s, s, 1, 1),
        child: child,
      ),
    );
  }
}

/// The in-place details: the full move list (or a move's cues), notes and
/// the save footer (the ▶ is laid over its right end). The clip grows on
/// [height]; each row animates itself (text after its thumbnail lands).
/// Reduced motion: no height move, the block reveals within its bounds.
class _Details extends StatelessWidget {
  const _Details({
    required this.t,
    required this.height,
    required this.fade,
    required this.reduced,
    required this.rows,
    required this.footer,
    this.note,
    this.header,
    this.topPad = pad,
    this.clip = true,
  });

  /// A set's header (title + meta; the collapse toggle is laid over its right).
  final Widget? header;
  final double topPad;

  /// Clip-reveal by [height] itself (one move); a set's card clips the
  /// whole content in one place instead.
  final bool clip;
  final Animation<double> t;
  final Animation<double> height;

  /// Note and the save row: in at the end, out first on fold.
  final Animation<double> fade;
  final bool reduced;
  final List<Widget> rows;
  final Widget footer;
  final String? note;

  /// Side / top padding of the list.
  static const pad = CoachSpace.x2;

  /// Divider → footer row, and footer row → card content edge.
  static const footerTop = 14.0;
  static const footerBottom = 4.0;
  static const footerRow = 48.0;

  @override
  Widget build(BuildContext context) {
    Widget content = Padding(
      padding: EdgeInsets.fromLTRB(pad, topPad, pad, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ...rows,
          if (note != null)
            PaintReveal(
              progress: fade,
              child: Padding(
                padding: const EdgeInsets.only(top: CoachSpace.x1),
                child: Text(
                  note!,
                  style: CoachUiTheme.of(context).typography.caption,
                ),
              ),
            ),
          PaintReveal(
            progress: fade,
            child: Container(
              margin: const EdgeInsets.only(top: CoachSpace.x2),
              padding: const EdgeInsets.only(
                top: footerTop,
                bottom: footerBottom,
              ),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: CoachUiTheme.of(
                      context,
                    ).colors.text.withValues(alpha: .08),
                  ),
                ),
              ),
              child: SizedBox(height: footerRow, child: footer),
            ),
          ),
        ],
      ),
    );
    if (header case final h?) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [h, content],
      );
    }
    if (reduced) content = PaintReveal(progress: t, child: content);
    if (!clip) return RepaintBoundary(child: content);

    return AnimatedBuilder(
      animation: height,
      builder: (context, child) {
        if (t.value == 0) return const SizedBox(width: double.infinity);
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: reduced ? 1 : height.value.clamp(0.0, 1.0),
            child: child,
          ),
        );
      },
      child: RepaintBoundary(child: content),
    );
  }
}

/// The unfolded set's header (≈56 px): plan title and meta on the left in
/// the page's ink, room for collapse on the right. Tapping it opens the plan
/// page, as the folded card does.
class _Header extends StatelessWidget {
  const _Header({
    super.key,
    required this.height,
    required this.title,
    required this.meta,
    required this.openKey,
    required this.onOpen,
    required this.progress,
    required this.fade,
    required this.reduced,
    required this.toggle,
  });
  final double height;
  final String title;
  final String meta;
  final Key openKey;
  final VoidCallback onOpen;
  final Animation<double> progress;
  final Animation<double> fade;
  final bool reduced;
  final Widget toggle;

  static const minHeight = 56.0;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Row(
      children: [
        Expanded(
          child: AnimatedBuilder(
            animation: progress,
            builder: (context, child) {
              if (progress.value == 0) return const SizedBox.shrink();
              final inactive = progress.value < 1;
              return ExcludeFocus(
                excluding: inactive,
                child: IgnorePointer(
                  ignoring: inactive,
                  child: ExcludeSemantics(excluding: inactive, child: child!),
                ),
              );
            },
            child: PaintReveal(
              key: const ValueKey('plan-header-fade'),
              progress: fade,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, .12),
                  end: Offset.zero,
                ).animate(reduced ? kAlwaysCompleteAnimation : fade),
                child: CoachPressable(
                  key: openKey,
                  semanticLabel: CoachUiTheme.of(
                    context,
                  ).strings.planDetails(title),
                  scale: 1,
                  haptic: CoachHaptic.selection,
                  onTap: onOpen,
                  child: Padding(
                    padding: const EdgeInsets.only(left: _Details.pad),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: CoachUiTheme.of(context).colors.text,
                              fontSize: 17,
                              height: 1.25,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: CoachUiTheme.of(context).colors.muted,
                              fontSize: 12.5,
                              height: 1.35,
                              fontWeight: FontWeight.w500,
                              fontFeatures: CoachUiTypography.tabular,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: CoachSpace.x3),
        toggle,
      ],
    ),
  );
}

/// expand / collapse: a small disclosure pill; the chevron turns over as the card
/// opens. Exposes expanded / collapsed to TalkBack.
class _ExpandToggle extends StatelessWidget {
  const _ExpandToggle({
    super.key,
    required this.expanded,
    required this.turns,
    required this.onMedia,
    required this.onTap,
  });
  final bool expanded;
  final Animation<double> turns;
  final bool onMedia;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final glass = CoachUiTheme.of(context).colors.isDark && !onMedia;
    final fg = onMedia
        ? CoachUiTheme.of(context).colors.onMedia
        : glass
        ? CoachUiTheme.of(context).colors.text
        : CoachUiTheme.of(context).colors.muted;
    final label = expanded
        ? CoachUiTheme.of(context).strings.collapse
        : CoachUiTheme.of(context).strings.expand;
    return CoachPressable(
      semanticLabel: expanded
          ? CoachUiTheme.of(context).strings.collapseDetails
          : CoachUiTheme.of(context).strings.expandDetails,
      expanded: expanded,
      haptic: CoachHaptic.selection,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
        child: Center(
          child: _toggleFace(
            context: context,
            glass: glass,
            onMedia: onMedia,
            child: Padding(
              padding: glass
                  ? const EdgeInsets.fromLTRB(12, 9, 9, 9)
                  : const EdgeInsets.fromLTRB(10, 5, 7, 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 12.5,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 2),
                  // Down when closed, up when open.
                  AnimatedBuilder(
                    animation: turns,
                    builder: (_, child) => Transform.rotate(
                      angle: math.pi * (.5 - turns.value),
                      child: child,
                    ),
                    child: CoachIcon(
                      CoachGlyph.chevronRight,
                      size: 14,
                      color: fg,
                      strokeWidth: 2.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dark on the glass card: the idle control face; otherwise the quiet tonal
/// pill (light) or the scrim pill over media.
Widget _toggleFace({
  required BuildContext context,
  required bool glass,
  required bool onMedia,
  required Widget child,
}) => glass
    ? CoachControlFace(padding: EdgeInsets.zero, minHeight: 0, child: child)
    : DecoratedBox(
        decoration: ShapeDecoration(
          color: onMedia
              ? CoachUiTheme.of(context).colors.mediaScrim
              : CoachUiTheme.of(context).colors.text.withValues(
                  alpha: CoachUiTheme.of(context).colors.isDark ? .10 : .06,
                ),
          shape: const StadiumBorder(),
        ),
        child: child,
      );

class _CueRow extends StatelessWidget {
  const _CueRow({
    required this.index,
    required this.text,
    required this.anim,
    required this.reduced,
  });
  final int index;
  final String text;
  final Animation<double> anim;
  final bool reduced;

  @override
  Widget build(BuildContext context) => _rowIn(
    anim: anim,
    reduced: reduced,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Text(
              '$index',
              style: CoachUiTheme.of(context).typography.label.copyWith(
                color: CoachUiTheme.of(context).colors.muted,
                fontFeatures: CoachUiTypography.tabular,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: CoachUiTheme.of(context).typography.callout,
            ),
          ),
        ],
      ),
    ),
  );
}

/// A row's text arriving: paint reveal + an 8 px rise (none under
/// reduced motion, where the whole details block reveals instead).
Widget _rowIn({
  Key? key,
  required Animation<double> anim,
  required bool reduced,
  required Widget child,
}) => reduced
    ? child
    : PaintReveal(
        key: key,
        progress: anim,
        child: AnimatedBuilder(
          animation: anim,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, 8 * (1 - anim.value)),
            child: child,
          ),
          child: child,
        ),
      );

/// The cover image on its stage colour; settles from 1.04 as a card lands.
class _Media extends StatelessWidget {
  const _Media({
    required this.exercise,
    this.landing = false,
    this.cutout = false,
    this.still = false,
    this.cutoutAlignment = Alignment.center,
  });
  final CoachExercise? exercise;
  final bool landing;

  /// Show the cutout's still cover (while the card unfolds / folds).
  final bool still;

  /// The keyed figure straight on the glass (no stage box), when [exercise]
  /// has one (the supplied cutout); otherwise the boxed cover as before.
  final bool cutout;
  final Alignment cutoutAlignment;

  @override
  Widget build(BuildContext context) {
    final e = exercise;
    if (cutout && e != null && (e.cutout != null)) {
      final reduced = CoachMotion.reduced(context);
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: landing && !reduced ? 1.04 : 1, end: 1),
        duration: const Duration(milliseconds: 600),
        curve: CoachMotion.standard,
        builder: (_, k, img) => k == 1
            ? img!
            : Transform.scale(scale: k, alignment: cutoutAlignment, child: img),
        child: _mediaImage(
          context,
          CoachMediaRequest(
            exercise: e,
            asset: (reduced || still)
                ? (e.stillCutout ?? e.cutout!)
                : e.cutout!,
            cutout: true,
            still: reduced || still,
            landing: landing,
            fit: BoxFit.contain,
            alignment: cutoutAlignment,
            semanticLabel: e.name,
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: (e?.stage ?? CoachUiTheme.of(context).colors.stage).mediaStage,
        ),
        if (e != null)
          TweenAnimationBuilder<double>(
            // M7: once, as the card lands, the cover settles into place.
            tween: Tween(
              begin: landing && !CoachMotion.reduced(context) ? 1.04 : 1,
              end: 1,
            ),
            duration: const Duration(milliseconds: 600),
            curve: CoachMotion.standard,
            builder: (_, k, img) =>
                k == 1 ? img! : Transform.scale(scale: k, child: img),
            child: _mediaImage(
              context,
              CoachMediaRequest(
                exercise: e,
                asset: e.poster,
                cutout: false,
                still: true,
                landing: landing,
                fit: BoxFit.cover,
                alignment: const Alignment(0, -.15),
              ),
            ),
          ),
      ],
    );
  }
}

Widget _mediaImage(BuildContext context, CoachMediaRequest request) =>
    CoachUiTheme.of(context).builders.media?.call(context, request) ??
    Image.asset(
      request.asset,
      fit: request.fit,
      alignment: request.alignment,
      gaplessPlayback: request.cutout,
      semanticLabel: request.semanticLabel,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );

/// One move: square preview left; name, dose, one cue right, tags on the
/// bottom line beside start training.
class _ExerciseBody extends StatelessWidget {
  const _ExerciseBody({
    required this.exercise,
    required this.item,
    required this.fallbackName,
    required this.duration,
    required this.tags,
    this.landing = false,
    this.still = false,
    this.cutoutTop,
  });
  final bool still;
  final CoachExercise? exercise;
  final CoachRoutineItem item;
  final String fallbackName;
  final String duration;
  final List<String> tags;
  final bool landing;
  final double? cutoutTop;

  @override
  Widget build(BuildContext context) {
    final e = exercise;
    final cue = e == null || e.cues.isEmpty ? '' : e.cues.first;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: CoachPlanCard.exerciseHeight - 12,
          child: e?.cutout != null && cutoutTop != null
              ? LayoutBuilder(
                  builder: (context, constraints) {
                    const side = CoachPlanCard.exerciseHeight - 12;
                    final bottom = (constraints.maxHeight + side) / 2;
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: 0,
                          width: side,
                          top: math.min(cutoutTop!, bottom),
                          height: math.max(0, bottom - cutoutTop!),
                          child: _Media(
                            exercise: e,
                            landing: landing,
                            cutout: true,
                            still: still,
                            cutoutAlignment: Alignment.topCenter,
                          ),
                        ),
                      ],
                    );
                  },
                )
              : Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: (e?.cutout != null)
                        ? _Media(
                            exercise: e,
                            landing: landing,
                            cutout: true,
                            still: still,
                          )
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(
                              CoachRadius.lg - 6,
                            ),
                            child: _Media(exercise: e, landing: landing),
                          ),
                  ),
                ),
        ),
        const SizedBox(width: CoachSpace.x3),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              0,
              CoachSpace.x1,
              0,
              CoachSpace.x1,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 72), // clear of expand
                  child: Text(
                    e?.name ?? fallbackName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CoachUiTheme.of(context).typography.callout.copyWith(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${item.doseText()} · $duration',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CoachUiTheme.of(context).typography.label.copyWith(
                    fontFeatures: CoachUiTypography.tabular,
                  ),
                ),
                if (cue.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    cue,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CoachUiTheme.of(context).typography.caption.copyWith(
                      color: CoachUiTheme.of(context).colors.muted,
                    ),
                  ),
                ],
                const Spacer(),
                // Tags share the bottom line with the ▶ (its 48 px disc
                // sits on the card's bottom edge; centres line up).
                Padding(
                  padding: const EdgeInsets.only(
                    right: CoachStartButton.reserve,
                    bottom: 9,
                  ),
                  child: _Tags(tags),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Small flat tags (equipment · body part · level); one line, clipped.
class _Tags extends StatelessWidget {
  const _Tags(this.tags);
  final List<String> tags;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: math.max(
      22,
      MediaQuery.textScalerOf(context).scale(11.5) * 1.3 + 6,
    ),
    child: ClipRect(
      child: Wrap(
        spacing: CoachSpace.x1,
        clipBehavior: Clip.hardEdge,
        children: [
          for (final t in tags)
            DecoratedBox(
              decoration: ShapeDecoration(
                color: CoachUiTheme.of(context).colors.text.withValues(
                  alpha: CoachUiTheme.of(context).colors.isDark ? .10 : .06,
                ),
                shape: const StadiumBorder(),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Text(
                  t,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.3,
                    fontWeight: FontWeight.w500,
                    color: CoachUiTheme.of(context).colors.muted,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// A set, folded: the first move as the hero, the other moves as a strip
/// of thumbnails under it. The card lays the title + meta and the ▶ over
/// it, and as it unfolds flies the hero into row 1 and the thumbnails into
/// rows 2… ([hero] / [thumbs] / [chip] hide them meanwhile).
class _SetBody extends StatelessWidget {
  const _SetBody({
    required this.cover,
    required this.shown,
    required this.more,
    required this.thumbs,
    required this.hero,
    required this.chip,
    this.landing = false,
    this.still = false,
    this.cutoutBounds,
  });
  final bool still;
  final CoachExercise? cover;
  final List<CoachExercise?> shown;
  final int more;
  final Animation<double> thumbs;
  final Animation<double> hero;
  final Animation<double> chip;
  final bool landing;
  final Rect? cutoutBounds;

  static const stripHeight = 52.0;
  static const stripTop = 6.0;
  static const thumb = 36.0;
  static const gap = 6.0;

  /// Room under a cutout hero for the title + meta laid over the card.
  static const fusedTitleRoom = 50.0;

  /// Slots in the strip for a card content width (the last one turns
  /// into +N when some moves don't fit).
  static int fitCount(double width) {
    final room =
        width - CoachSpace.x1 - CoachStartButton.reserve - CoachSpace.x1;
    return ((room + gap) / (thumb + gap)).floor().clamp(1, 99);
  }

  @override
  Widget build(BuildContext context) {
    final cover = this.cover;
    // A keyed figure stands straight on the glass: no stage box, no scrim,
    // the title in the page's own ink under it.
    final fused = (cover?.cutout != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: PaintReveal(
            key: const ValueKey('plan-hero'),
            progress: hero,
            child: fused
                ? cutoutBounds != null
                      ? Stack(
                          fit: StackFit.expand,
                          clipBehavior: Clip.none,
                          children: [
                            Positioned.fromRect(
                              rect: cutoutBounds!,
                              child: _Media(
                                exercise: cover,
                                landing: landing,
                                cutout: true,
                                still: still,
                                cutoutAlignment: Alignment.topCenter,
                              ),
                            ),
                          ],
                        )
                      : Padding(
                          padding: const EdgeInsets.fromLTRB(
                            CoachSpace.x4,
                            CoachSpace.x1,
                            CoachSpace.x4,
                            fusedTitleRoom,
                          ),
                          child: _Media(
                            exercise: cover,
                            landing: landing,
                            cutout: true,
                            still: still,
                          ),
                        )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(CoachRadius.lg - 6),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _Media(exercise: cover, landing: landing),
                        _heroScrim(
                          cover?.stage ?? CoachUiTheme.of(context).colors.stage,
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        SizedBox(
          height: stripHeight,
          child: Padding(
            padding: const EdgeInsets.only(top: stripTop, left: CoachSpace.x1),
            child: Row(
              children: [
                for (final e in shown) ...[
                  PaintReveal(
                    progress: thumbs,
                    child: _Thumb(
                      size: thumb,
                      child: _Media(exercise: e),
                    ),
                  ),
                  const SizedBox(width: gap),
                ],
                if (more > 0)
                  PaintReveal(
                    progress: chip,
                    child: _Thumb(
                      size: thumb,
                      child: ColoredBox(
                        color: CoachUiTheme.of(context).colors.text.withValues(
                          alpha: CoachUiTheme.of(context).colors.isDark
                              ? .12
                              : .07,
                        ),
                        child: Center(
                          child: Text(
                            '+$more',
                            style: CoachUiTheme.of(context).typography.label
                                .copyWith(
                                  fontWeight: FontWeight.w600,
                                  fontFeatures: CoachUiTypography.tabular,
                                ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Lower scrim over a boxed hero: transparent → stage, under the title.
Widget _heroScrim(CoachMediaPalette stage, {double strength = 1}) =>
    DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [.35, 1],
          colors: [
            stage.mediaStage.withValues(alpha: 0),
            stage.mediaStage.withValues(alpha: .92 * strength.clamp(0.0, 1.0)),
          ],
        ),
      ),
    );

class _HeroTitle extends StatelessWidget {
  const _HeroTitle({
    required this.title,
    required this.meta,
    required this.titleColor,
    required this.metaColor,
  });
  final String title;
  final String meta;
  final Color titleColor;
  final Color metaColor;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: titleColor,
          fontSize: 19,
          height: 1.25,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        meta,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: metaColor,
          fontSize: 13,
          height: 1.35,
          fontWeight: FontWeight.w500,
        ),
      ),
    ],
  );
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.size, required this.child});
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(CoachRadius.xs + 2),
    child: SizedBox.square(dimension: size, child: child),
  );
}

/// The effective typography used by both paragraph measurement and Text.
/// Keep accessibility spacing, inherited font metrics and nonlinear scaling
/// identical so changing the host theme cannot invalidate the media paths.
class _MoveRowTypography {
  _MoveRowTypography._({
    required this.name,
    required this.dose,
    required this.index,
    required this.scaler,
    required this.direction,
    required this.locale,
    required this.heightBehavior,
    required this.widthBasis,
    required this.align,
  });

  factory _MoveRowTypography.of(BuildContext context) {
    final theme = CoachUiTheme.of(context);
    final defaults = DefaultTextStyle.of(context);
    TextStyle effective(TextStyle style) {
      var result = style.inherit ? defaults.style.merge(style) : style;
      if (MediaQuery.boldTextOf(context)) {
        result = result.copyWith(fontWeight: FontWeight.bold);
      }
      return result
          .merge(
            TextStyle(
              height: MediaQuery.maybeLineHeightScaleFactorOverrideOf(context),
              letterSpacing: MediaQuery.maybeLetterSpacingOverrideOf(context),
              wordSpacing: MediaQuery.maybeWordSpacingOverrideOf(context),
            ),
          )
          .copyWith(inherit: false);
    }

    final label = effective(
      theme.typography.label.copyWith(fontFeatures: CoachUiTypography.tabular),
    );
    return _MoveRowTypography._(
      name: effective(theme.typography.callout),
      dose: label,
      index: label.copyWith(color: theme.colors.muted),
      scaler: MediaQuery.textScalerOf(context),
      direction: Directionality.of(context),
      locale: Localizations.maybeLocaleOf(context),
      heightBehavior:
          defaults.textHeightBehavior ??
          DefaultTextHeightBehavior.maybeOf(context),
      widthBasis: defaults.textWidthBasis,
      align: defaults.textAlign ?? TextAlign.start,
    );
  }

  final TextStyle name, dose, index;
  final TextScaler scaler;
  final TextDirection direction;
  final Locale? locale;
  final TextHeightBehavior? heightBehavior;
  final TextWidthBasis widthBasis;
  final TextAlign align;

  Size measure(
    String value,
    TextStyle style, {
    double width = double.infinity,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      textDirection: direction,
      textAlign: align,
      textScaler: scaler,
      locale: locale,
      textHeightBehavior: heightBehavior,
      textWidthBasis: widthBasis,
    )..layout(maxWidth: width);
    final size = painter.size;
    painter.dispose();
    return size;
  }

  Text text(String value, TextStyle style, {Key? key, int? maxLines}) => Text(
    value,
    key: key,
    style: style,
    textScaler: scaler,
    textDirection: direction,
    textAlign: align,
    locale: locale,
    textHeightBehavior: heightBehavior,
    textWidthBasis: widthBasis,
    maxLines: maxLines,
    softWrap: true,
    overflow: TextOverflow.visible,
  );
}

/// One immutable layout decision feeds the actual row and every animation
/// calculation. Short doses retain the original single-line 48 px row; when
/// two complete labels do not fit side by side, the dose gets the full text
/// column below the name and wraps without a line limit.
class _MoveRowLayout {
  const _MoveRowLayout._({
    required this.type,
    required this.width,
    required this.indexWidth,
    required this.textWidth,
    required this.doseWidth,
    required this.bodyHeight,
    required this.indexSize,
    required this.height,
    required this.stacked,
  });

  factory _MoveRowLayout.measure({
    required _MoveRowTypography type,
    required String index,
    required String name,
    required String dose,
    required double width,
    required double indexWidth,
  }) {
    final textWidth = math.max(
      1.0,
      width - indexWidth - _MoveRow.thumbSize - CoachSpace.x3,
    );
    final naturalName = type.measure(name, type.name);
    final naturalDose = type.measure(dose, type.dose);
    final doseWidth = naturalDose.width.ceilToDouble();
    final stacked = naturalName.width + CoachSpace.x2 + doseWidth > textWidth;
    final nameSize = type.measure(
      name,
      type.name,
      width: stacked ? textWidth : textWidth - doseWidth - CoachSpace.x2,
    );
    final doseSize = type.measure(
      dose,
      type.dose,
      width: stacked ? textWidth : doseWidth,
    );
    final bodyHeight = stacked
        ? nameSize.height + CoachSpace.x1 + doseSize.height
        : math.max(nameSize.height, doseSize.height);
    final indexSize = type.measure(index, type.index, width: indexWidth);
    final contentHeight = math.max(
      _MoveRow.thumbSize,
      math.max(bodyHeight, indexSize.height),
    );
    return _MoveRowLayout._(
      type: type,
      width: width,
      indexWidth: indexWidth,
      textWidth: textWidth,
      doseWidth: doseWidth,
      bodyHeight: bodyHeight,
      indexSize: indexSize,
      height: math.max(_MoveRow.minHeight, contentHeight + 8).ceilToDouble(),
      stacked: stacked,
    );
  }

  final _MoveRowTypography type;
  final double width, indexWidth, textWidth, doseWidth, bodyHeight, height;
  final Size indexSize;
  final bool stacked;
  double get thumbTop => (height - _MoveRow.thumbSize) / 2;
  double get thumbLeft => type.direction == TextDirection.ltr
      ? indexWidth
      : width - indexWidth - _MoveRow.thumbSize;

  /// Include the full 8 px entrance translation while text is fading in.
  Rect get textBand => Rect.fromLTWH(
    type.direction == TextDirection.ltr
        ? indexWidth + _MoveRow.thumbSize + CoachSpace.x3
        : 0,
    (height - bodyHeight) / 2,
    textWidth,
    bodyHeight + 8,
  );
  Rect get indexBand => Rect.fromLTWH(
    type.direction == TextDirection.ltr ? 0 : width - indexSize.width,
    (height - indexSize.height) / 2,
    indexSize.width,
    indexSize.height + 8,
  );
}

class _MoveRow extends StatelessWidget {
  const _MoveRow({
    super.key,
    required this.index,
    required this.layout,
    required this.item,
    required this.exercise,
    required this.text,
    required this.thumb,
    required this.reduced,
  });
  final int index;
  final _MoveRowLayout layout;
  final CoachRoutineItem item;
  final CoachExercise? exercise;

  /// The number, name and dose arriving (after the thumbnail lands).
  final Animation<double> text;

  /// The row's own thumbnail (hidden while its flyer is in the air).
  final Animation<double> thumb;
  final bool reduced;

  static const minHeight = 48.0;
  static const indexWidth = 20.0;
  static const thumbSize = 40.0;
  static const radius = (CoachRadius.xs + 2) * thumbSize / _SetBody.thumb;

  /// The row's thumbnail (also what flies in from the strip / the hero).
  static Widget thumbFor(CoachExercise? e, {Key? key}) => ClipRRect(
    key: key,
    borderRadius: BorderRadius.circular(radius),
    child: SizedBox.square(
      dimension: thumbSize,
      child: _Media(exercise: e),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final type = layout.type;
    final name = type.text(
      exercise?.name ?? item.exerciseId,
      type.name,
      key: ValueKey('plan-name-$index'),
    );
    final dose = type.text(
      item.doseText(),
      type.dose,
      key: ValueKey('plan-dose-$index'),
    );
    final body = layout.stacked
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              name,
              const SizedBox(height: CoachSpace.x1),
              dose,
            ],
          )
        : Row(
            children: [
              Expanded(child: name),
              const SizedBox(width: CoachSpace.x2),
              SizedBox(width: layout.doseWidth, child: dose),
            ],
          );
    return SizedBox(
      height: layout.height,
      child: DefaultTextStyle(
        // The dose must remain unlimited even inside a host's single-line
        // text scope. Its resolved styles and metrics come from [layout].
        style: DefaultTextStyle.of(context).style,
        softWrap: true,
        overflow: TextOverflow.visible,
        child: Row(
          children: [
            _rowIn(
              anim: text,
              reduced: reduced,
              child: SizedBox(
                width: layout.indexWidth,
                child: Align(
                  heightFactor: 1,
                  alignment: AlignmentDirectional.centerStart,
                  child: type.text('$index', type.index, maxLines: 1),
                ),
              ),
            ),
            PaintReveal(
              progress: thumb,
              child: thumbFor(exercise, key: ValueKey('plan-row-thumb-$index')),
            ),
            const SizedBox(width: CoachSpace.x3),
            Expanded(
              child: _rowIn(
                key: const ValueKey('row-text'),
                anim: text,
                reduced: reduced,
                child: body,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
