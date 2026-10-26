import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

class _PackBundle extends CachingAssetBundle {
  _PackBundle({this.corrupt = false});
  final bool corrupt;
  @override
  Future<ByteData> load(String key) async {
    final path = key.replaceFirst('packages/ugk_trainer/', '');
    final data = await File(path).readAsBytes();
    if (corrupt &&
        key.endsWith('/catalog.json') &&
        !key.endsWith('/catalog/catalog.json')) {
      data[0] = 0;
    }
    return ByteData.sublistView(data);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PoseHubAppTestCatalog catalog;
  setUpAll(() async {
    catalog = await PoseHubActionLibrary.load(bundle: _PackBundle());
  });

  test(
    'bundled original metadata loads all 219 media identities unchanged',
    () {
      expect(catalog.allActions, hasLength(219));
      expect(catalog.semanticCompleteActions, hasLength(142));
      expect(catalog.pendingActions, hasLength(77));
      expect(catalog.allActions.map((a) => a.id).toSet(), hasLength(219));
      for (final action in catalog.allActions) {
        expect(catalog.tryGet(action.id), same(action));
        for (final file in [action.video, action.cover, action.thumbnail]) {
          expect(
            file.resolve(Uri.parse('https://example.test/pack/')).path,
            '/pack/${file.path}',
          );
          expect(file.bytes, greaterThan(0));
        }
      }
      expect(catalog.toAiCatalog().drills, hasLength(142));
    },
  );

  test(
    'changed source bytes cannot masquerade as the checked R1 catalog',
    () async {
      await expectLater(
        PoseHubActionLibrary.load(bundle: _PackBundle(corrupt: true)),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'browser lists all entries and separates the 77 pending actions',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PoseHubActionBrowser(
            catalog: catalog,
            mediaBaseUri: Uri.parse('https://example.test/pack/'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('动作库 · 219'), findsOneWidget);
      expect(find.text('显示 219 个动作'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('posehub-filter-pending')));
      await tester.pump();
      expect(find.text('显示 77 个动作'), findsOneWidget);
      final pending = catalog.pendingActions.first;
      expect(
        find.byKey(ValueKey('posehub-action-${pending.id}')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(ValueKey('posehub-action-${pending.id}')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('posehub-pending-label')),
        300,
      );
      expect(
        find.byKey(const ValueKey('posehub-pending-label')),
        findsOneWidget,
      );
      expect(find.textContaining('原始建议：'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('posehub-practice')),
        200,
      );
      await tester.tap(find.byKey(const ValueKey('posehub-practice')));
      await tester.pumpAndSettle();
      expect(find.byType(PoseHubSinglePracticePage), findsOneWidget);
      await tester.scrollUntilVisible(find.text('开始单练'), 300);
      expect(find.text('开始单练'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('all 219 are addressable and search never renames an action ID', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PoseHubActionBrowser(
          catalog: catalog,
          mediaBaseUri: Uri.parse('https://example.test/pack/'),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('posehub-search')),
      catalog.allActions.last.id,
    );
    await tester.pump();
    expect(
      find.byKey(ValueKey('posehub-action-${catalog.allActions.last.id}')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(
          ValueKey('posehub-action-${catalog.allActions.last.id}'),
        ),
        matching: find.text(catalog.allActions.last.id),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'manual pending practice records real time and ends once without a dose',
    (tester) async {
      final action = catalog.pendingActions.first;
      final results = <PoseHubPracticeResult>[];
      await tester.pumpWidget(
        MaterialApp(
          home: PoseHubSinglePracticePage(
            action: action,
            mediaBaseUri: Uri.parse('https://example.test/pack/'),
            onFinished: results.add,
          ),
        ),
      );
      expect(find.textContaining('原始建议：'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('posehub-practice-toggle')),
        300,
      );
      await tester.tap(find.byKey(const ValueKey('posehub-practice-toggle')));
      await tester.pump();
      expect(find.text('暂停'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('posehub-practice-finish')),
        200,
      );
      await tester.tap(find.byKey(const ValueKey('posehub-practice-finish')));
      await tester.pump();
      expect(results, hasLength(1));
      expect(results.single.actionId, action.id);
      expect(results.single.trainingDefinitionComplete, isFalse);
      expect(find.text('单练已结束'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
