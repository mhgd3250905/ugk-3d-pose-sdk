import 'dart:convert';

import 'package:test/test.dart';

import '../tool/compare_coach_agent_v2.dart';

ComparisonJson _summary(String mode) => {
  'thinkingMode': mode,
  'requestedModel': 'configured-model',
  'fixtureSha256': 'same-fixture',
  'cases': [
    for (final id in ['R1', 'R2', 'R3', 'R4', 'R5', 'R6'])
      {
        'id': id,
        'thinkingMode': mode,
        'caseValidity': 'valid-model-route',
        'modelCalls': 1,
        'elapsedMs': 100,
        'callStatistics': {
          'maxRequestBytes': 12000,
          'totalTokens': {'knownTotal': 123, 'unknownCalls': 0},
        },
        'calls': <Object?>[],
        'turns': [
          {
            'turn': 1,
            'origin': 'approved-original',
            'user': '原话 $id',
            'assistant': '回答 $mode $id',
            'calls': <Object?>[],
            'params': <String, Object?>{},
            'task': null,
          },
        ],
        'events': <Object?>[],
      },
  ],
};

ComparisonJson _firstCase(ComparisonJson summary) =>
    ((summary['cases'] as List).first as Map).cast<String, Object?>();
ComparisonJson _on(ComparisonJson comparison) =>
    (_firstCase(comparison)['on'] as Map).cast<String, Object?>();
ComparisonJson _quality(ComparisonJson comparison, String field) =>
    ((_on(comparison)['quality'] as Map)[field] as Map).cast<String, Object?>();

