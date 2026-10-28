import 'dart:convert';

import 'package:test/test.dart';

import '../tool/eval_context_stats.dart';

List<int> body(
  List<Map<String, Object?>> messages, {
  String system = '角色',
  Object? tools = const [
    {
      'type': 'function',
      'function': {'name': 'echo'},
    },
  ],
}) => utf8.encode(
  jsonEncode({
    'model': 'deepseek-flash',
    'messages': [
      {'role': 'system', 'content': system},
      ...messages,
    ],
    'tools': tools,
  }),
);

Map<String, Object?> tail(String value) => {
  'role': 'user',
  'content': '$evaluationTailStatePrefix$value',
};

void main() {
  test(
    'complete history prefix is compared before the changing generated tail',
    () {
      final tracker = EvaluationContextTracker();
      final history = <Map<String, Object?>>[
        {'role': 'user', 'content': '原话'},
        {
          'role': 'assistant',
          'content': '',
          'reasoning_content': 'private reasoning',
          'tool_calls': <Object?>[],
        },
        {'role': 'tool', 'tool_call_id': 'x', 'content': '{"ok":true}'},
      ];
      final first = tracker.observe(body([...history, tail('旧状态')]));
      expect(first['fullJsonLcpBytes'], isNull);
      final next = tracker.observe(
        body([
          ...history,
          {'role': 'assistant', 'content': '继续'},
          tail('新状态'),
        ]),
      );
      expect(next['systemsEqual'], isTrue);
      expect(next['toolsEqual'], isTrue);
      expect(next['historyPrefixFullyPreserved'], isTrue);
      expect(next['historyMessagesLcpCount'], 3);
      expect(next['historyMessageCount'], 4);
      expect(jsonEncode(next), isNot(contains('private reasoning')));
      expect(jsonEncode(next), isNot(contains('旧状态')));
      expect(jsonEncode(next), isNot(contains('新状态')));
    },
  );

  test(
    'full JSON LCP counts actual UTF-8 bytes and reasoning changes break prefix',
    () {
      final tracker = EvaluationContextTracker();
      final before = body([
        {'role': 'assistant', 'content': '', 'reasoning_content': '私密α'},
        tail('same'),
      ]);
      final after = body([
        {'role': 'assistant', 'content': '', 'reasoning_content': '私密β'},
        tail('same'),
      ]);
      tracker.observe(before);
      final result = tracker.observe(after);
      final prefix = utf8.decode(before).split('α').first;
      // Greek alpha/beta share their first UTF-8 byte.
      expect(result['fullJsonLcpBytes'], utf8.encode(prefix).length + 1);
      expect(result['historyPrefixFullyPreserved'], isFalse);
      expect(result['historyMessagesLcpCount'], 0);
      expect(jsonEncode(result), isNot(contains('私密')));
    },
  );

  test(
    'system/tools equality is separate from historical message equality',
    () {
      final tracker = EvaluationContextTracker();
      tracker.observe(
        body([
          {'role': 'user', 'content': '相同'},
          tail('state'),
        ]),
      );
      final next = tracker.observe(
        body(
          [
            {'role': 'user', 'content': '相同'},
            tail('state'),
          ],
          system: '新角色',
          tools: const [],
        ),
      );
      expect(next['systemsEqual'], isFalse);
      expect(next['toolsEqual'], isFalse);
      expect(next['historyPrefixFullyPreserved'], isTrue);
    },
  );

  test(
    'tail content bytes and serialized message bytes are measured separately',
    () {
      final state = tail('含"引号"\n换行');
      final result = EvaluationContextTracker().observe(body([state]));
      final measured = result['tailState'] as Map;
      expect(measured['observed'], isTrue);
      expect(
        measured['contentBytes'],
        utf8.encode(state['content'] as String).length,
      );
      expect(
        measured['serializedMessageBytes'],
        utf8.encode(jsonEncode(state)).length,
      );
      expect(
        measured['serializedMessageBytes'] as int,
        greaterThan(measured['contentBytes'] as int),
      );
      final absent = EvaluationContextTracker().observe(
        body([
          {'role': 'user', 'content': '当前状态：用户原话'},
        ]),
      );
      expect((absent['tailState'] as Map)['observed'], isFalse);
      expect((absent['tailState'] as Map)['contentBytes'], isNull);
    },
  );

  test(
    'SDK fold diagnostics are labelled separately from wire measurements and whitelist fields',
    () {
      final tracker = EvaluationContextTracker();
      final actual = body([
        {'role': 'user', 'content': '一'},
        tail('state'),
      ]);
      tracker.observe(actual, sdkDiagnostics: {'epoch': 1, 'afterBytes': 4});
      final result = tracker.observe(
        actual,
        sdkDiagnostics: {
          'sdkDiagnosticIndex': 2,
          'epoch': 2,
          'beforeBytes': 80000,
          'afterBytes': 60000,
          'completedTurnsFolded': 2,
          'receiptBodiesFolded': 3,
          'measurement': 'conservative_sdk_estimate',
          'tailStateBytes': 200,
          'fitsHardLimit': true,
          'privateReasoning': 'must-not-escape',
        },
      );
      expect(result['epochChanged'], isTrue);
      expect(result['foldType'], 'completed_turns_and_receipt_bodies');
      expect(result['wireMinusSdkAfterBytes'], actual.length - 60000);
      expect(result['measurement'], 'actual_http_request_body_utf8');
      expect(
        (result['sdkDiagnostics'] as Map)['measurement'],
        'conservative_sdk_estimate',
      );
      expect(jsonEncode(result), isNot(contains('must-not-escape')));
    },
  );

  test(
    'same-epoch prefix changes fail architecture acceptance, folds and epoch invalidation do not',
    () {
      Map<String, Object?> diag(
        int epoch, {
        int completed = 0,
        int receipts = 0,
      }) => {
        'epoch': epoch,
        'completedTurnsFolded': completed,
        'receiptBodiesFolded': receipts,
      };
      for (final scenario in ['same', 'fold', 'epoch']) {
        final tracker = EvaluationContextTracker();
        tracker.observe(
          body([
            {'role': 'user', 'content': '旧'},
            tail('state'),
          ]),
          sdkDiagnostics: diag(1),
        );
        final changed = tracker.observe(
          body([
            {'role': 'user', 'content': '新'},
            tail('state'),
          ], system: '新system'),
          sdkDiagnostics: scenario == 'epoch'
              ? diag(2)
              : diag(1, completed: scenario == 'fold' ? 1 : 0),
        );
        final validation = changed['prefixValidation'] as Map;
        expect(
          validation['status'],
          scenario == 'same' ? 'fail' : 'not_applicable',
        );
        if (scenario == 'same') {
          expect(validation['violations'], [
            'system_messages',
            'history_messages',
          ]);
        }
      }
      final stable = EvaluationContextTracker();
      stable.observe(
        body([
          {'role': 'user', 'content': '旧'},
          tail('旧state'),
        ]),
        sdkDiagnostics: diag(1),
      );
      final appended = stable.observe(
        body([
          {'role': 'user', 'content': '旧'},
          {'role': 'assistant', 'content': '新'},
          tail('新state'),
        ]),
        sdkDiagnostics: diag(1),
      );
      expect((appended['prefixValidation'] as Map)['status'], 'pass');
    },
  );

  test(
    'cache observation preserves zero, uses primary then fallback, and never guesses unknown',
    () {
      final zero = evaluationCacheObservation({
        'prompt_cache_hit_tokens': 0,
        'prompt_tokens_details': {'cached_tokens': 99},
        'prompt_tokens': 100,
      });
      expect(zero['status'], 'known');
      expect(zero['hitTokens'], 0);
      expect(zero['source'], 'usage.prompt_cache_hit_tokens');
      final fallback = evaluationCacheObservation({
        'prompt_tokens_details': {'cached_tokens': 12},
        'prompt_tokens': 24,
      });
      expect(fallback['hitFraction'], .5);
      expect(fallback['source'], 'usage.prompt_tokens_details.cached_tokens');
      for (final usage in [
        null,
        <String, Object?>{},
        {'prompt_cache_hit_tokens': -1},
        {
          'prompt_tokens_details': {'cached_tokens': '0'},
        },
        {'prompt_cache_hit_tokens': 1.5},
      ]) {
        final result = evaluationCacheObservation(usage);
        expect(result['status'], 'unknown');
        expect(result['hitTokens'], isNull);
      }
    },
  );

  test('cache aggregation exposes known/unknown counts and partial totals', () {
    final stats = evaluationContextStatistics([
      {
        'usage': {'prompt_cache_hit_tokens': 0},
      },
      {
        'usage': {
          'prompt_tokens_details': {'cached_tokens': 8},
        },
      },
      {'usage': null},
    ]);
    final cache = stats['cache'] as Map;
    expect(cache['knownCalls'], 2);
    expect(cache['unknownCalls'], 1);
    expect(cache['knownHitTokensTotal'], 8);
    expect(cache['coverage'], 'partial');
    final unknown = evaluationContextStatistics([
      {'usage': null},
    ]);
    expect((unknown['cache'] as Map)['knownHitTokensTotal'], isNull);
    final knownZero = evaluationContextStatistics([
      {
        'usage': {'prompt_cache_hit_tokens': 0},
      },
    ]);
    expect((knownZero['cache'] as Map)['knownHitTokensTotal'], 0);
  });

  test(
    'soft mode thresholds report exceedance but hard limit remains 65536 bytes',
    () {
      expect(
        evaluationRequestBudget(45000, thinking: false)['status'],
        'above_soft_current_turn_allowed',
      );
      expect(
        evaluationRequestBudget(45000, thinking: true)['status'],
        'within_soft',
      );
      expect(
        evaluationRequestBudget(65536, thinking: false)['hardExceeded'],
        isFalse,
      );
      expect(
        evaluationRequestBudget(65537, thinking: true)['hardExceeded'],
        isTrue,
      );
    },
  );
}
