import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

const _stage = CoachMediaPalette(
  mediaStage: Colors.transparent,
  onStage: Colors.black,
  onStageMuted: Colors.grey,
);

CoachRoutine _plan(bool single, {String id = 'alpha'}) => CoachRoutine(
  id: id,
  title: 'Training',
  items: [
    const CoachRoutineItem(exerciseId: 'a', dose: '30 seconds'),
    if (!single) const CoachRoutineItem(exerciseId: 'b', dose: '30 seconds'),
  ],
  durationLabel: '1 minute',
  gearLabel: 'None',
  levelLabel: 'Easy',
  metaLabel: '2 moves',
);

final _library = CoachExerciseLibrary([
  for (final id in ['a', 'b'])
    CoachExercise(
      id: id,
      name: 'Move $id',
      poster: '$id-thumb.webp',
      cutout: '$id-cover.webp',
      stillCutout: '$id-still.webp',
      stage: _stage,
      cues: const ['Move slowly'],
    ),
]);

Future<void> _mount(
  WidgetTester tester, {
  double? inset,
  bool single = false,
  bool reduced = false,
  double scale = 1,
  double viewportWidth = 360,
  double parentWidth = 320,
  Brightness brightness = Brightness.light,
  Widget? Function(BuildContext, CoachMediaRequest)? media,
  CoachExerciseLibrary? library,
  Widget Function(BuildContext, CoachCardSurface)? surface,
  double? surfaceTopInset,
  VoidCallback? onOpen,
  VoidCallback? onStart,
  Key? captureKey,
}) async {
  final theme = ThemeData(brightness: brightness);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(viewportWidth, 800),
          textScaler: TextScaler.linear(scale),
          disableAnimations: reduced,
        ),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: parentWidth,
              child: RepaintBoundary(
                key: captureKey,
                child: CoachUiTheme(
                  style: CoachUiStyle(
                    colors: CoachUiColors.fromTheme(theme),
                    typography: CoachUiTypography.fromTheme(theme),
                    strings: const CoachUiStrings(
                      expand: '展开',
                      collapse: '收起',
                      expandDetails: '展开详情',
                      collapseDetails: '收起详情',
                      save: '保存',
                      saved: '已保存',
                      start: '开始训练',
                    ),
                    builders: CoachUiBuilders(media: media, surface: surface),
                  ),
                  child: CoachPlanCard(
                    plan: _plan(single),
                    library: library ?? _library,
                    saved: false,
                    cutoutTopInset: inset,
                    surfaceTopInset: surfaceTopInset,
                    onStart: (_) => onStart?.call(),
                    onSave: () {},
                    onOpen: onOpen ?? () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Widget _media(BuildContext context, CoachMediaRequest request) => ColoredBox(
  key: ValueKey('media-${request.asset}-${request.cutout}-${request.still}'),
  color: request.cutout ? Colors.orange : Colors.blue,
);

Widget Function(BuildContext, CoachCardSurface) _hostSurface(double top) =>
    (context, surface) => SizedBox(
      width: surface.width,
      child: Stack(
        fit: StackFit.passthrough,
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            top: top,
            child: DecoratedBox(
              key: const ValueKey('host-visible-surface'),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(surface.radius),
              ),
            ),
          ),
          Padding(
            padding: surface.padding ?? EdgeInsets.zero,
            child: surface.child,
          ),
        ],
      ),
    );

Widget _clippedHostSurface(BuildContext context, CoachCardSurface surface) =>
    SizedBox(
      width: surface.width,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(surface.radius),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
          ),
          child: Padding(
            padding: surface.padding ?? EdgeInsets.zero,
            child: surface.child,
          ),
        ),
      ),
    );

// A transparent cutout with a bright opaque shape close to its top. Sampling
// the rendered pixels checks both the actual paint and every ancestor clip,
// not just the image widget's layout rectangle.
class _CutoutMarker extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(
        size.width * .35,
        size.height * .04,
        size.width * .3,
        size.height * .12,
      ),
      Paint()..color = const Color(0xfff000d0),
    );
  }

  @override
  bool shouldRepaint(covariant _CutoutMarker oldDelegate) => false;
}

