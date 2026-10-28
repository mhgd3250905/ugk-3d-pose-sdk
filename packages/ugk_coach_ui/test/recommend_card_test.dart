import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

const _stage = CoachMediaPalette(
  mediaStage: Color(0xfff1f4f0),
  onStage: Color(0xff1d3028),
  onStageMuted: Color(0xff617267),
);

CoachExerciseLibrary _library({bool en = false, bool missing = false}) =>
    CoachExerciseLibrary([
      for (var i = 0; i < 6; i++)
        CoachExercise(
          id: 'move-$i',
          name: en ? 'Shoulder stretch $i' : '肩部拉伸$i',
          poster: missing ? '' : 'poster-$i.webp',
          stillCutout: missing ? null : 'first-frame-$i.webp',
          stage: _stage,
          levelLabel: en ? 'Beginner' : '初学',
          equipmentLabel: en ? 'Chair' : '椅子',
        ),
    ]);

Widget _app(
  Widget child, {
  double width = 360,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  bool en = false,
  Widget? Function(BuildContext, CoachMediaRequest)? media,
  Widget Function(BuildContext, CoachCardSurface)? surface,
  String? fontFamily,
}) {
  final theme = ThemeData(
    colorSchemeSeed: const Color(0xff417967),
    brightness: brightness,
    fontFamily: fontFamily,
  );
  return MaterialApp(
    theme: theme,
    home: MediaQuery(
      data: MediaQueryData(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: Scaffold(
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: width,
              child: CoachUiTheme(
                style: CoachUiStyle(
                  colors: CoachUiColors.fromTheme(theme),
                  typography: CoachUiTypography.fromTheme(theme),
                  strings: CoachUiStrings(
                    planFromActions: en ? 'Make a plan' : '排成计划',
                    actionUnavailable: en ? 'Action unavailable' : '动作暂不可用',
                  ),
                  builders: CoachUiBuilders(media: media, surface: surface),
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _media(BuildContext context, CoachMediaRequest request) => ColoredBox(
  key: ValueKey('media-${request.asset}'),
  color: Colors.green.withValues(alpha: .15),
);

void main() {
  testWidgets('one action uses a grid tile and delivers its original ID', (
    tester,
  ) async {
    final opened = <String>[];
    await tester.pumpWidget(
      _app(
        CoachRecommendCard(
          actionIds: const ['move-0'],
          note: '选择有牵扯感的动作，不憋气。',
          library: _library(),
          onOpenAction: opened.add,
        ),
        media: _media,
      ),
    );
    expect(find.text('选择有牵扯感的动作，不憋气。'), findsOneWidget);
    expect(find.text('肩部拉伸0'), findsOneWidget);
    expect(find.text('初学 · 椅子'), findsOneWidget);
    final tile = find.byKey(const ValueKey('recommend-action-move-0'));
    expect(tester.getSize(tile).width, 162);
    await tester.tap(find.text('肩部拉伸0'));
    expect(opened, ['move-0']);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('action cards follow the fixed grid specification $dark', (
      tester,
    ) async {
      final library = CoachExerciseLibrary([
        const CoachExercise(
          id: 'short',
          name: '短标题',
          poster: '',
          stage: _stage,
          levelLabel: '初学',
          equipmentLabel: '徒手',
        ),
        const CoachExercise(
          id: 'long',
          name: '一条超过两行仍然保留相同标题空间的动作标题',
          poster: '',
          stage: _stage,
        ),
        const CoachExercise(
          id: 'third',
          name: '第三个动作',
          poster: '',
          stage: _stage,
        ),
      ]);
      await tester.pumpWidget(
        _app(
          CoachRecommendCard(
            actionIds: const ['short', 'long', 'third'],
            note: '',
            library: library,
            onOpenAction: (_) {},
          ),
          brightness: dark ? Brightness.dark : Brightness.light,
        ),
      );
      final first = find.byKey(const ValueKey('recommend-action-short'));
      final second = find.byKey(const ValueKey('recommend-action-long'));
      final third = find.byKey(const ValueKey('recommend-action-third'));
      expect(tester.getSize(first), tester.getSize(second));
      expect(tester.getSize(first), tester.getSize(third));
      expect(tester.getTopLeft(second).dx - tester.getTopRight(first).dx, 12);
      expect(tester.getTopLeft(third).dy - tester.getBottomLeft(first).dy, 12);
      final art = tester.getRect(
        find.byKey(const ValueKey('recommend-image-area-short')),
      );
      expect(art.width, art.height);
      expect(art.left - tester.getTopLeft(first).dx, 12);
      expect(art.top - tester.getTopLeft(first).dy, 12);
      final surface =
          tester
                  .widget<DecoratedBox>(
                    find.byKey(const ValueKey('recommend-surface-short')),
                  )
                  .decoration
              as BoxDecoration;
      expect(
        surface.color,
        dark ? const Color(0xFF1A2324) : const Color(0xFFFFFFFF),
      );
      expect(surface.borderRadius, BorderRadius.circular(20));
      expect(surface.border!.top.width, 1);
      expect(
        surface.border!.top.color,
        dark
            ? const Color.from(alpha: .08, red: 1, green: 1, blue: 1)
            : const Color(0xFFE3E8E6),
      );
      expect(surface.gradient, isNull);
      final name = tester.widget<Text>(find.text('短标题'));
      expect(name.style!.fontSize, 15);
      expect(name.style!.fontWeight, FontWeight.w600);
      expect(name.style!.height, 1.35);
      expect(name.maxLines, 2);
      expect(name.overflow, TextOverflow.ellipsis);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('recommend-title-slot-short')))
            .height,
        40.5,
      );
      final tag = tester.widget<Text>(find.text('初学 · 徒手'));
      expect(tag.style!.fontSize, 12);
      expect(
        tester
            .getBottomLeft(find.byKey(const ValueKey('recommend-tags-short')))
            .dy,
        tester.getBottomLeft(first).dy - 12,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('six actions form two columns and plan callback keeps all IDs', (
    tester,
  ) async {
    final ids = [for (var i = 0; i < 6; i++) 'move-$i'];
    List<String>? planned;
    final opened = <String>[];
    await tester.pumpWidget(
      _app(
        CoachRecommendCard(
          actionIds: ids,
          note: '推荐这些动作。',
          library: _library(),
          onOpenAction: opened.add,
          onPlanFromActions: (value) => planned = value,
        ),
        media: _media,
      ),
    );
    final first = find.byKey(const ValueKey('recommend-action-move-0'));
    final second = find.byKey(const ValueKey('recommend-action-move-1'));
    final third = find.byKey(const ValueKey('recommend-action-move-2'));
    expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);
    expect(
      tester.getTopLeft(second).dx,
      greaterThan(tester.getTopLeft(first).dx),
    );
    expect(
      tester.getTopLeft(third).dy,
      greaterThan(tester.getTopLeft(first).dy),
    );
    expect(find.text('初学 · 椅子'), findsNWidgets(6));
    await tester.ensureVisible(find.text('肩部拉伸5'));
    await tester.tap(find.text('肩部拉伸5'));
    expect(opened, ['move-5']);
    await tester.ensureVisible(find.text('排成计划'));
    await tester.tap(find.text('排成计划'));
    expect(planned, ids);
    expect(tester.takeException(), isNull);
  });

  testWidgets('null planning callback does not build a planning button', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        CoachRecommendCard(
          actionIds: const ['move-0'],
          note: '',
          library: _library(),
          onOpenAction: (_) {},
        ),
        media: _media,
      ),
    );
    expect(find.byKey(const ValueKey('recommend-plan-button')), findsNothing);
    expect(find.text('排成计划'), findsNothing);
  });

  for (final en in [false, true]) {
    testWidgets(
      'catalogue names and facts follow ${en ? 'English' : 'Chinese'}',
      (tester) async {
        await tester.pumpWidget(
          _app(
            CoachRecommendCard(
              actionIds: const ['move-0'],
              note: en ? 'Keep breathing naturally.' : '保持自然呼吸。',
              library: _library(en: en),
              onOpenAction: (_) {},
              onPlanFromActions: (_) {},
            ),
            en: en,
            media: _media,
          ),
        );
        expect(find.text(en ? 'Shoulder stretch 0' : '肩部拉伸0'), findsOneWidget);
        expect(find.text(en ? 'Beginner · Chair' : '初学 · 椅子'), findsOneWidget);
        expect(find.text(en ? 'Make a plan' : '排成计划'), findsOneWidget);
        expect(find.text('move-0'), findsNothing);
      },
    );
  }

  testWidgets('missing catalogue/media shows a quiet placeholder without IDs', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        CoachRecommendCard(
          actionIds: const ['move-0', 'unknown-id'],
          note: '素材缺失时仍可浏览已知动作。',
          library: _library(missing: true),
          onOpenAction: (_) {},
        ),
      ),
    );
    expect(find.byIcon(Icons.fitness_center_outlined), findsNWidgets(2));
    expect(find.text('动作暂不可用'), findsOneWidget);
    expect(find.text('unknown-id'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'first frame uses the existing media override and static request',
    (tester) async {
      final requests = <CoachMediaRequest>[];
      await tester.pumpWidget(
        _app(
          CoachRecommendCard(
            actionIds: const ['move-0'],
            note: '从这里开始。',
            library: _library(),
            onOpenAction: (_) {},
          ),
          media: (context, request) {
            requests.add(request);
            return _media(context, request);
          },
        ),
      );
      final request = requests.single;
      expect(request.asset, 'first-frame-0.webp');
      expect(request.still, isTrue);
      expect(request.cutout, isTrue);
      expect(request.landing, isFalse);
      expect(request.fit, BoxFit.contain);
      expect(
        find.byKey(const ValueKey('media-first-frame-0.webp')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'poster fallback preserves no-spinner asset playback and error placeholder',
    (tester) async {
      await tester.pumpWidget(
        _app(
          CoachRecommendCard(
            actionIds: const ['fallback'],
            note: '从这里开始。',
            library: CoachExerciseLibrary([
              const CoachExercise(
                id: 'fallback',
                name: '无首帧动作',
                poster: 'missing-poster.webp',
                stage: _stage,
                levelLabel: '初学',
                equipmentLabel: '徒手',
              ),
            ]),
            onOpenAction: (_) {},
          ),
        ),
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.gaplessPlayback, isTrue);
      expect(image.frameBuilder, isNotNull);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.fitness_center_outlined), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow large text and dark host tokens stay within layout bounds',
    (tester) async {
      var surfaces = 0;
      await tester.pumpWidget(
        _app(
          CoachRecommendCard(
            actionIds: const [
              'move-0',
              'move-1',
              'move-2',
              'move-3',
              'move-4',
              'move-5',
            ],
            note: '动作和元信息随主题显示。',
            library: _library(),
            onOpenAction: (_) {},
            onPlanFromActions: (_) {},
          ),
          width: 240,
          textScale: 1.5,
          brightness: Brightness.dark,
          media: _media,
          surface: (_, surface) {
            surfaces++;
            return DecoratedBox(
              decoration: const BoxDecoration(color: Color(0xff17271e)),
              child: Padding(
                padding: surface.padding ?? EdgeInsets.zero,
                child: surface.child,
              ),
            );
          },
        ),
      );
      expect(surfaces, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('export a real Flutter six-action render when requested', (
    tester,
  ) async {
    final capture = Platform.environment['COACH_RECOMMEND_CAPTURE'];
    if (capture == null || capture.isEmpty) return;
    const captureKey = ValueKey('recommend-capture');
    final font = File(r'C:\Windows\Fonts\msyh.ttc');
    if (font.existsSync()) {
      final loader = FontLoader('RecommendCapture')
        ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
      await loader.load();
    }
    tester.view.physicalSize = const Size(414, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    const ids = [
      'h-chair-lat',
      'h-wall-angel',
      'o-seated-catcow',
      'o-seated-fig4',
      'h-wall-calf',
      'o-seated-ham',
    ];
    const names = ['扶椅背阔肌拉伸', '靠墙天使', '坐姿猫牛式', '坐姿四字前压', '靠墙小腿拉伸', '坐姿腘绳肌前伸'];
    final bytes = <String, Uint8List>{
      for (final id in ids)
        id: File(
          '../ugk_trainer/assets/pose_hub/app-test-pack-r1/standing/$id.webp',
        ).readAsBytesSync(),
    };
    final library = CoachExerciseLibrary([
      for (var i = 0; i < ids.length; i++)
        CoachExercise(
          id: ids[i],
          name: names[i],
          poster: '',
          stillCutout: '${ids[i]}.webp',
          stage: _stage,
          levelLabel: '初学',
          equipmentLabel: i == 1 || i == 4 ? '墙面' : '椅子',
        ),
    ]);
    await tester.pumpWidget(
      _app(
        RepaintBoundary(
          key: captureKey,
          child: CoachRecommendCard(
            actionIds: ids,
            note: '先从这几个动作试起，放松肩背和久坐紧绷的髋腿。保持自然呼吸，有牵扯感即可。',
            library: library,
            onOpenAction: (_) {},
            onPlanFromActions: (_) {},
          ),
        ),
        width: 390,
        brightness: Platform.environment['COACH_RECOMMEND_THEME'] == 'dark'
            ? Brightness.dark
            : Brightness.light,
        fontFamily: font.existsSync() ? 'RecommendCapture' : null,
        media: (_, request) => Image.memory(
          bytes[request.exercise.id]!,
          fit: request.fit,
          alignment: request.alignment,
          gaplessPlayback: true,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(captureKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(capture);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  });
}
