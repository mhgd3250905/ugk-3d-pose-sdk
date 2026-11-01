import 'package:flutter/material.dart';

/// Original conversation palette roles. Every colour, type
/// size, spacing step, radius, shadow and motion timing in the UI comes
/// from here, so the app is drawn with one hand.
///
/// Teal carries the primary action and selection; coral marks starting or
/// completing a workout. The chat floats in an endless sky (dark, default)
/// or an endless white room (light).

/// Bundled Noto Sans SC (assets/fonts/NotoSansSC.ttf, OFL 1.1; GB2312 +
/// UI subset of the variable font, weights 100–900).
const chatFontFamily = 'NotoSansSC';

/// Colours sampled from the icon. The pale colours are decorative; text
/// uses the contrast-adjusted roles in [CoachChatPalette].
abstract final class ChatBrand {
  static const mint = Color(0xFFBDF7CF);
  static const teal = Color(0xFF7AD4D5);
  static const coral = Color(0xFFE8705F);
}

/// One complete set of colour tokens: [dark] (deep sky) and [light]
/// (paper white). Same roles in both; only values differ.
@immutable
class CoachChatPalette {
  const CoachChatPalette({
    required this.brightness,
    required this.skyTop,
    required this.skyBottom,
    required this.dust,
    required this.background,
    required this.surfaceLow,
    required this.surface,
    required this.surfaceHigh,
    required this.line,
    required this.accent,
    required this.accentText,
    required this.onAccent,
    required this.emphasis,
    required this.emphasisText,
    required this.onEmphasis,
    required this.text,
    required this.muted,
    required this.faint,
    required this.caution,
    required this.danger,
    required this.mediaStage,
    required this.onStage,
    required this.onStageMuted,
    required this.thumb,
    required this.scrim,
    required this.track,
    required this.userBubble,
    required this.assistantBubble,
    required this.shadow,
    this.overrides = const {},
  });

  final Brightness brightness;

  /// The endless space behind the chat and the player (top → bottom).
  final Color skyTop;
  final Color skyBottom;

  /// Star dust (dark) / floating motes (light), drawn at low alpha.
  final Color dust;

  /// Plain pages (library, about …) and the system navigation bar.
  final Color background;

  /// Level 0: fixed page furniture, underneath cards and raised controls.
  final Color surfaceLow;

  /// Level 1: cards, the input capsule, sheets, dialogs, the drawer.
  final Color surface;

  /// Level 2: things inside a card or on the page that you press
  /// (chips, circle buttons, the user's bubble, segment tracks).
  final Color surfaceHigh;

  /// Hairline. Light theme only, where white on near-white needs an edge;
  /// on dark the tone steps carry the shape.
  final Color line;

  /// Primary action, progress and selection, in the icon's teal hue.
  final Color accent;

  /// Accent as small text / icons on the page (AA on [background]).
  final Color accentText;
  final Color onAccent;

  /// Starting / completing a workout and important non-safety notices.
  /// Safety and destructive actions retain [caution] / [danger].
  final Color emphasis;
  final Color emphasisText;
  final Color onEmphasis;

  final Color text;
  final Color muted;
  final Color faint;

  /// Safety only (不舒服, 换侧 notice). Never decoration.
  final Color caution;

  /// Destructive confirmations (删除, 结束今天的训练).
  final Color danger;

  /// What sits behind a drill clip: the colour its render is baked on
  /// (#101013 dark renders, #EFEFEF light-stage renders, §6).
  final Color mediaStage;

  /// Text laid over a media stage (the plan card's title and meta line).
  final Color onStage;
  final Color onStageMuted;

  /// The sliding thumb of a segmented control (the one neutral raised part).
  final Color thumb;

  /// Labels floating on media (已暂停, 不舒服).
  final Color scrim;

  /// Ring / progress tracks.
  final Color track;

  final Color userBubble;
  final Color assistantBubble;
  final Color shadow;

  /// Optional named surface tokens for the composer and detail controls.
  final Map<String, Color> overrides;
  Color token(String name, Color fallback) => overrides[name] ?? fallback;
  CoachChatPalette get palette => this;
  Color get skyGlow => token(
    'skyGlow',
    isDark ? const Color(0x0AFFFFFF) : const Color(0x0F9DB8AC),
  );
  List<BoxShadow> get cardShadow => [
    BoxShadow(color: shadow, blurRadius: 4, offset: const Offset(0, 2)),
  ];
  BorderSide get cardEdge => BorderSide(color: line);

