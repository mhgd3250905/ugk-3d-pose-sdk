import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

void main() {
  testWidgets(
    'three surface levels use injected opaque colours and no sampling',
    (tester) async {
      final theme = TrainerTheme.dark.copyWith(
        background: const Color(0xFF101820),
        surface: const Color(0xFF263744),
        surfaceHigh: const Color(0xFF405465),
        border: const Color(0xFF5D7182),
        shadow: const Color(0x12010203),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              for (final level in TrainerSurfaceLevel.values)
                TrainerSurface(
                  key: ValueKey(level),
                  theme: theme,
                  level: level,
                  width: 120,
                  height: 48,
                  child: const Text('Surface'),
                ),
            ],
          ),
        ),
      );
      final expected = [theme.background, theme.surface, theme.surfaceHigh];
      for (final level in TrainerSurfaceLevel.values) {
        final surface = find.byKey(ValueKey(level));
        final decoration =
            tester
                    .widget<DecoratedBox>(
                      find.descendant(
                        of: surface,
                        matching: find.byType(DecoratedBox),
                      ),
                    )
                    .decoration
                as ShapeDecoration;
        expect(decoration.color, expected[level.index]);
        expect(decoration.color!.a, 1);
        expect(decoration.gradient, isNull);
        final border = decoration.shape as OutlinedBorder;
        expect(border.side.color, theme.border);
        expect(border.side.width, 1);
        expect(tester.getSize(surface), const Size(120, 48));
        if (level != TrainerSurfaceLevel.background) {
          expect(decoration.shadows!.single.color, theme.shadow);
        }
      }
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(ImageFiltered), findsNothing);
      expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
    },
  );

  test('copyWith covers the complete visual theme contract', () {
    final theme = TrainerTheme.light.copyWith(
      brightness: Brightness.dark,
      background: const Color(0xFF010101),
      surface: const Color(0xFF020202),
      surfaceHigh: const Color(0xFF030303),
      border: const Color(0xFF040404),
      shadow: const Color(0x10050505),
      track: const Color(0xFF060606),
      ringKnob: const Color(0xFF070707),
      accent: const Color(0xFF080808),
      accentSubtle: const Color(0xFF090909),
      accentText: const Color(0xFF0A0A0A),
      onAccent: const Color(0xFF0B0B0B),
      pausedColor: const Color(0xFF0C0C0C),
      onPaused: const Color(0xFF0D0D0D),
      text: const Color(0xFF0E0E0E),
      muted: const Color(0xFF0F0F0F),
      faint: const Color(0xFF101010),
      caution: const Color(0xFF111111),
      danger: const Color(0xFF121212),
      mediaStage: const Color(0xFF131313),
      fontFamily: 'HostFont',
      radius: 18,
    );
    final colours = [
      theme.background,
      theme.surface,
      theme.surfaceHigh,
      theme.border,
      theme.track,
      theme.ringKnob,
      theme.accent,
      theme.accentSubtle,
      theme.accentText,
      theme.onAccent,
      theme.pausedColor,
      theme.onPaused,
      theme.text,
      theme.muted,
      theme.faint,
      theme.caution,
      theme.danger,
      theme.mediaStage,
    ];
    expect(colours.map((colour) => colour.toARGB32()), [
      0xFF010101,
      0xFF020202,
      0xFF030303,
      0xFF040404,
      0xFF060606,
      0xFF070707,
      0xFF080808,
      0xFF090909,
      0xFF0A0A0A,
      0xFF0B0B0B,
      0xFF0C0C0C,
      0xFF0D0D0D,
      0xFF0E0E0E,
      0xFF0F0F0F,
      0xFF101010,
      0xFF111111,
      0xFF121212,
      0xFF131313,
    ]);
    expect(theme.shadow, const Color(0x10050505));
    expect(theme.isDark, isTrue);
    expect(theme.fontFamily, 'HostFont');
    expect(theme.radius, 18);
    expect(theme.body.fontFamily, 'HostFont');
    expect(theme.body.color, theme.text);
  });
}
