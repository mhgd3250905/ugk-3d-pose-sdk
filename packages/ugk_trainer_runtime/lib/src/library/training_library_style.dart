import 'package:flutter/material.dart';

import '../ui/trainer_theme.dart';

/// The shared library defaults extracted from SF 52d30ae's palette/type and
/// sheet tokens. Fonts remain host assets; an explicit theme can rebrand them.
abstract final class TrainingLibraryStyle {
  static TrainerTheme themeOf(BuildContext context, TrainerTheme? supplied) {
    if (supplied != null) return supplied;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return (dark ? TrainerTheme.dark : TrainerTheme.light).copyWith(
      background: dark ? const Color(0xFF0B0C10) : const Color(0xFFF4F5F3),
      surface: dark ? const Color(0xFF19262B) : Colors.white,
      surfaceHigh: dark ? const Color(0xFF26383E) : const Color(0xFFEBF2EE),
      border: dark ? const Color(0xFF34484F) : const Color(0xFFD7E3DC),
      shadow: dark ? const Color(0x24000000) : const Color(0x0A142E24),
      accent: dark ? const Color(0xFF7AD4D5) : const Color(0xFF0E7673),
      accentText: dark ? const Color(0xFF7AD4D5) : const Color(0xFF0A6C69),
      onAccent: dark ? const Color(0xFF092F30) : Colors.white,
      text: dark ? const Color(0xFFF2F3F5) : const Color(0xFF121614),
      muted: dark ? const Color(0xFFA0A4AC) : const Color(0xFF5D6661),
      faint: dark ? const Color(0xFF5C6068) : const Color(0xFF9AA29E),
      mediaStage: dark ? const Color(0xFF101013) : const Color(0xFFEFEFEF),
      cardSurface: dark ? const Color(0xFF19262B) : Colors.white,
      cardBorder: dark ? const Color(0xFF34484F) : const Color(0xFFD7E3DC),
      fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
    );
  }

  static const sheetAnimation = AnimationStyle(
    duration: Duration(milliseconds: 400),
    reverseDuration: Duration(milliseconds: 340),
  );
  static const sheetShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
  );

  static TextStyle detailTitle(TrainerTheme theme) => theme.title.copyWith(
    fontSize: 22,
    fontWeight: FontWeight.w800,
    letterSpacing: -.1,
  );
}
