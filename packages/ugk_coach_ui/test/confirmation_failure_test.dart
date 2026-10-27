import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

const fields = [
  CoachQuestionField(
    key: 'scene',
    label: '场景',
    options: ['办公室', '家里', '健身房'],
    initialSelections: ['办公室'],
    previousSelections: ['办公室'],
  ),
  CoachQuestionField(
    key: 'equipment',
    label: '器械',
    options: ['徒手', '瑜伽垫', '椅子'],
    multiple: true,
    initialSelections: ['徒手'],
    previousSelections: ['徒手'],
    optionsByScene: {
      '办公室': ['徒手', '椅子'],
      '家里': ['徒手', '瑜伽垫'],
      '健身房': ['徒手', '瑜伽垫'],
    },
  ),
  CoachQuestionField(
    key: 'minutes',
    label: '时长',
    options: ['5 分钟', '10 分钟', '15 分钟'],
    initialSelections: ['10 分钟'],
    previousSelections: ['10 分钟'],
  ),
];

void main() {
  testWidgets(
    'confirmation starts preselected, permits edits and submits once',
    (tester) async {
      final done = Completer<void>();
      final answers = <Map<String, List<String>>>[];
      Widget host({Map<String, List<String>>? accepted}) => MaterialApp(
        home: Scaffold(
          body: CoachQuestionBubble(
            question: CoachQuestionData(
              id: 'confirm',
              question: '确认训练条件',
              mode: CoachQuestionMode.form,
              fields: fields,
              isConfirmation: true,
              focus: '大腿内侧拉伸',
              answered: accepted != null,
              answeredForm: accepted ?? const {},
            ),
            enabled: true,
            onTextAnswer: (_) async {},
            onChoiceAnswer: (_) async {},
            onFormAnswer: (answer) {
              answers.add(answer);
              return done.future;
            },
          ),
        ),
      );
      await tester.pumpWidget(host());
      Finder pill(String field, int index) =>
          find.byKey(ValueKey('question-field-confirm-$field-$index'));
      expect(tester.widget<CoachOptionPill>(pill('scene', 0)).chosen, isTrue);
      expect(
        tester.widget<CoachOptionPill>(pill('equipment', 0)).chosen,
        isTrue,
      );
      expect(tester.widget<CoachOptionPill>(pill('minutes', 1)).chosen, isTrue);
      expect(find.text('办公室 · 上次'), findsOneWidget);
      expect(find.text('大腿内侧拉伸'), findsOneWidget);
      expect(find.text('按默认来'), findsOneWidget);
      expect(pill('equipment', 1), findsNothing);
      await tester.tap(pill('scene', 1));
      await tester.pump();
      expect(pill('equipment', 2), findsNothing);
      await tester.tap(pill('equipment', 1));
      await tester.pump();
      expect(
        tester.widget<CoachOptionPill>(pill('equipment', 0)).chosen,
        isFalse,
      );
      expect(
        tester.widget<CoachOptionPill>(pill('equipment', 1)).chosen,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('question-submit-confirm')));
      await tester.pump();
      expect(answers, [
        {
          'scene': ['家里'],
          'equipment': ['瑜伽垫'],
          'minutes': ['10 分钟'],
        },
      ]);
      await tester.tap(find.byKey(const ValueKey('question-submit-confirm')));
      expect(answers, hasLength(1));
      done.complete();
      await tester.pump();
      // A completed Future<void> alone may mean rejected/cancelled. The
      // authoritative host must explicitly mark the form answered.
      expect(
        find.byKey(const ValueKey('question-submit-confirm')),
        findsOneWidget,
      );
      await tester.pumpWidget(host(accepted: answers.single));
      expect(find.text('家里 · 瑜伽垫 · 10 分钟'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('question-submit-confirm')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'answered confirmation restores saved values and disables edits',
    (tester) async {
      var submissions = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CoachQuestionBubble(
              question: const CoachQuestionData(
                id: 'history',
                question: '确认训练条件',
                mode: CoachQuestionMode.form,
                fields: fields,
                answered: true,
                answeredForm: {
                  'scene': ['家里'],
                  'equipment': ['椅子'],
                  'minutes': ['15 分钟'],
                },
              ),
              enabled: true,
              onTextAnswer: (_) async => submissions++,
              onChoiceAnswer: (_) async => submissions++,
            ),
          ),
        ),
      );
      final selected = find.byKey(
        const ValueKey('question-field-history-scene-1'),
      );
      final other = find.byKey(
        const ValueKey('question-field-history-scene-0'),
      );
      expect(tester.widget<CoachOptionPill>(selected).chosen, isTrue);
      await tester.tap(other);
      await tester.pump();
      expect(tester.widget<CoachOptionPill>(selected).chosen, isTrue);
      expect(submissions, 0);
      expect(
        find.byKey(const ValueKey('question-submit-history')),
        findsNothing,
      );
    },
  );

  testWidgets('default action collapses only after host accepts conditions', (
    tester,
  ) async {
    var skips = 0;
    Widget host({bool accepted = false}) => MaterialApp(
      home: Scaffold(
        body: CoachQuestionBubble(
          question: CoachQuestionData(
            id: 'default',
            question: '确认训练条件',
            mode: CoachQuestionMode.form,
            isConfirmation: true,
            fields: fields,
            defaultSelections: {
              'scene': ['家里'],
              'equipment': ['徒手'],
              'minutes': ['15 分钟'],
            },
            answered: accepted,
            answeredForm: accepted
                ? const {
                    'scene': ['家里'],
                    'equipment': ['徒手'],
                    'minutes': ['15 分钟'],
                  }
                : const {},
          ),
          enabled: true,
          onTextAnswer: (_) async {},
          onChoiceAnswer: (_) async {},
          onSkip: () async => skips++,
        ),
      ),
    );
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const ValueKey('question-skip-default')));
    await tester.pump();
    expect(skips, 1);
    expect(find.text('确认训练条件'), findsOneWidget);
    await tester.pumpWidget(host(accepted: true));
    expect(find.text('家里 · 徒手 · 15 分钟'), findsOneWidget);
    expect(find.text('确认训练条件'), findsNothing);
  });

  for (final outcome in ['rejected', 'cancelled', 'failed']) {
    testWidgets('a $outcome callback does not locally mark confirmation answered', (
      tester,
    ) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CoachQuestionBubble(
              question: const CoachQuestionData(
                id: 'unaccepted',
                question: '确认训练条件',
                mode: CoachQuestionMode.form,
                isConfirmation: true,
                fields: fields,
              ),
              enabled: true,
              onTextAnswer: (_) async {},
              onChoiceAnswer: (_) async {},
              // Host adapters returning Future<void> may hide a null, cancellation,
              // or failed result. No accepted state is published in any such case.
              onFormAnswer: (_) async {
                calls++;
              },
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('question-submit-unaccepted')),
      );
      await tester.pump();
      expect(calls, 1);
      expect(
        find.byKey(const ValueKey('question-summary-unaccepted')),
        findsNothing,
      );
      final button = tester.widget<ElevatedButton>(
        find.byKey(const ValueKey('question-submit-unaccepted')),
      );
      expect(button.onPressed, isNotNull);
    });
  }

  testWidgets('confirmed card stays collapsed when later generation fails', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CoachQuestionBubble(
            question: const CoachQuestionData(
              id: 'accepted',
              question: '确认训练条件',
              mode: CoachQuestionMode.form,
              isConfirmation: true,
              fields: fields,
              answered: true,
              answeredForm: {
                'scene': ['办公室'],
                'equipment': ['椅子'],
                'minutes': ['10 分钟'],
              },
            ),
            enabled: false,
            onTextAnswer: (_) async {},
            onChoiceAnswer: (_) async {},
          ),
        ),
      ),
    );
    expect(find.text('办公室 · 椅子 · 10 分钟'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('question-submit-accepted')),
      findsNothing,
    );
  });

  testWidgets('unmatched preset action never appears', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CoachFailureBubble(
            onRetry: () async {},
            onSecondary: () async {},
            presetMatchesFocus: false,
          ),
        ),
      ),
    );
    expect(find.text('网络不太稳，方案没生成出来'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('用预设方案'), findsNothing);
  });

  testWidgets('form fallback sends a natural answer without field labels', (
    tester,
  ) async {
    final answers = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CoachQuestionBubble(
            question: const CoachQuestionData(
              id: 'natural',
              question: '确认训练条件',
              mode: CoachQuestionMode.form,
              isConfirmation: true,
              fields: [
                CoachQuestionField(
                  key: 'scene',
                  label: '场景',
                  options: ['办公室'],
                  initialSelections: ['办公室'],
                ),
                CoachQuestionField(
                  key: 'equipment',
                  label: '可用器械（可多选）',
                  options: ['椅子', '墙'],
                  multiple: true,
                  initialSelections: ['椅子', '墙'],
                ),
                CoachQuestionField(
                  key: 'minutes',
                  label: '时长',
                  options: ['10 分钟'],
                  initialSelections: ['10 分钟'],
                ),
              ],
            ),
            enabled: true,
            onTextAnswer: (text) async => answers.add(text),
            onChoiceAnswer: (_) async {},
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('question-submit-natural')));
    await tester.pump();
    expect(answers, ['办公室，有椅子和墙，10 分钟']);
    expect(
      find.byKey(const ValueKey('question-submit-natural')),
      findsOneWidget,
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'failure actions are explicit and guarded in ${brightness.name}',
      (tester) async {
        final done = Completer<void>();
        var retries = 0;
        var secondaries = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: CoachFailureBubble(
                message: '暂时没能生成，请重试。',
                retryLabel: '再试一次',
                secondaryLabel: '修改条件',
                presetMatchesFocus: true,
                onRetry: () {
                  retries++;
                  return done.future;
                },
                onSecondary: () async => secondaries++,
              ),
            ),
          ),
        );
        expect(retries, 0);
        expect(find.text('暂时没能生成，请重试。'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('coach-failure-retry')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('coach-failure-secondary')));
        expect(retries, 1);
        expect(secondaries, 0);
        done.complete();
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('coach-failure-secondary')));
        await tester.pump();
        expect(secondaries, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
