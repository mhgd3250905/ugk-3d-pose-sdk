part of 'plan_card.dart';

/// A single plan surface. Supplying [header], [collapsedSummary] or [onToggle]
/// enables the persistent-header card used by a host's plan collection.
/// Without these optional slots, the expanded-only presentation stays valid.
///
/// The shell never fades. Only summary/body/collapse controls animate; the host
/// continues to own [expanded]. All styling uses the existing plan theme.
class CoachPlanExpanded extends StatefulWidget {
  const CoachPlanExpanded({
    super.key,
    required this.plan,
    required this.library,
    required this.expanded,
    required this.onCollapse,
    required this.onStart,
    this.header,
    this.collapsedSummary,
    this.onToggle,
    this.actionIcon = CoachGlyph.bookmark,
    this.actionLabel,
    this.onAction,
  }) : _dialogCanvas = null,
       _dialogWidth = null;

  // The original conversation canvas projects its media flights into the same
  // single shell. It does not own or return another card surface.
  const CoachPlanExpanded._dialog({
    required this.plan,
    required this.library,
    required this.expanded,
    required this.onCollapse,
    required this.onStart,
    required this.onAction,
    required double width,
    required Widget canvas,
  }) : header = null,
       collapsedSummary = null,
       onToggle = null,
       actionIcon = CoachGlyph.bookmark,
       actionLabel = null,
       _dialogCanvas = canvas,
       _dialogWidth = width;

  final CoachRoutine plan;
  final CoachExerciseLibrary library;
  final bool expanded;
  final VoidCallback onCollapse;
  final void Function(CoachOriginRect from) onStart;
  final Widget? header;
  final Widget? collapsedSummary;
  final VoidCallback? onToggle;
  final CoachGlyph? actionIcon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Widget? _dialogCanvas;
  final double? _dialogWidth;

  @override
  State<CoachPlanExpanded> createState() => _CoachPlanExpandedState();
}

abstract final class _PlanCardMotion {
  static const size = Duration(milliseconds: 280);
  static const enterDelay = Duration(milliseconds: 60);
  static const enter = Duration(milliseconds: 180);
  static const exit = Duration(milliseconds: 120);
  static const summaryDelay = Duration(milliseconds: 160);
  static const curve = Curves.easeOutCubic;
}

