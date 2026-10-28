import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/context_turn_ledger.dart';
import 'package:ugk_coach/src/agent/session_snapshot.dart';
import 'package:ugk_coach/src/agent/session_state.dart';
import 'package:ugk_coach/src/tools/ask_user.dart';

Map<String, Object?> object(Object? value) =>
    (value! as Map<Object?, Object?>).cast<String, Object?>();
List<Object?> array(Object? value) => value! as List<Object?>;

void main() {
  const user = '坐了挺久，我想拉伸一下\n"原话" 🧘';
  const delivery = '动作以卡片为准。\n保持呼吸，别弹震。';
  final params = {
    'scene': CoachParamValue(
      value: 'office',
      source: 'derived',
      quote: '坐了挺久',
      turn: 1,
    ),
    'minutes': CoachParamValue(
      value: 15,
      source: 'derived',
      quote: '再短点',
      direction: 'shorter',
      basedOn: CoachParamValue(
        value: 20,
        source: 'user',
        quote: '20 分钟',
        turn: 1,
      ),
      turn: 2,
    ),
  };
  final task = CoachTaskState(
    type: 'recommend',
    reused: false,
    nodes: [
      for (final id in ['understand', 'parameters', 'actions', 'output'])
        CoachNodeState(id: id, status: 'done', stamp: '结果 $id', doneAtTurn: 1),
    ],
  );
  final ledger = ContextTurnLedger([
    CompletedContextTurn(
      turn: 1,
      userText: user,
      finalDeliveryText: delivery,
      params: params,
      task: task,
      picks: ['a', 'b'],
      candidates: const [
        ['a', '动作A', 'body.abs', 'seconds', 1],
      ],
      loadedSkillNames: ['action-library', 'action-coaching'],
      seenActionIds: ['a', 'b'],
      deliveries: [
        ContextDeliveryRef(type: 'actions', actionIds: ['a', 'b']),
      ],
      outcome: 'completed',
    ),
  ]);
  CoachSessionSnapshot sample({AskUserQuestion? question}) =>
      CoachSessionSnapshot(
        sessionState: CoachSessionState(
          userTurns: const [CoachUserTurn(turn: 1, text: user)],
          params: params,
          task: task,
          picks: const ['a', 'b'],
          seenActionIds: const {'a', 'b'},
          completedContextLedger: ledger.toJson(),
        ),
        ledger: ledger,
        pendingQuestion: question,
        pendingQuestionMessageId: question == null ? null : 'question-message',
        candidates: const [
          ['a', '动作A', 'body.abs', 'seconds', 1],
        ],
        loadedSkillNames: const ['action-library', 'action-coaching'],
        agentState: const {
          'turnCount': 1,
          'lastConfirmedForm': {
            'scene': ['办公室'],
          },
        },
        recommendations: [
          CoachRecommendationSnapshot(
            messageId: 'delivery-1',
            actionIds: ['a', 'b'],
            note: delivery,
          ),
        ],
      );

  test(
    'portable session JSON roundtrip preserves exact sourced facts and references',
    () {
      final original = sample();
      final json = jsonDecode(jsonEncode(original.toJson()));
      final restored = CoachSessionSnapshot.fromJson(json);
      expect(restored.isValid, isTrue);
      expect(restored.schemaVersion, 1);
      expect(restored.toJson(), original.toJson());
      expect(restored.sessionState.toJson(), original.sessionState.toJson());
      expect(restored.ledger.toJson(), ledger.toJson());
      expect(restored.ledger.turns.single.userText, user);
      expect(restored.ledger.turns.single.finalDeliveryText, delivery);
      expect(restored.sessionState.params['minutes']!.quote, '再短点');
      expect(restored.sessionState.params['minutes']!.basedOn!.quote, '20 分钟');
      expect(
        restored.recommendations.single.toJson(),
        original.recommendations.single.toJson(),
      );
      expect(
        (restored.toJson()['sessionState'] as Map)['loadedSkillNames'],
        original.loadedSkillNames,
      );
      expect(
        (restored.toJson()['sessionState'] as Map)['candidates'],
        original.candidates,
      );
    },
  );

  test('empty session can be serialized independently of a plan card', () {
    final original = CoachSessionSnapshot(
      sessionState: CoachSessionState(),
      ledger: ContextTurnLedger(const []),
    );
    final restored = CoachSessionSnapshot.fromJson(
      jsonDecode(jsonEncode(original.toJson())),
    );
    expect(restored.isValid, isTrue);
    expect(restored.toJson(), original.toJson());
    expect(restored.sessionState.plans, isEmpty);
  });

  for (final language in ['zh', 'en']) {
    for (final mode in ['text', 'choice', 'form']) {
      test(
        'pending $language $mode question keeps its exact admitted shape',
        () {
          final raw = {
            'question': language == 'en'
                ? 'Where would you like to stretch?'
                : '在哪里拉伸？',
            'mode': mode,
            if (mode == 'choice') ...{
              'options': language == 'en' ? ['Home', 'Office'] : ['居家', '办公室'],
              'multiple': false,
            },
            if (mode == 'form')
              'fields': [
                {
                  'key': 'scene',
                  'label': language == 'en' ? 'Place' : '场景',
                  'options': language == 'en'
                      ? ['Home', 'Office']
                      : ['居家', '办公室'],
                  'multiple': false,
                },
              ],
          };
          final admitted = AskUserGate.check(
            jsonEncode(raw),
            language: language,
          ).question!;
          final original = sample(question: admitted);
          final restored = CoachSessionSnapshot.fromJson(
            jsonDecode(jsonEncode(original.toJson())),
          );
          expect(restored.isValid, isTrue, reason: restored.invalidReason);
          expect(restored.pendingQuestion!.toJson(), admitted.toJson());
          expect(restored.pendingQuestion!.skipLabel, admitted.skipLabel);
          expect(restored.pendingQuestionMessageId, 'question-message');
        },
      );
    }
  }

  test(
    'SDK confirmation retains defaults, previous selections and scene-specific options',
    () {
      final question = AskUserQuestion.confirmation(
        question: 'Confirm your conditions',
        language: 'en',
        focus: 'core',
        fields: [
          AskUserField(
            key: 'scene',
            label: 'Place',
            options: ['Home', 'Office'],
            preselected: ['Home'],
          ),
          AskUserField(
            key: 'equipment',
            label: 'Equipment',
            options: ['None', 'Chair'],
            multiple: true,
            preselected: ['Chair'],
            previousSelections: ['Chair'],
            optionsByScene: const {
              'Home': ['None', 'Chair'],
              'Office': ['Chair'],
            },
          ),
          AskUserField(
            key: 'minutes',
            label: 'Time',
            options: ['10 minutes', '20 minutes'],
            preselected: ['20 minutes'],
          ),
        ],
        defaultSelections: const {
          'scene': ['Home'],
          'equipment': ['Chair'],
          'minutes': ['20 minutes'],
        },
      );
      final restored = CoachSessionSnapshot.fromJson(
        jsonDecode(jsonEncode(sample(question: question).toJson())),
      );
      expect(restored.isValid, isTrue);
      expect(restored.pendingQuestion!.toJson(), question.toJson());
      expect(restored.pendingQuestion!.skipLabel, 'Use defaults');
    },
  );

  test(
    'unknown, damaged and non-JSON inputs return a safe invalid sentinel',
    () {
      final corruptions = <Object?>[
        null,
        [],
        'broken',
        {'schemaVersion': 99},
        {'schemaVersion': '1'},
        {'schemaVersion': 1, 'sessionState': {}, 'ledger': {}},
      ];
      void corrupt(void Function(Map<String, Object?>) edit) {
        final json =
            jsonDecode(jsonEncode(sample().toJson())) as Map<String, Object?>;
        edit(json);
        corruptions.add(json);
      }

      corrupt(
        (j) => (j['sessionState'] as Map)['params'] = {
          'minutes': {'value': 15, 'source': 'fabricated', 'turn': 2},
        },
      );
      corrupt(
        (j) => (j['sessionState'] as Map)['plans'] = {
          'p': [
            {'version': 'x'},
          ],
        },
      );
      corrupt(
        (j) => object(
          array(object(object(j['sessionState'])['task'])['nodes']).first,
        )['status'] = 'broken',
      );
      corrupt(
        (j) => object(array(object(j['ledger'])['turns']).first)['userText'] =
            null,
      );
      corrupt(
        (j) => object(
          array(object(j['ledger'])['turns']).first,
        )['finalDeliveryText'] = 'tampered',
      );
      corrupt(
        (j) => object(array(j['recommendations']).first)['actionIds'] = [1],
      );
      corrupt((j) => j['agentState'] = <String, Object?>{'nonJson': Object()});
      corrupt((j) => j['pendingQuestionMessageId'] = 'missing-question');
      for (final value in corruptions) {
        final invalid = CoachSessionSnapshot.fromJson(value);
        expect(invalid.isValid, isFalse);
        expect(invalid.invalidReason, isNotNull);
        expect(() => jsonEncode(invalid.toJson()), returnsNormally);
        expect(
          CoachSessionSnapshot.fromJson(invalid.toJson()).isValid,
          isFalse,
        );
        expect(invalid.sessionState.userTurns, isEmpty);
      }
    },
  );

  test('snapshot metadata and exported JSON cannot mutate each other', () {
    final candidates = <Object?>[
      <Object?>[
        'a',
        <String, Object?>{
          'nested': <Object?>['original'],
        },
      ],
    ];
    final agentState = <String, Object?>{
      'nested': <Object?>['original'],
    };
    final ids = ['a'];
    final snapshot = CoachSessionSnapshot(
      sessionState: CoachSessionState(),
      ledger: ContextTurnLedger(const []),
      candidates: candidates,
      agentState: agentState,
      recommendations: [
        CoachRecommendationSnapshot(
          messageId: 'm',
          actionIds: ids,
          note: delivery,
        ),
      ],
    );
    ids.add('b');
    ((candidates.first as List)[1] as Map)['nested'] = ['changed'];
    (agentState['nested'] as List).add('changed');
    expect(snapshot.recommendations.single.actionIds, ['a']);
    expect(snapshot.agentState['nested'], ['original']);
    expect(
      () => (snapshot.agentState['nested'] as List).add('x'),
      throwsUnsupportedError,
    );
    expect(() => snapshot.candidates.add('x'), throwsUnsupportedError);
    final encoded = snapshot.toJson();
    ((encoded['agentState'] as Map)['nested'] as List).add('export mutation');
    (((encoded['sessionState'] as Map)['candidates'] as List).first
            as List)[0] =
        'changed';
    array(
      object(array(encoded['recommendations']).first)['actionIds'],
    ).add('changed');
    expect(snapshot.agentState['nested'], ['original']);
    expect((snapshot.candidates.first as List).first, 'a');
    expect(snapshot.recommendations.single.actionIds, ['a']);
  });

  test(
    'known continuation fields reject malformed shapes before restoration',
    () {
      for (final state in <Map<String, Object?>>[
        {'turnCount': 'broken'},
        {'turnCount': -1},
        {'questionsAsked': 1.5},
        {'questionsAsked': -1},
        {'relativeDurationPolicy': 'false'},
        {
          'confirmedPlanContext': {'scene': 1},
        },
        {
          'confirmedPlanContext': {'goal': false},
        },
        {
          'confirmedPlanContext': {'language': null},
        },
        {
          'confirmedPlanContext': {'equipment': 'chair'},
        },
        {
          'confirmedPlanContext': {
            'avoid': [1],
          },
        },
        {
          'confirmedPlanContext': {
            'notes': [false],
          },
        },
        {
          'confirmedPlanContext': {'level': '1'},
        },
        {
          'confirmedPlanContext': {'minutes': 1.5},
        },
        {
          'confirmedPlanContext': {'hasExplicitAvoid': 'true'},
        },
        {'safetyContext': []},
        {
          'lastConfirmedForm': {'scene': 'home'},
        },
        {
          'lastConfirmedForm': {
            'scene': [1],
          },
        },
        {
          'latestExplicitAvoid': [1],
        },
        {'focus': 1},
        {'goal': []},
        {
          'memoryOrigins': {'hash': 'turn'},
        },
        {
          'memoryOrigins': {
            'hash': [0],
          },
        },
        {
          'memoryOrigins': {
            'hash': [-1],
          },
        },
        {
          'memoryOrigins': {
            'hash': [1.5],
          },
        },
      ]) {
        final json = sample().toJson()..['agentState'] = state;
        final invalid = CoachSessionSnapshot.fromJson(json);
        expect(invalid.isValid, isFalse, reason: state.toString());
        expect(invalid.invalidReason, 'invalid_snapshot');
      }
    },
  );

  test(
    'known continuation shapes and future JSON metadata roundtrip intact',
    () {
      final state = <String, Object?>{
        'turnCount': 2,
        'questionsAsked': 0,
        'relativeDurationPolicy': true,
        'confirmedPlanContext': {
          'scene': 'home',
          'goal': 'core',
          'language': 'en',
          'equipment': ['chair'],
          'avoid': ['knee'],
          'notes': ['Keep breathing.'],
          'level': 1,
          'minutes': 15,
          'hasExplicitAvoid': true,
        },
        'safetyContext': {'hasExplicitAvoid': false},
        'lastConfirmedForm': {
          'scene': ['Home'],
        },
        'latestExplicitAvoid': ['knee'],
        'focus': 'core',
        'goal': 'strength',
        'memoryOrigins': {
          'opaque-hash': [1, 2],
        },
        'futureFact': {
          'nested': [1, true, null],
        },
      };
      final json = sample().toJson()..['agentState'] = state;
      final restored = CoachSessionSnapshot.fromJson(json);
      expect(restored.isValid, isTrue);
      expect(restored.agentState, state);
      expect(restored.toJson(), json);
    },
  );
}
