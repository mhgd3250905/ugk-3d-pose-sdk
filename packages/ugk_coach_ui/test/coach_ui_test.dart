import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';
// Exercise the copyable host adapter without exporting it as SDK runtime API.
// ignore: avoid_relative_lib_imports
import '../example/lib/host_conversation.dart';

void main() {
  Widget host(Widget child, {CoachUiStyle? style, ThemeData? theme}) =>
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: style == null
              ? child
              : CoachUiTheme(style: style, child: child),
        ),
      );

  testWidgets(
    'public host example composes a question and forwards its answer',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final answers = <String>[];
      await tester.pumpWidget(
        host(
          HostConversation(
            messages: [
              HostMessage(
                id: 'host-question',
                at: DateTime(2026),
                question: const CoachQuestionData(
                  id: 'host-question',
                  question: 'Where?',
                  mode: CoachQuestionMode.choice,
                  options: ['Home', 'Office'],
                ),
              ),
            ],
            controller: controller,
            catalog: CoachExerciseLibrary(const []),
            onAnswer: (id, text) async => answers.add('$id:$text'),
            onStart: (_, _) {},
            onSave: (_) {},
            onOpen: (_) {},
            isSaved: (_) => false,
            awaitingQuestionId: 'host-question',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(answers, ['host-question:Home']);
    },
  );

  testWidgets('text question submits trimmed text once while callback awaits', (
    tester,
  ) async {
    final answers = <String>[];
    final completion = Completer<void>();
    await tester.pumpWidget(
      host(
        CoachQuestionBubble(
          question: const CoachQuestionData(
            id: 'text',
            question: 'Where is it tight?',
            mode: CoachQuestionMode.text,
          ),
          enabled: true,
          onTextAnswer: (text) {
            answers.add(text);
            return completion.future;
          },
          onChoiceAnswer: (_) async {},
        ),
      ),
    );
    final input = find.byKey(const ValueKey('question-input-text'));
    final submit = find.byKey(const ValueKey('question-submit-text'));
    await tester.tap(submit);
    expect(answers, isEmpty);
    await tester.enterText(input, '  hips  ');
    await tester.pump();
    await tester.tap(submit);
    await tester.pump();
    expect(answers, ['hips']);
    expect(tester.widget<TextField>(input).enabled, isFalse);
    await tester.tap(submit);
    expect(answers, ['hips']);
    completion.complete();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'single choice answers immediately; disabled history cannot answer',
    (tester) async {
      final answers = <List<String>>[];
      const q = CoachQuestionData(
        id: 'choice',
        question: 'How long?',
        mode: CoachQuestionMode.choice,
        options: ['10 min', '20 min'],
      );
      Widget bubble(bool enabled) => CoachQuestionBubble(
        question: q,
        enabled: enabled,
        onTextAnswer: (_) async {},
        onChoiceAnswer: (value) async => answers.add(value),
      );
      await tester.pumpWidget(host(bubble(true)));
      await tester.tap(find.text('20 min'));
      await tester.pumpAndSettle();
      expect(answers, [
        ['20 min'],
      ]);
      await tester.pumpWidget(host(bubble(false)));
      await tester.tap(find.text('10 min'));
      await tester.pumpAndSettle();
      expect(answers, hasLength(1));
    },
  );

  testWidgets(
    'multiple choice toggles and submits in the original option order',
    (tester) async {
      final answers = <List<String>>[];
      await tester.pumpWidget(
        host(
          CoachQuestionBubble(
            question: const CoachQuestionData(
              id: 'multi',
              question: 'Which equipment?',
              mode: CoachQuestionMode.choice,
              options: ['Mat', 'Band', 'Chair'],
              multiple: true,
            ),
            enabled: true,
            onTextAnswer: (_) async {},
            onChoiceAnswer: (value) async => answers.add(value),
          ),
        ),
      );
      await tester.tap(find.text('Chair'));
      await tester.pump();
      await tester.tap(find.text('Mat'));
      await tester.pump();
      await tester.tap(find.text('Chair'));
      await tester.pump();
      expect(answers, isEmpty);
      await tester.tap(find.byKey(const ValueKey('question-submit-multi')));
      await tester.pumpAndSettle();
      expect(answers, [
        ['Mat'],
      ]);
    },
  );

  testWidgets(
    'answered question preserves selection and removes all answer controls',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        host(
          CoachQuestionBubble(
            question: const CoachQuestionData(
              id: 'old',
              question: 'Equipment?',
              mode: CoachQuestionMode.choice,
              options: ['Mat', 'Band'],
              multiple: true,
              answered: true,
              answeredChoices: ['Band'],
            ),
            enabled: true,
            onTextAnswer: (_) async {
              calls++;
            },
            onChoiceAnswer: (_) async {
              calls++;
            },
          ),
        ),
      );
      final pills = tester
          .widgetList<CoachOptionPill>(find.byType(CoachOptionPill))
          .toList();
      expect(pills.map((p) => p.enabled), everyElement(isFalse));
      expect(pills.singleWhere((p) => p.label == 'Band').chosen, isTrue);
      expect(find.byKey(const ValueKey('question-submit-old')), findsNothing);
      await tester.tap(find.text('Band'));
      expect(calls, 0);
    },
  );

  testWidgets(
    'host typography, colours and copy apply with no product dependency',
    (tester) async {
      final theme = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.purple),
        fontFamily: 'HostFont',
      );
      final style = CoachUiStyle(
        colors: CoachUiColors.fromTheme(theme),
        typography: CoachUiTypography.fromTheme(theme),
        strings: const CoachUiStrings(
          answerHint: 'Reply here',
          submitAnswer: 'Continue',
        ),
      );
      await tester.pumpWidget(
        host(
          CoachQuestionBubble(
            question: const CoachQuestionData(
              id: 'themed',
              question: 'Custom host question',
              mode: CoachQuestionMode.text,
            ),
            enabled: true,
            onTextAnswer: (_) async {},
            onChoiceAnswer: (_) async {},
          ),
          style: style,
        ),
      );
      expect(find.text('Reply here'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.text('Custom host question'))
            .style
            ?.fontFamily,
        'HostFont',
      );
      final decorations = tester.widgetList<DecoratedBox>(
        find.byType(DecoratedBox),
      );
      expect(
        decorations.any(
          (d) =>
              d.decoration is BoxDecoration &&
              (d.decoration as BoxDecoration).color ==
                  style.colors.assistantBubble,
        ),
        isTrue,
      );
    },
  );

  testWidgets(
    'routine expansion, save, detail and start callbacks remain independent',
    (tester) async {
      var saved = 0, opened = 0, started = 0;
      const stage = CoachMediaPalette(
        mediaStage: Colors.white,
        onStage: Colors.black,
        onStageMuted: Colors.grey,
      );
      final library = CoachExerciseLibrary(const [
        CoachExercise(
          id: 'a',
          name: 'First exercise',
          poster: 'unused-a',
          stage: stage,
        ),
        CoachExercise(
          id: 'b',
          name: 'Second exercise',
          poster: 'unused-b',
          stage: stage,
        ),
      ]);
      const routine = CoachRoutine(
        id: 'routine',
        title: 'Host routine',
        items: [
          CoachRoutineItem(exerciseId: 'a', dose: '10 reps'),
          CoachRoutineItem(exerciseId: 'b', dose: '20 seconds'),
        ],
        durationLabel: '2 minutes',
        gearLabel: 'No equipment',
        levelLabel: 'Easy',
        metaLabel: '2 minutes · 2 exercises',
      );
      await tester.pumpWidget(
        host(
          CoachPlanCard(
            plan: routine,
            library: library,
            saved: false,
            onSave: () => saved++,
            onOpen: () => opened++,
            onStart: (origin) {
              expect(origin(), isNotNull);
              started++;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('plan-open-routine')));
      expect(opened, 1);
      await tester.tap(find.byKey(const ValueKey('plan-start-routine')));
      expect(started, 1);
      await tester.tap(find.byKey(const ValueKey('plan-expand-routine')));
      await tester.pumpAndSettle();
      expect(find.text('First exercise'), findsOneWidget);
      expect(find.text('Second exercise'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('plan-save-routine')));
      expect(saved, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'list retains rows while appending and keeps latest at the bottom',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final at = DateTime(2026, 1, 1);
      Widget list(List<CoachChatEntry> rows) => host(
        CoachChatList(
          entries: rows,
          controller: controller,
          dockHeight: 0,
          initiallySeen: const {'a'},
          timeMarkBuilder: (_, _) => const Text('Today'),
        ),
      );
      final first = CoachChatEntry(
        id: 'a',
        at: at,
        isUser: true,
        child: const Text('First message'),
      );
      await tester.pumpWidget(list([first]));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        list([
          first,
          CoachChatEntry(
            id: 'b',
            at: at,
            isUser: false,
            child: const Text('Latest reply'),
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('First message'), findsOneWidget);
      expect(find.text('Latest reply'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Latest reply')).dy,
        greaterThan(tester.getTopLeft(find.text('First message')).dy),
      );
      expect(controller.offset, 0);
    },
  );
}