class _CoachPlanExpandedState extends State<CoachPlanExpanded>
    with TickerProviderStateMixin {
  final _bounds = GlobalKey();
  late final _body = AnimationController(
    vsync: this,
    value: widget.expanded ? 1 : 0,
  );
  late final _slide = AnimationController(
    vsync: this,
    value: widget.expanded ? 1 : 0,
  );
  late final _summary = AnimationController(
    vsync: this,
    value: widget.expanded ? 0 : 1,
  );
  late final _collapse = AnimationController(
    vsync: this,
    value: widget.expanded ? 1 : 0,
  );
  Timer? _bodyDelay;
  Timer? _summaryDelay;
  bool _summaryInteractive = false;
  Widget? _defaultHeader;
  CoachRoutine? _headerPlan;

  bool get _slots =>
      widget.header != null ||
      widget.collapsedSummary != null ||
      widget.onToggle != null;

  @override
  void initState() {
    super.initState();
    _summaryInteractive = !widget.expanded;
  }

  @override
  void didUpdateWidget(CoachPlanExpanded oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget._dialogCanvas == null && oldWidget.expanded != widget.expanded) {
      _animate();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _defaultHeader = null;
    if (widget._dialogCanvas == null && CoachMotion.reduced(context)) {
      _cancelDelays();
      _body.value = _slide.value = _collapse.value = widget.expanded ? 1 : 0;
      _summary.value = widget.expanded ? 0 : 1;
      _summaryInteractive = !widget.expanded;
    }
  }

  void _cancelDelays() {
    _bodyDelay?.cancel();
    _summaryDelay?.cancel();
    _bodyDelay = _summaryDelay = null;
  }

  void _animate() {
    _cancelDelays();
    final opening = widget.expanded;
    _summaryInteractive = false;
    if (CoachMotion.reduced(context)) {
      _body.value = _slide.value = _collapse.value = opening ? 1 : 0;
      _summary.value = opening ? 0 : 1;
      _summaryInteractive = !opening;
      return;
    }
    _collapse.animateTo(opening ? 1 : 0, duration: _PlanCardMotion.exit);
    _body.stop();
    _slide.stop();
    _summary.stop();
    if (opening) {
      _summary.animateTo(0, duration: _PlanCardMotion.exit);
      _bodyDelay = Timer(_PlanCardMotion.enterDelay, () {
        if (!mounted || !widget.expanded) return;
        _body.animateTo(1, duration: _PlanCardMotion.enter);
        _slide.animateTo(
          1,
          duration: _PlanCardMotion.enter,
          curve: _PlanCardMotion.curve,
        );
      });
    } else {
      _body.animateTo(0, duration: _PlanCardMotion.exit).whenCompleteOrCancel(
        () {
          if (mounted && !widget.expanded && _body.value == 0) _slide.value = 0;
        },
      );
      _summaryDelay = Timer(_PlanCardMotion.summaryDelay, () {
        if (!mounted || widget.expanded) return;
        setState(() => _summaryInteractive = true);
        _summary.animateTo(1, duration: _PlanCardMotion.exit);
      });
    }
  }

  @override
  void dispose() {
    _cancelDelays();
    if (widget._dialogCanvas == null) {
      _body.dispose();
      _slide.dispose();
      _summary.dispose();
      _collapse.dispose();
    }
    super.dispose();
  }

  Widget _size(Widget child) {
    if (CoachMotion.reduced(context)) return child;
    return AnimatedSize(
      key: const ValueKey('plan-expanded-size'),
      duration: _PlanCardMotion.size,
      reverseDuration: _PlanCardMotion.size,
      curve: _PlanCardMotion.curve,
      alignment: Alignment.topCenter,
      clipBehavior: Clip.hardEdge,
      child: child,
    );
  }

  Widget _shell(double width, Widget child) => CoachCardSurface(
    key: const ValueKey('plan-expanded-shell'),
    width: width,
    radius: 20,
    padding: const EdgeInsets.all(_PlanCardState._inset),
    child: ClipRRect(
      key: const ValueKey('plan-expanded-clip'),
      borderRadius: BorderRadius.circular(20),
      clipper: const _PlanSurfaceClip(),
      clipBehavior: Clip.hardEdge,
      child: Material(
        type: MaterialType.transparency,
        textStyle: DefaultTextStyle.of(context).style,
        child: child,
      ),
    ),
  );

  Widget _inactive({required bool inactive, required Widget child}) =>
      ExcludeFocus(
        excluding: inactive,
        child: IgnorePointer(
          ignoring: inactive,
          child: ExcludeSemantics(excluding: inactive, child: child),
        ),
      );

  void _collapseRequested() => widget.onCollapse();

  Widget _collapseControl() => AnimatedBuilder(
    animation: _collapse,
    builder: (context, child) => _inactive(
      inactive: !widget.expanded || _collapse.value == 0,
      child: child!,
    ),
    child: FadeTransition(
      key: const ValueKey('plan-expanded-collapse-fade'),
      opacity: _collapse,
      child: _ExpandToggle(
        key: ValueKey('plan-expand-${widget.plan.id}'),
        expanded: true,
        turns: kAlwaysCompleteAnimation,
        onMedia: false,
        onTap: _collapseRequested,
      ),
    ),
  );

  Widget _header(double headerHeight, double titleHeight) {
    final control = _collapseControl();
    Widget content;
    if (widget.header case final header?) {
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: header),
          const SizedBox(width: CoachSpace.x3),
          control,
        ],
      );
    } else {
      if (_defaultHeader == null || _headerPlan != widget.plan) {
        _headerPlan = widget.plan;
        _defaultHeader = _Header(
          key: const ValueKey('plan-header'),
          height: headerHeight,
          titleLineHeight: titleHeight,
          surfaceTopInset: 0,
          title: widget.plan.title,
          meta: widget.plan.metaLabel,
          openKey: ValueKey('plan-open-${widget.plan.id}'),
          onOpen: null,
          progress: kAlwaysCompleteAnimation,
          fade: kAlwaysCompleteAnimation,
          reduced: false,
          toggle: control,
        );
      }
      content = _defaultHeader!;
    }
    return InkWell(
      key: const ValueKey('plan-expanded-header'),
      onTap: widget.onToggle,
      child: content,
    );
  }

  Widget _summarySlot() => AnimatedBuilder(
    animation: _summary,
    builder: (context, child) => _inactive(
      inactive: widget.expanded || !_summaryInteractive || _summary.value == 0,
      child: child!,
    ),
    child: FadeTransition(
      key: const ValueKey('plan-expanded-summary-fade'),
      opacity: _summary,
      child: InkWell(
        key: const ValueKey('plan-expanded-summary'),
        onTap: widget.onToggle,
        child: widget.collapsedSummary ?? const SizedBox.shrink(),
      ),
    ),
  );

  Widget _expandedBody(Widget body) => AnimatedBuilder(
    animation: _body,
    builder: (context, child) => _inactive(
      inactive: !widget.expanded || _body.value == 0,
      child: child!,
    ),
    child: AnimatedBuilder(
      animation: _slide,
      builder: (context, child) => Transform.translate(
        key: const ValueKey('plan-expanded-motion'),
        offset: Offset(0, -8 * (1 - _slide.value)),
        child: child,
      ),
      child: FadeTransition(
        key: const ValueKey('plan-expanded-fade'),
        opacity: _body,
        child: body,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (widget._dialogCanvas case final canvas?) {
      // A continuously changing legacy media canvas is followed by AnimatedSize
      // without an additional trailing height animation.
      return _shell(
        widget._dialogWidth!,
        _FollowCanvasSize(child: _size(canvas)),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final preferred = (MediaQuery.sizeOf(context).width - 32).clamp(
          280.0,
          400.0,
        );
        final width = constraints.hasBoundedWidth
            ? math.min(preferred, constraints.maxWidth)
            : preferred;
        final innerWidth = width - _PlanCardState._inset * 2;
        final titleHeight = _Header.lineHeight(
          context,
          widget.plan.title,
          _Header.titleStyle,
        );
        final headerHeight = _Header.heightFor(
          context,
          titleHeight,
          widget.plan.metaLabel,
          0,
        );
        final rows = _measurePlanRows(
          widget.plan,
          widget.library,
          _MoveRowTypography.of(context),
          innerWidth - _Details.pad * 2,
        );
        final details = _PlanExpandedDetails(
          plan: widget.plan,
          library: widget.library,
          onAction: widget.onAction,
          actionIcon: widget.actionIcon,
          actionLabel: widget.actionLabel,
          dialog: _PlanExpandedDialog(
            progress: kAlwaysCompleteAnimation,
            height: kAlwaysCompleteAnimation,
            fade: kAlwaysCompleteAnimation,
            reduced: false,
            clip: false,
            topPad: 0,
            header: _slots ? null : SizedBox(height: headerHeight),
            rows: rows,
            textOf: (_) => kAlwaysCompleteAnimation,
            thumbOf: (_) => kAlwaysCompleteAnimation,
          ),
        );
        final list = Stack(
          children: [
            details,
            if (!_slots)
              Positioned(
                left: 0,
                right: CoachSpace.x1,
                top: 0,
                child: _header(headerHeight, titleHeight),
              ),
            Positioned(
              right: _Details.pad,
              bottom: _Details.footerBottom,
              child: CoachStartButton(
                key: ValueKey('plan-start-${widget.plan.id}'),
                onTap: () =>
                    widget.onStart(() => coachRectOf(_bounds.currentContext)),
              ),
            ),
          ],
        );
        final body = _expandedBody(list);
        final content = _PlanContentLayout(
          expanded: widget.expanded,
          summary: _slots ? _summarySlot() : const SizedBox.shrink(),
          body: _slots ? body : _shell(width, body),
        );
        return SizedBox(
          key: _bounds,
          width: width,
          child: _slots
              ? _shell(
                  width,
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(headerHeight, titleHeight),
                      _size(content),
                    ],
                  ),
                )
              : ClipRect(child: _size(content)),
        );
      },
    );
  }
}