void main() {
  test(
    'comparison reads six existing cases without mutation or model execution',
    () {
      final on = _summary('on');
      final off = _summary('off');
      final before = jsonEncode([on, off]);
      final result = buildThinkingComparison(on, off);
      expect(jsonEncode([on, off]), before);
      expect(result['modelCallsMade'], 0);
      expect(result['cases'], hasLength(6));
      final metrics = _on(result)['metrics'] as Map;
      expect(metrics['modelCalls'], 1);
      expect(metrics['elapsedMs'], 100);
      expect(metrics['maxRequestBytes'], 12000);
      expect(metrics['tokensKnownTotal'], 123);
      final markdown = thinkingComparisonMarkdown(result);
      expect(markdown, contains('原话 R1'));
      expect(markdown, contains('回答 on R1'));
      expect(markdown, contains('回答 off R1'));
      expect(markdown, contains('manual_review'));
    },
  );

  test('missing delivery does not fabricate duration or equipment passes', () {
    final result = buildThinkingComparison(_summary('on'), _summary('off'));
    expect(_quality(result, 'planDurationError')['status'], 'not_observed');
    expect(_quality(result, 'equipmentCompliance')['status'], 'not_observed');
    expect(_quality(result, 'repeatedQuestions')['status'], 'manual_review');
    expect(
      _quality(result, 'parameterStampConsistency')['status'],
      'manual_review',
    );
    final compatibility = result['inputCompatibility'] as Map;
    expect((compatibility['sourceSha256'] as Map)['match'], isNull);
  });

  test('duration error is calculated from measured seconds and target', () {
    final on = _summary('on');
    final turn = ((_firstCase(on)['turns'] as List).first as Map);
    turn['plan'] = {'targetMinutes': 20};
    turn['params'] = {
      'minutes': {'value': 20, 'source': 'user'},
    };
    turn['estimatedPlanSeconds'] = 1320;
    final result = buildThinkingComparison(on, _summary('off'));
    final duration = _quality(result, 'planDurationError');
    expect(duration['status'], 'pass');
    final plan = (duration['plans'] as List).single as Map;
    expect(plan['errorPercent'], 10);
    expect(plan['acceptedLedgerMinutes'], 20);
    expect(plan['cardTargetMinutes'], 20);
    expect(plan['targetMatchesLedger'], isTrue);
    turn['estimatedPlanSeconds'] = 1321;
    expect(
      _quality(
        buildThinkingComparison(on, _summary('off')),
        'planDurationError',
      )['status'],
      'fail',
    );
    turn.remove('estimatedPlanSeconds');
    expect(
      _quality(
        buildThinkingComparison(on, _summary('off')),
        'planDurationError',
      )['status'],
      'manual_review',
    );
  });

  test(
    'ledger target wins when the card silently changes requested minutes',
    () {
      final on = _summary('on');
      final turn = ((_firstCase(on)['turns'] as List).first as Map);
      turn['params'] = {
        'minutes': {'value': 20, 'source': 'user'},
      };
      turn['plan'] = {'targetMinutes': 10};
      turn['estimatedPlanSeconds'] = 600;
      final duration = _quality(
        buildThinkingComparison(on, _summary('off')),
        'planDurationError',
      );
      expect(duration['status'], 'fail');
      final plan = (duration['plans'] as List).single as Map;
      expect(plan['acceptedLedgerMinutes'], 20);
      expect(plan['cardTargetMinutes'], 10);
      expect(plan['targetMatchesLedger'], isFalse);
      expect(plan['comparisonTargetMinutes'], 20);
      expect(plan['errorPercent'], 50);
      turn['estimatedPlanSeconds'] = 1200;
      expect(
        _quality(
          buildThinkingComparison(on, _summary('off')),
          'planDurationError',
        )['status'],
        'fail',
      );
    },
  );

  test(
    'card-only duration is measured but cannot pass without accepted ledger minutes',
    () {
      final on = _summary('on');
      final turn = ((_firstCase(on)['turns'] as List).first as Map);
      turn['plan'] = {'targetMinutes': 20};
      turn['estimatedPlanSeconds'] = 1200;
      final duration = _quality(
        buildThinkingComparison(on, _summary('off')),
        'planDurationError',
      );
      expect(duration['status'], 'manual_review');
      final plan = (duration['plans'] as List).single as Map;
      expect(plan['acceptedLedgerMinutes'], isNull);
      expect(plan['cardTargetMinutes'], 20);
      expect(plan['targetMatchesLedger'], isNull);
      expect(plan['errorPercent'], 0);
      expect(plan['comparisonBasis'], 'card-only-unverified');
    },
  );

  test(
    'equipment check requires an accepted ledger and actual action facts',
    () {
      final on = _summary('on');
      final turn = ((_firstCase(on)['turns'] as List).first as Map);
      turn['actions'] = [
        {'id': 'known-action'},
      ];
      turn['params'] = {
        'equipment': {
          'value': ['equip.dumbbell'],
          'source': 'user',
        },
      };
      turn['actionFacts'] = [
        {
          'id': 'known-action',
          'equipment': ['dumbbell'],
        },
      ];
      expect(
        _quality(
          buildThinkingComparison(on, _summary('off')),
          'equipmentCompliance',
        )['status'],
        'pass',
      );
      turn['actionFacts'] = [
        {
          'id': 'known-action',
          'equipment': ['mat'],
        },
      ];
      expect(
        _quality(
          buildThinkingComparison(on, _summary('off')),
          'equipmentCompliance',
        )['status'],
        'fail',
      );
      turn['params'] = <String, Object?>{};
      expect(
        _quality(
          buildThinkingComparison(on, _summary('off')),
          'equipmentCompliance',
        )['status'],
        'manual_review',
      );
    },
  );

  test(
    'unaccepted start_task response is not used to infer the Task column',
    () {
      final on = _summary('on');
      final item = _firstCase(on);
      final turn = ((item['turns'] as List).first as Map);
      turn['task'] = null;
      turn['calls'] = [
        {
          'turn': 1,
          'caseElapsedMs': 1,
          'response': {
            'tool_calls': [
              {'name': 'start_task', 'arguments': '{"type":"plan"}'},
            ],
          },
        },
      ];
      final result = buildThinkingComparison(on, _summary('off'));
      final dialogue = (_on(result)['dialogue'] as List).single as Map;
      expect(dialogue['task'], 'qa');
    },
  );

  test('rejects wrong modes or missing six-case evidence', () {
    expect(
      () => buildThinkingComparison(_summary('off'), _summary('off')),
      throwsFormatException,
    );
    final incomplete = _summary('on');
    (incomplete['cases'] as List).removeLast();
    expect(
      () => buildThinkingComparison(incomplete, _summary('off')),
      throwsFormatException,
    );
  });
}
