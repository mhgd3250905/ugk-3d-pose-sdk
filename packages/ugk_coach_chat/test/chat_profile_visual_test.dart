import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach_chat/src/theme/chat_theme.dart';
import 'package:ugk_coach_chat/src/theme/chat_tokens.dart';
import 'package:ugk_coach_chat/src/ui/coach_ui_adapter.dart';

import 'chat_controller_test.dart' show chatCatalog, chatPlan;

void main() {
  testWidgets(
    'profile theme and painter stay local to their own conversation',
    (tester) async {
      Widget profile(String id, Color accent, String family) => CoachChatTheme(
        visual: CoachChatVisuals(
          light: CoachChatPalette.light.copyWith(accent: accent),
          fontFamily: family,
          iconBuilder: (_, icon) => ColoredBox(
            key: ValueKey('paint-$id'),
            color: icon.color,
            child: SizedBox(width: icon.size, height: icon.size),
          ),
        ),
        child: Builder(
          builder: (context) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ChatIcon(
                ChatGlyph.bookmark,
                size: 21,
                color: ChatTheme.of(context).colors.accent,
              ),
              Text(id, style: ChatType.of(context).body),
            ],
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Row(
            children: [
              profile('Hip', Colors.blue, 'HipFont'),
              profile('Flare', Colors.orange, 'FlareFont'),
            ],
          ),
        ),
      );
      expect(
        tester
            .widget<ColoredBox>(find.byKey(const ValueKey('paint-Hip')))
            .color,
        Colors.blue,
      );
      expect(
        tester
            .widget<ColoredBox>(find.byKey(const ValueKey('paint-Flare')))
            .color,
        Colors.orange,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('paint-Hip'))),
        const Size(21, 21),
      );
      expect(
        tester.widget<Text>(find.text('Hip')).style!.fontFamily,
        'HipFont',
      );
      expect(
        tester.widget<Text>(find.text('Flare')).style!.fontFamily,
        'FlareFont',
      );
    },
  );

  test('dose unit overrides apply to plain and grouped action doses', () {
    const item = coach.PlanItem(
      exerciseId: 'one',
      mode: coach.DoseMode.reps,
      sets: 2,
      reps: 8,
      perSide: true,
      restSeconds: 0,
    );
    expect(chatDoseText(item), '2 组 × 每侧 8 次');
    expect(chatDoseText(item, unitLabels: {'one': '拍'}), '2 组 × 每侧 8 拍');
    final grouped = item.copyWith(
      segments: const [
        coach.PlanSegment(
          id: 'a',
          exerciseId: 'one',
          mode: coach.DoseMode.reps,
          reps: 8,
        ),
        coach.PlanSegment(
          id: 'b',
          exerciseId: 'two',
          mode: coach.DoseMode.time,
          workSeconds: 20,
        ),
      ],
    );
    expect(
      chatDoseText(grouped, unitLabels: {'one': '拍', 'two': '秒保持'}),
      '2 组 × (每侧 8 拍 + 每侧 20 秒保持)',
    );
  });

  test('legacy equipment IDs keep the original readable card label', () {
    final plan = const coach.PlanCodec().decode({
      ...chatPlan().toJson(),
      'equipment': ['mat'],
    });
    final routine = toCoachRoutine(plan, chatCatalog());
    expect(routine.gearLabel, '瑜伽垫');
    expect(routine.metaLabel, contains('瑜伽垫'));
  });
}
