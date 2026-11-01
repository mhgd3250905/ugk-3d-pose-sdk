import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

import 'chat_palette.dart';
import 'chat_preview_status.dart';
import 'chat_tokens.dart';

export 'chat_palette.dart';
export 'chat_preview_status.dart';

enum ChatGlyph {
  play,
  pause,
  skipNext,
  close,
  back,
  chevronRight,
  check,
  checkCircle,
  loop,
  chair,
  home,
  flame,
  today,
  checkup,
  progress,
  radar,
  bolt,
  pinch,
  volume,
  volumeLow,
  subtitles,
  info,
  clipboard,
  copy,
  shield,
  bell,
  voice,
  contrast,
  stop,
  figure,
  dancer,
  person,
  bandage,
  skipPrevious,
  bookmark,
  arrowUp,
  more,
  grid,
  sliders,
  swap,
  clock,
  sparkle,
}

@immutable
class CoachChatIconData {
  const CoachChatIconData({
    required this.glyph,
    required this.size,
    required this.color,
    required this.filled,
    required this.strokeWidth,
  });
  final ChatGlyph glyph;
  final double size, strokeWidth;
  final Color color;
  final bool filled;
}

typedef CoachChatIconBuilder =
    Widget Function(BuildContext context, CoachChatIconData icon);
typedef CoachChatExerciseResolver =
    CoachExercise? Function(String actionId, Brightness brightness);
typedef CoachChatPosterPreloader =
    Future<void> Function(BuildContext context, String actionId);
typedef CoachChatPreviewBuilder =
    Widget Function(BuildContext context, String actionId, bool playing);

String chatPlanDetailsLabel(String title) => '计划详情：$title';
String chatTimeLabel(DateTime at, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  final hm =
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  return switch (today.difference(day).inDays) {
    0 => '今天 $hm',
    1 => '昨天 $hm',
    _ => '${at.month}月${at.day}日 $hm',
  };
}

/// Host-owned theme, glyph and artwork bindings. No action assets are bundled.
@immutable
class CoachChatVisuals {
  const CoachChatVisuals({
    this.light = CoachChatPalette.light,
    this.dark = CoachChatPalette.dark,
    this.fontFamily = chatFontFamily,
    this.iconBuilder,
    this.exerciseFor,
    this.assetResolverFor,
    this.mediaBuilder,
    this.cutoutBuilder,
    this.cutoutFor,
    this.preloadPoster,
    this.previewBuilder,
    this.retirePreview,
    this.previewStatusFor,
    this.showStars = true,
    this.animateBackground = true,
    this.uiStrings = const CoachUiStrings(
      expand: '展开',
      collapse: '收起',
      expandDetails: '展开详情',
      collapseDetails: '收起详情',
      save: '保存',
      saved: '已保存',
      start: '开始训练',
      cancel: '取消',
      preparing: '正在准备回复…',
      progressHint: '助理会分步查动作和核对计划，可能需要几分钟',
      answerHint: '说说你的情况…',
      submitAnswer: '确认回答',
      multipleHint: '可以选择多项',
      planFromActions: '排成计划',
      actionUnavailable: '动作暂不可用',
      planDetails: chatPlanDetailsLabel,
      timeLabel: chatTimeLabel,
    ),
  });

  final CoachChatPalette light, dark;
  final String? fontFamily;
  final CoachChatIconBuilder? iconBuilder;
  final CoachChatExerciseResolver? exerciseFor;

  /// Uses the shared catalogue resolver when no custom artwork adapter is needed.
  final coach.AssetResolver Function(Brightness brightness)? assetResolverFor;
  final Widget? Function(BuildContext, CoachMediaRequest)? mediaBuilder;
  final CoachTaskCutoutBuilder? cutoutBuilder;
  final ImageProvider? Function(String actionId, Brightness brightness)?
  cutoutFor;
  final CoachChatPosterPreloader? preloadPoster;
  final CoachChatPreviewBuilder? previewBuilder;

  /// Retires this context's preview surface before another slot can play.
  final Future<void> Function(BuildContext context, String actionId)?
  retirePreview;
  final ValueListenable<CoachChatPreviewStatus>? Function(String actionId)?
  previewStatusFor;
  final bool showStars, animateBackground;
  final CoachUiStrings uiStrings;
}

class CoachChatTheme extends StatelessWidget {
  const CoachChatTheme({
    super.key,
    required this.visual,
    this.executionTiming,
    this.doseUnitLabels = const {},
    required this.child,
  });
  final CoachChatVisuals visual;
  final coach.PlanExecutionTimingCallback? executionTiming;
  final Map<String, String> doseUnitLabels;
  final Widget child;

  static CoachChatThemeData of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_ChatThemeScope>();
    final visual = scope?.visual ?? const CoachChatVisuals();
    final colors = Theme.of(context).brightness == Brightness.dark
        ? visual.dark
        : visual.light;
    return CoachChatThemeData(
      visual,
      colors,
      scope?.executionTiming,
      doseUnitLabels: scope?.doseUnitLabels ?? const {},
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: visual.fontFamily),
        primaryTextTheme: theme.primaryTextTheme.apply(
          fontFamily: visual.fontFamily,
        ),
      ),
      child: _ChatThemeScope(
        visual: visual,
        executionTiming: executionTiming,
        doseUnitLabels: doseUnitLabels,
        child: child,
      ),
    );
  }
}

