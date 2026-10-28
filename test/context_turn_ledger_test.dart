import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/context_turn_ledger.dart';
import 'package:ugk_coach/ugk_coach.dart';

void main() {
  const userText = '坐了挺久，我想拉伸一下\n他说："慢一点" 🧘🏽‍♂️\n';
  const deliveredText = '给你安排了这些动作：\n"髋部放松" → 点击排成计划 😀\n';
  final params = {
    'minutes': CoachParamValue(
      value: 15,
      source: 'derived',
      turn: 2,
      quote: '短一点\n"请保留原话" 😀',
      direction: 'shorter',
      basedOn: CoachParamValue(
        value: 20,
        source: 'user',
        turn: 1,
        quote: '20 分钟\n"不超过" 🕑',
      ),
    ),
    'equipment': CoachParamValue(
      value: ['equip.mat', 'equip.wall'],
      source: 'host',
      turn: 0,
    ),
  };
  final task = CoachTaskState(
    type: 'plan',
    reused: true,
    nodes: [
      for (final id in [
        'understand',
        'parameters',
        'actions',
        'planning',
        'review',
        'output',
      ])
        CoachNodeState(
          id: id,
          status: id == 'parameters' ? 'updated' : 'done',
          stamp: '"$id"\n真实结果 ✅',
          doneAtTurn: 2,
        ),
    ],
  );
  ContextDeliveryRef planRef() => ContextDeliveryRef(
    type: 'plan',
    planId: 'p',
    version: 3,
    actionIds: ['a', 'b'],
  );
  CompletedContextTurn record({List<Object?> candidates = const []}) =>
      CompletedContextTurn(
        turn: 2,
        userText: userText,
        finalDeliveryText: deliveredText,
        params: params,
        task: task,
        deliveries: [planRef()],
        currentPlanRef: planRef(),
        picks: ['b', 'a'],
        candidates: candidates,
        loadedSkillNames: ['ask', 'action-library', 'plan-training'],
        seenActionIds: ['a', 'b', 'c'],
        outcome: 'completed',
      );

  test(
    'summary preserves complete text and source proofs as one deterministic user message',
    () {
      final turn = record();
      final ledger = ContextTurnLedger([turn]);
      final message = ledger.summaryMessage();
      expect(message.role, LlmRole.user);
      expect(message.reasoning, isNull);
      expect(message.toolCalls, isEmpty);
      expect(message.toolCallId, isNull);
      expect(
        message.content.startsWith('${ContextTurnLedger.summaryPrefix}\n'),
        isTrue,
      );
      expect(message.content, ledger.summaryMessage().content);
      final decoded =
          jsonDecode(
                message.content.substring(
                  ContextTurnLedger.summaryPrefix.length + 1,
                ),
              )
              as Map<String, dynamic>;
      final saved = (decoded['turns'] as List).single as Map;
      expect(saved['userText'], userText);
      expect(saved['finalDeliveryText'], deliveredText);
      expect((saved['params'] as Map)['minutes'], params['minutes']!.toJson());
      expect(message.toJson().keys, ['role', 'content']);
      expect(saved.keys, isNot(contains('state')));
      expect(saved.keys, isNot(contains('contextTurns')));
      expect(saved.keys, isNot(contains('messages')));
      expect(saved.keys, isNot(contains('reasoning_content')));
    },
  );

  test(
    'nodes references skills and every candidate survive save and restore without a cap',
    () {
      final candidates = <Object?>[
        for (var i = 0; i < 87; i++)
          [
            'id-$i',
            '动作 "$i"\n😀',
            'body.abs',
            'seconds',
            {
              'extra': {
                'aliases': ['自由字段', 'unchanged-$i'],
                'rank': i,
              },
            },
          ],
      ];
      final original = ContextTurnLedger([record(candidates: candidates)]);
      final restored = ContextTurnLedger.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      expect(restored.toJson(), original.toJson());
      final turn = restored.turns.single;
      expect(turn.candidates, candidates);
      expect(turn.candidates, hasLength(87));
      expect(turn.task!.toJson(), task.toJson());
      expect(turn.params['minutes']!.toJson(), params['minutes']!.toJson());
      expect(turn.picks, ['b', 'a']);
      expect(turn.seenActionIds, ['a', 'b', 'c']);
      expect(turn.currentPlanRef!.toJson(), planRef().toJson());
      expect(turn.deliveries.single.toJson(), planRef().toJson());
      expect(turn.loadedSkillNames, ['ask', 'action-library', 'plan-training']);
      expect(turn.outcome, 'completed');
    },
  );

  test(
    'ask JSON and the following answer are linked without editing the earlier turn',
    () {
      final question = <String, Object?>{
        'question': '选一个场景\n"可以跳过" 😀',
        'mode': 'form',
        'fields': [
          {
            'key': 'scene',
            'label': '场景',
            'options': ['在家', '办公室'],
            'preselected': ['办公室'],
            'futureField': {'preserve': true},
          },
        ],
        'skipLabel': '直接出方案',
        'extra': [
          1,
          2,
          {'x': '全文'},
        ],
      };
      final ask = CompletedContextTurn(
        turn: 1,
        userText: userText,
        finalDeliveryText: '请选场景。',
        params: const {},
        askQuestions: [question],
        deliveries: [ContextDeliveryRef(type: 'question')],
        outcome: 'awaiting_user',
      );
      final before = jsonEncode(ask.toJson());
      final answer = CompletedContextTurn(
        turn: 2,
        userText: '选"办公室"\n不想靠墙 😀',
        finalDeliveryText: deliveredText,
        params: params,
        answeredAsk: ContextAskReplyRef(
          questionTurn: 1,
          answerJson: {
            'scene': ['办公室'],
            'skip': false,
            'extra': {'literal': '选"办公室"\n😀'},
          },
        ),
      );
      final restored = ContextTurnLedger.fromJson(
        jsonDecode(jsonEncode(ContextTurnLedger([ask, answer]).toJson()))
            as Map<String, dynamic>,
      );
      expect(restored.turns.first.askQuestions.single, question);
      expect(restored.turns.last.answeredAsk!.questionTurn, 1);
      expect(restored.turns.last.answeredAsk!.questionIndex, 0);
      expect(
        restored.turns.last.answeredAsk!.toJson(),
        answer.answeredAsk!.toJson(),
      );
      expect(restored.turns.last.userText, answer.userText);
      expect(jsonEncode(ask.toJson()), before);
    },
  );

  test(
    'constructor and exported JSON cannot mutate recorded collections or the source state',
    () {
      final source = CoachSessionState(
        params: params,
        task: task,
        picks: ['a'],
        seenActionIds: {'a', 'b'},
        activePlanId: 'p',
      );
      final sourceBefore = source.toJson();
      final options = <String>['在家', '办公室'];
      final question = <String, Object?>{'question': '哪里？', 'options': options};
      final candidate = <String, Object?>{
        'id': 'a',
        'nested': <String>['original'],
      };
      final skills = <String>['ask'];
      final turn = CompletedContextTurn(
        turn: 1,
        userText: userText,
        finalDeliveryText: deliveredText,
        params: source.params,
        task: source.task,
        picks: source.picks,
        seenActionIds: source.seenActionIds.toList(),
        askQuestions: [question],
        candidates: [candidate],
        loadedSkillNames: skills,
        currentPlanRef: planRef(),
        answeredAsk: ContextAskReplyRef(
          questionTurn: 0,
          answerJson: {'selected': options},
        ),
      );
      final turns = <CompletedContextTurn>[turn];
      final ledger = ContextTurnLedger(turns);
      final before = ledger.toJson();
      options.add('健身房');
      (candidate['nested'] as List).add('mutated');
      skills.add('plan-training');
      turns.clear();
      expect(ledger.toJson(), before);
      expect(() => turn.candidates.add('x'), throwsUnsupportedError);
      expect(
        () => (turn.candidates.first as Map)['id'] = 'changed',
        throwsUnsupportedError,
      );
      expect(
        () => turn.askQuestions.first['question'] = 'changed',
        throwsUnsupportedError,
      );
      expect(() => turn.loadedSkillNames.add('x'), throwsUnsupportedError);
      expect(() => turn.params.clear(), throwsUnsupportedError);
      expect(
        () => turn.currentPlanRef!.actionIds.add('x'),
        throwsUnsupportedError,
      );
      expect(
        () => (turn.answeredAsk!.answerJson!['selected'] as List).add('x'),
        throwsUnsupportedError,
      );
      final exported = ledger.toJson();
      final encodedTurn = (exported['turns'] as List).first as Map;
      ((encodedTurn['askQuestions'] as List).first as Map)['question'] =
          'changed';
      ((encodedTurn['candidates'] as List).first as Map)['id'] = 'changed';
      (((encodedTurn['params'] as Map)['minutes'] as Map)['basedOn']
              as Map)['quote'] =
          'changed';
      ledger.summaryMessage();
      expect(ledger.toJson(), before);
      expect(source.toJson(), sourceBefore);
    },
  );

  test(
    'empty history and optional outcomes do not invent state or model messages',
    () {
      final empty = ContextTurnLedger.fromJson(const {});
      expect(empty.toJson(), {'turns': <Object?>[]});
      expect(empty.summaryMessage().role, LlmRole.user);
      final error = CompletedContextTurn(
        turn: 9,
        userText: '完整原文\n😀',
        finalDeliveryText: '',
        params: const {},
        outcome: 'error',
      );
      final restored = CompletedContextTurn.fromJson(error.toJson());
      expect(restored.toJson(), error.toJson());
      expect(restored.deliveries, isEmpty);
      expect(restored.params, isEmpty);
      expect(restored.task, isNull);
    },
  );
}