/// The surface supplies its existing 6 px padding. Clip at that surface's
/// actual rounded boundary, so controls can paint inside the padding too.
class _PlanSurfaceClip extends CustomClipper<RRect> {
  const _PlanSurfaceClip();
  @override
  RRect getClip(Size size) => RRect.fromRectAndRadius(
    Rect.fromLTWH(
      -_PlanCardState._inset,
      -_PlanCardState._inset,
      size.width + _PlanCardState._inset * 2,
      size.height + _PlanCardState._inset * 2,
    ),
    const Radius.circular(20),
  );
  @override
  bool shouldReclip(_PlanSurfaceClip oldClipper) => false;
}

/// A legacy canvas already animates its natural height alongside media paths.
/// Give the shared AnimatedSize that exact size, avoiding a second animation
/// when a throttled frame jumps directly to a later point in the media flight.
class _FollowCanvasSize extends SingleChildRenderObjectWidget {
  const _FollowCanvasSize({required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFollowCanvasSize();
}

class _RenderFollowCanvasSize extends RenderProxyBox {
  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(child!.getDryLayout(constraints));
  @override
  void performLayout() {
    final natural = child!.getDryLayout(constraints);
    child!.layout(
      constraints.tighten(width: natural.width, height: natural.height),
      parentUsesSize: true,
    );
    size = child!.size;
  }
}

/// Both content branches remain mounted and measured at natural height. Only
/// the selected branch contributes layout size to AnimatedSize, while the
/// outgoing branch can finish its independent fade without losing state.
class _PlanContentLayout extends MultiChildRenderObjectWidget {
  _PlanContentLayout({
    required this.expanded,
    required Widget summary,
    required Widget body,
  }) : super(children: [summary, body]);
  final bool expanded;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPlanContentLayout(expanded);
  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPlanContentLayout renderObject,
  ) {
    renderObject.expanded = expanded;
  }
}

class _PlanContentParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderPlanContentLayout extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PlanContentParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PlanContentParentData> {
  _RenderPlanContentLayout(this._expanded);
  bool _expanded;
  set expanded(bool value) {
    if (_expanded == value) return;
    _expanded = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PlanContentParentData) {
      child.parentData = _PlanContentParentData();
    }
  }

