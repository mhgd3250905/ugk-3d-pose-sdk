part of 'plan_card.dart';

/// The reusable, expanded plan card: numbered moves with their trusted
/// thumbnails and complete doses, collapse, a left action and one start button.
///
/// Names and assets come from [library], never from model-supplied paths.
/// [expanded] is controlled by the host; height animates for 280 ms with
/// easeOutCubic, and content fades during the first 180 ms. Initially expanded
/// content is immediately visible. A collapsed widget occupies no height and
/// exposes no interactive or semantic controls.
///
/// The left action defaults to the theme's Save label and bookmark icon. Its
/// callback may be omitted to leave it disabled. Colours, typography, media and
/// surfaces use the same [CoachUiTheme] and builders as [CoachPlanCard].
class CoachPlanExpanded extends StatefulWidget {
  const CoachPlanExpanded({
    super.key,
    required this.plan,
    required this.library,
    required this.expanded,
    required this.onCollapse,
    required this.onStart,
    this.actionIcon = CoachGlyph.bookmark,
    this.actionLabel,
    this.onAction,
  }) : _dialogLayout = null;

  // Dialogue cards retain their existing media-flight choreography. Keeping
  // the adapter private avoids exposing presentation/animation knobs to hosts.
  const CoachPlanExpanded._dialog({
    required this.plan,
    required this.library,
    required this.expanded,
    required this.onCollapse,
    required this.onStart,
    required this.onAction,
    required _PlanExpandedDialog dialog,
  }) : _dialogLayout = dialog,
       actionIcon = CoachGlyph.bookmark,
       actionLabel = null;

  final CoachRoutine plan;
  final CoachExerciseLibrary library;
  final bool expanded;
  final VoidCallback onCollapse;
  final void Function(CoachOriginRect from) onStart;
  final CoachGlyph? actionIcon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final _PlanExpandedDialog? _dialogLayout;

  @override
  State<CoachPlanExpanded> createState() => _CoachPlanExpandedState();
}

class _CoachPlanExpandedState extends State<CoachPlanExpanded>
    with TickerProviderStateMixin {
  final _bounds = GlobalKey();
  late final _height = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    value: widget.expanded ? 1 : 0,
  );
  late final _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: widget.expanded ? 1 : 0,
  );

  @override
  void didUpdateWidget(CoachPlanExpanded oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget._dialogLayout != null || oldWidget.expanded == widget.expanded) {
      return;
    }
    _animate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget._dialogLayout == null && CoachMotion.reduced(context)) {
      _height.value = widget.expanded ? 1 : 0;
      _fade.value = widget.expanded ? 1 : 0;
    }
  }

  void _animate() {
    final target = widget.expanded ? 1.0 : 0.0;
    if (CoachMotion.reduced(context)) {
      _height.value = target;
      _fade.value = target;
    } else {
      _height.animateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      _fade.animateTo(target, duration: const Duration(milliseconds: 180));
    }
  }

  @override
  void dispose() {
    if (widget._dialogLayout == null) {
      _height.dispose();
      _fade.dispose();
    }
    super.dispose();
  }

  Widget _details(BuildContext context, _PlanExpandedDialog layout) {
    final plan = widget.plan;
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
              exercise: widget.library.tryGet(plan.items[i].exerciseId),
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
            icon: widget.actionIcon,
            iconFilled: layout.saved,
            color: layout.saved ? style.colors.accentText : style.colors.text,
            label: layout.saved
                ? style.strings.saved
                : widget.actionLabel ?? style.strings.save,
            onPressed: layout.saved ? null : widget.onAction,
            boxed: true,
          ),
          const Spacer(),
          const SizedBox(width: CoachStartButton.size),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget._dialogLayout case final layout?) {
      return _details(context, layout);
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
        final body = _details(
          context,
          _PlanExpandedDialog(
            progress: kAlwaysCompleteAnimation,
            height: kAlwaysCompleteAnimation,
            fade: kAlwaysCompleteAnimation,
            reduced: false,
            clip: false,
            topPad: 0,
            header: SizedBox(height: headerHeight),
            rows: rows,
            textOf: (_) => kAlwaysCompleteAnimation,
            thumbOf: (_) => kAlwaysCompleteAnimation,
          ),
        );
        return SizedBox(
          key: _bounds,
          width: width,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _height,
              builder: (context, child) => Align(
                alignment: Alignment.topCenter,
                heightFactor: _height.value,
                child: child,
              ),
              child: ExcludeFocus(
                excluding: !widget.expanded,
                child: IgnorePointer(
                  ignoring: !widget.expanded,
                  child: ExcludeSemantics(
                    excluding: !widget.expanded,
                    child: FadeTransition(
                      key: const ValueKey('plan-expanded-fade'),
                      opacity: _fade,
                      child: CoachCardSurface(
                        width: width,
                        padding: const EdgeInsets.all(_PlanCardState._inset),
                        child: Stack(
                          children: [
                            body,
                            Positioned(
                              left: 0,
                              right: CoachSpace.x1,
                              top: 0,
                              child: _Header(
                                key: const ValueKey('plan-header'),
                                height: headerHeight,
                                titleLineHeight: titleHeight,
                                surfaceTopInset: 0,
                                title: widget.plan.title,
                                meta: widget.plan.metaLabel,
                                openKey: ValueKey(
                                  'plan-open-${widget.plan.id}',
                                ),
                                onOpen: null,
                                progress: kAlwaysCompleteAnimation,
                                fade: kAlwaysCompleteAnimation,
                                reduced: false,
                                toggle: _ExpandToggle(
                                  key: ValueKey(
                                    'plan-expand-${widget.plan.id}',
                                  ),
                                  expanded: true,
                                  turns: kAlwaysCompleteAnimation,
                                  onMedia: false,
                                  onTap: widget.onCollapse,
                                ),
                              ),
                            ),
                            Positioned(
                              right: _Details.pad,
                              bottom: _Details.footerBottom,
                              child: CoachStartButton(
                                key: ValueKey('plan-start-${widget.plan.id}'),
                                onTap: () => widget.onStart(
                                  () => coachRectOf(_bounds.currentContext),
                                ),
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
        );
      },
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
