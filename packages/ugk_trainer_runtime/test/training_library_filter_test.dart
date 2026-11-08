import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

void main() {
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File(
      '../ugk_trainer/assets/pose_hub/app-pack-r2-v10/catalog.json',
    ).readAsBytesSync(),
  );
  final actions = catalog.semanticCompleteActions
      .where((a) => a.availableForApp)
      .toList();

  Future<void> mount(
    WidgetTester tester, {
    TrainingLibraryFilter initialFilter = const TrainingLibraryFilter(),
    TrainingLibraryConfig? config,
    Size size = const Size(390, 844),
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: TrainingLibraryBrowser(
          actions: actions,
          config: config,
          initialFilter: initialFilter,
          actionArtwork: (_, action, _) => const ColoredBox(color: Colors.teal),
          onOpenAction: (_) {},
        ),
      ),
    );
    await tester.pump();
  }

  int shown(WidgetTester tester) {
    final grid = find.byKey(const ValueKey('posehub-action-list'));
    if (grid.evaluate().isEmpty) return 0;
    return (tester.widget<GridView>(grid).childrenDelegate
            as SliverChildBuilderDelegate)
        .childCount!;
  }

  int expected(TrainingLibraryFilter filter) =>
      actions.where((a) => PoseHubActionFacets.matchesFilter(a, filter)).length;

  group('search', () {
    final squat = actions.firstWhere((a) => a.id == 'h-squat');

    test('matches Chinese names, id words and host names, any case', () {
      expect(
        PoseHubActionFacets.matches(squat, query: squat.nameZh.substring(0, 2)),
        isTrue,
      );
      expect(PoseHubActionFacets.matches(squat, query: 'SQUAT'), isTrue);
      expect(PoseHubActionFacets.matches(squat, query: 'h-squat'), isTrue);
      expect(PoseHubActionFacets.matches(squat, query: 'Goblet'), isFalse);
      expect(
        PoseHubActionFacets.matches(
          squat,
          query: 'goblet',
          extraNames: const ['Goblet squat'],
        ),
        isTrue,
      );
    });

    testWidgets('default hint and config search names', (tester) async {
      await mount(
        tester,
        config: TrainingLibraryConfig(
          scopeManifest: CoachActionScopeManifest.fromCatalogBytes(
            appId: 'test',
            catalogBytes: File(
              '../ugk_trainer/assets/pose_hub/app-pack-r2-v10/catalog.json',
            ).readAsBytesSync(),
            allowedActionIds: [for (final a in actions) a.id],
          ),
          searchNames: (id) => id == 'h-squat' ? const ['Air squat zz'] : [],
        ),
      );
      expect(find.text('搜动作，中文或英文都行'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('posehub-search')),
        'air squat zz',
      );
      await tester.pump();
      expect(shown(tester), 1);
      expect(find.byKey(const ValueKey('posehub-action-h-squat')), findsOne);
      await tester.tap(find.byKey(const ValueKey('posehub-search-clear')));
      await tester.pump();
      expect(shown(tester), actions.length);
    });
  });

  testWidgets('quick body-part pills, badge and 全部', (tester) async {
    await mount(tester);
    expect(find.byKey(const ValueKey('posehub-filter-badge')), findsNothing);
    expect(
      find.byKey(const ValueKey('posehub-filter-options-器械')),
      findsNothing,
    );
    final core = find.byKey(const ValueKey('posehub-quick-核心'));
    await tester.ensureVisible(core);
    await tester.pump();
    await tester.tap(core);
    await tester.pump();
    expect(
      shown(tester),
      expected(const TrainingLibraryFilter(bodyPart: '核心')),
    );
    expect(shown(tester), lessThan(actions.length));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('posehub-filter-badge')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    final all = find.byKey(const ValueKey('posehub-quick-全部'));
    await tester.scrollUntilVisible(
      all,
      -100,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('posehub-quick-options')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pump();
    await tester.tap(all);
    await tester.pump();
    expect(shown(tester), actions.length);
    expect(find.byKey(const ValueKey('posehub-filter-badge')), findsNothing);
  });

  testWidgets('sheet holds every facet, counts live, resets and applies', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('posehub-filter-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('posehub-filter-sheet')), findsOneWidget);
    for (final id in ['部位', '器械', '类型', 'level', 'side']) {
      expect(
        find.byKey(ValueKey('posehub-filter-section-$id')),
        findsOneWidget,
        reason: id,
      );
    }
    expect(find.text('查看 ${actions.length} 个动作'), findsOneWidget);
    Future<void> tap(String key) async {
      final chip = find.byKey(ValueKey(key));
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pump();
    }

    await tap('posehub-器械-徒手');
    await tap('posehub-level-1');
    await tap('posehub-side-unilateral');
    const draft = TrainingLibraryFilter(
      equipment: '徒手',
      level: 1,
      side: TrainingLibrarySide.unilateral,
    );
    final n = expected(draft);
    expect(n, greaterThan(0));
    expect(n, lessThan(actions.length));
    expect(find.text('查看 $n 个动作'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('posehub-filter-reset')));
    await tester.pump();
    expect(find.text('查看 ${actions.length} 个动作'), findsOneWidget);
    await tap('posehub-器械-徒手');
    await tap('posehub-level-1');
    await tap('posehub-side-unilateral');
    await tester.tap(find.byKey(const ValueKey('posehub-filter-apply')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('posehub-filter-sheet')), findsNothing);
    expect(shown(tester), n);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('posehub-filter-badge')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
    for (final a in actions.where(
      (a) => PoseHubActionFacets.matchesFilter(a, draft),
    )) {
      expect(PoseHubActionFacets.equipment(a), isEmpty);
      expect(a.raw['level'], 1);
      expect(a.raw['unilateral'], isTrue);
    }
  });

  testWidgets('initial muscle filter shows a removable pill', (tester) async {
    await mount(
      tester,
      initialFilter: const TrainingLibraryFilter(muscle: 'glute-max'),
    );
    final n = expected(const TrainingLibraryFilter(muscle: 'glute-max'));
    expect(n, greaterThan(0));
    expect(shown(tester), n);
    expect(find.text('臀大肌'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('posehub-quick-muscle')));
    await tester.pump();
    expect(shown(tester), actions.length);
  });

  testWidgets('initial body part and query are restored on first build', (
    tester,
  ) async {
    const filter = TrainingLibraryFilter(bodyPart: '背', query: 'row');
    await mount(tester, initialFilter: filter);
    expect(shown(tester), expected(filter));
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('posehub-search')))
          .controller!
          .text,
      'row',
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets('narrow 1.5x text does not overflow (${brightness.name})', (
      tester,
    ) async {
      await mount(
        tester,
        size: const Size(320, 640),
        textScale: 1.5,
        brightness: brightness,
        initialFilter: const TrainingLibraryFilter(
          muscle: 'abs',
          equipment: 'mat',
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('posehub-filter-button')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('posehub-filter-reset')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('posehub-filter-apply')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(shown(tester), actions.length);
    });
  }

  test('filter value semantics', () {
    const a = TrainingLibraryFilter(level: 2, muscle: 'lats');
    expect(a.activeCount, 2);
    expect(a.copyWith(clearLevel: true).level, isNull);
    expect(a.cleared(), const TrainingLibraryFilter());
    expect(a, const TrainingLibraryFilter(level: 2, muscle: 'lats'));
    expect(const TrainingLibraryFilter(query: ' x ').isEmpty, isFalse);
  });

  test('library strings cover 14 languages', () {
    expect(trainingLibraryStringsByLanguage.length, 14);
    final tags = trainingLibraryStringsByLanguage.keys.toSet();
    expect(tags, {
      'zh',
      'zh-Hant',
      'en',
      'ja',
      'ko',
      'de',
      'fr',
      'es',
      'it',
      'pt',
      'ru',
      'ar',
      'hi',
      'id',
    });
    for (final entry in trainingLibraryStringsByLanguage.entries) {
      final s = entry.value;
      for (final text in [
        s.title,
        s.searchHint,
        s.filter,
        s.reset,
        s.level,
        s.side,
        s.bilateral,
        s.unilateral,
        s.levelBeginner,
        s.levelBasic,
        s.levelAdvanced,
        s.muscleGroup,
      ]) {
        expect(text.trim(), isNotEmpty, reason: entry.key);
      }
      expect(s.viewResults, contains('{count}'), reason: entry.key);
      expect(s.activeFilters, contains('{count}'), reason: entry.key);
      expect(s.viewResultsFor(7), contains('7'));
    }
    expect(TrainingLibraryStrings.forLanguage('zh_TW').title, '動作庫');
    expect(TrainingLibraryStrings.forLanguage('en-US').filter, 'Filter');
    expect(TrainingLibraryStrings.forLanguage('xx').filter, '筛选');
  });
}
