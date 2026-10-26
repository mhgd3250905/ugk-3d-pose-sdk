import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

void main() {
  final cjkFont = Platform.environment['BROWSER_PREVIEW_CJK_FONT'];
  final iconFont = Platform.environment['BROWSER_PREVIEW_ICON_FONT'];
  testWidgets('local Chinese action browser preview', (tester) async {
    await (FontLoader('BrowserChinese')..addFont(
          Future.value(ByteData.sublistView(File(cjkFont!).readAsBytesSync())),
        ))
        .load();
    await (FontLoader('MaterialIcons')..addFont(
          Future.value(ByteData.sublistView(File(iconFont!).readAsBytesSync())),
        ))
        .load();
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
          rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        ))
        .load();
    final catalog = PoseHubAppTestCatalog.fromBytes(
      File('assets/pose_hub/app-test-pack-r1/catalog.json').readAsBytesSync(),
    );
    final output = Directory('../../.review-artifacts/feedback-release-browser')
      ..createSync(recursive: true);
    final boundaryKey = GlobalKey();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'BrowserChinese'),
        home: RepaintBoundary(
          key: boundaryKey,
          child: PoseHubActionBrowser(
            catalog: catalog,
            mediaBaseUri: Uri.parse('file:///pack/'),
            theme: TrainerTheme.light.copyWith(fontFamily: 'BrowserChinese'),
          ),
        ),
      ),
    );
    Future<void> capture(String name) async {
      await tester.runAsync(() async {
        for (final element in find.byType(Image).evaluate()) {
          final image = element.widget as Image;
          await precacheImage(image.image, element);
        }
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${output.path}/$name.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('browser-default');
    for (final key in ['posehub-器械-徒手', 'posehub-部位-核心', 'posehub-类型-力量']) {
      final chip = find.byKey(ValueKey(key));
      await Scrollable.ensureVisible(tester.element(chip), alignment: .5);
      await tester.pumpAndSettle();
      expect(chip.hitTestable(), findsOneWidget);
      await tester.tap(chip);
      await tester.pumpAndSettle();
    }
    await capture('browser-filtered');
    await tester.enterText(
      find.byKey(const ValueKey('posehub-search')),
      '不存在的动作',
    );
    await tester.pump();
    await capture('browser-empty');
    tester.view.physicalSize = const Size(320, 844);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          fontFamily: 'BrowserChinese',
        ),
        home: RepaintBoundary(
          key: boundaryKey,
          child: PoseHubActionBrowser(
            key: const ValueKey('dark-browser'),
            catalog: catalog,
            mediaBaseUri: Uri.parse('file:///pack/'),
            theme: TrainerTheme.dark.copyWith(fontFamily: 'BrowserChinese'),
          ),
        ),
      ),
    );
    await capture('browser-dark-320');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: cjkFont == null || iconFont == null);
}
