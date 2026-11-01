import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'action_scope_manifest_test.dart'
    show
        actionScopeCatalog,
        actionScopeDrill,
        actionScopeManifest,
        actionScopeProfile;

LlmToolCall _call(String id, String name, Object arguments) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments));

LlmResponse _calls(List<LlmToolCall> tools) =>
    LlmResponse(content: '', toolCalls: tools, finishReason: 'tool_calls');

Map<String, Object?> _receipt(LlmRequest request, String id) =>
    Map<String, Object?>.from(
      jsonDecode(
            request.messages
                .lastWhere((message) => message.toolCallId == id)
                .content,
          )
          as Map,
    );

String _publicReceipts(FakeLlmClient client) {
  Object compact(String value) {
    try {
      final parsed = jsonDecode(value);
      if (parsed is Map) {
        return {
          for (final entry in parsed.entries)
            if (!{'skills', 'profile', 'format'}.contains(entry.key))
              entry.key: entry.value,
        };
      }
    } on FormatException {
      // Plain virtual-file receipts need no JSON decoding.
    }
    return value;
  }

  return jsonEncode([
    for (final request in client.requests)
      for (final message in request.messages)
        if (message.role == LlmRole.tool)
          {'id': message.toolCallId, 'receipt': compact(message.content)},
  ]);
}

