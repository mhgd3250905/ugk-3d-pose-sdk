import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

const _paintKey = ValueKey('host-cutout-paint');

class _HostCutoutPainter extends CustomPainter {
  const _HostCutoutPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // Like SfAlphaAsset's sourceRect painter, the host owns the crop and draw.
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.purple);
  }

  @override
  bool shouldRepaint(_HostCutoutPainter oldDelegate) => false;
}

Widget _cutout(String id) => Semantics(
  image: true,
  label: 'Action $id',
  child: ClipRect(
    key: ValueKey('host-clip-$id'),
    child: const CustomPaint(key: _paintKey, painter: _HostCutoutPainter()),
  ),
);

Future<void> _show(
  WidgetTester tester, {
  required Widget child,
  Brightness brightness = Brightness.light,
  Brightness? paletteBrightness,
  bool reduced = false,
}) async {
  final theme = ThemeData(brightness: brightness);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, child) => CoachUiTheme(
        style: CoachUiStyle(
          colors: CoachUiColors.fromTheme(
            theme,
          ).copyWith(brightness: paletteBrightness ?? brightness),
          typography: CoachUiTypography.fromTheme(theme),
        ),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        ),
      ),
      home: Scaffold(body: child),
    ),
  );
  await tester.pump();
}

Finder _thumbnail(String id) =>
    find.byKey(ValueKey('generation-thumbnail-$id'));

