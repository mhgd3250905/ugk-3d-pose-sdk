import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

void main() {
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('assets/pose_hub/app-test-pack-r1/catalog.json').readAsBytesSync(),
  );

  testWidgets('export the action library when requested', (tester) async {
    final capture = Platform.environment['TRAINER_LIBRARY_CAPTURE'];
    if (capture == null || capture.isEmpty) return;
    final font = File(r'C:\Windows\Fonts\msyh.ttc');
    if (font.existsSync()) {
      final loader = FontLoader('LibraryCapture')
        ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
      await loader.load();
    }
    final icons = FontLoader('packages/cupertino_icons/CupertinoIcons')
      ..addFont(
        rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
      );
    await icons.load();
    tester.view.physicalSize = const Size(414, 896);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final dark = Platform.environment['TRAINER_LIBRARY_THEME'] == 'dark';
    final theme = dark ? TrainerTheme.dark : TrainerTheme.light;
    const captureKey = ValueKey('library-capture');
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: dark ? Brightness.dark : Brightness.light,
          fontFamily: 'LibraryCapture',
        ),
        home: RepaintBoundary(
          key: captureKey,
          child: PoseHubActionBrowser(
            catalog: catalog,
            mediaBaseUri: Uri.parse('file:///pack/'),
            theme: theme.copyWith(fontFamily: 'LibraryCapture'),
          ),
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
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<void> mount(WidgetTester tester, {bool dark = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PoseHubActionBrowser(
          catalog: catalog,
          mediaBaseUri: Uri.parse('file:///pack/'),
          theme: (dark ? TrainerTheme.dark : TrainerTheme.light).copyWith(
            radius: 36,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'cards use 20px corners, transparent square art and two-line names',
    (tester) async {
      await mount(tester);
      final action = catalog.semanticCompleteActions.first;
      final area = find.byKey(ValueKey('posehub-image-area-${action.id}'));
      final size = tester.getSize(area);
      expect(size.width, closeTo(size.height, .01));
      expect(tester.widget<AspectRatio>(area).aspectRatio, 1);
      expect(
        find.descendant(of: area, matching: find.byType(DecoratedBox)),
        findsNothing,
      );
      final surface =
          tester
                  .widget<DecoratedBox>(
                    find.byKey(ValueKey('posehub-card-surface-${action.id}')),
                  )
                  .decoration
              as BoxDecoration;
      expect(surface.color, TrainerTheme.light.cardSurface);
      expect(surface.border!.top.color, TrainerTheme.light.cardBorder);
      expect(surface.border!.top.width, 1);
      final clip = tester.widget<ClipRRect>(
        find.byKey(ValueKey('posehub-card-clip-${action.id}')),
      );
      expect(clip.borderRadius, BorderRadius.circular(20));
      final name = tester.widget<Text>(find.text(action.nameZh));
      expect(name.maxLines, 2);
      expect(name.overflow, TextOverflow.ellipsis);
      expect(name.style!.fontSize, 15);
      expect(name.style!.fontWeight, FontWeight.w600);
      expect(name.style!.height, 1.35);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'selected facets are visible; clear restores search and every facet ${dark ? 'dark' : 'light'}',
      (tester) async {
        await mount(tester, dark: dark);
        final clear = find.byKey(const ValueKey('posehub-clear-filters'));
        expect(tester.widget<TextButton>(clear).onPressed, isNull);
        for (final key in ['posehub-器械-徒手', 'posehub-部位-核心', 'posehub-类型-力量']) {
          final chip = find.byKey(ValueKey(key));
          await tester.ensureVisible(chip);
          await tester.tap(chip);
          await tester.pump();
          final selected = tester.widget<ChoiceChip>(chip);
          expect(selected.selected, isTrue);
          expect(selected.showCheckmark, isTrue);
          final color = selected.selectedColor!;
          expect(color.g, greaterThan(color.r));
          expect(color.g, greaterThan(color.b));
        }
        expect(find.text('器械：徒手'), findsOneWidget);
        expect(find.text('部位：核心'), findsOneWidget);
        expect(find.text('类型：力量'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('posehub-search')),
          '没有这种动作',
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('posehub-empty-state')),
          findsOneWidget,
        );
        expect(find.text('试试其他关键词，或清除筛选'), findsOneWidget);
        await tester.tap(clear);
        await tester.pump();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('posehub-search')))
              .controller!
              .text,
          isEmpty,
        );
        expect(find.byType(GridView), findsOneWidget);
        expect(find.byKey(const ValueKey('posehub-empty-state')), findsNothing);
        for (final title in ['器械', '部位', '类型']) {
          final scroll = find.byKey(ValueKey('posehub-filter-options-$title'));
          await tester.drag(scroll, const Offset(1000, 0));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<ChoiceChip>(find.byKey(ValueKey('posehub-$title-全部')))
                .selected,
            isTrue,
          );
        }
        await tester.enterText(
          find.byKey(const ValueKey('posehub-search')),
          '没有这种动作',
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('posehub-empty-clear')));
        await tester.pump();
        expect(find.byType(GridView), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
