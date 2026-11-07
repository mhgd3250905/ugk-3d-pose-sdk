import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach_ui/ugk_coach_ui.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart'
    show PoseHubCatalogImage, TrainerTheme;

import '../core/chat_models.dart' show ChatMessage;
import '../theme/chat_controls.dart';
import '../theme/chat_polish_card.dart';
import '../theme/chat_surface.dart';
import '../theme/chat_theme.dart';
import '../theme/chat_tokens.dart';
import 'training_visible_poster_preload.dart';

Widget withCoachChatUi(BuildContext context, Widget child) =>
    CoachUiTheme.contains(context)
    ? child
    : CoachUiTheme(style: coachChatUiStyle(context), child: child);

Widget chatPlanFocusIcon(BuildContext context, double size, Color color) =>
    ChatIcon(ChatGlyph.bookmark, size: size, color: color);
Widget chatPlanFocusClearIcon(BuildContext context, double size, Color color) =>
    ChatIcon(ChatGlyph.close, size: size, color: color);

CoachTaskCutoutBuilder? chatTaskCutouts(
  BuildContext context,
  coach.Catalog catalog,
) {
  final visual = ChatTheme.of(context).visual;
  if (visual.cutoutBuilder != null) return visual.cutoutBuilder;
  if (visual.cutoutFor == null) return null;
  return (context, id, size, brightness) {
    final provider = visual.cutoutFor!(id, brightness);
    return provider == null
        ? const SizedBox.shrink()
        : ClipOval(
            child: SizedBox.fromSize(
              size: size,
              child: Image(
                image: provider,
                fit: BoxFit.contain,
                alignment: Alignment.center,
                semanticLabel: catalog[id]?.name.of('zh'),
              ),
            ),
          );
  };
}

