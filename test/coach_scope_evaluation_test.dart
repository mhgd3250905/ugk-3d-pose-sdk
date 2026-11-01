import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../tool/coach_scope_guard_evaluation.dart';

Map<String, Object?> _plan() => TrainingPlan(
  id: 'test',
  source: 'test',
  title: 'test',
  goal: 'relax',
  scene: 'home',
  level: 1,
  targetMinutes: 5,
  blocks: const [
    PlanBlock(
      id: 'b',
      name: 'main',
      type: BlockType.main,
      items: [
        PlanItem(
          exerciseId: 'safe',
          mode: DoseMode.time,
          sets: 1,
          workSeconds: 30,
          perSide: false,
          restSeconds: 0,
        ),
      ],
    ),
  ],
).toJson();

void main() {
  test(
    'fake transport records actual bytes and usage without network',
    () async {
      final logs = <Map<String, Object?>>[];
      final wire = ScopeEvaluationWireClient(
        MockClient(
          (request) async => http.Response(
            jsonEncode({
              'model': 'fake',
              'usage': {
                'prompt_tokens': 20,
                'completion_tokens': 5,
                'total_tokens': 25,
                'prompt_cache_hit_tokens': 10,
              },
            }),
            200,
          ),
        ),
        logs.add,
      );
      addTearDown(wire.close);
      final response = await wire.post(
        Uri.parse('https://fake.invalid/v1'),
        body: '测试',
      );
      expect(response.statusCode, 200);
      expect(wire.calls.single['requestBytes'], utf8.encode('测试').length);
      expect(wire.calls.single['elapsedMs'], isA<int>());
      expect((wire.calls.single['usage']! as Map)['cached_tokens'], 10);
      expect(logs.length, 1);
    },
  );

  test('six fixed cases preserve eleven original user turns', () {
    final sf = scopeEvaluationScenarios('smartfit');
    final hip = scopeEvaluationScenarios('hiplab');
    expect(sf.map((c) => c.id), ['five-3', 'five-1']);
    expect(hip.map((c) => c.id), [
      'R1-partial-substitute',
      'R2-partial-remove',
      'R4-insist',
      'R6-safety-first',
    ]);
    expect([...sf, ...hip].fold<int>(0, (n, c) => n + c.inputs.length), 11);
    expect(
      sf.every((c) => c.inputs.length == 3 && c.inputs.last == '换一套，改成5分钟'),
      isTrue,
    );
  });

  test('case option preserves explicit order and rejects unknown names', () {
    expect(
      scopeEvaluationScenarios('smartfit', 'five-1,five-3').map((c) => c.id),
      ['five-1', 'five-3'],
    );
    expect(
      () => scopeEvaluationScenarios('smartfit', 'other'),
      throwsArgumentError,
    );
    expect(
      () => scopeEvaluationScenarios('smartfit', 'five-1,five-1'),
      throwsArgumentError,
    );
  });

  test('delivered plan requires allowed IDs and both duration clocks', () {
    final scenario = scopeEvaluationScenarios('hiplab').first;
    final row = <String, Object?>{
      'turn': 1,
      'status': 'ok',
      'text': '已用可用动作替代。',
      'plan': _plan(),
      'timing': {
        'cardSeconds': 300,
        'executionSeconds': 330,
        'isEstimate': true,
      },
      'scopeRecords': [
        {
          'kind': 'substituted',
          'sourceId': 'h-side-leg-raise',
          'adoptedActionId': 'safe',
          'turn': 1,
        },
      ],
    };
    List<String> check() => scopeEvaluationCheckTurn(
      row,
      host: 'hiplab',
      scenario: scenario,
      allowedIds: {'safe'},
    );
    expect(check(), isEmpty);
    (row['timing']! as Map)['executionSeconds'] = 335;
    expect(check(), contains('executionSeconds_outside_tolerance'));
    (row['timing']! as Map)['executionSeconds'] = 300;
    expect(
      scopeEvaluationCheckTurn(
        row,
        host: 'hiplab',
        scenario: scenario,
        allowedIds: {'different'},
      ),
      contains('outside_plan_id'),
    );
    ((row['scopeRecords']! as List).single as Map)['adoptedActionId'] =
        'missing';
    expect(check(), contains('replacement_not_in_plan'));
  });

  test('HTTP target does not change functional success', () {
    final calls = List.generate(
      7,
      (_) => <String, Object?>{
        'requestBytes': 100,
        'elapsedMs': 10,
        'usage': {
          'prompt_tokens': 20,
          'completion_tokens': 5,
          'total_tokens': 25,
          'cached_tokens': 10,
        },
      },
    );
    final metrics = scopeEvaluationMetrics(calls, [
      {
        'kind': 'recompile',
        'reason': 'incompatible_action',
        'elapsedMicros': 1,
      },
      {'kind': 'tool', 'name': 'search_actions', 'elapsedMicros': 2},
    ]);
    expect(metrics['httpCalls'], 7);
    expect(metrics['httpTarget'], 6);
    expect(metrics['httpTargetMet'], isFalse);
    expect(metrics['searchAttempts'], 1);
    final row = <String, Object?>{
      'turn': 3,
      'status': 'ok',
      'plan': _plan(),
      'timing': {'cardSeconds': 300, 'executionSeconds': 300},
      'metrics': metrics,
    };
    expect(
      scopeEvaluationCheckTurn(
        row,
        host: 'smartfit',
        scenario: scopeEvaluationScenarios('smartfit').first,
        allowedIds: {'safe'},
      ),
      isEmpty,
    );
  });

  test('safety case requires no plan and an actual safety result', () {
    final scenario = scopeEvaluationScenarios('hiplab').last;
    final row = <String, Object?>{
      'turn': 1,
      'status': 'ok',
      'plan': null,
      'text': '先暂停这次训练安排，按安全提示处理。',
      'scopeRecords': [
        {'kind': 'safetyBlocked', 'turn': 1},
      ],
    };
    List<String> check() => scopeEvaluationCheckTurn(
      row,
      host: 'hiplab',
      scenario: scenario,
      allowedIds: {'safe'},
    );
    expect(check(), isEmpty);
    ((row['scopeRecords']! as List).single as Map)['kind'] = 'outOfScope';
    expect(check(), contains('missing_safetyBlocked_result'));
    row['plan'] = _plan();
    row['timing'] = {'cardSeconds': 300, 'executionSeconds': 300};
    expect(check(), contains('unexpected_plan'));
  });
}
