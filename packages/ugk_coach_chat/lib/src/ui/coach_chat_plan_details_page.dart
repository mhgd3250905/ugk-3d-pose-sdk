import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;

import '../core/chat_controller.dart';
import '../core/chat_models.dart';
import '../theme/chat_controls.dart';
import '../theme/chat_guide_tokens.dart';
import '../theme/chat_surface.dart';
import '../theme/chat_theme.dart';
import '../theme/chat_tokens.dart';
import 'coach_ui_adapter.dart';
import 'guide_preview.dart';
import 'plan_details_controls.dart';

/// Opens the same article for a currently admitted conversation card.
Future<void> openCoachChatPlanDetails(
  BuildContext context,
  CoachChatController controller,
  ChatMessage message, {
  coach.TrainingPlan? planOverride,
}) async {
  await controller.start();
  if (!context.mounted) return;
  final plan = planOverride ?? message.plan ?? message.validatedPlan?.plan;
  if (plan == null) return;
  final admitted = controller.agent
      .gateFor(controller.catalog)
      .admitTraining(plan, context: message.request ?? requestForPlan(plan));
  if (admitted == null) {
    showChatSolidToast(
      context,
      '计划包含尚未可用的动作。已保存计划仍保留。',
      icon: ChatIcon(
        ChatGlyph.info,
        size: 18,
        color: ChatTheme.of(context).colors.accentText,
      ),
    );
    return;
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      settings: const RouteSettings(name: 'plan'),
      builder: (_) => CoachChatPlanDetailsPage(
        controller: controller,
        plan: CoachChatPlanReference(
          admittedPlan: admitted,
          messageId: message.id,
        ),
      ),
    ),
  );
}

/// Original sectioned article, sharing the controller's catalogue and player.
class CoachChatPlanDetailsPage extends StatelessWidget {
  const CoachChatPlanDetailsPage({
    super.key,
    required this.controller,
    required this.plan,
  });
  final CoachChatController controller;
  final CoachChatPlanReference plan;

  @override
  Widget build(BuildContext context) => CoachChatTheme(
    visual: controller.profile.visual,
    executionTiming: controller.profile.executionTiming,
    doseUnitLabels: {
      for (final entry in controller.profile.doseOverrides.entries)
        if (entry.value.unitLabel != null) entry.key: entry.value.unitLabel!,
    },
    child: _CoachChatPlanDetailsBody(controller: controller, reference: plan),
  );
}

class _CoachChatPlanDetailsBody extends StatefulWidget {
  const _CoachChatPlanDetailsBody({
    required this.controller,
    required this.reference,
  });
  final CoachChatController controller;
  final CoachChatPlanReference reference;
  @override
  State<_CoachChatPlanDetailsBody> createState() => _PlanPageState();
}

