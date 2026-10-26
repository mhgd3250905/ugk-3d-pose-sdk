import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

const fields = [
  CoachQuestionField(key: 'scene', label: '场景', options: ['办公室', '家里', '健身房']),
  CoachQuestionField(
    key: 'equipment',
    label: '器械',
    options: ['徒手', '瑜伽垫', '椅子'],
    multiple: true,
  ),
  CoachQuestionField(
    key: 'minutes',
    label: '时长',
    options: ['5 分钟', '10 分钟', '15 分钟', '20+ 分钟'],
  ),
];
Widget host({
  String id = 'form',
  bool enabled = true,
  required Future<void> Function(String) onText,
  Future<void> Function(Map<String, List<String>>)? onForm,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: CoachQuestionBubble(
        question: CoachQuestionData(
          id: id,
          question: '补充训练条件',
          mode: CoachQuestionMode.form,
          fields: fields,
        ),
        enabled: enabled,
        onTextAnswer: onText,
        onChoiceAnswer: (_) async {},
        onFormAnswer: onForm,
      ),
    ),
  ),
);
void main() {
  testWidgets(
    'grouped choices are independent; bodyweight excludes gear; one submission until settled',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final answers = <Map<String, List<String>>>[];
      final gate = Completer<void>();
      await tester.pumpWidget(
        host(
          onText: (_) async {},
          onForm: (answer) async {
            answers.add(answer);
            await gate.future;
          },
        ),
      );
      for (final label in ['家里', '瑜伽垫', '椅子', '徒手', '10 分钟']) {
        await tester.tap(find.text(label));
        await tester.pump();
      }
      final submit = find.byKey(const ValueKey('question-submit-form'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pump();
      await tester.tap(submit);
      await tester.pump();
      expect(answers, [
        {
          'scene': ['家里'],
          'equipment': ['徒手'],
          'minutes': ['10 分钟'],
        },
      ]);
      gate.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'skip is immediate, disabled while sending, and a new question clears old selections',
    (tester) async {
      final texts = <String>[];
      await tester.pumpWidget(host(onText: (text) async => texts.add(text)));
      final skip = find.byKey(const ValueKey('question-skip-form'));
      await tester.ensureVisible(skip);
      await tester.tap(skip);
      await tester.pumpAndSettle();
      expect(texts, ['直接出方案']);
      await tester.pumpWidget(
        host(enabled: false, onText: (text) async => texts.add(text)),
      );
      await tester.tap(skip);
      await tester.pump();
      expect(texts, hasLength(1));
      await tester.pumpWidget(
        host(id: 'new', onText: (text) async => texts.add(text)),
      );
      expect(find.byKey(const ValueKey('question-submit-new')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'old text callback receives a readable grouped answer without a form callback',
    (tester) async {
      final texts = <String>[];
      await tester.pumpWidget(host(onText: (text) async => texts.add(text)));
      for (final label in ['家里', '瑜伽垫', '10 分钟']) {
        await tester.tap(find.text(label));
        await tester.pump();
      }
      final submit = find.byKey(const ValueKey('question-submit-form'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(texts, ['场景：家里；器械：瑜伽垫；时长：10 分钟']);
    },
  );
}
