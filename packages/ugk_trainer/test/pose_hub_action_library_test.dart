import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart' as engine;
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
              'assets/pose_hub/app-pack-r2-v2/catalog.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  const version = 'app-pack-r2-v3';
  const prefix = 'pack/r2-v3/';
  data['pack'] = 'r2-v3';
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

  test('bundled r2-v2 metadata, media still under r2-v1', () {
    expect(PoseHubActionLibrary.packVersion, 'r2-v2');
    expect(
      PoseHubActionLibrary.mediaReleaseBaseUri,
      'https://media.uuugk.win/pack/r2-v1/',
    );
    expect(
      PoseHubActionLibrary.mediaBaseUriFor(catalog).toString(),
      PoseHubActionLibrary.mediaReleaseBaseUri,
    );
    expect(
      PoseHubActionLibrary.catalogDownloadUri,
      'https://media.uuugk.win/pack/r2-v2/catalog.json',
    );
  });

  test(
    'bundled audit digest records this release without gating future data',
    () async {
      final source = await File(
        'assets/pose_hub/app-pack-r2-v2/catalog.json',
      ).readAsBytes();
      expect(
        sha256.convert(source).toString(),
        PoseHubActionLibrary.catalogSha256,
      );
    },
  );

  test('bundled r2-v2 metadata loads all 249 media identities unchanged', () {
    expect(catalog.allActions, hasLength(249));
    expect(catalog.semanticCompleteActions, hasLength(249));
    expect(catalog.pendingActions, isEmpty);
    expect(catalog.allActions.map((a) => a.id).toSet(), hasLength(249));
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
    expect(catalog.toAiCatalog().drills, hasLength(249));
  });

  test('AI catalog delivers each action pack execution rhythm', () {
    final ai = catalog.toAiCatalog();
    final rhythms = engine.rhythmsFromCatalog(ai);
    expect(rhythms, hasLength(249));
    var pairs = 0;
    for (final action in catalog.allActions) {
      final execution =
          (action.raw['rhythm']! as Map<String, Object?>)['execution']!
              as Map<String, Object?>;
      // Only the training pace travels; media fps/frames never do.
      expect(ai[action.id]!.raw['rhythm'], execution, reason: action.id);
      expect(action.executionRhythm, execution, reason: action.id);
      final rhythm = rhythms[action.id]!;
      expect(rhythm.source, engine.RhythmSource.catalog, reason: action.id);
      final expected = engine.Rhythm.fromJson(
        Map<String, dynamic>.from(execution),
      );
      expect(rhythm.toJson(), expected.toJson(), reason: action.id);
      if (rhythm.alternatePair) {
        pairs++;
        expect(execution['repUnit'], 'left+right', reason: action.id);
        expect(rhythm.pairFirstSide, execution['startingSide'] ?? 'right');
      }
    }
    expect(pairs, 23);
  });

  test('media rhythm is not delivered as a pace', () {
    final source =
        jsonDecode(
              File(
                'assets/pose_hub/app-pack-r2-v2/catalog.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final first = (source['actions']! as List).first as Map<String, Object?>;
    final rhythm = Map<String, Object?>.from(first['rhythm']! as Map)
      ..remove('execution');
    first['rhythm'] = rhythm;
    final loaded = PoseHubAppTestCatalog.fromJson(source);
    final id = first['id']! as String;
    expect(loaded.tryGet(id)!.executionRhythm, isNull);
    expect(loaded.toAiCatalog()[id]!.raw.containsKey('rhythm'), isFalse);
    final paced = engine.rhythmsFromCatalog(loaded.toAiCatalog())[id]!;
    expect(paced.source, isNot(engine.RhythmSource.catalog));
  });

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
      expect(loaded.allActions, hasLength(249));
      expect(loaded.semanticCompleteActions, hasLength(249));
      expect(loaded.pendingActions, isEmpty);
      expect(loaded.toAiCatalog().length, 249);
      expect(
        (loaded.raw['mediaDistribution']! as Map<String, Object?>)['version'],
        'app-pack-r2-v3',
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
        'assets/pose_hub/app-pack-r2-v2/catalog/catalog.json',
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
      expect(loaded.toAiCatalog().length, 249);
    },
  );

  testWidgets(
    'browser shows two columns, hides internals, searches names and opens trainer',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PoseHubActionBrowser(
            catalog: catalog,
            mediaBaseUri: Uri.parse('file:///pack/'),
          ),
        ),
      );
      expect(find.text('动作库'), findsOneWidget);
      expect(find.textContaining('249'), findsNothing);
      expect(find.textContaining('说明完整'), findsNothing);
      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        2,
      );
      expect(grid.childrenDelegate.estimatedChildCount, 249);
      final action = catalog.semanticCompleteActions.first;
      await tester.enterText(
        find.byKey(const ValueKey('posehub-search')),
        action.id,
      );
      await tester.pump();
      expect(
        find.byKey(ValueKey('posehub-action-${action.id}')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('posehub-search')),
        action.nameZh,
      );
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('posehub-action-${action.id}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(TrainerPlayer), findsOneWidget);
      final player = tester.widget<TrainerPlayer>(find.byType(TrainerPlayer));
      expect(player.startMode, TrainerStartMode.preview);
      expect(player.prepSeconds, 10);
      expect(
        player.drillOf(action.id)!.cues,
        (action.raw['cues'] as Map)['zh'],
      );
      expect(player.drillOf(action.id)!.cue, isNull);
      expect(find.textContaining('原始'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  test('facets combine real equipment, body parts and training type', () {
    final actions = catalog.semanticCompleteActions;
    final filtered = actions
        .where(
          (a) => PoseHubActionFacets.matches(
            a,
            equipment: 'mat',
            bodyPart: '核心',
            type: '力量',
          ),
        )
        .toList();
    expect(filtered, isNotEmpty);
    expect(
      filtered.every((a) => (a.raw['equipment'] as List).contains('mat')),
      isTrue,
    );
    expect(
      filtered.every(
        (a) => const ['core', 'strength'].contains(a.raw['category']),
      ),
      isTrue,
    );
    expect(catalog.pendingActions.any(PoseHubActionFacets.matches), isFalse);
    expect(
      actions.where((a) => PoseHubActionFacets.matches(a, equipment: '徒手')),
      everyElement(
        predicate<PoseHubPackAction>(
          (a) => (a.raw['equipment'] as List).isEmpty,
        ),
      ),
    );
    expect(
      actions
          .expand(PoseHubActionFacets.equipment)
          .toSet()
          .difference(poseHubEquipmentLabels.keys.toSet()),
      isEmpty,
    );
  });

  testWidgets(
    'single practice retains training default and forwards preview events',
    (tester) async {
      final action = catalog.semanticCompleteActions.first;
      TrainerPlayer? player;
      void started() {}
      Future<void> completed(SessionResult result) async {}
      for (final preview in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                final page = preview
                    ? PoseHubSinglePracticePage(
                        action: action,
                        mediaBaseUri: Uri.parse('file:///pack/'),
                        startMode: TrainerStartMode.preview,
                        onStartTraining: started,
                        onCompleted: completed,
                      )
                    : PoseHubSinglePracticePage(
                        action: action,
                        mediaBaseUri: Uri.parse('file:///pack/'),
                      );
                player = page.build(context) as TrainerPlayer;
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        expect(
          player!.startMode,
          preview ? TrainerStartMode.preview : TrainerStartMode.training,
        );
        expect(player!.prepSeconds, preview ? 10 : 0);
        expect(player!.onStartTraining, preview ? same(started) : isNull);
        expect(player!.onCompleted, preview ? same(completed) : isNull);
        final drill = player!.drillOf(action.id)!;
        expect(drill.cues, (action.raw['cues'] as Map)['zh']);
        expect(drill.targetMuscles, action.raw['muscleGroupsZh']);
        expect(drill.equipment, '瑜伽垫');
        expect(drill.thumbnailAsset, endsWith('/${action.id}.webp'));
      }
    },
  );

  testWidgets('two-column browser supports a 320px screen and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: PoseHubActionBrowser(
          catalog: catalog,
          mediaBaseUri: Uri.parse('file:///pack/'),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final first = catalog.semanticCompleteActions.first;
    final second = catalog.semanticCompleteActions[1];
    expect(
      tester.getTopLeft(find.byKey(ValueKey('posehub-action-${first.id}'))).dy,
      tester.getTopLeft(find.byKey(ValueKey('posehub-action-${second.id}'))).dy,
    );
    expect(
      tester.getSize(find.text(first.nameZh)).height,
      lessThanOrEqualTo(100),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