void main() {
  const normalInput = '在家用垫子做5分钟拉伸';
  const allowed = {'hip-a', 'hip-b', 'hip-c', 'unsafe-hip'};
  const goodIds = ['hip-a', 'hip-b', 'hip-c'];
  final catalog = actionScopeCatalog(
    rows: [
      ...actionScopeCatalog().drills.map((drill) => drill.raw),
      actionScopeDrill('hip-c', name: '另一内侧伸展'),
    ],
  );
  final profile = actionScopeProfile();
  final manifest = actionScopeManifest(catalog, ids: allowed);
  final policy = CoachScopeConversationPolicy(
    specialty: '本 App 专注髋部、臀部和温和拉伸。',
    suggestions: ['温和髋部拉伸', '臀部激活'],
    safetyMessage: '先暂停训练并处理疼痛。',
  );

  CoachAgent coach(FakeLlmClient client, {bool scoped = true}) {
    final agent = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      scopeManifest: scoped ? manifest : null,
      scopePolicy: scoped ? policy : null,
      enableUserMemory: false,
      maxRequestRetries: 0,
    );
    addTearDown(agent.dispose);
    return agent;
  }

  Map<String, Object?> assessment(
    String quote, {
    Map<String, Object?>? extra,
  }) => {'quote': quote, 'targetBodyCodes': <String>[], ...?extra};

  Map<String, Object?> parameters(String input, {bool scoped = true}) => {
    'fields': {
      'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
      'equipment': {
        'value': ['equip.mat'],
        'source': 'user',
        'quote': '垫子',
      },
      'goal': {
        'value': ['purpose.stretch'],
        'source': 'user',
        'quote': '拉伸',
      },
      'minutes': {'value': 5, 'source': 'user', 'quote': '5分钟'},
    },
    if (scoped) 'scope_request': assessment(input),
  };

  LlmResponse setup(String input, {bool scoped = true}) => _calls([
    _call('start', AgentTools.startTask, {'type': 'plan'}),
    _call('params', AgentTools.setParams, parameters(input, scoped: scoped)),
    _call('search', AgentTools.searchActions, {
      'tags': <String>[],
      'limit': 20,
    }),
  ]);

  Map<String, Object?> draft(String? planId, List<String> ids) => {
    'plan_id': ?planId,
    'title': '五分钟髋部拉伸',
    'blocks': [
      {
        'kind': 'main',
        'items': [
          for (final id in ids) {'id': id},
        ],
      },
    ],
  };

  List<Object> deliveryScript(
    String input, {
    bool scoped = true,
    List<String> ids = goodIds,
    String note = '循序渐进。',
  }) => [
    setup(input, scoped: scoped),
    (LlmRequest request) {
      expect(_receipt(request, 'params')['ok'], isTrue);
      final rows = _receipt(request, 'search')['items']! as List;
      expect(rows, isNotEmpty);
      final searched = {for (final row in rows) (row as Map)['id']};
      expect(searched.containsAll(ids), isTrue);
      final id = _receipt(request, 'start')['plan_id'] as String?;
      return _calls([
        _call('draft', AgentTools.draftPlan, draft(id, ids)),
        _call('show', AgentTools.showPlan, {'plan_id': ?id, 'note': note}),
      ]);
    },
  ];

  void expectAllowedPlan(CoachTurnResult result, FakeLlmClient client) {
    final reason =
        '${result.issues} ${result.error} ${_publicReceipts(client)}';
    expect(result.status, TurnStatus.ok, reason: reason);
    expect(result.plan, isNotNull, reason: reason);
    expect(result.plan!.plan.items, isNotEmpty);
    expect(allowed.containsAll(result.plan!.plan.exerciseIds), isTrue);
  }

  test(
    'exact full current quote assesses without mutating plan state',
    () async {
      final client = FakeLlmClient([
        _calls([
          _call('assess', AgentTools.setParams, {
            'scope_request': assessment(normalInput),
          }),
        ]),
        '可以继续。',
      ], latency: Duration.zero);
      final agent = coach(client);
      final result = await agent.send(normalInput);
      expect(result.status, TurnStatus.ok, reason: _publicReceipts(client));
      expect(agent.sessionState.scopeAssessmentTurn, 1);
      expect(agent.sessionState.scopeDecisionRecords, hasLength(1));
      expect(
        agent.sessionState.scopeDecisionRecords.single['originalText'],
        normalInput,
      );
      expect(agent.sessionState.scopeDecisionRecords.single['kind'], 'inScope');
      expect(agent.sessionState.plans, isEmpty);
      expect(result.plan, isNull);
    },
  );

  for (final quote in [
    '5分钟拉伸',
    '在家用垫子做5分钟拉伸。',
    ' $normalInput',
    '$normalInput ',
  ]) {
    test(
      'rewritten or partial scope quote is rejected: ${jsonEncode(quote)}',
      () async {
        late CoachAgent agent;
        final client = FakeLlmClient([
          _calls([
            _call('bad-assess', AgentTools.setParams, {
              'scope_request': assessment(quote),
            }),
          ]),
          (LlmRequest request) {
            expect(_receipt(request, 'bad-assess')['ok'], isFalse);
            expect(
              _receipt(request, 'bad-assess')['code'],
              'scope_quote_not_current_input',
            );
            expect(agent.sessionState.scopeAssessmentTurn, isNull);
            expect(agent.sessionState.scopeDecisionRecords, isEmpty);
            return _calls([
              _call('fixed-assess', AgentTools.setParams, {
                'scope_request': assessment(normalInput),
              }),
            ]);
          },
          '可以继续。',
        ], latency: Duration.zero);
        agent = coach(client);
        final result = await agent.send(normalInput);
        expect(result.status, TurnStatus.ok, reason: _publicReceipts(client));
        expect(agent.sessionState.scopeAssessmentTurn, 1);
        expect(agent.sessionState.scopeDecisionRecords, hasLength(1));
      },
    );
  }

  test('a previous user turn quote cannot assess the next user turn', () async {
    const nextInput = '我改成10分钟';
    late CoachAgent agent;
    final client = FakeLlmClient([
      _calls([
        _call('first-assess', AgentTools.setParams, {
          'scope_request': assessment(normalInput),
        }),
      ]),
      '可以继续。',
      _calls([
        _call('stale-assess', AgentTools.setParams, {
          'scope_request': assessment(normalInput),
        }),
      ]),
      (LlmRequest request) {
        expect(_receipt(request, 'stale-assess')['ok'], isFalse);
        expect(
          _receipt(request, 'stale-assess')['code'],
          'scope_quote_not_current_input',
        );
        expect(agent.sessionState.scopeAssessmentTurn, 1);
        expect(agent.sessionState.scopeDecisionRecords, hasLength(1));
        return _calls([
          _call('current-assess', AgentTools.setParams, {
            'scope_request': assessment(nextInput),
          }),
        ]);
      },
      '可以继续。',
    ], latency: Duration.zero);
    agent = coach(client);
    expect((await agent.send(normalInput)).status, TurnStatus.ok);
    final second = await agent.send(nextInput);
    expect(second.status, TurnStatus.ok, reason: _publicReceipts(client));
    expect(agent.sessionState.scopeAssessmentTurn, 2);
    expect(agent.sessionState.scopeDecisionRecords, hasLength(2));
    expect(
      agent.sessionState.scopeDecisionRecords.last['originalText'],
      nextInput,
    );
  });

  test(
    'normal scoped draft and show deliver a nonempty authorized plan',
    () async {
      final client = FakeLlmClient(
        deliveryScript(normalInput),
        latency: Duration.zero,
      );
      final agent = coach(client);
      final result = await agent.send(normalInput);
      expectAllowedPlan(result, client);
      expect(
        agent.sessionState.plans.values.expand((versions) => versions),
        hasLength(1),
      );
      expect(agent.sessionState.scopeAssessmentTurn, 1);
      expect(client.remaining, 0);
    },
  );

  test(
    'scope omission leaves existing unscoped plan and plain-response paths intact',
    () async {
      final client = FakeLlmClient(
        deliveryScript(normalInput, scoped: false),
        latency: Duration.zero,
      );
      final agent = coach(client, scoped: false);
      final result = await agent.send(normalInput);
      expectAllowedPlan(result, client);
      expect(agent.sessionState.scopeAssessmentTurn, isNull);
      expect(agent.sessionState.scopeDecisionRecords, isEmpty);

      final plain = coach(
        FakeLlmClient(['你好。'], latency: Duration.zero),
        scoped: false,
      );
      final response = await plain.send('你好');
      expect(response.status, TurnStatus.ok);
      expect(response.text, '你好。');
    },
  );

  test(
    'plain model output requires assessment before it can finish a scoped turn',
    () async {
      final client = FakeLlmClient([
        '已经安排好了。',
        _calls([
          _call('assess', AgentTools.setParams, {
            'scope_request': assessment(normalInput),
          }),
        ]),
        '条件已确认。',
      ], latency: Duration.zero);
      final agent = coach(client);
      final result = await agent.send(normalInput);
      expect(result.status, TurnStatus.ok, reason: _publicReceipts(client));
      expect(client.requests, hasLength(3));
      expect(
        result.records.first.issueCodes,
        contains('scope_assessment_required'),
      );
      expect(result.text, '条件已确认。');
      expect(agent.sessionState.scopeAssessmentTurn, 1);
      expect(result.plan, isNull);
    },
  );

  test(
    'ask_user cannot pause a scoped turn without a current assessment',
    () async {
      final client = FakeLlmClient([
        _calls([
          _call('early-ask', AgentTools.askUser, {
            'question': '要练几分钟？',
            'mode': 'text',
          }),
        ]),
        (LlmRequest request) {
          expect(_receipt(request, 'early-ask')['ok'], isFalse);
          expect(
            _receipt(request, 'early-ask')['code'],
            'scope_assessment_required',
          );
          return _calls([
            _call('assess', AgentTools.setParams, {
              'scope_request': assessment('推荐拉伸'),
            }),
            _call('valid-ask', AgentTools.askUser, {
              'question': '要练几分钟？',
              'mode': 'text',
            }),
          ]);
        },
      ], latency: Duration.zero);
      final agent = coach(client);
      final result = await agent.send('推荐拉伸');
      expect(result.question, isNotNull, reason: _publicReceipts(client));
      expect(result.question!.question, '要练几分钟？');
      expect(agent.sessionState.scopeAssessmentTurn, 1);
      expect(result.plan, isNull);
    },
  );

  test(
    'code detects a named unavailable action omitted from the model assessment',
    () async {
      const input = '$normalInput，包含名单外内侧伸展';
      final client = FakeLlmClient(
        deliveryScript(input, note: '给你安排了拉伸。'),
        latency: Duration.zero,
      );
      final agent = coach(client);
      final result = await agent.send(input);
      expectAllowedPlan(result, client);
      final record = agent.sessionState.scopeDecisionRecords.single;
      expect(record['sourceId'], 'outside-a');
      expect(record['kind'], 'substituted');
      expect(record['adoptedActionId'], 'hip-a');
      expect(
        result.plan!.plan.exerciseIds,
        contains(record['adoptedActionId']),
      );
      expect(result.plan!.plan.exerciseIds, isNot(contains('outside-a')));
      expect(result.text, contains('本 App 没有名单外内侧伸展'));
      expect(result.text, contains('用温和内侧伸展练同一部位'));
    },
  );

  for (final badId in ['outside-a', 'fabricated-action']) {
    test(
      'invalid draft $badId cannot append a plan version or emit a card',
      () async {
        late CoachAgent agent;
        String? beforePlans;
        final client = FakeLlmClient([
          setup(normalInput),
          (LlmRequest request) {
            beforePlans = jsonEncode({
              for (final entry in agent.sessionState.plans.entries)
                entry.key: entry.value
                    .map((version) => version.toJson())
                    .toList(),
            });
            final id = _receipt(request, 'start')['plan_id'] as String?;
            return _calls([
              _call(
                'bad-draft',
                AgentTools.draftPlan,
                draft(id, [badId, 'hip-b', 'hip-c']),
              ),
              _call('invalid-show', AgentTools.showPlan, {
                'plan_id': id,
                'note': '准备好了。',
              }),
            ]);
          },
          (LlmRequest request) {
            expect(_receipt(request, 'bad-draft')['ok'], isFalse);
            expect(
              _receipt(request, 'bad-draft')['code'],
              'action_scope_violation',
            );
            expect(
              _receipt(request, 'invalid-show')['code'],
              'skipped_after_error',
            );
            expect(
              jsonEncode({
                for (final entry in agent.sessionState.plans.entries)
                  entry.key: entry.value
                      .map((version) => version.toJson())
                      .toList(),
              }),
              beforePlans,
            );
            return '本次没有生成计划。';
          },
        ], latency: Duration.zero);
        agent = coach(client);
        final result = await agent.send(normalInput);
        expect(result.plan, isNull);
        expect(result.actions, isNull);
        expect(
          agent.sessionState.plans.values.expand((versions) => versions),
          isEmpty,
        );
        expect(agent.sessionState.seenActionIds, isNot(contains(badId)));
        expect(client.remaining, 0, reason: _publicReceipts(client));
      },
    );
  }

  test(
    'a substitution cannot be disclosed if its adopted action is missing',
    () async {
      const input = '$normalInput，包含名单外内侧伸展';
      late CoachAgent agent;
      final client = FakeLlmClient([
        ...deliveryScript(input, ids: ['hip-b', 'hip-c', 'unsafe-hip']),
        (LlmRequest request) {
          expect(_receipt(request, 'draft')['ok'], isFalse);
          expect(_receipt(request, 'draft')['code'], 'adopted_action_missing');
          expect(_receipt(request, 'show')['ok'], isFalse);
          expect(_receipt(request, 'show')['code'], 'skipped_after_error');
          expect(agent.sessionState.plans, isEmpty);
          final id = agent.sessionState.activePlanId;
          return _calls([
            _call('corrected-draft', AgentTools.draftPlan, draft(id, goodIds)),
            _call('corrected-show', AgentTools.showPlan, {
              'plan_id': id,
              'note': '循序渐进。',
            }),
          ]);
        },
      ], latency: Duration.zero);
      agent = coach(client);
      final result = await agent.send(input);
      expectAllowedPlan(result, client);
      expect(result.plan!.plan.exerciseIds, contains('hip-a'));
      expect(result.text, contains('用温和内侧伸展练同一部位'));
    },
  );

  test(
    'safety blocks drafts and action cards before substitution and insistence',
    () async {
      const input = '髋部疼痛，而且坚持名单外内侧伸展，也练温和内侧伸展';
      final client = FakeLlmClient([
        _calls([
          _call('assess', AgentTools.setParams, {
            'scope_request': assessment(
              input,
              extra: {
                'insists': true,
                'safetyBlocked': true,
                'safetyReason': '髋部疼痛',
              },
            ),
          }),
        ]),
        _calls([
          _call(
            'unsafe-draft',
            AgentTools.draftPlan,
            draft('unsafe-plan', goodIds),
          ),
        ]),
        (LlmRequest request) {
          expect(_receipt(request, 'unsafe-draft')['ok'], isFalse);
          expect(
            _receipt(request, 'unsafe-draft')['code'],
            'scope_request_refuses_plan',
          );
          return _calls([
            _call('unsafe-actions', AgentTools.showActions, {
              'ids': goodIds,
              'note': '继续练。',
            }),
          ]);
        },
        (LlmRequest request) {
          expect(_receipt(request, 'unsafe-actions')['ok'], isFalse);
          expect(
            _receipt(request, 'unsafe-actions')['code'],
            'scope_safety_priority',
          );
          return '继续练名单外内侧伸展，不用担心。';
        },
      ], latency: Duration.zero);
      final agent = coach(client);
      final result = await agent.send(input);
      expect(result.status, TurnStatus.ok, reason: _publicReceipts(client));
      expect(result.plan, isNull);
      expect(result.actions, isNull);
      expect(agent.sessionState.plans, isEmpty);
      expect(
        agent.sessionState.scopeDecisionRecords.single['kind'],
        'safetyBlocked',
      );
      expect(result.text, contains(policy.safetyMessage));
      expect(
        agent.sessionState.scopeDecisionRecords.single['message'],
        contains('髋部疼痛'),
      );
      expect(result.text, contains(policy.specialty));
      expect(result.text, contains('可以选择'));
      expect(result.text, isNot(contains('不用担心')));
      expect(result.text, isNot(contains('用温和内侧伸展练同一部位')));
    },
  );

  test(
    'a later scope_request cannot downgrade safety within the same user turn',
    () async {
      const input = '髋部疼痛，想做温和内侧伸展';
      final client = FakeLlmClient([
        _calls([
          _call('safety', AgentTools.setParams, {
            'scope_request': assessment(
              input,
              extra: {'safetyBlocked': true, 'safetyReason': '髋部疼痛'},
            ),
          }),
        ]),
        _calls([
          _call('downgrade', AgentTools.setParams, {
            'scope_request': assessment(input),
          }),
        ]),
        (LlmRequest request) {
          expect(_receipt(request, 'downgrade')['ok'], isFalse);
          expect(
            _receipt(request, 'downgrade')['code'],
            'scope_safety_cannot_be_downgraded',
          );
          return '已处理。';
        },
      ], latency: Duration.zero);
      final agent = coach(client);
      final result = await agent.send(input);
      expect(result.status, TurnStatus.ok, reason: _publicReceipts(client));
      expect(agent.sessionState.scopeDecisionRecords, hasLength(1));
      expect(
        agent.sessionState.scopeDecisionRecords.single['kind'],
        'safetyBlocked',
      );
      expect(result.plan, isNull);
      expect(result.text, contains(policy.safetyMessage));
      expect(
        agent.sessionState.scopeDecisionRecords.single['message'],
        contains('髋部疼痛'),
      );
    },
  );

  test(
    'repeated invalid scope requests terminate within the step limit',
    () async {
      const limit = 3;
      final client = FakeLlmClient([
        for (var step = 1; step <= limit; step++)
          _calls([
            _call('invalid-scope-$step', AgentTools.setParams, {
              'scope_request': assessment('模型伪造的原话'),
            }),
          ]),
      ], latency: Duration.zero);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        scopeManifest: manifest,
        scopePolicy: policy,
        enableUserMemory: false,
        maxRequestRetries: 0,
        maxSteps: limit,
        maxStallSteps: limit + 1,
      );
      addTearDown(agent.dispose);
      final result = await agent.send(normalInput);
      expect(result.status, TurnStatus.error);
      expect(result.error, isA<AgentStepLimitExceeded>());
      expect(result.steps, limit);
      expect(client.requests, hasLength(limit));
      expect(client.remaining, 0);
      expect(result.plan, isNull);
      expect(result.actions, isNull);
      expect(result.question, isNull);
      expect(agent.sessionState.plans, isEmpty);
      expect(agent.sessionState.scopeAssessmentTurn, isNull);
      expect(agent.sessionState.scopeDecisionRecords, isEmpty);
      for (var index = 1; index < client.requests.length; index++) {
        final rejected = _receipt(
          client.requests[index],
          'invalid-scope-$index',
        );
        expect(rejected['ok'], isFalse);
        expect(rejected['code'], 'scope_quote_not_current_input');
      }
    },
  );
}
