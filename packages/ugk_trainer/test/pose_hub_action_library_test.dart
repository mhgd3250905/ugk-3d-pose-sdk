import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

class _PackBundle extends CachingAssetBundle {
  _PackBundle({
    this.corrupt = false,
    this.catalogBytes,
    this.extraFiles = const {},
  });
  final bool corrupt;
  final List<int>? catalogBytes;
  final Map<String, List<int>> extraFiles;
  @override
  Future<ByteData> load(String key) async {
    final path = key.replaceFirst('packages/ugk_trainer/', '');
    final rootCatalog =
        key.endsWith('/catalog.json') && !key.endsWith('/catalog/catalog.json');
    final provided = rootCatalog ? catalogBytes : extraFiles[key];
    final data = provided != null
        ? Uint8List.fromList(provided)
        : await File(path).readAsBytes();
    if (corrupt && rootCatalog) {
      data[0] = 0;
    }
    return ByteData.sublistView(data);
  }
}

Map<String, Object?> _futureRelease() {
  final data =
      jsonDecode(
            File(
              'assets/pose_hub/app-test-pack-r1/catalog.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  const version = 'posehub-app-test-pack-r1-v4';
  const prefix = 'pack/r1-v4/';
  const base = 'https://media.uuugk.win/$prefix';
  var files = 0;
  var bytes = 0;
  for (final raw in data['actions']! as List<Object?>) {
    final action = raw! as Map<String, Object?>;
    for (final value in (action['files']! as Map<String, Object?>).values) {
      final file = value! as Map<String, Object?>;
      final name = (file['path']! as String).split('/').last;
      file['assetName'] = name;
      file['downloadUrl'] = '$base${file['path']}';
      files++;
      bytes += file['bytes']! as int;
    }
  }
  data['mediaDistribution'] = {
    'version': version,
    'kind': 'r2-objects@1',
    'baseUrl': base,
    'pathRule': 'relative-path',
    'objectKeyPrefix': prefix,
    'mediaFiles': files,
    'mediaBytes': bytes,
  };
  return data;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PoseHubAppTestCatalog catalog;
  setUpAll(() async {
    catalog = await PoseHubActionLibrary.load(bundle: _PackBundle());
  });

  test('v3 standalone locations preserve the legacy whole-pack ZIP URL', () {
    const release =
        'https://github.com/mhgd3250905/ugk-3d-pose-sdk/releases/download/';
    expect(
      PoseHubActionLibrary.mediaReleaseBaseUri,
      'https://media.uuugk.win/pack/r1-v3/',
    );
    expect(
      PoseHubActionLibrary.catalogDownloadUri,
      '${release}posehub-app-test-pack-r1-v3/catalog.json',
    );
    expect(
      PoseHubActionLibrary.downloadUri,
      '${release}posehub-app-test-pack-r1-v2/posehub-app-test-pack-r1-v2.zip',
    );
  });

  test(
    'bundled audit digest records this release without gating future data',
    () async {
      final source = await File(
        'assets/pose_hub/app-test-pack-r1/catalog.json',
      ).readAsBytes();
      expect(
        sha256.convert(source).toString(),
        PoseHubActionLibrary.catalogSha256,
      );
    },
  );

  test(
    'bundled original metadata loads all 219 media identities unchanged',
    () {
      expect(catalog.allActions, hasLength(219));
      expect(catalog.semanticCompleteActions, hasLength(211));
      expect(catalog.pendingActions, hasLength(8));
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
      expect(catalog.toAiCatalog().drills, hasLength(211));
    },
  );

  test('malformed source JSON is rejected', () async {
    await expectLater(
      PoseHubActionLibrary.load(bundle: _PackBundle(corrupt: true)),
      throwsFormatException,
    );
  });

  test(
    'loader accepts a self-consistent future version without a hash pin',
    () async {
      final future = _futureRelease();
      final loaded = await PoseHubActionLibrary.load(
        bundle: _PackBundle(catalogBytes: utf8.encode(jsonEncode(future))),
      );
      expect(loaded.allActions, hasLength(219));
      expect(loaded.semanticCompleteActions, hasLength(211));
      expect(loaded.pendingActions, hasLength(8));
      expect(loaded.toAiCatalog().length, 211);
      expect(
        (loaded.raw['mediaDistribution']! as Map<String, Object?>)['version'],
        'posehub-app-test-pack-r1-v4',
      );
    },
  );

  test('loader rejects inconsistent future media manifests', () async {
    final future = _futureRelease();
    (future['mediaDistribution']! as Map<String, Object?>)['mediaFiles'] = 656;
    await expectLater(
      PoseHubActionLibrary.load(
        bundle: _PackBundle(catalogBytes: utf8.encode(jsonEncode(future))),
      ),
      throwsFormatException,
    );
  });

  test(
    'loader follows the canonical path declared by a future catalogue',
    () async {
      final future = _futureRelease();
      const path = 'catalog/revisions/v4.json';
      (future['semanticCatalog']! as Map<String, Object?>)['path'] = path;
      final canonicalBytes = await File(
        'assets/pose_hub/app-test-pack-r1/catalog/catalog.json',
      ).readAsBytes();
      final loaded = await PoseHubActionLibrary.load(
        bundle: _PackBundle(
          catalogBytes: utf8.encode(jsonEncode(future)),
          extraFiles: {
            '${PoseHubActionLibrary.assetRoot}$path': canonicalBytes,
          },
        ),
      );
      expect(loaded.semanticCatalogFile.path, path);
      expect(loaded.toAiCatalog().length, 211);
    },
  );

  testWidgets('browser lists all entries and separates the 8 pending actions', (
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
    await tester.pump();
    expect(find.text('动作库 · 219'), findsOneWidget);
    expect(find.text('显示 219 个动作'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('posehub-filter-pending')));
    await tester.pump();
    expect(find.text('显示 8 个动作'), findsOneWidget);
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
    expect(find.byKey(const ValueKey('posehub-pending-label')), findsOneWidget);
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
  });

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
