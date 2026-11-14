import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

const _title = '刚才感觉怎么样？';
const _description = '选一个，下一组帮你调整';
const _theme = TrainerTheme.playerV1;

Finder _card(TrainerRestFeedbackChoice choice) =>
    find.byKey(ValueKey('player-v1-rest-${choice.name}'));

Finder _inside(Finder card, Finder child) =>
    find.descendant(of: card, matching: child, matchRoot: true);

Finder _badge(Finder card) => _inside(card, find.byIcon(Icons.check_rounded));

BoxDecoration _decoration(WidgetTester tester, Finder card) =>
    tester
            .widget<AnimatedContainer>(
              _inside(card, find.byType(AnimatedContainer)),
            )
            .decoration!
        as BoxDecoration;

AnimatedOpacity _fade(WidgetTester tester, Finder card) =>
    tester.widget<AnimatedOpacity>(_inside(card, find.byType(AnimatedOpacity)));

Future<void> _mount(
  WidgetTester tester,
  WidgetBuilder builder, {
  bool reduced = false,
}) => tester.pumpWidget(
  MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(
        body: Center(
          child: SizedBox(width: 330, child: Builder(builder: builder)),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('legacy options render three equal semantic feedback cards', (
    tester,
  ) async {
    await _mount(
      tester,
      (_) => const TrainerRestFeedbackPanel(
        theme: _theme,
        title: _title,
        description: _description,
        comfortableLabel: '舒服',
        tightLabel: '有点紧',
        painLabel: '疼',
      ),
    );

    final title = tester.widget<Text>(find.text(_title));
    expect(title.textAlign, TextAlign.center);
    expect(title.style?.fontSize, 16);
    expect(title.style?.fontWeight, FontWeight.w600);
    expect(title.style?.color, const Color(0xFF1F2A2E));
    final subtitle = tester.widget<Text>(find.text(_description));
    expect(subtitle.textAlign, TextAlign.center);
    expect(subtitle.style?.fontSize, 12);
    expect(subtitle.style?.fontWeight, FontWeight.w400);
    expect(subtitle.style?.color, const Color(0xFF8A9499));

    final cases = [
      (
        TrainerRestFeedbackChoice.comfortable,
        '舒服',
        Icons.sentiment_satisfied_alt_rounded,
        const Color(0xFF1E9E78),
      ),
      (
        TrainerRestFeedbackChoice.tight,
        '有点紧',
        Icons.sentiment_neutral_rounded,
        const Color(0xFFE3A23B),
      ),
      (
        TrainerRestFeedbackChoice.pain,
        '疼',
        Icons.sentiment_dissatisfied_rounded,
        const Color(0xFFE5634D),
      ),
    ];
    Rect? previous;
    for (final (choice, label, symbol, color) in cases) {
      final card = _card(choice);
      final rect = tester.getRect(card);
      expect(rect.height, 84);
      expect(rect.width, closeTo((330 - 20) / 3, .01));
      if (previous != null) {
        expect(rect.left - previous.right, closeTo(10, .01));
      }
      previous = rect;

      final decoration = _decoration(tester, card);
      expect(decoration.color, color.withValues(alpha: .08));
      expect(decoration.borderRadius, BorderRadius.circular(18));
      final side = (decoration.border! as Border).top;
      expect(side.color, color.withValues(alpha: .22));
      expect(side.width, 1);
      final icon = tester.widget<Icon>(_inside(card, find.byIcon(symbol)));
      expect(icon.size, 26);
      expect(icon.color, color);
      final text = tester.widget<Text>(_inside(card, find.text(label)));
      expect(text.style?.fontSize, 15);
      expect(text.style?.fontWeight, FontWeight.w600);
      expect(text.style?.color, const Color(0xFF1F2A2E));
      expect(_badge(card), findsNothing);
    }
  });

  testWidgets(
    'selection marks one card and saves only when the choice changes',
    (tester) async {
      const comfortable = TrainerRestFeedbackChoice.comfortable;
      const tight = TrainerRestFeedbackChoice.tight;
      const pain = TrainerRestFeedbackChoice.pain;
      final calls = <TrainerRestFeedbackChoice>[];
      TrainerRestFeedbackChoice? selected;
      await _mount(
        tester,
        (_) => StatefulBuilder(
          builder: (_, setState) {
            void select(TrainerRestFeedbackChoice choice) => setState(() {
              calls.add(choice);
              selected = choice;
            });
            return TrainerRestFeedbackPanel(
              theme: _theme,
              title: _title,
              description: _description,
              recordedTitle: '已记录',
              selected: selected,
              comfortableLabel: '舒服',
              onComfortable: () => select(comfortable),
              tightLabel: '有点紧',
              onTight: () => select(tight),
              painLabel: '疼',
              onPain: () => select(pain),
            );
          },
        ),
      );

      final comfortableCard = _card(comfortable);
      final tightCard = _card(tight);
      final painCard = _card(pain);
      await tester.tap(comfortableCard);
      await tester.pumpAndSettle();
      expect(calls, [comfortable]);
      expect(find.text('已记录'), findsOneWidget);
      final badge = tester.widget<Icon>(_badge(comfortableCard));
      expect(badge.size, 12);
      expect(badge.color, Colors.white);
      expect(_badge(tightCard), findsNothing);
      expect(_badge(painCard), findsNothing);
      expect(_fade(tester, comfortableCard).opacity, 1);
      expect(_fade(tester, tightCard).opacity, .45);
      expect(_fade(tester, painCard).opacity, .45);
      final decoration = _decoration(tester, comfortableCard);
      expect(decoration.color, _theme.feedbackPositive.withValues(alpha: .16));
      final side = (decoration.border! as Border).top;
      expect(side.color, _theme.feedbackPositive);
      expect(side.width, 1.5);

      await tester.tap(comfortableCard);
      await tester.pumpAndSettle();
      expect(calls, [comfortable]);
      await tester.tap(tightCard);
      await tester.pumpAndSettle();
      expect(calls, [comfortable, tight]);
      expect(_badge(comfortableCard), findsNothing);
      expect(_badge(tightCard), findsOneWidget);
      expect(_fade(tester, comfortableCard).opacity, .45);
      expect(_fade(tester, tightCard).opacity, 1);
    },
  );

  testWidgets(
    'options infer tone by position and honor host colors and icons',
    (tester) async {
      const positive = Color(0xFF4488AA);
      const neutral = Color(0xFF1155BB);
      const negative = Color(0xFFCC2277);
      const themeOptions = [
        TrainerRestFeedbackOption(
          choice: TrainerRestFeedbackChoice.pain,
          label: 'First',
          icon: Icons.thumb_up_rounded,
        ),
        TrainerRestFeedbackOption(
          choice: TrainerRestFeedbackChoice.comfortable,
          label: 'Second',
        ),
        TrainerRestFeedbackOption(
          choice: TrainerRestFeedbackChoice.tight,
          label: 'Third',
        ),
      ];
      final theme = _theme.copyWith(
        feedbackPositive: positive,
        feedbackNeutral: neutral,
        feedbackNegative: negative,
      );
      Future<void> show(List<TrainerRestFeedbackOption> options) => _mount(
        tester,
        (_) => TrainerRestFeedbackPanel(
          theme: theme,
          title: _title,
          description: _description,
          options: options,
        ),
      );
      await show(themeOptions);
      final first = _card(TrainerRestFeedbackChoice.pain);
      final second = _card(TrainerRestFeedbackChoice.comfortable);
      final third = _card(TrainerRestFeedbackChoice.tight);
      expect(
        tester
            .widget<Icon>(_inside(first, find.byIcon(Icons.thumb_up_rounded)))
            .color,
        positive,
      );
      expect(
        tester
            .widget<Icon>(
              _inside(second, find.byIcon(Icons.sentiment_neutral_rounded)),
            )
            .color,
        neutral,
      );
      expect(
        tester
            .widget<Icon>(
              _inside(third, find.byIcon(Icons.sentiment_dissatisfied_rounded)),
            )
            .color,
        negative,
      );

      await show([
        const TrainerRestFeedbackOption(
          choice: TrainerRestFeedbackChoice.pain,
          label: 'First',
          tone: TrainerRestFeedbackTone.negative,
        ),
        ...themeOptions.skip(1),
      ]);
      await tester.pumpAndSettle();
      final override = _inside(
        first,
        find.byIcon(Icons.sentiment_dissatisfied_rounded),
      );
      expect(tester.widget<Icon>(override).color, negative);
    },
  );

  testWidgets('reduced rest feedback fades over 150 ms without scaling', (
    tester,
  ) async {
    const comfortable = TrainerRestFeedbackChoice.comfortable;
    final selectedCard = _card(comfortable);
    final dimmedCard = _card(TrainerRestFeedbackChoice.tight);
    TrainerRestFeedbackChoice? selected;
    await _mount(
      tester,
      (_) => StatefulBuilder(
        builder: (_, setState) => TrainerRestFeedbackPanel(
          theme: _theme,
          title: _title,
          selected: selected,
          comfortableLabel: '舒服',
          onComfortable: () => setState(() => selected = comfortable),
          tightLabel: '有点紧',
          painLabel: '疼',
        ),
      ),
      reduced: true,
    );
    await tester.tap(selectedCard);
    await tester.pumpAndSettle();
    expect(_inside(selectedCard, find.byType(ScaleTransition)), findsNothing);
    expect(_inside(selectedCard, find.byType(AnimatedScale)), findsNothing);
    expect(_badge(selectedCard), findsOneWidget);
    expect(
      _fade(tester, dimmedCard).duration,
      const Duration(milliseconds: 150),
    );
    expect(
      tester
          .widget<AnimatedContainer>(
            _inside(selectedCard, find.byType(AnimatedContainer)),
          )
          .duration,
      const Duration(milliseconds: 150),
    );
    expect(_fade(tester, dimmedCard).opacity, .45);
  });
}