class _ChatThemeScope extends InheritedWidget {
  const _ChatThemeScope({
    required this.visual,
    required this.executionTiming,
    required this.doseUnitLabels,
    required super.child,
  });
  final CoachChatVisuals visual;
  final coach.PlanExecutionTimingCallback? executionTiming;
  final Map<String, String> doseUnitLabels;
  @override
  bool updateShouldNotify(_ChatThemeScope oldWidget) =>
      oldWidget.visual != visual ||
      oldWidget.executionTiming != executionTiming ||
      oldWidget.doseUnitLabels != doseUnitLabels;
}

abstract final class ChatTheme {
  static CoachChatThemeData of(BuildContext context) =>
      CoachChatTheme.of(context);
}

class CoachChatThemeData {
  const CoachChatThemeData(
    this.visual,
    this.colors,
    this.executionTiming, {
    this.doseUnitLabels = const {},
  });
  final CoachChatVisuals visual;
  final CoachChatPalette colors;
  final coach.PlanExecutionTimingCallback? executionTiming;
  final Map<String, String> doseUnitLabels;
  ChatTextTokens get type => ChatTextTokens(colors, visual.fontFamily);
  ChatComposerStyle get composer => ChatComposerStyle(colors);
  ChatFeaturePanelStyle get panel => ChatFeaturePanelStyle(colors);
  ChatDockStyle get dock => ChatDockStyle(colors);
  Color get cardFill => colors.token(
    'cardFill',
    colors.isDark ? const Color(0xFF1A2324) : const Color(0xFFFFFFFF),
  );
  Color get cardEdge => colors.token(
    'cardEdge',
    colors.isDark
        ? const Color(0xFFFFFFFF).withValues(alpha: .08)
        : const Color(0xFFE3E8E6),
  );
}

class ChatDockStyle {
  const ChatDockStyle(this.colors);
  final CoachChatPalette colors;
  Color get background => colors.skyBottom;
  LinearGradient get gradient => ChatComposerStyle(colors).dockGradient;
}

class ChatIcon extends StatelessWidget {
  const ChatIcon(
    this.glyph, {
    super.key,
    this.size,
    this.color,
    this.filled = false,
    this.strokeWidth = 1.75,
  });
  final ChatGlyph glyph;
  final double? size;
  final Color? color;
  final bool filled;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final theme = ChatTheme.of(context);
    final iconTheme = IconTheme.of(context);
    final request = CoachChatIconData(
      glyph: glyph,
      size: size ?? iconTheme.size ?? 24,
      color: color ?? iconTheme.color ?? theme.colors.text,
      filled: filled,
      strokeWidth: strokeWidth,
    );
    return theme.visual.iconBuilder?.call(context, request) ??
        Icon(_materialGlyph(glyph), size: request.size, color: request.color);
  }
}

IconData _materialGlyph(ChatGlyph glyph) => switch (glyph) {
  ChatGlyph.play => Icons.play_arrow_rounded,
  ChatGlyph.pause => Icons.pause_rounded,
  ChatGlyph.skipNext => Icons.skip_next_rounded,
  ChatGlyph.skipPrevious => Icons.skip_previous_rounded,
  ChatGlyph.close => Icons.close_rounded,
  ChatGlyph.back => Icons.arrow_back_rounded,
  ChatGlyph.chevronRight => Icons.chevron_right_rounded,
  ChatGlyph.check => Icons.check_rounded,
  ChatGlyph.checkCircle => Icons.check_circle_outline_rounded,
  ChatGlyph.loop => Icons.loop_rounded,
  ChatGlyph.chair => Icons.chair_outlined,
  ChatGlyph.home => Icons.home_outlined,
  ChatGlyph.flame => Icons.local_fire_department_outlined,
  ChatGlyph.today => Icons.today_outlined,
  ChatGlyph.checkup => Icons.fact_check_outlined,
  ChatGlyph.progress => Icons.trending_up_rounded,
  ChatGlyph.radar => Icons.radar_rounded,
  ChatGlyph.bolt => Icons.bolt_rounded,
  ChatGlyph.pinch => Icons.pinch_outlined,
  ChatGlyph.volume => Icons.volume_up_outlined,
  ChatGlyph.volumeLow => Icons.volume_down_outlined,
  ChatGlyph.subtitles => Icons.subtitles_outlined,
  ChatGlyph.info => Icons.info_outline_rounded,
  ChatGlyph.clipboard => Icons.assignment_outlined,
  ChatGlyph.copy => Icons.copy_rounded,
  ChatGlyph.shield => Icons.shield_outlined,
  ChatGlyph.bell => Icons.notifications_outlined,
  ChatGlyph.voice => Icons.record_voice_over_outlined,
  ChatGlyph.contrast => Icons.contrast_rounded,
  ChatGlyph.stop => Icons.stop_rounded,
  ChatGlyph.figure ||
  ChatGlyph.dancer ||
  ChatGlyph.person => Icons.person_outline_rounded,
  ChatGlyph.bandage => Icons.healing_rounded,
  ChatGlyph.bookmark => Icons.bookmark_border_rounded,
  ChatGlyph.arrowUp => Icons.arrow_upward_rounded,
  ChatGlyph.more => Icons.more_horiz_rounded,
  ChatGlyph.grid => Icons.grid_view_rounded,
  ChatGlyph.sliders => Icons.tune_rounded,
  ChatGlyph.swap => Icons.swap_horiz_rounded,
  ChatGlyph.clock => Icons.schedule_rounded,
  ChatGlyph.sparkle => Icons.auto_awesome_rounded,
};
