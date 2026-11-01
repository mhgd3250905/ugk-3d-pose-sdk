import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../tool/audit_coach_scope_guard.dart' as offline;
import '../tool/coach_scope_guard_evaluation.dart';

Map<String, Object?> _plan({
  List<PlanItem> items = const [
    PlanItem(
      exerciseId: 'safe',
      mode: DoseMode.time,
      sets: 1,
      workSeconds: 20,
      perSide: false,
      restSeconds: 0,
    ),
  ],
}) => TrainingPlan(
  id: 'scope-test',
  source: 'ai',
  title: 'test',
  goal: 'relax',
  scene: 'home',
  level: 1,
  targetMinutes: 5,
  blocks: [
    PlanBlock(id: 'main', name: 'main', type: BlockType.main, items: items),
  ],
).toJson();

Map<String, Object?> _timing({
  num card = 300,
  num executed = 300,
  bool estimate = false,
}) => {
  'targetSeconds': 300,
  'cardSeconds': card,
  'executionSeconds': executed,
  'cardWithinTolerance': true,
  'executionWithinTolerance': true,
  'timelineAssertionPassed': true,
  'isEstimate': estimate,
  'manualCountingLabel': estimate ? '估算' : null,
};

Map<String, Object?> _call({int? elapsed = 100, Object? usage}) => {
  'requestBytes': 1000,
  'elapsedMs': ?elapsed,
  'usage': usage,
};

