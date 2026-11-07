import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

const _stage = CoachMediaPalette(
  mediaStage: Colors.white,
  onStage: Colors.black,
  onStageMuted: Colors.grey,
);

Widget _app(
  Widget child, {
  CoachUiBuilders builders = const CoachUiBuilders(),
}) {
  final theme = ThemeData();
  return MaterialApp(
    theme: theme,
    home: Scaffold(
      body: SingleChildScrollView(
        child: SizedBox(
          width: 360,
          child: CoachUiTheme(
            style: CoachUiStyle(
              colors: CoachUiColors.fromTheme(theme),
              typography: CoachUiTypography.fromTheme(theme),
              builders: builders,
            ),
            child: child,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'recommendations use catalogue thumbnails even without old assets',
    (tester) async {
      final requested = <bool>[];
      var hostCalls = 0;
      final exercise = CoachExercise(
        id: 'move',
        name: 'Current move',
        poster: '',
        stage: _stage,
        artworkBuilder: (_, {required bool thumbnail}) {
          requested.add(thumbnail);
          return const ColoredBox(
            key: ValueKey('catalogue-image'),
            color: Colors.green,
          );
        },
      );
      await tester.pumpWidget(
        _app(
          CoachRecommendCard(
            actionIds: const ['move'],
            note: '',
            library: CoachExerciseLibrary([exercise]),
            onOpenAction: (_) {},
          ),
          builders: CoachUiBuilders(
            media: (_, _) {
              hostCalls++;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(find.byKey(const ValueKey('catalogue-image')), findsOneWidget);
      expect(requested, [true]);
      expect(hostCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('plan hero uses cover while small action slots use thumbnails', (
    tester,
  ) async {
    final requests = <bool>[];
    final exercises = [
      for (final id in ['first', 'second'])
        CoachExercise(
          id: id,
          name: id,
          poster: '',
          stage: _stage,
          artworkBuilder: (_, {required bool thumbnail}) {
            requests.add(thumbnail);
            return ColoredBox(
              key: ValueKey('catalogue-$id-$thumbnail'),
              color: Colors.green,
            );
          },
        ),
    ];
    await tester.pumpWidget(
      _app(
        CoachPlanCard(
          plan: const CoachRoutine(
            id: 'plan',
            title: 'Current plan',
            items: [
              CoachRoutineItem(exerciseId: 'first', dose: '30s'),
              CoachRoutineItem(exerciseId: 'second', dose: '30s'),
            ],
            durationLabel: '1 min',
            gearLabel: '',
            levelLabel: '',
            metaLabel: '',
          ),
          library: CoachExerciseLibrary(exercises),
          saved: false,
          onStart: (_) {},
          onSave: () {},
          onOpen: () {},
        ),
      ),
    );
    expect(requests, containsAll([false, true]));
    expect(tester.takeException(), isNull);
  });
}
