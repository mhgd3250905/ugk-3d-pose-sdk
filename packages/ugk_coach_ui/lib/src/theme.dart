import 'package:flutter/material.dart';
import 'models.dart';
import 'primitives.dart';

@immutable
class CoachUiColors {
  const CoachUiColors({
    required this.brightness,
    required this.text,
    required this.muted,
    required this.faint,
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.outline,
    required this.shadow,
    required this.accent,
    required this.accentText,
    required this.accentSoft,
    required this.onAccent,
    required this.userBubble,
    required this.assistantBubble,
    required this.stage,
    required this.emphasis,
    required this.onEmphasis,
    required this.onMedia,
    required this.mediaLabelSurface,
  });
  final Brightness brightness;
  final Color text, muted, faint;

  /// The three opaque levels: page, content card and raised control.
  final Color background, surface, surfaceRaised;

  /// A low-contrast 1 px edge and the colour of fixed, shallow shadows.
  final Color outline, shadow;
  final Color accent, accentText, accentSoft, onAccent;
  final Color userBubble, assistantBubble;
  final CoachMediaPalette stage;
  final Color emphasis, onEmphasis, onMedia, mediaLabelSurface;
  bool get isDark => brightness == Brightness.dark;

  static final light = CoachUiColors.fromTheme(ThemeData.light());
  static final dark = CoachUiColors.fromTheme(ThemeData.dark());

  CoachUiColors copyWith({
    Brightness? brightness,
    Color? text,
    Color? muted,
    Color? faint,
    Color? background,
    Color? surface,
    Color? surfaceRaised,
    Color? outline,
    Color? shadow,
    Color? accent,
    Color? accentText,
    Color? accentSoft,
    Color? onAccent,
    Color? userBubble,
    Color? assistantBubble,
    CoachMediaPalette? stage,
    Color? emphasis,
    Color? onEmphasis,
    Color? onMedia,
    Color? mediaLabelSurface,
  }) => CoachUiColors(
    brightness: brightness ?? this.brightness,
    text: text ?? this.text,
    muted: muted ?? this.muted,
    faint: faint ?? this.faint,
    background: background ?? this.background,
    surface: surface ?? this.surface,
    surfaceRaised: surfaceRaised ?? this.surfaceRaised,
    outline: outline ?? this.outline,
    shadow: shadow ?? this.shadow,
    accent: accent ?? this.accent,
    accentText: accentText ?? this.accentText,
    accentSoft: accentSoft ?? this.accentSoft,
    onAccent: onAccent ?? this.onAccent,
    userBubble: userBubble ?? this.userBubble,
    assistantBubble: assistantBubble ?? this.assistantBubble,
    stage: stage ?? this.stage,
    emphasis: emphasis ?? this.emphasis,
    onEmphasis: onEmphasis ?? this.onEmphasis,
    onMedia: onMedia ?? this.onMedia,
    mediaLabelSurface: mediaLabelSurface ?? this.mediaLabelSurface,
  );
  factory CoachUiColors.fromTheme(ThemeData theme) {
    final c = theme.colorScheme;
    return CoachUiColors(
      brightness: c.brightness,
      text: c.onSurface,
      muted: c.onSurfaceVariant,
      faint: c.outline,
      background: c.surface,
      surface: c.surfaceContainerLow,
      surfaceRaised: c.surfaceContainerHigh,
      outline: c.outlineVariant,
      shadow: c.shadow.withValues(alpha: .08),
      accent: c.primary,
      accentText: c.primary,
      accentSoft: c.primaryContainer,
      onAccent: c.onPrimary,
      userBubble: c.primaryContainer,
      assistantBubble: c.surfaceContainerHigh,
      stage: CoachMediaPalette(
        mediaStage: c.surfaceContainer,
        onStage: c.onSurface,
        onStageMuted: c.onSurfaceVariant,
      ),
      emphasis: c.primary,
      onEmphasis: c.onPrimary,
      onMedia: c.onSurface,
      mediaLabelSurface: c.surfaceContainerHigh,
    );
  }
}