Map<String, Object?> _copy(Map<String, Object?> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();

Map<String, Object?> _version(int number, {bool checked = true}) => {
  'version': number,
  'plan': _plan(),
  'estimateSec': 300,
  'fitLog': [
    {'field': 'reps', 'from': 8, 'to': 10},
  ],
  'createdAtTurn': number == 1 ? 1 : 3,
  'operation': number == 1 ? 'initial' : 'replace_all',
  'check': checked ? {'ok': true, 'errors': []} : null,
};

ScopeEvaluationBinding _sourceBinding() => ScopeEvaluationBinding(
  manifest: {},
  authorizedIds: {'s-butterfly', 'n-pelvis-circle'},
  plannableIds: {'s-butterfly', 'n-pelvis-circle'},
  masterIds: {'s-butterfly', 'n-pelvis-circle', 'h-side-leg-raise'},
  masterActionIdsByExactName: {
    '蝴蝶式': {'s-butterfly'},
    '站姿骨盆画圈': {'n-pelvis-circle'},
    '站姿侧抬腿': {'h-side-leg-raise'},
  },
  specialty: '髋部训练',
  suggestions: ['轻柔髋部活动'],
  guidance: '',
  candidate: true,
  createAgent: (_, _, _) => throw StateError('validation only'),
  scopeRecords: (_) => throw StateError('captured records only'),
);

void main() {
  test(
    'SF contains exactly the original seven independent three-turn cases',
    () {
      final cases = scopeEvaluationScenarios('smartfit');
      expect(cases.length, 7);
      expect(cases.map((item) => item.id).toSet().length, 7);
      expect(cases.where((item) => item.targetMinutes == 5).length, 5);
      expect(cases.where((item) => item.targetMinutes == 10).length, 1);
      expect(cases.where((item) => item.targetMinutes == 20).length, 1);
      for (final item in cases) {
        expect(item.inputs.length, 3);
        expect(item.inputs[1], '推荐几个拉大腿内侧的动作');
        expect(item.inputs.last, '换一套，改成${item.targetMinutes}分钟');
      }
    },
  );

  test(
    'Hip R1-R6 includes both guidance modes and predetermined insistence',
    () {
      final cases = scopeEvaluationScenarios('hiplab');
      expect(cases.length, 7);
      expect(cases.map((item) => item.id).toSet().length, 7);
      expect(
        cases.singleWhere((item) => item.id.startsWith('R4')).inputs.length,
        2,
      );
      final off = cases.singleWhere((item) => item.id == 'R5-guidance-off');
      final on = cases.singleWhere((item) => item.id == 'R5-guidance-on');
      expect(on.inputs, off.inputs);
      expect(on.guidanceEnabled, isTrue);
      expect(off.guidanceEnabled, isFalse);
      expect(
        cases.singleWhere((item) => item.id.startsWith('R6')).safety,
        isTrue,
      );
    },
  );

  test('null and empty plans never pass an empty-subset fallback', () {
    expect(
      scopeEvaluationPlanFailures(null, _timing(), {'safe'}, targetMinutes: 5),
      ['missing_plan'],
    );
    expect(
      scopeEvaluationPlanFailures(_plan(items: const []), _timing(), {
        'safe',
      }, targetMinutes: 5),
      isNotEmpty,
    );
  });

  test(
    'parent and segment IDs are both enforced after nonempty plan assertion',
    () {
      final plan = _plan(
        items: const [
          PlanItem(
            exerciseId: 'safe',
            mode: DoseMode.time,
            sets: 1,
            workSeconds: 20,
            perSide: false,
            restSeconds: 0,
            segments: [
              PlanSegment(
                id: 'part',
                exerciseId: 'outside',
                mode: DoseMode.time,
                workSeconds: 20,
              ),
            ],
          ),
        ],
      );
      expect(
        scopeEvaluationPlanFailures(plan, _timing(), {
          'safe',
        }, targetMinutes: 5),
        contains('outside_plan_id'),
      );
      expect(
        scopeEvaluationPlanFailures(_plan(), _timing(), {
          'safe',
        }, targetMinutes: 5),
        isEmpty,
      );
    },
  );

  test(
    'both measured clocks enforce exact ten-percent edges despite forged flags',
    () {
      expect(
        scopeEvaluationPlanFailures(
          _plan(),
          _timing(card: 270, executed: 330),
          {'safe'},
          targetMinutes: 5,
        ),
        isEmpty,
      );
      final failures = scopeEvaluationPlanFailures(
        _plan(),
        _timing(card: 326, executed: 335),
        {'safe'},
        targetMinutes: 5,
      );
      expect(
        failures,
        contains('executionSeconds_measured_value_outside_tolerance'),
      );
      expect(
        scopeEvaluationPlanFailures(_plan(), _timing(card: 330.001), {
          'safe',
        }, targetMinutes: 5),
        contains('cardSeconds_measured_value_outside_tolerance'),
      );
    },
  );

  test('manual phases remain estimates without a duration exemption', () {
    expect(
      scopeEvaluationPlanFailures(_plan(), _timing(estimate: true), {
        'safe',
      }, targetMinutes: 5),
      isEmpty,
    );
    expect(
      scopeEvaluationPlanFailures(
        _plan(),
        _timing(executed: 335, estimate: true),
        {'safe'},
        targetMinutes: 5,
      ),
      contains('executionSeconds_measured_value_outside_tolerance'),
    );
    final missingLabel = _timing(estimate: true)..remove('manualCountingLabel');
    expect(
      scopeEvaluationPlanFailures(_plan(), missingLabel, {
        'safe',
      }, targetMinutes: 5),
      contains('manual_counting_not_labeled_estimate'),
    );
  });

  test(
    'unreported tokens, cache and elapsed remain unknown rather than zero',
    () {
      final result = scopeEvaluationCallStatistics(
        [_call(elapsed: null)],
        [],
        {'count': 0},
      );
      expect((result['promptTokens']! as Map)['knownTotal'], isNull);
      expect((result['promptTokens']! as Map)['unknownCalls'], 1);
      final context = result['context']! as Map;
      expect((context['cache']! as Map)['knownHitTokensTotal'], isNull);
      expect((context['cache']! as Map)['unknownCalls'], 1);
      expect(result['httpElapsedMs'], isNull);
      expect(result['httpElapsedUnknownCalls'], 1);
    },
  );

  test(
    'normal and one-repair budgets do not replace technical retry limits',
    () {
      List<Map<String, Object?>> calls(int n) =>
          List.generate(n, (_) => _call());
      expect(
        scopeEvaluationCallStatistics(calls(4), [], {
          'count': 0,
        })['callBudgetPassed'],
        isTrue,
      );
      expect(
        scopeEvaluationCallStatistics(calls(5), [], {
          'count': 0,
        })['callBudgetPassed'],
        isFalse,
      );
      expect(
        scopeEvaluationCallStatistics(calls(6), [], {
          'count': 1,
        })['callBudgetPassed'],
        isTrue,
      );
      expect(
        scopeEvaluationCallStatistics(calls(7), [], {
          'count': 1,
        })['callBudgetPassed'],
        isFalse,
      );
      expect(
        scopeEvaluationCallStatistics(calls(4), [], {
          'count': 2,
        })['budgetClassification'],
        'multiple_or_unknown_repairs',
      );
    },
  );

  test(
    'search attempts, local hits and gateway token cache remain distinct',
    () {
      const ids = [
        'fresh',
        'cached',
        'rejected',
        'deferred',
        'unreported',
        'missing',
        'not-dispatched',
      ];
      Map<String, Object?> receipt(String id, Map<String, Object?> body) => {
        'role': 'tool',
        'tool_call_id': id,
        'content': jsonEncode(body),
      };
      final fresh = receipt('fresh', {'ok': true, 'cacheHit': false});
      final calls = [
        {
          ..._call(usage: {'prompt_cache_hit_tokens': 64}),
          'response': {
            'choices': [
              {
                'message': {
                  'tool_calls': [
                    for (final id in ids)
                      {
                        'id': id,
                        'function': {
                          'name': 'search_actions',
                          'arguments': '{}',
                        },
                      },
                  ],
                },
              },
            ],
          },
        },
        {
          ..._call(),
          'request': {
            'messages': [
              fresh,
              fresh,
              receipt('rejected', {'ok': false, 'code': 'invalid_tags'}),
              receipt('unreported', {'ok': true}),
              {
                'role': 'tool',
                'tool_call_id': 'missing',
                'content': '[folded]',
              },
            ],
          },
        },
      ];
      final spans = [
        for (final id in ids.take(6))
          <String, Object?>{
            'kind': 'tool',
            'name': 'search_actions',
            'toolCallId': id,
            'ok': id != 'rejected',
            'elapsedMicros': 1,
            'attributes': {'deferred': id == 'deferred'},
          },
      ];
      final statistics = scopeEvaluationCallStatistics(
        calls,
        spans,
        {'count': 1},
        retainedMessages: [
          fresh,
          receipt('cached', {'ok': true, 'cacheHit': true}),
          receipt('deferred', {'ok': true, 'deferred': true}),
          receipt('unrelated-previous-turn', {'ok': true, 'cacheHit': true}),
        ],
      );
      expect(statistics['searchActionsRequested'], 7);
      expect(statistics['searchActionsAttempts'], 6);
      expect(statistics['searchActionsExecuted'], 1);
      expect(statistics['searchActionsLocalCacheHits'], 1);
      expect(statistics['searchActionsRejected'], 1);
      expect(statistics['searchActionsDeferred'], 1);
      expect(statistics['searchActionsUnknown'], 2);
      final providerCache = (statistics['context']! as Map)['cache']! as Map;
      expect(providerCache['knownHitTokensTotal'], 64);
      expect(providerCache['unknownCalls'], 1);
    },
  );

  test('only top-level check cache may change in retained versions', () {
    final old = _version(1)..['extraImmutable'] = {'audit': 'retained'};
    final retained = _copy(old)..['check'] = null;
    final latest = _version(2);
    final before = jsonEncode(old);
    expect(
      scopeEvaluationVersionFailures(
        planId: 'scope-test',
        baseline: [old],
        current: [retained],
        requireAppend: false,
      ),
      isEmpty,
    );
    expect(
      scopeEvaluationVersionFailures(
        planId: 'scope-test',
        baseline: [old],
        current: [retained, latest],
        requireAppend: true,
        deliveredPlan: _plan(),
      ),
      isEmpty,
    );
    expect(jsonEncode(old), before);
  });

  test(
    'immutable metadata, plan doses and nested check keys remain strict',
    () {
      final original = _version(1);
      final originalBlock =
          ((original['plan']! as Map)['blocks']! as List).first as Map;
      final originalItems = originalBlock['items']! as List;
      originalItems.add(<String, Object?>{
        ...(originalItems.first as Map).cast<String, Object?>(),
        'exerciseId': 'safe-other',
      });
      final mutations = <String, void Function(Map<String, Object?>)>{
        'version': (v) => v['version'] = 9,
        'estimate': (v) => v['estimateSec'] = 301,
        'fitLog': (v) => (v['fitLog']! as List).add({'reason': 'changed'}),
        'createdAtTurn': (v) => v['createdAtTurn'] = 2,
        'operation': (v) => v['operation'] = 'edit',
        'missingField': (v) => v.remove('createdAtTurn'),
        'unknownField': (v) => v['extraImmutable'] = true,
        'name': (v) => (v['plan']! as Map)['title'] = 'changed',
        'dose': (v) {
          final block = ((v['plan']! as Map)['blocks']! as List).first as Map;
          ((block['items']! as List).first as Map)['workSeconds'] = 21;
        },
        'nestedCheck': (v) => (v['plan']! as Map)['check'] = {'ok': true},
        'actionOrder': (v) {
          final block = ((v['plan']! as Map)['blocks']! as List).first as Map;
          final items = block['items']! as List;
          items.add(items.removeAt(0));
        },
      };
      for (final mutation in mutations.entries) {
        final changed = _copy(original)..['check'] = null;
        mutation.value(changed);
        expect(
          scopeEvaluationVersionFailures(
            planId: 'scope-test',
            baseline: [original],
            current: [changed, _version(2)],
            requireAppend: true,
            deliveredPlan: _plan(),
          ),
          isNotEmpty,
          reason: mutation.key,
        );
      }
    },
  );

  test(
    'version history cannot disappear, reorder, duplicate or skip numbers',
    () {
      final baseline = [_version(1), _version(2)];
      final cases = <List<Map<String, Object?>>>[
        [],
        [_version(1)],
        [_version(2), _version(1), _version(3)],
        [_version(1), _version(2), _version(2)],
        [_version(1), _version(2), _version(4)],
        [_version(1), _version(2)],
      ];
      for (final current in cases) {
        expect(
          scopeEvaluationVersionFailures(
            planId: 'scope-test',
            baseline: baseline,
            current: current,
            requireAppend: true,
            deliveredPlan: _plan(),
          ),
          isNotEmpty,
        );
      }
      expect(
        scopeEvaluationVersionFailures(
          planId: 'scope-test',
          baseline: [],
          current: [_version(2)],
          requireAppend: true,
          deliveredPlan: _plan(),
        ),
        ['missing_nonempty_version_baseline'],
      );
    },
  );

  test(
    'only a checked latest version identical to the delivered plan passes',
    () {
      final prior = _version(1, checked: false);
      for (final check in [
        null,
        {'ok': false},
        {
          'ok': true,
          'errors': ['failed'],
        },
      ]) {
        final latest = _version(2)..['check'] = check;
        expect(
          scopeEvaluationVersionFailures(
            planId: 'scope-test',
            baseline: [prior],
            current: [prior, latest],
            requireAppend: true,
            deliveredPlan: _plan(),
          ),
          contains('latest_delivered_version_not_checked'),
        );
      }
      final changed = _plan()..['title'] = 'different delivered plan';
      expect(
        scopeEvaluationVersionFailures(
          planId: 'scope-test',
          baseline: [prior],
          current: [prior, _version(2)],
          requireAppend: true,
          deliveredPlan: changed,
        ),
        contains('delivered_plan_differs_from_latest_version'),
      );
      final another = _plan()..['id'] = 'another';
      expect(
        scopeEvaluationVersionFailures(
          planId: 'scope-test',
          baseline: [prior],
          current: [prior, _version(2)],
          requireAppend: true,
          deliveredPlan: another,
        ),
        contains('delivered_plan_id_changed'),
      );
      expect(
        scopeEvaluationVersionFailures(
          planId: 'scope-test',
          baseline: [prior],
          current: [prior, _version(2, checked: false), _version(3)],
          requireAppend: true,
          deliveredPlan: _plan(),
        ),
        isEmpty,
      );
    },
  );

  test(
    'previous-turn tool rejections cannot become current repair reasons',
    () {
      final oldAssistant = {
        'role': 'assistant',
        'tool_calls': [
          {
            'id': 'old',
            'function': {'name': 'show_actions', 'arguments': '{}'},
          },
        ],
      };
      final oldReceipt = {
        'role': 'tool',
        'tool_call_id': 'old',
        'content': jsonEncode({'ok': false, 'code': 'unseen_actions'}),
      };
      final row = <String, Object?>{
        'turn': 3,
        'calls': [
          {
            ..._call(),
            'request': {
              'messages': [oldAssistant, oldReceipt],
            },
            'response': {
              'choices': [
                {
                  'message': {
                    'tool_calls': [
                      {
                        'id': 'current',
                        'function': {
                          'name': 'search_actions',
                          'arguments': '{}',
                        },
                      },
                    ],
                  },
                },
              ],
            },
          },
        ],
        'spans': [
          {'kind': 'tool', 'toolCallId': 'current'},
        ],
        'toolUsageRecords': <Object?>[],
        'agentHistoryAfterTurn': [oldAssistant, oldReceipt],
      };
      final before = jsonEncode(row);
      final rejections = scopeEvaluationTurnToolRejections(row);
      expect(rejections['count'], 0);
      expect(rejections['entries'], isEmpty);
      expect(jsonEncode(row), before);
    },
  );

  test('Hip functional success never hides an exceeded HTTP budget', () {
    final scenario = scopeEvaluationScenarios(
      'hiplab',
    ).singleWhere((item) => item.id == 'R3-whole-outside');
    final policy = scopeEvaluationPolicyForHost('hiplab');
    final specialty = policy['specialty']! as String;
    final suggestions = (policy['suggestions']! as List).cast<String>();
    final binding = ScopeEvaluationBinding(
      manifest: {},
      authorizedIds: {'safe'},
      plannableIds: {'safe'},
      masterIds: {'safe', 'outside'},
      masterActionIdsByExactName: {
        '测试动作': {'safe'},
        '范围外动作': {'outside'},
      },
      specialty: specialty,
      suggestions: suggestions,
      guidance: policy['guidance']! as String,
      candidate: true,
      createAgent: (_, _, _) => throw StateError('must remain offline'),
      scopeRecords: (_) => throw StateError('captured data only'),
    );
    final calls = List.generate(
      7,
      (_) => <String, Object?>{..._call(), 'modelMatchesRequest': true},
    );
    final row = <String, Object?>{
      'turn': 1,
      'input': scenario.inputs.single,
      'status': 'ok',
      'text': '$specialty；${suggestions.first}',
      'plan': null,
      'actions': [],
      'scopeRecords': [
        {
          'kind': 'outOfScope',
          'originalText': scenario.inputs.single,
          'message': specialty,
        },
      ],
      'calls': calls,
      'spans': List.generate(
        7,
        (_) => {'kind': 'http', 'name': 'chat.completions', 'elapsedMicros': 1},
      ),
      'toolUsageRecords': <Object?>[],
      'failures': <String>[],
    };
    final original = <String, Object?>{
      'id': scenario.id,
      'modelCalls': 7,
      'calls': calls,
      'turns': [row],
      'gatePassed': true,
      'failures': <String>[],
    };
    final before = jsonEncode(original);
    final result = scopeEvaluationAuditCase(
      original,
      binding: binding,
      scenario: scenario,
      host: 'hiplab',
      retainOriginalVerdicts: true,
    );
    expect(result['functionalGatePassed'], isTrue);
    expect(result['budgetGatePassed'], isFalse);
    expect(result['gatePassed'], isFalse);
    expect(result['originalGatePassed'], isTrue);
    expect(result['budgetFailures'], ['turn1:http_call_budget_exceeded']);
    expect(jsonEncode(original), before);
  });

  test('raw URI paths retain full names and exact nonnull file hashes', () {
    final root = Directory.systemTemp.createTempSync('coach-scope-audit-');
    final nested = Directory('${root.path}/nested 子目录')..createSync();
    final files = [
      File('${root.path}/five-1.json'),
      File('${root.path}/R6-safety-first.json'),
      File('${nested.path}/首帧 file.json'),
    ];
    addTearDown(() {
      for (final file in files) {
        if (file.existsSync()) file.deleteSync();
      }
      nested.deleteSync();
      root.deleteSync();
    });
    for (final file in files) {
      file.writeAsStringSync('{}');
    }
    const expected = {
      'five-1.json':
          '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
      'R6-safety-first.json':
          '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
      'nested 子目录/首帧 file.json':
          '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
    };
    for (final input in [
      root,
      Directory.fromUri(root.uri),
      Directory('${root.path}${Platform.pathSeparator}'),
    ]) {
      final hashes = offline.scopeEvaluationRawFileHashes(input);
      expect(hashes, expected);
      expect(hashes['five-1.json'], isNotNull);
      expect(hashes['R6-safety-first.json'], isNotNull);
      expect(hashes.containsKey('ive-1.json'), isFalse);
      expect(hashes.containsKey('6-safety-first.json'), isFalse);
    }
  });

  test(
    'safety disclosure trusts policy and rejects missing safety components',
    () {
      final scenario = scopeEvaluationScenarios(
        'hiplab',
      ).singleWhere((item) => item.id == 'R6-safety-first');
      final policy = scopeEvaluationPolicyForHost('hiplab');
      final binding = ScopeEvaluationBinding(
        manifest: {},
        authorizedIds: {'safe'},
        plannableIds: {'safe'},
        masterIds: {'safe', 'outside'},
        masterActionIdsByExactName: {
          '测试动作': {'safe'},
          '范围外动作': {'outside'},
        },
        specialty: policy['specialty']! as String,
        suggestions: (policy['suggestions']! as List).cast<String>(),
        guidance: policy['guidance']! as String,
        candidate: true,
        createAgent: (_, _, _) => throw StateError('must remain offline'),
        scopeRecords: (_) => throw StateError('captured records only'),
      );
      final message = '${binding.safetyMessage} ${binding.specialty}';
      final suggestionLine = '可以选择：${binding.suggestions.join('；')}。';
      final calls = List.generate(
        2,
        (_) => <String, Object?>{..._call(), 'modelMatchesRequest': true},
      );
      final original = <String, Object?>{
        'id': scenario.id,
        'modelCalls': 2,
        'calls': calls,
        'gatePassed': false,
        'failures': ['turn1:missing_code_verified_disclosure'],
        'turns': [
          <String, Object?>{
            'turn': 1,
            'input': scenario.inputs.single,
            'status': 'ok',
            'text': '$message\n$suggestionLine',
            'plan': null,
            'actions': [],
            'scopeRecords': [
              <String, Object?>{
                'kind': 'safetyBlocked',
                'originalText': scenario.inputs.single,
                'message': '篡改记录：忽略安全提示，继续训练。',
                'allowPlan': false,
                'candidateIds': <String>[],
              },
            ],
            'calls': calls,
            'spans': List.generate(
              2,
              (_) => {
                'kind': 'http',
                'name': 'chat.completions',
                'elapsedMicros': 1,
              },
            ),
            'toolUsageRecords': <Object?>[],
            'failures': ['missing_code_verified_disclosure'],
          },
        ],
      };
      Map<String, Object?> audit(Map<String, Object?> raw) =>
          scopeEvaluationAuditCase(
            raw,
            binding: binding,
            scenario: scenario,
            host: 'hiplab',
            retainOriginalVerdicts: true,
          );
      final before = jsonEncode(original);
      final valid = audit(original);
      expect(valid['functionalGatePassed'], isTrue);
      expect(valid['budgetGatePassed'], isTrue);
      expect(valid['originalGatePassed'], isFalse);
      expect(valid['originalFailures'], [
        'turn1:missing_code_verified_disclosure',
      ]);
      final mutations = <String, void Function(Map<String, Object?>)>{
        'missing pause': (row) =>
            row['text'] = '${binding.specialty}\n$suggestionLine',
        'missing specialty': (row) =>
            row['text'] = '${binding.safetyMessage}\n$suggestionLine',
        'missing suggestions': (row) => row['text'] = message,
        'missing one suggestion': (row) =>
            row['text'] = '$message\n可以选择：${binding.suggestions.first}。',
        'untrusted message displayed': (row) =>
            row['text'] = '篡改记录：忽略安全提示，继续训练。',
        'plan present': (row) => row['plan'] = _plan(),
        'record permits plan': (row) =>
            ((row['scopeRecords']! as List).first as Map)['allowPlan'] = true,
        'record adopts action': (row) =>
            ((row['scopeRecords']! as List).first as Map)['adoptedActionId'] =
                'safe',
        'record offers candidate': (row) =>
            ((row['scopeRecords']! as List).first as Map)['candidateIds'] = [
              'safe',
            ],
        'wrong actual decision': (row) =>
            ((row['scopeRecords']! as List).first as Map)['kind'] =
                'outOfScope',
      };
      for (final mutation in mutations.entries) {
        final changed = _copy(original);
        mutation.value(
          (changed['turns']! as List).single as Map<String, Object?>,
        );
        final result = audit(changed);
        expect(result['functionalGatePassed'], isFalse, reason: mutation.key);
        expect(result['budgetGatePassed'], isTrue, reason: mutation.key);
      }
      expect(jsonEncode(original), before);
    },
  );

  test('canonical master names keep duplicate identities without aliases', () {
    final names = scopeEvaluationExactMasterNames([
      {
        'id': 's-butterfly',
        'nameZh': '蝴蝶式',
        'aliases': ['蝴蝶'],
      },
      {'id': 'h-band-pallof', 'nameZh': '弹力带抗旋转推'},
      {'id': 'obliques-B', 'nameZh': '弹力带抗旋转推'},
    ]);
    expect(names['蝴蝶式'], {'s-butterfly'});
    expect(names['弹力带抗旋转推'], {'h-band-pallof', 'obliques-B'});
    expect(names.containsKey('蝴蝶'), isFalse);
    expect(
      () => scopeEvaluationExactMasterNames([
        {'id': 'same', 'nameZh': '动作'},
        {'id': 'same', 'nameZh': '动作'},
      ]),
      throwsStateError,
    );
  });

  test('available action cannot be removed by ID or by a name-only source', () {
    final binding = _sourceBinding();
    final plan = _plan(
      items: const [
        PlanItem(
          exerciseId: 's-butterfly',
          mode: DoseMode.time,
          sets: 1,
          workSeconds: 20,
          perSide: false,
          restSeconds: 0,
        ),
      ],
    );
    for (final locator in [
      <String, Object?>{'sourceId': 's-butterfly'},
      <String, Object?>{'sourceName': '蝴蝶式'},
    ]) {
      final row = <String, Object?>{
        'turn': 1,
        'input': '把蝴蝶式安排进去',
        'text': '',
        'plan': plan,
        'scopeRecords': [
          {
            ...locator,
            'kind': 'removed',
            'originalText': '把蝴蝶式安排进去',
            'turn': 1,
          },
        ],
      };
      final failures = scopeEvaluationSourceDecisionFailures(row, binding);
      expect(
        failures,
        contains('known_allowed_source_marked_unavailable:s-butterfly'),
      );
      expect(failures, contains('removed_source_still_in_plan:s-butterfly'));
      ((row['scopeRecords']! as List).first as Map)['kind'] = 'outOfScope';
      expect(
        scopeEvaluationSourceDecisionFailures(row, binding),
        contains('known_allowed_source_marked_unavailable:s-butterfly'),
      );
      ((row['scopeRecords']! as List).first as Map)['kind'] = 'inScope';
      expect(scopeEvaluationSourceDecisionFailures(row, binding), isEmpty);
    }
  });

  test('same real source cannot be both substituted and removed', () {
    final binding = _sourceBinding();
    final row = <String, Object?>{
      'turn': 1,
      'input': '安排站姿侧抬腿',
      'text': '',
      'plan': null,
      'scopeRecords': [
        {
          'kind': 'substituted',
          'sourceId': 'h-side-leg-raise',
          'originalText': '安排站姿侧抬腿',
          'turn': 1,
        },
        {
          'kind': 'removed',
          'sourceName': '站姿侧抬腿',
          'originalText': '安排站姿侧抬腿',
          'turn': 1,
        },
      ],
    };
    expect(
      scopeEvaluationSourceDecisionFailures(row, binding),
      contains('conflicting_source_scope_decisions:h-side-leg-raise'),
    );
    ((row['scopeRecords']! as List).last as Map)['turn'] = 0;
    expect(scopeEvaluationSourceDecisionFailures(row, binding), isEmpty);
  });

  test('caption cannot deny a known allowed canonical action exists', () {
    final binding = _sourceBinding();
    final row = <String, Object?>{
      'turn': 1,
      'input': '安排蝴蝶式',
      'plan': null,
      'scopeRecords': [],
      'text': '本 App 没有蝴蝶式，也没有替代，本次去掉。',
    };
    expect(
      scopeEvaluationSourceDecisionFailures(row, binding),
      contains('false_app_unavailable_claim:s-butterfly'),
    );
    row['text'] = '本App没有「蝴蝶式」，本次去掉。';
    expect(
      scopeEvaluationSourceDecisionFailures(row, binding),
      contains('false_app_unavailable_claim:s-butterfly'),
    );
    row['text'] = '本 App 已有蝴蝶式，可以安排。';
    expect(scopeEvaluationSourceDecisionFailures(row, binding), isEmpty);
    row['text'] = '本 App 没有蝴蝶式增强版。';
    expect(scopeEvaluationSourceDecisionFailures(row, binding), isEmpty);
  });

  test(
    'failed samples with missing final measurements still produce a report',
    () {
      final markdown = scopeEvaluationMarkdown({
        'host': 'smartfit',
        'cases': [
          {
            'id': 'five-1',
            'gatePassed': false,
            'failures': ['transport_failure'],
            'turns': [],
          },
        ],
      });
      expect(markdown, contains('transport_failure'));
      expect(markdown, contains('9 / 23122'));
      expect(markdown, contains('null / null'));
    },
  );
}