double _opacity(WidgetTester tester, Finder child) => tester
    .widget<Opacity>(
      find.ancestor(of: child, matching: find.byType(Opacity)).first,
    )
    .opacity;

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'host cutout receives the existing frame and $brightness palette',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final calls = <({String id, Size size, Brightness brightness})>[];
        await _show(
          tester,
          brightness: brightness,
          reduced: true,
          child: CoachTaskBubble(
            waiting: true,
            picks: const ['squat'],
            cutoutFor: (_) => throw StateError('renderer has precedence'),
            cutoutBuilder: (context, id, size, brightness) {
              calls.add((id: id, size: size, brightness: brightness));
              return _cutout(id);
            },
          ),
        );
        expect(calls, isNotEmpty);
        expect(
          calls,
          everyElement((
            id: 'squat',
            size: const Size.square(32),
            brightness: brightness,
          )),
        );
        expect(tester.getSize(find.byKey(_paintKey)), const Size.square(32));
        expect(
          tester.getSize(find.byKey(const ValueKey('generation-animation'))),
          const Size.square(44),
        );
        expect(find.byType(Image), findsNothing);
        expect(find.byType(ClipOval), findsNothing);
        expect(find.byKey(const ValueKey('host-clip-squat')), findsOneWidget);
        expect(find.bySemanticsLabel('Action squat'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(CoachTaskBubble),
            matching: find.byType(RepaintBoundary),
          ),
          findsNWidgets(4),
        );
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
    );
  }

  testWidgets('renderer brightness follows an overridden SDK palette', (
    tester,
  ) async {
    final received = <Brightness>[];
    await _show(
      tester,
      paletteBrightness: Brightness.dark,
      reduced: true,
      child: CoachTaskBubble(
        picks: const ['squat'],
        cutoutBuilder: (context, id, size, brightness) {
          received.add(brightness);
          return _cutout(id);
        },
      ),
    );
    expect(received, isNotEmpty);
    expect(received, everyElement(Brightness.dark));
  });

  testWidgets('empty picks retain the core without calling either source', (
    tester,
  ) async {
    await _show(
      tester,
      reduced: true,
      child: CoachTaskBubble(
        waiting: true,
        cutoutFor: (_) => throw StateError('no picked action'),
        cutoutBuilder: (_, _, _, _) => throw StateError('no picked action'),
      ),
    );
    expect(find.byKey(const ValueKey('generation-core')), findsOneWidget);
    expect(find.byKey(const ValueKey('generation-thumbnails')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing the renderer restores provider filtering and oval clip', (
    tester,
  ) async {
    final image = MemoryImage(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    const bubbleKey = ValueKey('same-bubble');
    await _show(
      tester,
      reduced: true,
      child: CoachTaskBubble(
        key: bubbleKey,
        picks: const ['missing', 'available'],
        cutoutBuilder: (context, id, size, brightness) => _cutout(id),
      ),
    );
    expect(_thumbnail('missing'), findsOneWidget);
    await _show(
      tester,
      reduced: true,
      child: CoachTaskBubble(
        key: bubbleKey,
        picks: const ['missing', 'available'],
        cutoutFor: (id) => id == 'available' ? image : null,
      ),
    );
    expect(_thumbnail('missing'), findsNothing);
    expect(_thumbnail('available'), findsOneWidget);
    expect(find.byType(ClipOval), findsOneWidget);
    final widget = tester.widget<Image>(_thumbnail('available'));
    expect(widget.image, same(image));
    expect(widget.fit, BoxFit.contain);
    expect(widget.alignment, Alignment.center);
    expect(widget.excludeFromSemantics, isTrue);
    await _show(
      tester,
      reduced: true,
      child: CoachTaskBubble(
        key: bubbleKey,
        picks: const ['missing'],
        cutoutFor: (_) => null,
      ),
    );
    expect(find.byKey(const ValueKey('generation-core')), findsOneWidget);
    expect(find.byKey(const ValueKey('generation-thumbnails')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('custom cutouts retain 180ms reveal and 900/250ms rotation', (
    tester,
  ) async {
    await _show(
      tester,
      child: CoachTaskBubble(
        waiting: true,
        picks: const ['squat', 'reach'],
        cutoutBuilder: (context, id, size, brightness) => _cutout(id),
      ),
    );
    final reveal = find
        .descendant(
          of: find.byKey(const ValueKey('generation-thumbnails')),
          matching: find.byType(Opacity),
        )
        .first;
    expect(tester.widget<Opacity>(reveal).opacity, 0);
    await tester.pump(const Duration(milliseconds: 180));
    expect(tester.widget<Opacity>(reveal).opacity, 0);
    await tester.pump(const Duration(milliseconds: 125));
    expect(tester.widget<Opacity>(reveal).opacity, closeTo(.5, .001));
    await tester.pump(const Duration(milliseconds: 125));
    expect(tester.widget<Opacity>(reveal).opacity, 1);
    await tester.pump(const Duration(milliseconds: 470));
    expect(_thumbnail('squat'), findsOneWidget);
    expect(_thumbnail('reach'), findsNothing);
    await tester.pump(const Duration(milliseconds: 125));
    expect(_opacity(tester, _thumbnail('squat')), closeTo(.5, .001));
    expect(_opacity(tester, _thumbnail('reach')), closeTo(.5, .001));
    await tester.pump(const Duration(milliseconds: 125));
    expect(_thumbnail('squat'), findsNothing);
    expect(_thumbnail('reach'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'reduced motion pins first custom cutout and picks updates reset',
    (tester) async {
      const bubbleKey = ValueKey('same-bubble');
      await _show(
        tester,
        reduced: true,
        child: CoachTaskBubble(
          key: bubbleKey,
          waiting: true,
          picks: const ['squat', 'reach'],
          cutoutBuilder: (context, id, size, brightness) => _cutout(id),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(_thumbnail('squat'), findsOneWidget);
      expect(_thumbnail('reach'), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      await _show(
        tester,
        reduced: true,
        child: CoachTaskBubble(
          key: bubbleKey,
          waiting: true,
          picks: const ['reach', 'balance'],
          cutoutBuilder: (context, id, size, brightness) => _cutout(id),
        ),
      );
      expect(_thumbnail('squat'), findsNothing);
      expect(_thumbnail('reach'), findsOneWidget);
      expect(_thumbnail('balance'), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('delivery completion clone retains the host renderer', (
    tester,
  ) async {
    Widget renderer(
      BuildContext context,
      String id,
      Size size,
      Brightness brightness,
    ) => _cutout(id);
    await _show(
      tester,
      child: CoachDeliveryTransition(
        preparing: true,
        child: CoachTaskBubble(
          waiting: true,
          picks: const ['squat'],
          cutoutBuilder: renderer,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 430));
    expect(find.byKey(_paintKey), findsOneWidget);
    await _show(
      tester,
      child: const CoachDeliveryTransition(
        preparing: false,
        successful: true,
        child: Text('Delivered plan'),
      ),
    );
    final completing = tester.widget<CoachTaskBubble>(
      find.byType(CoachTaskBubble),
    );
    expect(completing.visualComplete, isTrue);
    expect(completing.cutoutBuilder, same(renderer));
    expect(find.byKey(_paintKey), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(
      find.descendant(
        of: find.byType(CoachTaskBubble),
        matching: find.byType(RepaintBoundary),
      ),
      findsNWidgets(4),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
