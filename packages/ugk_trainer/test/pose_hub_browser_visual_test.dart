import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

void main() {
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('assets/pose_hub/app-test-pack-r1/catalog.json').readAsBytesSync(),
  );

  Future<void> mount(WidgetTester tester, {bool dark = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PoseHubActionBrowser(
          catalog: catalog,
          mediaBaseUri: Uri.parse('file:///pack/'),
          theme: (dark ? TrainerTheme.dark : TrainerTheme.light).copyWith(
            radius: 36,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'cards use 22px corners, square gradient art and two-line names',
    (tester) async {
      await mount(tester);
      final action = catalog.semanticCompleteActions.first;
      final area = find.byKey(ValueKey('posehub-image-area-${action.id}'));
      final size = tester.getSize(area);
      expect(size.width, closeTo(size.height, .01));
      final art = tester.widget<DecoratedBox>(area).decoration as BoxDecoration;
      expect(art.gradient, isA<LinearGradient>());
      final clip = tester.widget<ClipRRect>(
        find.byKey(ValueKey('posehub-card-clip-${action.id}')),
      );
      expect(clip.borderRadius, BorderRadius.circular(22));
      final name = tester.widget<Text>(find.text(action.nameZh));
      expect(name.maxLines, 2);
      expect(name.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'selected facets are visible; clear restores search and every facet ${dark ? 'dark' : 'light'}',
      (tester) async {
        await mount(tester, dark: dark);
        final clear = find.byKey(const ValueKey('posehub-clear-filters'));
        expect(tester.widget<TextButton>(clear).onPressed, isNull);
        for (final key in ['posehub-器械-徒手', 'posehub-部位-核心', 'posehub-类型-力量']) {
          final chip = find.byKey(ValueKey(key));
          await tester.ensureVisible(chip);
          await tester.tap(chip);
          await tester.pump();
          final selected = tester.widget<ChoiceChip>(chip);
          expect(selected.selected, isTrue);
          expect(selected.showCheckmark, isTrue);
          final color = selected.selectedColor!;
          expect(color.g, greaterThan(color.r));
          expect(color.g, greaterThan(color.b));
        }
        expect(find.text('器械：徒手'), findsOneWidget);
        expect(find.text('部位：核心'), findsOneWidget);
        expect(find.text('类型：力量'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('posehub-search')),
          '没有这种动作',
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('posehub-empty-state')),
          findsOneWidget,
        );
        expect(find.text('试试其他关键词，或清除筛选'), findsOneWidget);
        await tester.tap(clear);
        await tester.pump();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('posehub-search')))
              .controller!
              .text,
          isEmpty,
        );
        expect(find.byType(GridView), findsOneWidget);
        expect(find.byKey(const ValueKey('posehub-empty-state')), findsNothing);
        for (final title in ['器械', '部位', '类型']) {
          final scroll = find.byKey(ValueKey('posehub-filter-options-$title'));
          await tester.drag(scroll, const Offset(1000, 0));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<ChoiceChip>(find.byKey(ValueKey('posehub-$title-全部')))
                .selected,
            isTrue,
          );
        }
        await tester.enterText(
          find.byKey(const ValueKey('posehub-search')),
          '没有这种动作',
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('posehub-empty-clear')));
        await tester.pump();
        expect(find.byType(GridView), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