/// Only this plan card replaces its save copy and adds a host-owned action.
/// The SDK continues to own its footer, start button and expansion timeline.
Widget withCoachChatPlanSaveUi(
  BuildContext context,
  Widget child, {
  required String planId,
  String? saveLabel,
  String? savedLabel,
  VoidCallback? onSaveCopy,
}) {
  if (saveLabel == null && savedLabel == null && onSaveCopy == null) {
    return withCoachChatUi(context, child);
  }
  final base = CoachUiTheme.contains(context)
      ? CoachUiTheme.of(context)
      : coachChatUiStyle(context);
  final strings = base.strings;
  final builders = base.builders;
  final primaryBuilder =
      builders.textAction ?? coachChatUiStyle(context).builders.textAction!;
  return CoachUiTheme(
    style: CoachUiStyle(
      colors: base.colors,
      typography: base.typography,
      strings: CoachUiStrings(
        expand: strings.expand,
        collapse: strings.collapse,
        expandDetails: strings.expandDetails,
        collapseDetails: strings.collapseDetails,
        save: saveLabel ?? strings.save,
        saved: savedLabel ?? strings.saved,
        start: strings.start,
        cancel: strings.cancel,
        preparing: strings.preparing,
        progressHint: strings.progressHint,
        answerHint: strings.answerHint,
        submitAnswer: strings.submitAnswer,
        multipleHint: strings.multipleHint,
        planFromActions: strings.planFromActions,
        actionUnavailable: strings.actionUnavailable,
        planDetails: strings.planDetails,
        timeLabel: strings.timeLabel,
        taskThinkingTitle: strings.taskThinkingTitle,
        taskReadingStatus: strings.taskReadingStatus,
        taskCancel: strings.taskCancel,
        planFocusTitle: strings.planFocusTitle,
        clearPlanFocus: strings.clearPlanFocus,
      ),
      builders: CoachUiBuilders(
        pressable: builders.pressable,
        controlFace: builders.controlFace,
        textAction: (context, action) {
          final primary = primaryBuilder(context, action);
          if (onSaveCopy == null ||
              action.key != ValueKey('plan-save-$planId')) {
            return primary;
          }
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              KeyedSubtree(
                key: ValueKey('plan-primary-save-$planId'),
                child: primary,
              ),
              const SizedBox(width: 12),
              ChatPressable(
                key: ValueKey('plan-save-copy-$planId'),
                semanticLabel: '另存一份',
                onTap: onSaveCopy,
                child: SizedBox(
                  height: 44,
                  child: Center(
                    child: Text(
                      '另存一份',
                      style: ChatType.of(context).callout.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: ChatTheme.of(context).colors.accent,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
        surface: builders.surface,
        icon: builders.icon,
        startButton: builders.startButton,
        media: builders.media,
      ),
    ),
    child: child,
  );
}

/// Saved plans reuse the SDK plan view and its normal App theme. Its left
/// action opens details instead of saving, using the approved primary ink.
Widget withCoachChatSavedPlanUi(
  BuildContext context,
  Widget child, {
  bool compact = false,
}) {
  final base = coachChatUiStyle(context, planDetailsAction: true);
  final builders = base.builders;
  return CoachUiTheme(
    style: compact
        ? CoachUiStyle(
            colors: base.colors,
            typography: base.typography,
            strings: base.strings,
            builders: CoachUiBuilders(
              // The SDK retains its collapse control even when invisible.
              // A zero-size public control plus an empty header lets the
              // compact summary use the whole width without a second shell.
              pressable: (context, control) => control.expanded != null
                  ? const SizedBox.shrink()
                  : builders.pressable!(context, control),
              controlFace: builders.controlFace,
              textAction: builders.textAction,
              surface: builders.surface,
              icon: builders.icon,
              startButton: builders.startButton,
              media: builders.media,
            ),
          )
        : base,
    child: child,
  );
}

/// Recommendation layout, controls and card tokens use the SDK defaults.
/// Only fixed labels are localized; trusted artwork is supplied as model data.
Widget withCoachChatRecommendUi(BuildContext context, Widget child) {
  final style = CoachUiStyle.fromTheme(Theme.of(context));
  final assets = <String, String>{};
  if (child is CoachRecommendCard) {
    for (final id in child.actionIds) {
      final exercise = child.library.tryGet(id);
      if (exercise == null) continue;
      for (final asset in [
        exercise.poster,
        exercise.cutout,
        exercise.stillCutout,
      ]) {
        if (asset != null && asset.isNotEmpty) assets[asset] = id;
      }
    }
  }
  return CoachUiTheme(
    style: CoachUiStyle(
      colors: style.colors,
      typography: style.typography,
      strings: ChatTheme.of(context).visual.uiStrings,
    ),
    child: TrainingVisiblePosterPreload(assetActionIds: assets, child: child),
  );
}

CoachMediaPalette coachMediaPalette(CoachChatPalette p) => CoachMediaPalette(
  mediaStage: p.mediaStage,
  onStage: p.onStage,
  onStageMuted: p.onStageMuted,
);

CoachQuestionData toCoachQuestionData(ChatMessage message) {
  final question = message.question!;
  return CoachQuestionData(
    id: message.id,
    question: question.question,
    mode: switch (question.mode) {
      coach.AskUserMode.text => CoachQuestionMode.text,
      coach.AskUserMode.choice => CoachQuestionMode.choice,
      coach.AskUserMode.form => CoachQuestionMode.form,
    },
    options: question.options,
    multiple: question.multiple,
    answered: message.questionAnswered,
    answeredChoices: message.answeredChoices,
    answeredForm: message.answeredForm,
    isConfirmation: question.isConfirmation,
    focus: question.focus,
    defaultSelections: question.defaultSelections,
    fields: [
      for (final field in question.fields)
        CoachQuestionField(
          key: field.key,
          label: field.label,
          options: field.options,
          multiple: field.multiple,
          initialSelections: field.preselected,
          previousSelections: field.previousSelections,
          optionsByScene: field.optionsByScene,
        ),
    ],
    skipLabel: question.skipLabel,
  );
}

CoachUiStyle coachChatUiStyle(
  BuildContext context, {
  bool planDetailsAction = false,
}) {
  final p = ChatTheme.of(context).colors.palette;
  return CoachUiStyle(
    colors: CoachUiColors(
      brightness: p.brightness,
      taskAccent: p.accent,
      taskCardSurface: p.surface,
      taskCardBorder: (p.isDark ? Colors.white : Colors.black).withValues(
        alpha: p.isDark ? .08 : .06,
      ),
      taskGlow: p.accent.withValues(alpha: p.isDark ? .10 : .06),
      taskText: p.text,
      taskMuted: p.muted,
      taskChipSurface: p.accent.withValues(alpha: p.isDark ? .18 : .10),
      taskOrbFill: p.accent.withValues(alpha: p.isDark ? .14 : .08),
      taskProgressTrack: (p.isDark ? Colors.white : Colors.black).withValues(
        alpha: p.isDark ? .10 : .08,
      ),
      taskChipBorder: (p.isDark ? Colors.white : Colors.black).withValues(
        alpha: p.isDark ? .12 : .10,
      ),
      taskHalo: p.accent.withValues(alpha: .15),
      taskShadowNear: Colors.black.withValues(alpha: .04),
      taskShadowFar: Colors.black.withValues(alpha: .06),
      text: p.text,
      muted: p.muted,
      faint: p.faint,
      background: p.background,
      surface: ChatTheme.of(context).cardFill,
      surfaceRaised: p.surfaceHigh,
      outline: ChatTheme.of(context).cardEdge,
      shadow: p.shadow,
      accent: p.accent,
      accentText: p.accentText,
      accentSoft: p.accentSoft,
      onAccent: p.onAccent,
      userBubble: p.userBubble,
      assistantBubble: p.assistantBubble,
      stage: coachMediaPalette(p),
      emphasis: p.accent,
      onEmphasis: p.onAccent,
      onMedia: p.text,
      mediaLabelSurface: p.surfaceHigh,
    ),
    typography: CoachUiTypography(
      body: ChatType.of(context).body,
      callout: ChatType.of(context).callout,
      label: ChatType.of(context).label,
      caption: ChatType.of(context).caption,
      greeting: ChatType.of(context).greeting,
    ),
    strings: ChatTheme.of(context).visual.uiStrings,
    builders: CoachUiBuilders(
      media: (context, request) =>
          ChatTheme.of(context).visual.mediaBuilder?.call(context, request),
      pressable: (_, c) => c.expanded != null
          ? ChatPlanToggleButton(
              expanded: c.expanded!,
              onPressed: c.onTap,
              semanticLabel: c.semanticLabel,
              tooltip: c.tooltip,
              haptic: ChatHaptic.values[c.haptic.index],
            )
          : ChatPressable(
              onTap: c.onTap,
              semanticLabel: c.semanticLabel,
              tooltip: c.tooltip,
              scale: c.scale,
              expanded: c.expanded,
              haptic: ChatHaptic.values[c.haptic.index],
              child: c.child,
            ),
      controlFace: (_, c) => ChatTheme.of(context).colors.isDark
          ? ConstrainedBox(
              constraints: BoxConstraints(minHeight: c.minHeight),
              child: ChatSolidSurface(
                level: ChatSurfaceLevel.raised,
                radius: c.minHeight / 2,
                padding: c.padding,
                control: true,
                child: c.child,
              ),
            )
          : c.child,
      textAction: (_, c) => ChatTextAction(
        label: c.label,
        onPressed: c.onPressed,
        icon: c.icon == null ? null : _glyph(c.icon!),
        iconFilled: c.iconFilled,
        color: planDetailsAction
            ? ChatTheme.of(context).colors.accent
            : c.color,
        boxed: false,
      ),
      surface: (_, c) =>
          ChatPolishCard(padding: c.padding, width: c.width, child: c.child),
      icon: (_, c) => ChatIcon(
        _glyph(c.glyph),
        size: c.size,
        color: c.color,
        filled: c.filled,
        strokeWidth: c.strokeWidth,
      ),
      startButton: (_, c) => ChatPressable(
        semanticLabel: '开始训练',
        tooltip: '开始训练',
        onTap: c.onTap,
        haptic: ChatHaptic.medium,
        child: Container(
          key: const ValueKey('start-disc'),
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ChatTheme.of(context).colors.accent,
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.only(left: 2),
              child: ChatIcon(
                ChatGlyph.play,
                size: 18,
                filled: true,
                color: ChatTheme.of(context).colors.onAccent,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

ChatGlyph _glyph(CoachGlyph glyph) => switch (glyph) {
  CoachGlyph.bookmark => ChatGlyph.bookmark,
  CoachGlyph.chevronRight => ChatGlyph.chevronRight,
  CoachGlyph.play => ChatGlyph.play,
  CoachGlyph.stop => ChatGlyph.stop,
};

CoachExercise toCoachExercise(BuildContext context, coach.Drill drill) {
  final theme = ChatTheme.of(context);
  final resolved = theme.visual.exerciseFor?.call(
    drill.id,
    theme.colors.brightness,
  );
  if (resolved != null) return _withCatalogArtwork(resolved, drill);
  final cover = theme.visual.assetResolverFor
      ?.call(theme.colors.brightness)
      .resolve(drill)
      .cover
      ?.uri;
  final gear = drill.equipment
      .where((id) => id != 'none' && id.isNotEmpty)
      .toSet();
  return _withCatalogArtwork(
    CoachExercise(
      id: drill.id,
      name: drill.name.of('zh'),
      poster: cover ?? '',
      stage: coachMediaPalette(theme.colors),
      categoryLabel:
          const {
            'strength': '力量',
            'core': '核心',
            'cardio': '心肺',
            'mobility': '灵活',
            'stretch': '拉伸',
          }[drill.category] ??
          drill.category,
      levelLabel: coach.levelZh(drill.level),
      equipmentLabel: gear.isEmpty
          ? '徒手'
          : gear.map(chatEquipmentLabel).join('、'),
      cues: drill.cues['zh'] ?? const [],
    ),
    drill,
  );
}

CoachExercise _withCatalogArtwork(CoachExercise exercise, coach.Drill drill) {
  const sdkArtworkRoot = 'packages/ugk_trainer/assets/pose_hub/';
  bool isHostArtwork(String? asset) =>
      asset != null && asset.isNotEmpty && !asset.startsWith(sdkArtworkRoot);

  // Host theme covers, cutouts and explicit renderers retain precedence.
  if (isHostArtwork(exercise.poster) ||
      isHostArtwork(exercise.cutout) ||
      isHostArtwork(exercise.stillCutout) ||
      exercise.artworkBuilder != null) {
    return exercise;
  }
  final media = drill.raw['poseHubMedia'];
  if (media is! Map<String, Object?>) return exercise;
  final video = coach.PoseHubPackFile.fromJson(media['video']);
  final cover = coach.PoseHubPackFile.fromJson(media['cover']);
  final thumbnailFile = coach.PoseHubPackFile.fromJson(media['thumbnail']);
  final base = media['baseUri'];
  return CoachExercise(
    id: exercise.id,
    name: exercise.name,
    poster: exercise.poster,
    stage: exercise.stage,
    categoryLabel: exercise.categoryLabel,
    cues: exercise.cues,
    cutout: exercise.cutout,
    stillCutout: exercise.stillCutout,
    levelLabel: exercise.levelLabel,
    equipmentLabel: exercise.equipmentLabel,
    artworkBuilder: (context, {required bool thumbnail}) => PoseHubCatalogImage(
      id: drill.id,
      name: exercise.name,
      video: video,
      cover: cover,
      thumbnailFile: thumbnailFile,
      thumbnail: thumbnail,
      theme: Theme.of(context).brightness == Brightness.dark
          ? TrainerTheme.dark
          : TrainerTheme.light,
      mediaBaseUri: base is String ? Uri.tryParse(base) : null,
    ),
  );
}

CoachExercise toCoachRecommendationExercise(
  BuildContext context,
  coach.Drill drill,
) => toCoachExercise(context, drill);

String chatEquipmentLabel(String id) =>
    const {
      'none': '徒手',
      'mat': '瑜伽垫',
      'chair': '椅子',
      'wall': '墙',
      'band': '弹力带',
      'dumbbell': '哑铃',
      'block': '瑜伽砖',
      'slider': '滑垫',
      'cable': '绳索器械',
      'dip-bars': '双杠',
      'foam-roller': '泡沫轴',
      'ghd': 'GHD训练器',
      'hip-abductor-machine': '髋外展训练器',
      'kettlebell': '壶铃',
      'landmine': '地雷架',
      'leg-extension-machine': '腿屈伸训练器',
      'parallettes': '小双杠',
      'pullup-bar': '单杠',
      'reverse-hyper': '反向挺身器',
      'rings': '吊环',
      'roman-chair': '罗马椅',
      'swiss-ball': '健身球',
    }[id] ??
    id;

String chatDoseText(
  coach.PlanItem item, {
  String? unitLabel,
  Map<String, String> unitLabels = const {},
}) {
  unitLabel = unitLabels[item.exerciseId] ?? unitLabel;
  final per = item.perSide ? '每侧 ' : '';
  if (item.segments.isNotEmpty) {
    final parts = [
      for (final segment in item.segments)
        '${segment.label == null ? '' : '${segment.label} '}$per${segment.mode == coach.DoseMode.reps ? '${segment.reps} ${unitLabels[segment.exerciseId] ?? unitLabel ?? '次'}' : '${segment.workSeconds} ${unitLabels[segment.exerciseId] ?? unitLabel ?? '秒'}'}',
    ].join(' + ');
    return item.sets > 1 ? '${item.sets} 组 × ($parts)' : parts;
  }
  final amount = item.mode == coach.DoseMode.reps
      ? '$per${item.reps ?? 10} ${unitLabel ?? '次'}'
      : '$per${item.workSeconds ?? 30} ${unitLabel ?? '秒'}';
  return item.sets > 1 ? '${item.sets} 组 × $amount' : amount;
}

String chatDurationLabel(double seconds) {
  final minutes = (seconds / 60).round();
  return minutes < 1 ? '不到 1 分钟' : '约 $minutes 分钟';
}

CoachRoutine toCoachRoutine(
  coach.TrainingPlan plan,
  coach.Catalog catalog, {
  coach.PlanExecutionTimingCallback? executionTiming,
  Map<String, String> doseUnitLabels = const {},
}) {
  final gear = plan.equipment
      .where((id) => id != 'none' && id.isNotEmpty)
      .toSet();
  final gearText = gear.isEmpty
      ? '徒手'
      : gear
            .map(
              (id) => catalog.taxonomy.equipment[id] ?? chatEquipmentLabel(id),
            )
            .join('、');
  final seconds = executionTiming == null
      ? const coach.PlanDuration().estimateSeconds(plan, catalog)
      : coach.evaluatePlanExecutionTiming(plan, executionTiming).totalSeconds;
  final duration = chatDurationLabel(seconds);
  final items = [
    for (final block in plan.blocks)
      for (final item in block.items)
        CoachRoutineItem(
          exerciseId: item.exerciseId,
          dose: chatDoseText(item, unitLabels: doseUnitLabels),
          detailDose: chatDoseText(
            block.type == coach.BlockType.circuit
                ? item.copyWith(sets: 1)
                : item,
            unitLabels: doseUnitLabels,
          ),
        ),
  ];
  return CoachRoutine(
    id: plan.id,
    title: plan.title,
    items: items,
    durationLabel: duration,
    gearLabel: gearText,
    levelLabel: coach.levelZh(plan.level),
    metaLabel: [duration, '${items.length} 个动作', gearText].join(' · '),
    adjustmentsLabel: plan.notes.isEmpty
        ? null
        : '已按你的情况调整 ${plan.notes.length} 处',
  );
}
