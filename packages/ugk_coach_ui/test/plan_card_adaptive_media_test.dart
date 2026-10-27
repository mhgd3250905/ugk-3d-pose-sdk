import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

const _asset = 'test-only-adaptive-shape.png';

class _ImageBundle extends CachingAssetBundle {
  _ImageBundle(this.png, {this.waitForImage});
  final Uint8List png;
  final Future<void>? waitForImage;

  @override
  Future<ByteData> load(String key) async {
    if (key != _asset) return rootBundle.load(key);
    if (waitForImage case final wait?) await wait;
    return ByteData.sublistView(png);
  }
}

Future<Uint8List> _image(Rect shape, {int width = 64, int height = 64}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(shape, Paint()..color = const Color(0xffff0000));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return Uint8List.fromList(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<Uint8List> _fixture(
  WidgetTester tester,
  Rect shape, {
  int width = 64,
  int height = 64,
}) async =>
    (await tester.runAsync(() => _image(shape, width: width, height: height)))!;

Future<void> _mount(
  WidgetTester tester,
  _ImageBundle bundle, {
  bool adaptive = true,
  bool clipped = false,
  bool immediateMedia = false,
}) async {
  final theme = ThemeData();
  const stage = CoachMediaPalette(
    mediaStage: Colors.transparent,
    onStage: Colors.black,
    onStageMuted: Colors.grey,
  );
  final library = CoachExerciseLibrary([
    const CoachExercise(
      id: 'a',
      name: 'Move',
      poster: _asset,
      cutout: _asset,
      stillCutout: _asset,
      stage: stage,
    ),
  ]);
  const plan = CoachRoutine(
    id: 'adaptive',
    title: 'Training',
    items: [
      CoachRoutineItem(exerciseId: 'a', dose: '30 seconds'),
      CoachRoutineItem(exerciseId: 'a', dose: '30 seconds'),
    ],
    durationLabel: '1 minute',
    gearLabel: 'None',
    levelLabel: 'Easy',
    metaLabel: '2 moves',
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: DefaultAssetBundle(
        bundle: bundle,
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: CoachUiTheme(
                style: CoachUiStyle(
                  colors: CoachUiColors.fromTheme(theme),
                  typography: CoachUiTypography.fromTheme(theme),
                  builders: CoachUiBuilders(
                    media: immediateMedia
                        ? (_, request) => request.cutout
                              ? const ColoredBox(color: Color(0xffff0000))
                              : const SizedBox.shrink()
                        : null,
                    surface: clipped
                        ? (context, surface) => ClipRRect(
                            borderRadius: BorderRadius.circular(surface.radius),
                            child: ColoredBox(
                              color: theme.colorScheme.surface,
                              child: Padding(
                                padding: surface.padding ?? EdgeInsets.zero,
                                child: surface.child,
                              ),
                            ),
                          )
                        : null,
                  ),
                ),
                child: RepaintBoundary(
                  key: const ValueKey('adaptive-capture'),
                  child: CoachPlanCard(
                    plan: plan,
                    library: library,
                    saved: false,
                    adaptCutoutScale: adaptive,
                    surfaceTopInset: clipped ? 0 : null,
                    onStart: (_) {},
                    onSave: () {},
                    onOpen: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _resolve(WidgetTester tester) async {
  // Image decoding and the downsampled alpha scan complete on engine threads.
  // Pump at the same fake time so the 400 ms timeout does not win the race.
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
  }
}

Rect _hero(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey('plan-hero')));

Future<Rect?> _redBounds(WidgetTester tester, {double? maxY}) async {
  final finder = find.byKey(const ValueKey('adaptive-capture'));
  final origin = tester.getTopLeft(finder);
  final boundary = tester.renderObject<RenderRepaintBoundary>(finder);
  return tester.runAsync<Rect?>(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) return null;
      var left = image.width, top = image.height, right = -1, bottom = -1;
      for (var y = 0; y < image.height; y++) {
        if (maxY != null && origin.dy + y >= maxY) break;
        for (var x = 0; x < image.width; x++) {
          final i = (y * image.width + x) * 4;
          if (bytes.getUint8(i) > 220 &&
              bytes.getUint8(i + 1) < 30 &&
              bytes.getUint8(i + 2) < 30 &&
              bytes.getUint8(i + 3) > 240) {
            if (x < left) left = x;
            if (x > right) right = x;
            if (y < top) top = y;
            if (y > bottom) bottom = y;
          }
        }
      }
      if (right < left || bottom < top) return null;
      return Rect.fromLTRB(
        origin.dx + left,
        origin.dy + top,
        origin.dx + right + 1,
        origin.dy + bottom + 1,
      );
    } finally {
      image.dispose();
    }
  });
}

Future<double?> _redTop(WidgetTester tester) async =>
    (await _redBounds(tester))?.top;

void main() {
  testWidgets('short cutout grows while a tall cutout keeps its size', (
    tester,
  ) async {
    // 37 / 64 ≈ .58: resembles a standing figure with transparent margins.
    final standing = _ImageBundle(
      await _fixture(tester, const Rect.fromLTWH(20, 14, 24, 37)),
    );
    await _mount(tester, standing, adaptive: false);
    await _resolve(tester);
    final base = _hero(tester);
    await _mount(tester, standing);
    await _resolve(tester);
    final enlarged = _hero(tester);
    expect(enlarged.height, greaterThan(base.height * 1.04));
    expect(enlarged.height, lessThanOrEqualTo(base.height * 1.151));
    expect(enlarged.bottom, closeTo(base.bottom, .01));

    // 58 / 64 ≈ .91: a tall seated figure needs no extra enlargement.
    final seated = _ImageBundle(
      await _fixture(tester, const Rect.fromLTWH(9, 3, 46, 58)),
    );
    await _mount(tester, seated, adaptive: false);
    await _resolve(tester);
    final seatedBase = _hero(tester);
    await _mount(tester, seated);
    await _resolve(tester);
    expect(_hero(tester).height, closeTo(seatedBase.height, .1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal and almost edge-to-edge cutouts stay reserved', (
    tester,
  ) async {
    for (final (shape, clipped) in [
      (const Rect.fromLTWH(2, 25, 60, 9), false),
      (const Rect.fromLTWH(2, 1, 60, 9), false),
      (const Rect.fromLTWH(2, 25, 60, 9), true),
      (const Rect.fromLTWH(2, 1, 60, 9), true),
    ]) {
      final bundle = _ImageBundle(await _fixture(tester, shape));
      await _mount(tester, bundle, adaptive: false, clipped: clipped);
      await _resolve(tester);
      final originalPixels = await _redBounds(
        tester,
        maxY: tester
            .getRect(find.byKey(const ValueKey('plan-start-adaptive')))
            .top,
      );
      await _mount(tester, bundle, clipped: clipped);
      await _resolve(tester);
      await tester.pump(const Duration(milliseconds: 200));
      final adjusted = _hero(tester);
      final outer = tester.getRect(find.byType(CoachPlanCard));
      final face = tester.getRect(
        find.byKey(const ValueKey('plan-card-paint-boundary')),
      );
      // BoxFit.contain uses the square's top alignment: the first opaque row
      // must remain inside the layout region reserved for this card.
      final imageSide = adjusted.width < adjusted.height
          ? adjusted.width
          : adjusted.height;
      final opaqueTop = adjusted.top + imageSide * shape.top / 64;
      expect(opaqueTop, greaterThanOrEqualTo(outer.top - .5));
      final painted = await _redBounds(
        tester,
        maxY: tester
            .getRect(find.byKey(const ValueKey('plan-start-adaptive')))
            .top,
      );
      expect(painted, isNotNull, reason: 'the cutout must actually paint');
      expect(painted!.top, closeTo(opaqueTop, 3));
      expect(painted.top, greaterThanOrEqualTo(face.top - .5));
      expect(painted.left, greaterThanOrEqualTo(face.left));
      expect(painted.right, lessThanOrEqualTo(face.right));
      expect(
        painted.overlaps(
          tester.getRect(find.byKey(const ValueKey('plan-expand-adaptive'))),
        ),
        isFalse,
      );
      final opaqueBottom = adjusted.top + imageSide * shape.bottom / 64;
      expect(
        opaqueBottom,
        lessThanOrEqualTo(tester.getRect(find.text('Training')).top - 6),
      );
      expect(
        painted.bottom,
        lessThanOrEqualTo(tester.getRect(find.text('Training')).top - 6),
      );
      if (shape.top == 25) {
        expect(originalPixels, isNotNull);
        expect(painted.width, greaterThan(originalPixels!.width * 1.2));
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('non-square horizontal assets stay within the visible face', (
    tester,
  ) async {
    final bundle = _ImageBundle(
      await _fixture(tester, const Rect.fromLTWH(0, 13, 192, 19), width: 192),
    );
    await _mount(tester, bundle);
    await _resolve(tester);
    await tester.pump(const Duration(milliseconds: 200));
    final face = tester.getRect(
      find.byKey(const ValueKey('plan-card-paint-boundary')),
    );
    final painted = await _redBounds(
      tester,
      maxY: tester
          .getRect(find.byKey(const ValueKey('plan-start-adaptive')))
          .top,
    );
    expect(painted, isNotNull);
    expect(painted!.top, greaterThanOrEqualTo(face.top));
    expect(painted.left, greaterThanOrEqualTo(face.left));
    expect(painted.right, lessThanOrEqualTo(face.right));
    expect(
      painted.bottom,
      lessThanOrEqualTo(tester.getRect(find.text('Training')).top - 6),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('non-square standing foreground stays inside its reserve', (
    tester,
  ) async {
    final bundle = _ImageBundle(
      await _fixture(tester, const Rect.fromLTWH(80, 13, 10, 37), width: 192),
    );
    await _mount(tester, bundle);
    await _resolve(tester);
    final face = tester.getRect(
      find.byKey(const ValueKey('plan-card-paint-boundary')),
    );
    final painted = await _redBounds(
      tester,
      maxY: tester
          .getRect(find.byKey(const ValueKey('plan-start-adaptive')))
          .top,
    );
    expect(painted, isNotNull);
    expect(painted!.top, greaterThanOrEqualTo(face.top - 58));
    expect(
      painted.bottom,
      lessThanOrEqualTo(tester.getRect(find.text('Training')).top - 6),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal foreground stays in the face while flying', (
    tester,
  ) async {
    final bundle = _ImageBundle(
      await _fixture(tester, const Rect.fromLTWH(2, 25, 60, 9)),
    );
    await _mount(tester, bundle);
    await _resolve(tester);
    await tester.pump(const Duration(milliseconds: 200));
    final toggle = find.byKey(const ValueKey('plan-expand-adaptive'));
    await tester.tap(toggle);
    await tester.pump();
    for (final ms in [1, 60, 80, 100, 100]) {
      await tester.pump(Duration(milliseconds: ms));
      final face = tester.getRect(
        find.byKey(const ValueKey('plan-card-paint-boundary')),
      );
      final painted = await _redBounds(tester);
      expect(painted, isNotNull);
      expect(painted!.top, greaterThanOrEqualTo(face.top - .5));
      expect(painted.left, greaterThanOrEqualTo(face.left - .5));
      expect(painted.right, lessThanOrEqualTo(face.right + .5));
    }
    await tester.tap(toggle);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('same asset path in different bundles does not share bounds', (
    tester,
  ) async {
    final short = _ImageBundle(
      await _fixture(tester, const Rect.fromLTWH(20, 14, 24, 37)),
    );
    final tall = _ImageBundle(
      await _fixture(tester, const Rect.fromLTWH(9, 3, 46, 58)),
    );
    await _mount(tester, short);
    await _resolve(tester);
    final shortRect = _hero(tester);
    // Rebuild the same state and asset path, changing only the bundle.
    await _mount(tester, tall);
    await _resolve(tester);
    final tallRect = _hero(tester);
    expect(shortRect.height, greaterThan(tallRect.height * 1.04));
    expect(tester.takeException(), isNull);
  });

  testWidgets('late alpha scan does not move the flyer mid-animation', (
    tester,
  ) async {
    final gate = Completer<void>();
    final bundle = _ImageBundle(
      await _fixture(tester, const Rect.fromLTWH(20, 14, 24, 37)),
      waitForImage: gate.future,
    );
    await _mount(tester, bundle, immediateMedia: true);
    final initial = _hero(tester);
    await tester.tap(find.byKey(const ValueKey('plan-expand-adaptive')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    final before = tester.getRect(find.byKey(const ValueKey('fly-hero')));
    final fly = find.byKey(const ValueKey('fly-hero'));
    final ancestorOpacities = tester.widgetList<Opacity>(
      find.ancestor(of: fly, matching: find.byType(Opacity)),
    );
    expect(ancestorOpacities.every((opacity) => opacity.opacity > 0), isTrue);
    expect(await _redTop(tester), isNotNull, reason: 'the flight must paint');
    expect(before.left, closeTo(initial.left, 1));
    expect(before.top, closeTo(initial.top, 1));
    expect(before.width, closeTo(initial.width, 1));
    expect(before.height, closeTo(initial.height, 1));
    gate.complete();
    await _resolve(tester);
    final after = tester.getRect(find.byKey(const ValueKey('fly-hero')));
    expect(after.left, closeTo(before.left, .01));
    expect(after.top, closeTo(before.top, .01));
    expect(after.width, closeTo(before.width, .01));
    expect(after.height, closeTo(before.height, .01));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
