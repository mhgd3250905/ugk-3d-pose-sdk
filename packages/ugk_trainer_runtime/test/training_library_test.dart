import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

class _Bundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage({})!;
    }
    return ByteData.sublistView(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      ),
    );
  }
}

class _Repository implements CatalogMediaRepository {
  _Repository(this.catalog);
  @override
  final coach.PoseHubAppTestCatalog catalog;
  final requested = <String>[];
  @override
  Uri get mediaBaseUri => Uri.parse('file:///public-cache/');
  @override
  Future<Uri> ensureFile(coach.PoseHubPackFile file) {
    requested.add(file.path);
    return Completer<Uri>().future;
  }

  @override
  ValueListenable<CatalogMediaDownloadState> watchFile(
    coach.PoseHubPackFile file,
  ) => ValueNotifier(
    const CatalogMediaDownloadState(phase: CatalogMediaDownloadPhase.queued),
  );
  @override
  VoidCallback retainVideo(String actionId) => () {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Platform extends PackedAlphaPlatform {
  @override
  bool get isSupported => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late coach.PoseHubAppTestCatalog catalog;
  late coach.CoachActionScopeManifest scope;
  late TrainingLibraryConfig config;
  late _Repository repository;
  late TrainingMediaPolicy policy;
  setUpAll(() {
    final bytes = File(
      '../ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json',
    ).readAsBytesSync();
    catalog = coach.PoseHubAppTestCatalog.fromBytes(bytes);
    scope = coach.CoachActionScopeManifest.fromCatalogBytes(
      appId: 'test',
      catalogBytes: bytes,
      allowedActionIds: ['h-squat'],
    );
  });
  setUp(() {
    config = TrainingLibraryConfig(scopeManifest: scope);
    repository = _Repository(catalog);
    policy = TrainingMediaPolicy(
      repository: repository,
      posterAssetRoot: 'public/',
    );
    UgkPackedAlphaVideo.debugPlatform = _Platform();
  });
  tearDown(() => UgkPackedAlphaVideo.debugPlatform = null);

  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: DefaultAssetBundle(bundle: _Bundle(), child: child),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  test('library exposure uses the canonical scope manifest', () {
    expect(identical(config.scopeManifest, scope), isTrue);
    expect(config.actions(catalog).map((action) => action.id), ['h-squat']);
    expect(config.allowedActionIds.contains('supine-cross-demo'), isFalse);
  });

  testWidgets('public list uses the whitelist without requesting video', (
    tester,
  ) async {
    await mount(
      tester,
      TrainingLibraryPage(config: config, mediaPolicy: policy),
    );
    final grid = tester.widget<GridView>(
      find.byKey(const ValueKey('posehub-action-list')),
    );
    expect((grid.childrenDelegate as SliverChildBuilderDelegate).childCount, 1);
    final art = tester.widget<TrainingActionMedia>(
      find.byType(TrainingActionMedia),
    );
    expect(art.actionId, 'h-squat');
    expect(art.playing, isFalse);
    expect(repository.requested, isEmpty);
  });

  testWidgets('self-test artwork preserves right-side mirroring', (
    tester,
  ) async {
    await mount(
      tester,
      TrainingLibraryActionArt(
        actionId: 'h-squat',
        config: config,
        mediaPolicy: policy,
        mirrored: true,
      ),
    );
    final transforms = tester.widgetList<Transform>(
      find.descendant(
        of: find.byType(TrainingActionMedia),
        matching: find.byType(Transform),
      ),
    );
    expect(
      transforms.any(
        (widget) =>
            widget.transform.entry(0, 0) == -1 &&
            widget.transform.entry(1, 1) == 1,
      ),
      isTrue,
    );
    expect(repository.requested, isEmpty);
  });

  testWidgets(
    'brand, copy and category order configure shared search and clear',
    (tester) async {
      config = TrainingLibraryConfig(
        scopeManifest: scope,
        brand: 'Example',
        categoryOrder: const ['拉伸放松', '力量'],
        strings: const TrainingLibraryStrings(
          title: 'Moves',
          all: 'Any',
          emptyTitle: 'No moves',
          clear: 'Reset',
        ),
      );
      await mount(
        tester,
        TrainingLibraryPage(config: config, mediaPolicy: policy),
      );
      expect(find.text('Example · Moves'), findsOneWidget);
      expect(find.text('Any'), findsNWidgets(3));
      final options = tester
          .widgetList<ChoiceChip>(
            find.descendant(
              of: find.byKey(const ValueKey('posehub-filter-options-类型')),
              matching: find.byType(ChoiceChip),
            ),
          )
          .toList();
      expect(options.map((chip) => (chip.label as Text).data), [
        'Any',
        '拉伸放松',
        '力量',
      ]);
      await tester.enterText(
        find.byKey(const ValueKey('posehub-search')),
        '不存在动作',
      );
      await tester.pump();
      expect(find.text('No moves'), findsOneWidget);
      await tester.tap(find.text('Reset'));
      await tester.pump();
      expect(find.byKey(const ValueKey('posehub-action-list')), findsOneWidget);
      expect(repository.requested, isEmpty);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name} details defer download until explicit play',
      (tester) async {
        await mount(
          tester,
          Scaffold(
            body: TrainingLibraryDetail(
              action: catalog.tryGet('h-squat')!,
              config: config,
              mediaPolicy: policy,
            ),
          ),
          brightness: brightness,
        );
        expect(
          find.byKey(const ValueKey('library-detail-h-squat')),
          findsOneWidget,
        );
        expect(repository.requested, isEmpty);
        expect(
          tester
              .widget<TrainingActionMedia>(find.byType(TrainingActionMedia))
              .playing,
          isFalse,
        );
        await tester.tap(find.byKey(const ValueKey('library-detail-play')));
        await tester.pump();
        expect(repository.requested, [catalog.tryGet('h-squat')!.video.path]);
        expect(
          tester
              .widget<TrainingActionMedia>(find.byType(TrainingActionMedia))
              .playing,
          isTrue,
        );
      },
    );
  }

  testWidgets('default SF detail does not add a start action', (tester) async {
    await mount(
      tester,
      Scaffold(
        body: TrainingLibraryDetail(
          action: catalog.tryGet('h-squat')!,
          config: config,
          mediaPolicy: policy,
        ),
      ),
    );
    expect(find.byKey(const ValueKey('library-detail-start')), findsNothing);
    expect(find.text('力量 · 入门 · 徒手'), findsOneWidget);
    expect(repository.requested, isEmpty);
  });

  testWidgets('a blocked action cannot start from shared detail', (
    tester,
  ) async {
    config = TrainingLibraryConfig(scopeManifest: scope, showStartAction: true);
    await mount(
      tester,
      Scaffold(
        body: TrainingLibraryDetail(
          action: catalog.tryGet('h-squat')!,
          config: config,
          mediaPolicy: policy,
          canStart: false,
        ),
      ),
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('library-detail-start')),
          )
          .onPressed,
      isNull,
    );
    expect(repository.requested, isEmpty);
  });

  testWidgets('detail start delegates to host after closing its sheet', (
    tester,
  ) async {
    config = TrainingLibraryConfig(scopeManifest: scope, showStartAction: true);
    final started = <String>[];
    var nativePlayerStarted = false;
    late BuildContext source;
    await mount(
      tester,
      Builder(
        builder: (context) {
          source = context;
          return const Scaffold(body: Text('library source'));
        },
      ),
    );
    final opened = TrainingLibraryDetails.open(
      source,
      actionId: 'h-squat',
      config: config,
      mediaPolicy: policy,
      onStart: (id) async {
        nativePlayerStarted = find.byType(TrainerPlayer).evaluate().isNotEmpty;
        started.add(id);
      },
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<RawImage>(
            find.descendant(
              of: find.byType(TrainingLibraryDetail),
              matching: find.byType(RawImage),
            ),
          )
          .any((image) => image.image != null),
      isTrue,
      reason: 'The detail uses the same decoded poster key as the launcher',
    );
    final start = find.byKey(const ValueKey('library-detail-start'));
    await tester.ensureVisible(start);
    await tester.pumpAndSettle();
    await tester.tap(start);
    await tester.pumpAndSettle();
    await opened;
    expect(started, ['h-squat']);
    expect(nativePlayerStarted, isFalse);
    expect(find.byType(TrainingLibraryDetail), findsNothing);
    expect(repository.requested, isEmpty);
  });
}