  BoxConstraints _inner(BoxConstraints c) =>
      c.copyWith(minHeight: 0, maxHeight: double.infinity);
  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = _expanded ? lastChild! : firstChild!;
    return constraints.constrain(child.getDryLayout(_inner(constraints)));
  }

  @override
  void performLayout() {
    var child = firstChild;
    while (child != null) {
      child.layout(_inner(constraints), parentUsesSize: true);
      final data = child.parentData! as _PlanContentParentData;
      data.offset = Offset.zero;
      child = data.nextSibling;
    }
    size = constraints.constrain((_expanded ? lastChild! : firstChild!).size);
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _PlanExpandedDetails extends StatelessWidget {
  const _PlanExpandedDetails({
    required this.plan,
    required this.library,
    required this.onAction,
    required this.dialog,
    this.actionIcon = CoachGlyph.bookmark,
    this.actionLabel,
  });
  final CoachRoutine plan;
  final CoachExerciseLibrary library;
  final VoidCallback? onAction;
  final _PlanExpandedDialog dialog;
  final CoachGlyph? actionIcon;
  final String? actionLabel;
  @override
  Widget build(BuildContext context) {
    final layout = dialog;
    final plan = this.plan;
    final style = CoachUiTheme.of(context);
    final cues = layout.cues;
    return _Details(
      t: layout.progress,
      height: layout.height,
      fade: layout.fade,
      reduced: layout.reduced,
      clip: layout.clip,
      topPad: layout.topPad,
      header: layout.header,
      rows: [
        if (cues != null)
          for (final (i, cue) in cues.indexed)
            _CueRow(
              index: i + 1,
              text: cue,
              anim: layout.textOf(i),
              reduced: layout.reduced,
            )
        else
          for (var i = 0; i < plan.items.length; i++)
            _MoveRow(
              key: ValueKey('plan-row-$i'),
              index: i + 1,
              layout: layout.rows[i],
              item: CoachRoutineItem(
                exerciseId: plan.items[i].exerciseId,
                dose: plan.items[i].detailDose,
              ),
              exercise: library.tryGet(plan.items[i].exerciseId),
              text: layout.textOf(i),
              thumb: layout.thumbOf(i),
              reduced: layout.reduced,
            ),
      ],
      note: plan.adjustmentsLabel,
      footer: Row(
        children: [
          CoachTextAction(
            key: ValueKey('plan-save-${plan.id}'),
            icon: actionIcon,
            iconFilled: layout.saved,
            color: layout.saved ? style.colors.accentText : style.colors.text,
            label: layout.saved
                ? style.strings.saved
                : actionLabel ?? style.strings.save,
            onPressed: layout.saved ? null : onAction,
            boxed: true,
          ),
          const Spacer(),
          const SizedBox(width: CoachStartButton.size),
        ],
      ),
    );
  }
}

/// Private projections of the dialogue's existing media-flight timeline.
class _PlanExpandedDialog {
  const _PlanExpandedDialog({
    required this.progress,
    required this.height,
    required this.fade,
    required this.reduced,
    required this.clip,
    required this.topPad,
    required this.header,
    required this.rows,
    required this.textOf,
    required this.thumbOf,
    this.cues,
    this.saved = false,
  });
  final Animation<double> progress, height, fade;
  final bool reduced, clip, saved;
  final double topPad;
  final Widget? header;
  final List<_MoveRowLayout> rows;
  final Animation<double> Function(int index) textOf, thumbOf;
  final List<String>? cues;
}

List<_MoveRowLayout> _measurePlanRows(
  CoachRoutine plan,
  CoachExerciseLibrary library,
  _MoveRowTypography type,
  double width,
) {
  var indexWidth = _MoveRow.indexWidth;
  for (var i = 0; i < plan.items.length; i++) {
    indexWidth = math.max(
      indexWidth,
      type.measure('${i + 1}', type.index).width.ceilToDouble() + 4,
    );
  }
  return [
    for (var i = 0; i < plan.items.length; i++)
      _MoveRowLayout.measure(
        type: type,
        index: '${i + 1}',
        name:
            library.tryGet(plan.items[i].exerciseId)?.name ??
            plan.items[i].exerciseId,
        dose: plan.items[i].detailDose,
        width: width,
        indexWidth: indexWidth,
      ),
  ];
}
