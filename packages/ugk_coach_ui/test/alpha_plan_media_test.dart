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
          size: const Size(360, 800),
          disableAnimations: reduced,
        ),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: CoachUiTheme(
                style: CoachUiStyle(
                  colors: CoachUiColors.fromTheme(theme),
                  typography: CoachUiTypography.fromTheme(theme),
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