@immutable
class CoachUiTypography {
  const CoachUiTypography({
    required this.body,
    required this.callout,
    required this.label,
    required this.caption,
    required this.greeting,
  });
  final TextStyle body, callout, label, caption, greeting;
  static const tabular = [FontFeature.tabularFigures()];
  factory CoachUiTypography.fromTheme(ThemeData t) => CoachUiTypography(
    body: t.textTheme.bodyLarge!,
    callout: t.textTheme.titleSmall!,
    label: t.textTheme.labelMedium!,
    caption: t.textTheme.bodySmall!,
    greeting: t.textTheme.headlineMedium!,
  );
}

/// All fixed copy is replaceable; model / catalog copy lives in data snapshots.
@immutable
class CoachUiStrings {
  const CoachUiStrings({
    this.expand = 'Expand',
    this.collapse = 'Collapse',
    this.expandDetails = 'Expand details',
    this.collapseDetails = 'Collapse details',
    this.save = 'Save',
    this.saved = 'Saved',
    this.start = 'Start training',
    this.cancel = 'Cancel',
    this.preparing = 'Preparing a reply…',
    this.progressHint = 'The assistant is checking exercises and the routine.',
    this.answerHint = 'Type your answer',
    this.submitAnswer = 'Send answer',
    this.multipleHint = 'Choose one or more options',
    this.planDetails = _details,
    this.timeLabel = _time,
  });
  final String expand, collapse, expandDetails, collapseDetails;
  final String save, saved, start, cancel, preparing, progressHint;
  final String answerHint, submitAnswer, multipleHint;
  final String Function(String title) planDetails;
  final String Function(DateTime at, DateTime now) timeLabel;
  static String _details(String title) => 'Routine details: $title';
  static String _time(DateTime at, DateTime now) =>
      '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')} '
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
}

/// Optional host controls preserve a product's established design system.
/// Layout, list choreography and routine expansion remain owned by this package.
class CoachUiBuilders {
  const CoachUiBuilders({
    this.pressable,
    this.controlFace,
    this.textAction,
    this.surface,
    this.icon,
    this.startButton,
    this.media,
  });
  final Widget Function(BuildContext, CoachPressable)? pressable;
  final Widget Function(BuildContext, CoachControlFace)? controlFace;
  final Widget Function(BuildContext, CoachTextAction)? textAction;
  final Widget Function(BuildContext, CoachCardSurface)? surface;
  final Widget Function(BuildContext, CoachIcon)? icon;
  final Widget Function(BuildContext, CoachStartButton)? startButton;

  /// Optional asset rendering (for example a verified alpha sourceRect).
  /// SDK timing, layout and interactions remain owned by the card. A null
  /// result uses the standard asset image. No networking is performed here.
  final Widget? Function(BuildContext, CoachMediaRequest)? media;
}

@immutable
class CoachUiStyle {
  const CoachUiStyle({
    required this.colors,
    required this.typography,
    this.strings = const CoachUiStrings(),
    this.builders = const CoachUiBuilders(),
  });
  final CoachUiColors colors;
  final CoachUiTypography typography;
  final CoachUiStrings strings;
  final CoachUiBuilders builders;
  factory CoachUiStyle.fromTheme(ThemeData theme) => CoachUiStyle(
    colors: CoachUiColors.fromTheme(theme),
    typography: CoachUiTypography.fromTheme(theme),
  );
}

class CoachUiTheme extends StatelessWidget {
  const CoachUiTheme({super.key, required this.style, required this.child});
  final CoachUiStyle style;
  final Widget child;
  static CoachUiStyle of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_CoachUiThemeScope>()?.style ??
      CoachUiStyle.fromTheme(Theme.of(context));
  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_CoachUiThemeScope>() != null;
  @override
  Widget build(BuildContext context) => _CoachUiThemeScope(
    style: style,
    child: DefaultTextStyle.merge(
      style: style.typography.body.copyWith(color: style.colors.text),
      child: child,
    ),
  );
}

class _CoachUiThemeScope extends InheritedWidget {
  const _CoachUiThemeScope({required this.style, required super.child});
  final CoachUiStyle style;
  @override
  bool updateShouldNotify(_CoachUiThemeScope oldWidget) =>
      oldWidget.style != style;
}