  CoachChatPalette copyWith({
    Brightness? brightness,
    Color? skyTop,
    Color? skyBottom,
    Color? dust,
    Color? background,
    Color? surfaceLow,
    Color? surface,
    Color? surfaceHigh,
    Color? line,
    Color? accent,
    Color? accentText,
    Color? onAccent,
    Color? emphasis,
    Color? emphasisText,
    Color? onEmphasis,
    Color? text,
    Color? muted,
    Color? faint,
    Color? caution,
    Color? danger,
    Color? mediaStage,
    Color? onStage,
    Color? onStageMuted,
    Color? thumb,
    Color? scrim,
    Color? track,
    Color? userBubble,
    Color? assistantBubble,
    Color? shadow,
    Map<String, Color>? overrides,
  }) => CoachChatPalette(
    brightness: brightness ?? this.brightness,
    skyTop: skyTop ?? this.skyTop,
    skyBottom: skyBottom ?? this.skyBottom,
    dust: dust ?? this.dust,
    background: background ?? this.background,
    surfaceLow: surfaceLow ?? this.surfaceLow,
    surface: surface ?? this.surface,
    surfaceHigh: surfaceHigh ?? this.surfaceHigh,
    line: line ?? this.line,
    accent: accent ?? this.accent,
    accentText: accentText ?? this.accentText,
    onAccent: onAccent ?? this.onAccent,
    emphasis: emphasis ?? this.emphasis,
    emphasisText: emphasisText ?? this.emphasisText,
    onEmphasis: onEmphasis ?? this.onEmphasis,
    text: text ?? this.text,
    muted: muted ?? this.muted,
    faint: faint ?? this.faint,
    caution: caution ?? this.caution,
    danger: danger ?? this.danger,
    mediaStage: mediaStage ?? this.mediaStage,
    onStage: onStage ?? this.onStage,
    onStageMuted: onStageMuted ?? this.onStageMuted,
    thumb: thumb ?? this.thumb,
    scrim: scrim ?? this.scrim,
    track: track ?? this.track,
    userBubble: userBubble ?? this.userBubble,
    assistantBubble: assistantBubble ?? this.assistantBubble,
    shadow: shadow ?? this.shadow,
    overrides: overrides ?? this.overrides,
  );

  bool get isDark => brightness == Brightness.dark;

  /// Selected chip / option fill.
  Color get accentSoft =>
      Color.alphaBlend(accent.withValues(alpha: isDark ? .18 : .12), surface);

  Color get emphasisSoft =>
      Color.alphaBlend(emphasis.withValues(alpha: isDark ? .16 : .12), surface);

  static const dark = CoachChatPalette(
    brightness: Brightness.dark,
    skyTop: Color(0xFF121315), // deep neutral (round 4: no blue cast)
    skyBottom: Color(0xFF0B0B0D),
    dust: Color(0xFFDDE3F2),
    background: Color(0xFF0B0C10),
    surfaceLow: Color(0xFF111A1E),
    surface: Color(0xFF19262B),
    surfaceHigh: Color(0xFF26383E),
    line: Color(0xFF34484F),
    accent: ChatBrand.teal,
    accentText: ChatBrand.teal,
    onAccent: Color(0xFF092F30),
    emphasis: Color(0xFFF38F7F),
    emphasisText: Color(0xFFF38F7F),
    onEmphasis: Color(0xFF30120E),
    text: Color(0xFFF2F3F5),
    muted: Color(0xFFA0A4AC),
    faint: Color(0xFF5C6068),
    caution: Color(0xFFF3A443),
    danger: Color(0xFFEF6A6A),
    mediaStage: Color(0xFF101013),
    onStage: Color(0xFFFFFFFF),
    onStageMuted: Color(0xB8FFFFFF),
    thumb: Color(0xFF2A2D34),
    scrim: Color(0xA6000000),
    track: Color(0x1FFFFFFF),
    userBubble: Color(0xFF1B3F3D),
    assistantBubble: Color(0xFF19262B),
    shadow: Color(0x24000000),
  );

  static const light = CoachChatPalette(
    brightness: Brightness.light,
    skyTop: Color(0xFFFAFAF8),
    skyBottom: Color(0xFFEEF0EC),
    dust: Color(0xFF7D8781),
    background: Color(0xFFF4F5F3),
    surfaceLow: Color(0xFFF4F8F5),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFEBF2EE),
    line: Color(0xFFD7E3DC),
    accent: Color(0xFF0E7673),
    accentText: Color(0xFF0A6C69),
    onAccent: Color(0xFFFFFFFF),
    emphasis: ChatBrand.coral,
    emphasisText: Color(0xFFA83B2E),
    onEmphasis: Color(0xFF30120E),
    text: Color(0xFF121614),
    muted: Color(0xFF5D6661),
    faint: Color(0xFF9AA29E),
    caution: Color(0xFFB8650F),
    danger: Color(0xFFD43F3F),
    mediaStage: Color(0xFFEFEFEF),
    onStage: Color(0xFF121614),
    onStageMuted: Color(0xFF5D6661),
    thumb: Color(0xFFFFFFFF),
    scrim: Color(0x8C000000),
    track: Color(0x14000000),
    userBubble: Color(0xFFDCEFEA),
    assistantBubble: Color(0xFFFFFFFF),
    shadow: Color(0x0A142E24),
  );
}