Widget _markerMedia(BuildContext context, CoachMediaRequest request) {
  if (!request.cutout) return _media(context, request);
  return CustomPaint(
    key: ValueKey('media-${request.asset}-${request.cutout}-${request.still}'),
    painter: _CutoutMarker(),
  );
}

Future<bool> _markerAboveCard(
  WidgetTester tester,
  Finder capture,
  Finder card,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(capture);
  final origin = tester.getTopLeft(capture);
  final cardTop = tester.getTopLeft(card).dy;
  final result = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return false;
      final bottom = (cardTop - origin.dy).floor().clamp(0, image.height);
      for (var y = 0; y < bottom; y++) {
        for (var x = 0; x < image.width; x++) {
          final offset = (y * image.width + x) * 4;
          if (data.getUint8(offset) > 230 &&
              data.getUint8(offset + 1) < 20 &&
              data.getUint8(offset + 2) > 190 &&
              data.getUint8(offset + 3) > 240) {
            return true;
          }
        }
      }
      return false;
    } finally {
      image.dispose();
    }
  });
  return result ?? false;
}

Future<void> _mountPair(WidgetTester tester) async {
  tester.view.physicalSize = const Size(400, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final theme = ThemeData();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: CoachUiTheme(
                style: CoachUiStyle(
                  colors: CoachUiColors.fromTheme(theme),
                  typography: CoachUiTypography.fromTheme(theme),
                  builders: CoachUiBuilders(media: _markerMedia),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final id in ['first', 'second'])
                      CoachPlanCard(
                        key: ValueKey('card-$id'),
                        plan: _plan(false, id: id),
                        library: _library,
                        saved: false,
                        onStart: (_) {},
                        onSave: () {},
                        onOpen: () {},
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _within(Finder parent, Key key) =>
    find.descendant(of: parent, matching: find.byKey(key));

void _expectPairClear(WidgetTester tester) {
  final first = find.byKey(const ValueKey('card-first'));
  final second = find.byKey(const ValueKey('card-second'));
  final firstBounds = tester.getRect(first);
  final secondBounds = tester.getRect(second);
  expect(firstBounds.bottom, lessThanOrEqualTo(secondBounds.top + .01));
  for (final card in [first, second]) {
    final bounds = tester.getRect(card);
    final fly = _within(card, const ValueKey('fly-hero'));
    final hero = _within(card, const ValueKey('media-a-cover.webp-true-false'));
    final active = fly.evaluate().isNotEmpty ? fly : hero;
    if (active.evaluate().isEmpty) continue;
    final image = tester.getRect(active.first);
    expect(image.top, greaterThanOrEqualTo(bounds.top - .01));
    expect(image.bottom, lessThanOrEqualTo(bounds.bottom + .01));
  }
  expect(tester.takeException(), isNull);
}

Future<void> _pairFrames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    _expectPairClear(tester);
  }
}

Finder get _card => find.byKey(const ValueKey('plan-card-paint-boundary'));
Finder get _start => find.byKey(const ValueKey('plan-start-alpha'));
Finder get _expand => find.byKey(const ValueKey('plan-expand-alpha'));
Finder get _hero => find.descendant(
  of: find.byKey(const ValueKey('plan-hero')),
  matching: find.byKey(const ValueKey('media-a-cover.webp-true-false')),
);

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'routine thumbnails use transparent still and theme stage $brightness',
      (tester) async {
        final requests = <CoachMediaRequest>[];
        await _mount(
          tester,
          brightness: brightness,
          media: (context, request) {
            requests.add(request);
            return _media(context, request);
          },
        );
        expect(
          find.byKey(const ValueKey('media-b-still.webp-true-true')),
          findsWidgets,
        );
        final stageFinder = find.byKey(const ValueKey('plan-thumbnail-stage'));
        expect(stageFinder, findsWidgets);
        final theme = CoachUiTheme.of(tester.element(stageFinder.first));
        for (final stage in tester.widgetList<ColoredBox>(stageFinder)) {
          expect(
            stage.color,
            theme.colors.stage.mediaStage.withValues(alpha: 1),
          );
          expect(
            stage.color.computeLuminance(),
            brightness == Brightness.light ? greaterThan(.5) : lessThan(.2),
          );
        }
        await tester.tap(_expand);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('media-a-still.webp-true-true')),
          findsWidgets,
        );
        expect(
          find.byKey(const ValueKey('media-b-still.webp-true-true')),
          findsWidgets,
        );
        expect(
          requests.any(
            (r) =>
                r.asset == 'b-still.webp' &&
                r.cutout &&
                r.still &&
                r.fit == BoxFit.contain,
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'routine thumbnails fall back to a host poster when no still exists',
    (tester) async {
      final requests = <CoachMediaRequest>[];
      await _mount(
        tester,
        library: CoachExerciseLibrary([
          for (final id in ['a', 'b'])
            CoachExercise(
              id: id,
              name: id,
              poster: '$id-poster.webp',
              stage: _stage,
            ),
        ]),
        media: (context, request) {
          requests.add(request);
          return _media(context, request);
        },
      );
      expect(
        requests.any((r) => r.asset == 'b-poster.webp' && !r.cutout && r.still),
        isTrue,
      );
      await tester.tap(_expand);
      await tester.pumpAndSettle();
      expect(
        requests.any((r) => r.asset == 'a-poster.webp' && !r.cutout && r.still),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'adjacent cutout cards reserve space throughout both directions',
    (tester) async {
      await _mountPair(tester);
      final first = find.byKey(const ValueKey('card-first'));
      final second = find.byKey(const ValueKey('card-second'));
      final secondHero = _within(
        second,
        const ValueKey('media-a-cover.webp-true-false'),
      );
      final firstFace = _within(
        first,
        const ValueKey('plan-card-paint-boundary'),
      );
      expect(
        tester.getRect(secondHero).top,
        greaterThanOrEqualTo(tester.getRect(firstFace).bottom - .01),
      );
      _expectPairClear(tester);
      final hero = tester.getRect(
        _within(first, const ValueKey('media-a-cover.webp-true-false')),
      );
      final toggle = find.byKey(const ValueKey('plan-expand-first'));
      await tester.tap(toggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      final fly = tester.getRect(_within(first, const ValueKey('fly-hero')));
      expect(fly.left, closeTo(hero.left, 1));
      expect(fly.top, closeTo(hero.top, 1));
      expect(fly.width, closeTo(hero.width, 1));
      expect(fly.height, closeTo(hero.height, 1));
      await _pairFrames(tester, 8);
      await tester.tap(toggle); // Reverse while the hero is still flying.
      await tester.pump();
      await _pairFrames(tester, 30);
      await tester.pumpAndSettle();
      _expectPairClear(tester);
      expect(
        tester.getRect(
          _within(first, const ValueKey('media-a-cover.webp-true-false')),
        ),
        hero,
      );
      await tester.tap(toggle);
      await tester.pump();
      await _pairFrames(tester, 36);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pump();
      await _pairFrames(tester, 30);
      await tester.pumpAndSettle();
      _expectPairClear(tester);
    },
  );

  testWidgets('null media result retains standard asset rendering', (
    tester,
  ) async {
    await _mount(tester);
    final before = tester.getRect(_card);
    final images = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => (image.image as AssetImage).assetName)
        .toList();
    await _mount(tester, media: (_, _) => null);
    expect(tester.getRect(_card), before);
    expect(
      tester
          .widgetList<Image>(find.byType(Image))
          .map((image) => (image.image as AssetImage).assetName)
          .toList(),
      images,
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'clipped host keeps cutout pixels through the first animation frame $brightness',
      (tester) async {
        const capture = ValueKey('clipped-host-capture');
        final captureFinder = find.byKey(capture);
        await _mount(
          tester,
          brightness: brightness,
          inset: 0,
          surface: _clippedHostSurface,
          surfaceTopInset: 0,
          media: _markerMedia,
          captureKey: capture,
        );
        final hero = tester.getRect(_hero);
        expect(
          await _markerAboveCard(tester, captureFinder, _card),
          isTrue,
          reason: 'the host clips its child, but the cutout must overhang',
        );
        await tester.tap(_expand);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1));
        final flyer = tester.getRect(find.byKey(const ValueKey('fly-hero')));
        expect(flyer.left, closeTo(hero.left, 1));
        expect(flyer.top, closeTo(hero.top, 1));
        expect(flyer.width, closeTo(hero.width, 1));
        expect(flyer.height, closeTo(hero.height, 1));
        expect(
          await _markerAboveCard(tester, captureFinder, _card),
          isTrue,
          reason: 'the flying cutout must stay visible above the clipped host',
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'feedback header has balanced inset and first-line toggle $brightness ${scale}x',
        (tester) async {
          await _mount(
            tester,
            brightness: brightness,
            scale: scale,
            viewportWidth: 320,
            media: _media,
          );
          await tester.tap(_expand);
          await tester.pumpAndSettle();
          final card = tester.getRect(_card);
          final titleFinder = find.byKey(const ValueKey('plan-header-title'));
          final metaFinder = find.byKey(const ValueKey('plan-header-meta'));
          final title = tester.getRect(titleFinder);
          final meta = tester.getRect(metaFinder);
          expect(title.top - card.top, closeTo(23, .01));
          expect(title.left - card.left, closeTo(23, .01));
          expect(meta.top - title.bottom, closeTo(5, .01));
          expect(
            tester.getRect(_expand).center.dy,
            closeTo(title.center.dy, .01),
          );
          expect(tester.getRect(_expand).left, greaterThan(title.right));
          final text = tester.widget<Text>(metaFinder);
          expect(text.style!.fontSize, 12);
          expect(text.style!.fontWeight, FontWeight.w400);
          final theme = CoachUiTheme.of(tester.element(metaFinder));
          expect(text.style!.color, theme.colors.muted);
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final (faceTop, override) in <(double, double?)>[(14, null), (0, 0)]) {
      testWidgets(
        'custom surface header measures from visible face $brightness top $faceTop',
        (tester) async {
          await _mount(
            tester,
            brightness: brightness,
            inset: 0,
            surface: _hostSurface(faceTop),
            surfaceTopInset: override,
            media: _media,
          );
          await tester.tap(_expand);
          await tester.pumpAndSettle();
          final face = tester.getRect(
            find.byKey(const ValueKey('host-visible-surface')),
          );
          final title = tester.getRect(
            find.byKey(const ValueKey('plan-header-title')),
          );
          expect(title.top - face.top, closeTo(23, .01));
          expect(title.left - face.left, closeTo(23, .01));
          expect(
            tester.getRect(_expand).center.dy,
            closeTo(title.center.dy, .01),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final inset in <double?>[null, 0]) {
      testWidgets(
        'cutout actually paints above the card $brightness inset $inset',
        (tester) async {
          const capture = ValueKey('cutout-pixel-capture');
          await _mount(
            tester,
            brightness: brightness,
            inset: inset,
            media: _markerMedia,
            captureKey: capture,
          );
          expect(
            await _markerAboveCard(tester, find.byKey(capture), _card),
            isTrue,
            reason: 'opaque cutout pixels must survive clipping above the face',
          );
        },
      );

      testWidgets(
        'feedback cutout overhang keeps title and controls clear $brightness inset $inset',
        (tester) async {
          await _mount(
            tester,
            brightness: brightness,
            inset: inset,
            media: _media,
          );
          final card = tester.getRect(_card);
          final hero = tester.getRect(_hero);
          expect(card.height, CoachPlanCard.cutoutSetHeight);
          expect(hero.top, closeTo(card.top - 58, .01));
          expect(hero.height, greaterThan(118 * 1.25));
          final foldedTitle = tester.getRect(
            find
                .descendant(
                  of: find.byKey(const ValueKey('plan-hero-title')),
                  matching: find.byType(Column),
                )
                .first,
          );
          expect(foldedTitle.top - hero.bottom, closeTo(8, .01));
          expect(hero.overlaps(tester.getRect(_start)), isFalse);
          final strip = find.byKey(
            const ValueKey('media-b-still.webp-true-true'),
          );
          expect(hero.overlaps(tester.getRect(strip)), isFalse);
          final firstFrame = hero;
          await tester.tap(_expand);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 1));
          final flyer = tester.getRect(find.byKey(const ValueKey('fly-hero')));
          expect(flyer.left, closeTo(firstFrame.left, 1));
          expect(flyer.top, closeTo(firstFrame.top, 1));
          expect(flyer.width, closeTo(firstFrame.width, 1));
          expect(flyer.height, closeTo(firstFrame.height, 1));
          await tester.pump(const Duration(milliseconds: 520));
          final landed = tester.getRect(find.byKey(const ValueKey('fly-hero')));
          final rowThumb = tester.getRect(
            find.byKey(const ValueKey('plan-row-thumb-1')),
          );
          expect(landed, rowThumb);
          await tester.pumpAndSettle();
          await tester.tap(_expand);
          await tester.pumpAndSettle();
          expect(tester.getRect(_hero), firstFrame);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'opt-in cutout keeps controls and opens its top padding $brightness',
      (tester) async {
        var opened = 0;
        var started = 0;
        await _mount(tester, brightness: brightness, media: _media);
        final oldCard = tester.getRect(_card);
        final oldStart = tester.getRect(_start);
        final oldExpand = tester.getRect(_expand);
        final oldHero = tester.getRect(_hero);
        await _mount(
          tester,
          brightness: brightness,
          inset: 0,
          media: _media,
          onOpen: () => opened++,
          onStart: () => started++,
        );
        expect(tester.getRect(_card), oldCard);
        expect(tester.getRect(_start), oldStart);
        expect(tester.getRect(_expand), oldExpand);
        final hero = tester.getRect(_hero);
        expect(hero.top, closeTo(oldCard.top - 58, .01));
        expect(hero.top, oldHero.top);
        expect(hero.bottom, oldHero.bottom);
        await tester.tapAt(Offset(hero.center.dx, hero.top + 2));
        expect(opened, 1);
        await tester.tap(_start);
        expect(started, 1);
        expect(opened, 1);
        await tester.tap(_expand);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('plan-cutout-padding-hit')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'cutout flyer uses host still renderer and shared starting frame',
    (tester) async {
      final requests = <CoachMediaRequest>[];
      await _mount(
        tester,
        inset: 0,
        media: (context, request) {
          requests.add(request);
          return _media(context, request);
        },
      );
      final hero = tester.getRect(_hero);
      requests.clear();
      await tester.tap(_expand);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      final fly = find.byKey(const ValueKey('fly-hero'));
      expect(fly, findsOneWidget);
      final rect = tester.getRect(fly);
      expect(rect.top, closeTo(hero.top, 1));
      expect(rect.height, closeTo(hero.height, 1));
      expect(
        requests.any(
          (request) =>
              request.asset == 'a-still.webp' &&
              request.cutout &&
              request.still &&
              request.alignment == Alignment.topCenter,
        ),
        isTrue,
      );
      await tester.pump(const Duration(milliseconds: 130));
      await tester.tap(_expand);
      await tester.pumpAndSettle();
      expect(tester.getRect(_hero), hero);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('single cutout top and reduced motion use host rendering', (
    tester,
  ) async {
    var opened = 0;
    final requests = <CoachMediaRequest>[];
    await _mount(
      tester,
      inset: 0,
      single: true,
      reduced: true,
      onOpen: () => opened++,
      media: (context, request) {
        requests.add(request);
        return _media(context, request);
      },
    );
    final media = find.byKey(const ValueKey('media-a-still.webp-true-true'));
    expect(tester.getRect(media).top, tester.getRect(_card).top);
    expect(
      requests
          .where((request) => request.cutout)
          .every((request) => request.still),
      isTrue,
    );
    await tester.tapAt(tester.getRect(media).topCenter + const Offset(0, 2));
    expect(opened, 1);
    await tester.tap(_expand);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fly-hero')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
