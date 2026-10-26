import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

const _stage = CoachMediaPalette(
  mediaStage: Colors.transparent,
  onStage: Colors.black,
  onStageMuted: Colors.grey,
);

CoachRoutine _plan(bool single) => CoachRoutine(
  id: 'alpha',
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
  VoidCallback? onOpen,
  VoidCallback? onStart,
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
                  builders: CoachUiBuilders(media: media),
                ),
                child: CoachPlanCard(
                  plan: _plan(single),
                  library: _library,
                  saved: false,
                  cutoutTopInset: inset,
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
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Widget _media(BuildContext context, CoachMediaRequest request) => ColoredBox(
  key: ValueKey('media-${request.asset}-${request.cutout}-${request.still}'),
  color: request.cutout ? Colors.orange : Colors.blue,
);

Finder get _card => find.byKey(const ValueKey('plan-card-paint-boundary'));
Finder get _start => find.byKey(const ValueKey('plan-start-alpha'));
Finder get _expand => find.byKey(const ValueKey('plan-expand-alpha'));
Finder get _hero => find.descendant(
  of: find.byKey(const ValueKey('plan-hero')),
  matching: find.byKey(const ValueKey('media-a-cover.webp-true-false')),
);

void main() {
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
          expect(title.top - card.top, closeTo(22, .01));
          expect(title.left - card.left, closeTo(22, .01));
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

    for (final inset in <double?>[null, 0]) {
      testWidgets(
        'feedback cutout grows 25–35 percent without covering title or controls $brightness inset $inset',
        (tester) async {
          await _mount(
            tester,
            brightness: brightness,
            inset: inset,
            media: _media,
          );
          final card = tester.getRect(_card);
          final hero = tester.getRect(_hero);
          final oldHeroHeight = inset == null ? 118.0 : 128.0;
          expect(card.height, CoachPlanCard.cutoutSetHeight);
          expect(hero.height / oldHeroHeight, inInclusiveRange(1.25, 1.35));
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
            const ValueKey('media-b-thumb.webp-false-true'),
          );
          expect(hero.overlaps(tester.getRect(strip)), isFalse);
          final firstFrame = hero;
          await tester.tap(_expand);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 1));
          final flyer = tester.getRect(find.byKey(const ValueKey('fly-hero')));
          expect(flyer.top, closeTo(firstFrame.top, 1));
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
        expect(hero.top, oldCard.top);
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