class _PlanPageState extends State<_CoachChatPlanDetailsBody>
    with WidgetsBindingObserver {
  late coach.TrainingPlan _plan = widget.reference.plan;
  CoachChatController get _controller => widget.controller;
  ChatMessage? get _sourceMessage => _controller.messages
      .where((message) => message.id == widget.reference.messageId)
      .firstOrNull;
  coach.CoachContext get _request =>
      _sourceMessage?.request ?? requestForPlan(_plan);
  ChatMessage get _trainingMessage => ChatMessage(
    id: widget.reference.messageId ?? 'guide-${_plan.id}',
    role: ChatRole.assistant,
    at: _sourceMessage?.at ?? DateTime.now(),
    plan: _plan,
    request: _request,
  );
  final _scroll = ScrollController();
  final _viewport = GlobalKey();
  final _videos = <String, GlobalKey>{};
  final _coordinator = GuidePreviewCoordinator();
  bool _measurementQueued = false;
  String? _releasingSlot;
  bool _previewOn = true;
  bool _starting = false;
  int _launchEpoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_measureAfterLayout);
    _coordinator.addListener(_measureAfterLayout);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final first = _plan.items.firstOrNull?.exerciseId;
    if (first != null) {
      final warm = ChatTheme.of(
        context,
      ).visual.preloadPoster?.call(context, first);
      if (warm != null) unawaited(warm);
    }
    _measureAfterLayout();
  }

  @override
  void didChangeMetrics() => _measureAfterLayout();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _launchEpoch++;
  }

  void _measureAfterLayout() {
    if (_measurementQueued || !mounted) return;
    _measurementQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementQueued = false;
      if (!mounted) return;
      final slot = _coordinator.activeSlot;
      if (slot == null || slot == _releasingSlot) return;
      final viewport = _viewport.currentContext?.findRenderObject();
      if (viewport is! RenderBox || !viewport.hasSize) return;
      final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
      final covered =
          ChatGuideTokens.buttonHeight +
          ChatGuideTokens.buttonBottom +
          MediaQuery.paddingOf(context).bottom;
      final view = Rect.fromLTRB(
        bounds.left,
        bounds.top,
        bounds.right,
        bounds.bottom - covered,
      );
      final box = _videos[slot]?.currentContext?.findRenderObject();
      var visible = 0.0;
      if (box is RenderBox && box.attached && box.hasSize) {
        final rect = box.localToGlobal(Offset.zero) & box.size;
        final area = rect.width * rect.height;
        final intersection = rect.intersect(view);
        if (area > 0 && intersection.width > 0 && intersection.height > 0) {
          visible = intersection.width * intersection.height / area;
        }
      }
      // Only the active media rectangle is measured. Long instructions below
      // it must not keep an offscreen decoder alive.
      if (visible >= .2) return;
      _releasingSlot = slot;
      unawaited(
        _coordinator.release(slot).whenComplete(() {
          if (_releasingSlot == slot) _releasingSlot = null;
        }),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _coordinator.removeListener(_measureAfterLayout);
    _coordinator.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _swap(int bi, int ii) {
    final library = _controller.catalog;
    final item = _plan.blocks[bi].items[ii];
    final exercise = library[item.exerciseId]!;
    final alt = exercise.alternative == null
        ? null
        : library[exercise.alternative!];
    if (alt == null) return;
    final dose = alt.defaultDose;
    final blocks = [..._plan.blocks];
    final items = [...blocks[bi].items];
    items[ii] = coach.PlanItem(
      exerciseId: alt.id,
      mode: dose.mode,
      sets: item.sets,
      reps: dose.mode == coach.DoseMode.reps ? item.reps ?? dose.reps : null,
      workSeconds: dose.mode == coach.DoseMode.time
          ? item.workSeconds ?? dose.seconds
          : null,
      perSide: alt.unilateral,
      restSeconds: item.restSeconds,
      replacedFrom: exercise.id,
    );
    final block = blocks[bi];
    blocks[bi] = coach.PlanBlock(
      id: block.id,
      name: block.name,
      type: block.type,
      rounds: block.rounds,
      restBetweenRoundsSeconds: block.restBetweenRoundsSeconds,
      items: items,
    );
    final updated = _plan.copyWith(
      blocks: blocks,
      notes: [
        ..._plan.notes,
        '手动把「${exercise.name.of(_request.language)}」换成「${alt.name.of(_request.language)}」',
      ],
    );
    final report = coach.PlanValidator(
      catalog: library,
      profile: _controller.agent.profile,
      enforceDrillDoseRange: true,
    ).validate(updated, _request);
    final admitted = _controller.agent.prepareTraining(
      updated,
      context: _request,
    );
    final problem =
        report.errors.firstOrNull?.message ??
        (alt.level > (_request.level ?? _plan.level) + 1 ? '替代动作难度偏高' : null) ??
        (admitted == null ? '这次替换不适合当前计划，请换其他动作' : null);
    if (problem != null) {
      showChatSolidToast(
        context,
        '暂不能替换：$problem',
        icon: ChatIcon(
          ChatGlyph.info,
          size: 18,
          color: ChatTheme.of(context).colors.accentText,
        ),
        bottom: 24,
      );
      return;
    }
    unawaited(_coordinator.release('$bi:$ii'));
    setState(
      () => _plan = updated.copyWith(
        id: '${updated.id.split('~').first}~${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    _measureAfterLayout();
    unawaited(
      _controller.bindings.history
          .rememberStartedPlan(_plan)
          .catchError(
            (Object error) => _controller.bindings.observer?.call(
              'guide.remember.error',
              error,
            ),
          ),
    );
    final preload = ChatTheme.of(context).visual.preloadPoster;
    if (preload != null) {
      for (final id in _plan.exerciseIds) {
        unawaited(preload(context, id));
      }
    }
  }

  Future<void> _startTraining() async {
    if (_starting) return;
    _starting = true;
    final launchEpoch = _launchEpoch;
    try {
      await _controller.startTraining(
        context,
        _trainingMessage,
        sourceEntry: 'guide',
        afterStarting: () async {
          if (!mounted || launchEpoch != _launchEpoch) return false;
          setState(() => _previewOn = false);
          await _coordinator.stop();
          await WidgetsBinding.instance.endOfFrame;
          return mounted && launchEpoch == _launchEpoch;
        },
      );
    } finally {
      if (mounted) {
        setState(() {
          _previewOn = true;
          _starting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = _controller.catalog;
    if (_plan.items.isEmpty ||
        _plan.items.any((item) => !library.contains(item.exerciseId))) {
      return const Scaffold(
        appBar: ChatDetailsTopBar(title: '训练图文'),
        body: Center(child: Text('计划包含尚未可用的动作。已保存计划仍保留。')),
      );
    }
    final rows = _articleRows();
    final rowIndices = {
      for (var index = 0; index < rows.length; index++)
        ValueKey(rows[index].id): index,
    };
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      appBar: const ChatDetailsTopBar(title: '训练图文'),
      body: Stack(
        children: [
          SizedBox.expand(
            key: _viewport,
            child: NotificationListener<SizeChangedLayoutNotification>(
              onNotification: (_) {
                _measureAfterLayout();
                return false;
              },
              child: ListView.builder(
                key: const ValueKey('plan-article'),
                controller: _scroll,
                addAutomaticKeepAlives: false,
                addRepaintBoundaries: false,
                padding: EdgeInsets.fromLTRB(
                  ChatGuideTokens.pageInset,
                  0,
                  ChatGuideTokens.pageInset,
                  ChatGuideTokens.bottomSpace + safeBottom,
                ),
                itemCount: rows.length,
                findChildIndexCallback: (key) => rowIndices[key],
                itemBuilder: (context, index) {
                  final row = rows[index];
                  final child = switch (row.kind) {
                    _GuideRowKind.intro => _intro(library),
                    _GuideRowKind.section => _blockHeader(
                      _plan.blocks[row.block],
                    ),
                    _GuideRowKind.move => _moveArticle(
                      row.block,
                      row.item,
                      row.ordinal,
                      library,
                    ),
                    _GuideRowKind.safetyTitle => _sectionLabel('训练提醒'),
                    _GuideRowKind.safetyNote => Padding(
                      padding: EdgeInsets.only(
                        bottom: row.item < _plan.safetyNotes.length - 1 ? 8 : 0,
                      ),
                      child: Text(
                        row.note,
                        style: ChatGuideTokens.step(context),
                      ),
                    ),
                  };
                  return KeyedSubtree(key: ValueKey(row.id), child: child);
                },
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _trainingBar(safeBottom),
          ),
        ],
      ),
    );
  }

  List<_GuideRow> _articleRows() {
    final rows = <_GuideRow>[const _GuideRow(_GuideRowKind.intro, 'intro')];
    var ordinal = 0;
    for (var bi = 0; bi < _plan.blocks.length; bi++) {
      rows.add(_GuideRow(_GuideRowKind.section, 'section-$bi', block: bi));
      for (var ii = 0; ii < _plan.blocks[bi].items.length; ii++) {
        rows.add(
          _GuideRow(
            _GuideRowKind.move,
            'move-$bi:$ii',
            block: bi,
            item: ii,
            ordinal: ++ordinal,
          ),
        );
      }
    }
    if (_plan.safetyNotes.isNotEmpty) {
      rows.add(const _GuideRow(_GuideRowKind.safetyTitle, 'safety-title'));
      for (var index = 0; index < _plan.safetyNotes.length; index++) {
        rows.add(
          _GuideRow(
            _GuideRowKind.safetyNote,
            'safety-$index',
            item: index,
            note: _plan.safetyNotes[index],
          ),
        );
      }
    }
    return rows;
  }

  Widget _trainingBar(double safeBottom) => Column(
    key: const ValueKey('guide-training-bar'),
    mainAxisSize: MainAxisSize.min,
    children: [
      IgnorePointer(
        child: SizedBox(
          height: ChatGuideTokens.footerFade,
          width: double.infinity,
          child: DecoratedBox(
            key: const ValueKey('guide-training-gradient'),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  ChatTheme.of(context).colors.background.withValues(alpha: 0),
                  ChatTheme.of(context).colors.background,
                ],
              ),
            ),
          ),
        ),
      ),
      ColoredBox(
        color: ChatTheme.of(context).colors.background,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            ChatGuideTokens.pageInset,
            0,
            ChatGuideTokens.pageInset,
            ChatGuideTokens.buttonBottom + safeBottom,
          ),
          child: ChatPressable(
            key: const ValueKey('start'),
            semanticLabel: '前往训练',
            haptic: ChatHaptic.light,
            onTap: () => unawaited(_startTraining()),
            child: Container(
              key: const ValueKey('guide-training-button'),
              height: ChatGuideTokens.buttonHeight,
              decoration: BoxDecoration(
                color: ChatTheme.of(context).colors.accent,
                borderRadius: BorderRadius.circular(
                  ChatGuideTokens.buttonRadius,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ChatIcon(
                    ChatGlyph.play,
                    size: 20,
                    filled: true,
                    color: ChatTheme.of(context).colors.onAccent,
                  ),
                  const SizedBox(width: 8),
                  Text('前往训练', style: ChatGuideTokens.button(context)),
                ],
              ),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _intro(coach.Catalog library) => Column(
    key: const ValueKey('plan-introduction'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        _plan.title,
        key: const ValueKey('guide-title'),
        style: ChatGuideTokens.title(context),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: ChatGuideTokens.tagGap,
        runSpacing: ChatGuideTokens.tagGap,
        children: [
          _tag(
            chatDurationLabel(
              coach
                  .evaluatePlanExecutionTiming(
                    _plan,
                    _controller.profile.executionTiming,
                  )
                  .totalSeconds,
            ),
            0,
          ),
          _tag('${_plan.items.length} 个动作', 1),
          _tag(coach.levelZh(_plan.level), 2),
          _tag(_plan.scene == 'office' ? '办公室' : '居家', 3),
        ],
      ),
      if (_plan.summary.trim().isNotEmpty &&
          _plan.summary.trim() != _plan.title.trim()) ...[
        const SizedBox(height: 12),
        Text('安排说明', style: ChatGuideTokens.caption(context)),
        const SizedBox(height: 4),
        Text(
          _plan.summary,
          style: ChatGuideTokens.step(
            context,
          ).copyWith(color: ChatTheme.of(context).colors.muted),
        ),
        for (final note in _plan.notes)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              note,
              style: ChatGuideTokens.muscles(context).copyWith(height: 1.5),
            ),
          ),
      ],
    ],
  );

  Widget _tag(String text, int index) => Container(
    key: ValueKey('guide-tag-$index'),
    height: ChatGuideTokens.tagHeight,
    padding: ChatGuideTokens.tagPadding,
    decoration: BoxDecoration(
      color: ChatTheme.of(context).colors.surfaceHigh,
      borderRadius: BorderRadius.circular(ChatGuideTokens.tagRadius),
    ),
    child: Center(
      widthFactor: 1,
      child: Text(text, style: ChatGuideTokens.tag(context)),
    ),
  );

  Widget _sectionLabel(String label, {Key? key}) => Padding(
    key: key,
    padding: ChatGuideTokens.sectionPadding,
    child: Text(label, style: ChatGuideTokens.section(context)),
  );

  Widget _blockHeader(coach.PlanBlock block) {
    final protocolName = block.name.trim().toLowerCase();
    final mainName =
        const {
          'main',
          'main_set',
          'main-set',
          'workout',
        }.contains(protocolName) ||
        (protocolName.isEmpty && block.type == coach.BlockType.main);
    final title = mainName ? '主训' : planSectionLabel(block);
    final extra = block.type == coach.BlockType.circuit && block.rounds > 1
        ? ' · 循环 ${block.rounds} 轮，轮间休息 ${block.restBetweenRoundsSeconds} 秒'
        : '';
    return _sectionLabel(
      '$title$extra',
      key: ValueKey('guide-section-${block.id}'),
    );
  }

  Widget _moveArticle(int bi, int ii, int ordinal, coach.Catalog library) {
    final block = _plan.blocks[bi];
    final item = block.items[ii];
    final exercise = library[item.exerciseId]!;
    final cues =
        exercise.cues[_request.language] ??
        exercise.cues['zh'] ??
        const <String>[];
    final muscles = exercise.muscles.isNotEmpty
        ? exercise.muscles
        : exercise.muscleGroups;
    final slot = '$bi:$ii';
    final videoKey = _videos.putIfAbsent(slot, GlobalKey.new);
    final dose = block.type == coach.BlockType.circuit
        ? chatDoseText(
            item.copyWith(sets: 1),
            unitLabels: ChatTheme.of(context).doseUnitLabels,
          )
        : chatDoseText(item, unitLabels: ChatTheme.of(context).doseUnitLabels);
    return Padding(
      key: ValueKey('plan-move-$slot'),
      padding: EdgeInsets.only(
        bottom: ii < block.items.length - 1 ? ChatGuideTokens.cardGap : 0,
      ),
      child: RepaintBoundary(
        key: ValueKey('guide-repaint-$slot'),
        child: SizeChangedLayoutNotifier(
          child: Semantics(
            key: ValueKey('item-${exercise.id}'),
            container: true,
            explicitChildNodes: true,
            child: DecoratedBox(
              key: ValueKey('guide-card-$slot'),
              decoration: BoxDecoration(
                color: ChatGuideTokens.cardFill(context),
                borderRadius: BorderRadius.circular(ChatGuideTokens.cardRadius),
                boxShadow: ChatGuideTokens.cardShadow(context),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(ChatGuideTokens.cardRadius),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    RepaintBoundary(
                      key: videoKey,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(ChatGuideTokens.cardRadius),
                        ),
                        child: AspectRatio(
                          key: ValueKey('article-video-$slot'),
                          aspectRatio: ChatGuideTokens.mediaRatio,
                          child: GuideMedia(
                            key: ValueKey('plan-demo-$slot-${exercise.id}'),
                            actionId: exercise.id,
                            slot: slot,
                            coordinator: _coordinator,
                            enabled: _previewOn,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      key: ValueKey('guide-body-$slot'),
                      padding: ChatGuideTokens.bodyPadding,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _moveNumber(ordinal, slot),
                              const SizedBox(width: ChatGuideTokens.nameGap),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    LayoutBuilder(
                                      builder: (context, constraints) => Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Text(
                                              exercise.name.of(
                                                _request.language,
                                              ),
                                              key: ValueKey('guide-name-$slot'),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: ChatGuideTokens.name(
                                                context,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          ConstrainedBox(
                                            constraints: BoxConstraints(
                                              maxWidth:
                                                  constraints.maxWidth / 2,
                                            ),
                                            child: _dose(dose, slot),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(
                                      height: ChatGuideTokens.muscleGap,
                                    ),
                                    Text(
                                      muscles.join('、'),
                                      key: ValueKey('guide-muscles-$slot'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: ChatGuideTokens.muscles(context),
                                      semanticsLabel:
                                          '目标肌群：${muscles.join('、')}',
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: ChatGuideTokens.dividerGap),
                          SizedBox(
                            key: ValueKey('guide-divider-$slot'),
                            height: 1,
                            child: ColoredBox(
                              color: ChatTheme.of(
                                context,
                              ).colors.line.withValues(alpha: .6),
                            ),
                          ),
                          const SizedBox(
                            height: ChatGuideTokens.instructionGap,
                          ),
                          Text('怎么做', style: ChatGuideTokens.caption(context)),
                          const SizedBox(
                            height: ChatGuideTokens.instructionGap,
                          ),
                          for (var index = 0; index < cues.length; index++) ...[
                            if (index > 0)
                              const SizedBox(height: ChatGuideTokens.stepGap),
                            _step(cues[index], index + 1, slot),
                          ],
                          if (exercise.cautions.isNotEmpty ||
                              item.note != null ||
                              exercise.alternative != null) ...[
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '注意要点',
                                    style: ChatGuideTokens.caption(context),
                                  ),
                                ),
                                if (exercise.alternative != null)
                                  ChatDetailsCircleButton(
                                    key: ValueKey('swap-${exercise.id}'),
                                    tooltip: '换一个',
                                    icon: ChatGlyph.swap,
                                    size: 40,
                                    filled: false,
                                    fill: Colors.transparent,
                                    iconColor: ChatTheme.of(
                                      context,
                                    ).colors.muted,
                                    haptic: ChatHaptic.selection,
                                    onPressed: () => _swap(bi, ii),
                                  ),
                              ],
                            ),
                            if (exercise.cautions.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                '留意部位：${exercise.cautions.join('、')}',
                                style: ChatGuideTokens.step(context),
                              ),
                            ],
                            if (item.note case final note?) ...[
                              const SizedBox(height: 4),
                              Text(note, style: ChatGuideTokens.step(context)),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _moveNumber(int ordinal, String slot) => Container(
    key: ValueKey('guide-number-$slot'),
    width: ChatGuideTokens.numberSize,
    height: ChatGuideTokens.numberSize,
    decoration: BoxDecoration(
      color: ChatTheme.of(context).colors.accent.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(ChatGuideTokens.numberRadius),
    ),
    alignment: Alignment.center,
    child: Text('$ordinal', style: ChatGuideTokens.number(context)),
  );

  Widget _dose(String text, String slot) => Tooltip(
    message: text,
    child: Container(
      key: ValueKey('guide-dose-chip-$slot'),
      height: ChatGuideTokens.tagHeight,
      padding: ChatGuideTokens.tagPadding,
      decoration: BoxDecoration(
        color: ChatGuideTokens.doseFill(context),
        borderRadius: BorderRadius.circular(ChatGuideTokens.tagRadius),
      ),
      child: Center(
        widthFactor: 1,
        child: Text(
          text,
          key: ValueKey('plan-dose-$slot'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ChatGuideTokens.dose(context),
        ),
      ),
    ),
  );

  Widget _step(String text, int ordinal, String slot) => Row(
    key: ValueKey('guide-step-$slot-$ordinal'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        key: ValueKey('guide-step-number-$slot-$ordinal'),
        width: ChatGuideTokens.stepSize,
        height: ChatGuideTokens.stepSize,
        decoration: BoxDecoration(
          color: ChatTheme.of(context).colors.surfaceHigh,
          borderRadius: BorderRadius.circular(ChatGuideTokens.stepSize / 2),
        ),
        alignment: Alignment.center,
        child: Text('$ordinal', style: ChatGuideTokens.stepNumber(context)),
      ),
      const SizedBox(width: ChatGuideTokens.stepGap),
      Expanded(
        child: Text(
          text,
          key: ValueKey('guide-step-text-$slot-$ordinal'),
          style: ChatGuideTokens.step(context),
        ),
      ),
    ],
  );
}

enum _GuideRowKind { intro, section, move, safetyTitle, safetyNote }

class _GuideRow {
  const _GuideRow(
    this.kind,
    this.id, {
    this.block = 0,
    this.item = 0,
    this.ordinal = 0,
    this.note = '',
  });
  final _GuideRowKind kind;
  final String id;
  final int block, item, ordinal;
  final String note;
}

String planSectionLabel(coach.PlanBlock block) {
  final name = block.name.trim();
  final translated = switch (name.toLowerCase()) {
    'warmup' || 'warm_up' || 'warm-up' || 'warm up' => '热身',
    'main' || 'main_set' || 'main-set' || 'workout' => '主练',
    'cooldown' || 'cool_down' || 'cool-down' || 'cool down' => '放松',
    'circuit' => '循环',
    'preparation' || 'prepare' => '准备',
    'stretch' || 'stretching' => '拉伸',
    'rest' || 'recovery' => '休息',
    'mobility' => '活动',
    'balance' => '平衡',
    'cardio' || 'aerobic' => '有氧',
    'interval' || 'intervals' => '间歇',
    'core' => '核心',
    'activation' => '激活',
    _ => null,
  };
  if (translated != null) return translated;
  if (name.isNotEmpty && !RegExp(r'[A-Za-z]').hasMatch(name)) return name;
  return switch (block.type) {
    coach.BlockType.warmup => '热身',
    coach.BlockType.main => '主练',
    coach.BlockType.circuit => '循环',
    coach.BlockType.cooldown => '放松',
  };
}
