import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

void main() {
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File(
      '../ugk_trainer/assets/pose_hub/app-pack-r2-v1/catalog.json',
    ).readAsBytesSync(),
  );
  final actions = catalog.semanticCompleteActions.take(2).toList();

  Future<void> mount(
    WidgetTester tester,
    ValueChanged<PoseHubPackAction> open,
  ) => tester.pumpWidget(
    MaterialApp(
      home: TrainingLibraryBrowser(
        actions: actions,
        actionArtwork: (_, action, _) => ColoredBox(
          key: ValueKey('injected-art-${action.id}'),
          color: Colors.teal,
        ),
        onOpenAction: open,
      ),
    ),
  );

  testWidgets(
    'public browser uses caller artwork and selection without a pack route',
    (tester) async {
      final opened = <String>[];
      await mount(tester, (action) => opened.add(action.id));
      expect(
        find.byKey(ValueKey('injected-art-${actions.first.id}')),
        findsOneWidget,
      );
      expect(find.byType(Image), findsNothing);
      await tester.tap(
        find.byKey(ValueKey('posehub-action-${actions.first.id}')),
      );
      expect(opened, [actions.first.id]);
      expect(find.byType(TrainerPlayer), findsNothing);
    },
  );

  testWidgets(
    'public browser filters the supplied actions and clears its query',
    (tester) async {
      await mount(tester, (_) {});
      await tester.enterText(
        find.byKey(const ValueKey('posehub-search')),
        '没有这样的动作',
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('posehub-empty-state')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('posehub-empty-clear')));
      await tester.pump();
      final grid = tester.widget<GridView>(
        find.byKey(const ValueKey('posehub-action-list')),
      );
      expect(
        (grid.childrenDelegate as SliverChildBuilderDelegate).childCount,
        actions.length,
      );
    },
  );

  testWidgets('browser hides retired but keeps not_recommended', (
    tester,
  ) async {
    final json =
        jsonDecode(
              File(
                '../ugk_trainer/assets/pose_hub/app-pack-r2-v1/catalog.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final ids = actions.map((a) => a.id).toList();
    for (final row in json['actions']! as List<Object?>) {
      final action = row! as Map<String, Object?>;
      if (action['id'] == ids[0]) action['status'] = 'not_recommended';
      if (action['id'] == ids[1]) action['status'] = 'retired';
    }
    final flagged = PoseHubAppTestCatalog.fromBytes(
      utf8.encode(jsonEncode(json)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: TrainingLibraryBrowser(
          actions: [for (final id in ids) flagged.tryGet(id)!],
          actionArtwork: (_, action, _) => const SizedBox(),
          onOpenAction: (_) {},
        ),
      ),
    );
    expect(find.byKey(ValueKey('posehub-action-${ids[0]}')), findsOneWidget);
    expect(find.byKey(ValueKey('posehub-action-${ids[1]}')), findsNothing);
    // Saved plans and history still resolve the retired action.
    expect(flagged.tryGet(ids[1])!.browsable, isFalse);
  });
}
