import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

// These expected images were generated from immutable caa6817c source, before
// iconBuilder, clearIconBuilder or cutoutBuilder existed. See the golden README.
const _capture = ValueKey('ui-kit-default-golden');

Future<void> _loadMaterialIcons() async {
  // Resolve the installed SDK through package:flutter rather than copying a
  // font into the package or relying on machine-specific absolute paths.
  final config = File('.dart_tool/package_config.json').absolute;
  final packages = jsonDecode(await config.readAsString())['packages'] as List;
  final flutter = packages.singleWhere((entry) => entry['name'] == 'flutter');
  final flutterPackage = Directory.fromUri(
    config.uri.resolve(flutter['rootUri'] as String),
  );
  final flutterSdk = flutterPackage.parent.parent;
  final font = File(
    '${flutterSdk.path}/bin/cache/artifacts/material_fonts/'
    'MaterialIcons-Regular.otf',
  );
  final loader = FontLoader('MaterialIcons')
    ..addFont(font.readAsBytes().then(ByteData.sublistView));
  await loader.load();
}

Future<MemoryImage> _cutout(WidgetTester tester, bool second) async {
  final bytes = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..color = second ? Colors.indigo : Colors.deepOrange;
    canvas.drawCircle(Offset(second ? 20 : 12, 7), 5, paint);
    canvas.drawPath(
      Path()
        ..moveTo(second ? 16 : 9, 13)
        ..lineTo(second ? 24 : 16, 13)
        ..lineTo(25, 31)
        ..lineTo(20, 33)
        ..lineTo(16, 23)
        ..lineTo(10, 33)
        ..lineTo(5, 30)
        ..close(),
      paint,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(32, 36);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    return Uint8List.fromList(data!.buffer.asUint8List());
  });
  return MemoryImage(bytes!);
}

Future<void> _show(
  WidgetTester tester, {
  required bool dark,
  required Widget child,
}) async {
  final theme = ThemeData(
    brightness: dark ? Brightness.dark : Brightness.light,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, child) =>
          CoachUiTheme(style: CoachUiStyle.fromTheme(theme), child: child!),
      home: Scaffold(
        body: RepaintBoundary(
          key: _capture,
          child: ColoredBox(
            color: theme.scaffoldBackgroundColor,
            child: SizedBox(
              width: 400,
              height: 240,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Align(alignment: Alignment.topLeft, child: child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _match(WidgetTester tester, String name) => expectLater(
  find.byKey(_capture),
  matchesGoldenFile('goldens/ui-kit-slots/$name.png'),
);

CoachTaskBubble _bubble({
  ImageProvider? Function(String actionId)? cutoutFor,
  bool complete = false,
}) => CoachTaskBubble(
  title: 'A plan for your day',
  status: 'Choosing 2 exercises',
  phase: complete ? 4 : 1,
  parameters: const [
    (field: 'scene', label: 'At home', user: true),
    (field: 'level', label: 'Beginner', user: false),
  ],
  picks: const ['squat', 'lunge'],
  complete: complete,
  waiting: !complete,
  onCancel: () {},
  cutoutFor: cutoutFor,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadMaterialIcons);

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    testWidgets('caa6817c default focus label pixels: $mode', (tester) async {
      tester.view.physicalSize = const Size(400, 240);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await _show(
        tester,
        dark: dark,
        child: PlanFocusLabel(title: 'Morning mobility', onClear: () {}),
      );
      await tester.pump(const Duration(milliseconds: 90));
      await _match(tester, 'focus-enter-90ms-$mode');
      await tester.pump(const Duration(milliseconds: 90));
      await _match(tester, 'focus-visible-$mode');

      // Supplying the old IconData parameters remains supported and unchanged.
      await _show(
        tester,
        dark: dark,
        child: PlanFocusLabel(
          title: 'Morning mobility',
          onClear: () {},
          icon: Icons.star_outline,
          clearIcon: Icons.cancel_outlined,
        ),
      );
      await _match(tester, 'focus-old-icon-data-$mode');
      await _show(
        tester,
        dark: dark,
        child: PlanFocusLabel(title: null, onClear: () {}),
      );
      await tester.pump(const Duration(milliseconds: 60));
      await _match(tester, 'focus-exit-60ms-$mode');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('caa6817c default task bubble pixels: $mode', (tester) async {
      tester.view.physicalSize = const Size(400, 240);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await _show(tester, dark: dark, child: _bubble());
      await tester.pump(const Duration(milliseconds: 450));
      await _match(tester, 'task-breath-450ms-$mode');
      await tester.pumpWidget(const SizedBox.shrink());

      final first = await _cutout(tester, false);
      final second = await _cutout(tester, true);
      ImageProvider cutoutFor(String id) => id == 'squat' ? first : second;
      await _show(
        tester,
        dark: dark,
        child: _bubble(cutoutFor: cutoutFor),
      );
      await tester.runAsync(() async {
        final context = tester.element(find.byType(CoachTaskBubble));
        await precacheImage(first, context);
        await precacheImage(second, context);
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 305));
      await _match(tester, 'task-cutout-reveal-305ms-$mode');
      await tester.pump(const Duration(milliseconds: 720));
      await _match(tester, 'task-cutout-crossfade-1025ms-$mode');
      await _show(
        tester,
        dark: dark,
        child: _bubble(cutoutFor: cutoutFor, complete: true),
      );
      await tester.pump(const Duration(milliseconds: 260));
      await _match(tester, 'task-complete-260ms-$mode');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
