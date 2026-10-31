import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

const _user = '在家徒手练核心5分钟';
const _profile = CoachProfile(
  id: 'duration-recovery-agent',
  appName: 'duration-recovery-agent',
  minActions: 1,
  limits: PlanLimits(
    sets: IntRange(1, 1),
    rounds: IntRange(1, 1),
    workSeconds: IntRange(1, 600),
    restSeconds: IntRange(0, 0),
    restBetweenRoundsSeconds: IntRange(0, 0),
    minutes: IntRange(1, 60),
  ),
);

Drill _drill(String id, int seconds, {int? maximum}) => Drill(
  id: id,
  name: LocalizedText({'en': id}),
  category: 'core',
  muscleGroups: const ['abs'],
  position: 'standing',
  unilateral: false,
  level: 1,
  scenes: const ['home'],
  defaultDose: Dose(
    mode: DoseMode.time,
    sets: 1,
    seconds: seconds,
    restSeconds: 0,
  ),
  doseRange: DoseRange(
    sets: const IntRange(1, 1),
    seconds: IntRange(seconds, maximum ?? seconds),
    restSeconds: const IntRange(0, 0),
  ),
);

LlmToolCall _call(String id, String name, Object arguments) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments));

LlmResponse _calls(List<LlmToolCall> calls) => LlmResponse(
  content: '',
  toolCalls: calls,
  finishReason: 'tool_calls',
  model: 'fake',
);

Map<String, Object?> _receipt(LlmRequest request, String id) =>
    (jsonDecode(
              request.messages
                  .lastWhere((message) => message.toolCallId == id)
                  .content,
            )
            as Map)
        .cast<String, Object?>();

LlmResponse _setup({List<Map<String, Object?>>? dose, String? quote}) =>
    _calls([
      _call('start', AgentTools.startTask, {'type': 'plan'}),
      _call('params', AgentTools.setParams, {
        'fields': {
          'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
          'minutes': {'value': 5, 'source': 'user', 'quote': '5分钟'},
          'goal': {
            'value': ['body.abs'],
            'source': 'user',
            'quote': '练核心',
          },
          'equipment': {'value': <String>[], 'source': 'user', 'quote': '徒手'},
          if (dose != null)
            'dose': {'value': dose, 'source': 'user', 'quote': quote},
        },
      }),
      _call('search', AgentTools.searchActions, {
        'tags': <String>[],
        'limit': 20,
      }),
    ]);

LlmResponse _draft(String callId, List<String> ids) => _calls([
  _call(callId, AgentTools.draftPlan, {
    'title': 'Core session',
    'blocks': [
      {
        'kind': 'main',
        'items': [
          for (final id in ids) {'id': id},
        ],
      },
    ],
  }),
]);

LlmResponse _show(LlmRequest request, String draftId) {
  final result = _receipt(request, draftId);
  expect(result['ok'], isTrue, reason: '$result');
  expect(result['plan_id'], isA<String>());
  return _calls([
    _call('show', CoachTools.showPlan, {
      'plan_id': result['plan_id'],
      'note': '量力而行。',
    }),
  ]);
}

CoachAgent _agent(Catalog catalog, FakeLlmClient client) {
  final agent = CoachAgent(
    client: client,
    catalog: () => catalog,
    profile: _profile,
    enableUserMemory: false,
    maxRequestRetries: 0,
  );
  addTearDown(agent.dispose);
  return agent;
}

void _expectPlan(CoachTurnResult result, Catalog catalog) {
  expect(
    result.status,
    TurnStatus.ok,
    reason: '${result.error}; ${result.issues}',
  );
  expect(result.question, isNull);
  expect(result.plan, isNotNull, reason: '${result.error}; ${result.issues}');
  expect(
    const PlanDuration().estimateSeconds(result.plan!.plan, catalog),
    inInclusiveRange(270, 330),
  );
}

void main() {
  final long = Catalog(
    version: 'long-combination',
    drills: [
      _drill('alpha', 180, maximum: 300),
      _drill('beta', 180, maximum: 300),
    ],
  );

  test(
    'model-selected minimum over target returns to draft and delivers',
    () async {
      final client = FakeLlmClient([
        _setup(),
        _draft('bad-draft', ['alpha', 'beta']),
        (LlmRequest request) {
          final result = _receipt(request, 'bad-draft');
          expect(result['code'], 'duration_fit_failed');
          expect(result['minEstimatedSec'], 385);
          expect(result['maxEstimatedSec'], 625);
          expect(result['needsDraftRebuild'], isTrue);
          expect(result['clarificationAllowed'], isFalse);
          expect(result['removeCandidates'], isNotEmpty);
          return _draft('fixed-draft', ['alpha']);
        },
        (LlmRequest request) => _show(request, 'fixed-draft'),
      ], latency: Duration.zero);
      final agent = _agent(long, client);
      final events = <AgentEvent>[];
      final sub = agent.events.listen(events.add);
      addTearDown(sub.cancel);
      final result = await agent.send(_user);
      _expectPlan(result, long);
      expect(
        events.where((event) => event.kind == AgentEventKind.askUser),
        isEmpty,
      );
      expect(agent.sessionState.plans.values.single, hasLength(1));
      expect(client.requests, hasLength(4));
    },
  );

  test('model cannot replace a required rebuild with ask_user', () async {
    final client = FakeLlmClient([
      _setup(),
      _draft('bad-draft', ['alpha', 'beta']),
      (LlmRequest request) {
        expect(_receipt(request, 'bad-draft')['needsDraftRebuild'], isTrue);
        return _calls([
          _call('premature-ask', AgentTools.askUser, {
            'question': '要减少一个动作吗？',
            'mode': 'text',
          }),
        ]);
      },
      (LlmRequest request) {
        final rejected = _receipt(request, 'premature-ask');
        expect(rejected['ok'], isFalse);
        expect(rejected['code'], 'duration_fit_failed');
        expect(rejected['minEstimatedSec'], 385);
        expect(rejected['removeCandidates'], isNotEmpty);
        expect(rejected['clarificationAllowed'], isFalse);
        return _draft('fixed-draft', ['beta']);
      },
      (LlmRequest request) => _show(request, 'fixed-draft'),
    ], latency: Duration.zero);
    final agent = _agent(long, client);
    final events = <AgentEvent>[];
    final sub = agent.events.listen(events.add);
    addTearDown(sub.cancel);
    _expectPlan(await agent.send(_user), long);
    expect(
      events.where((event) => event.kind == AgentEventKind.askUser),
      isEmpty,
    );
    expect(client.requests, hasLength(5));
  });

  test(
    'insufficient maximum adds a compatible action before delivery',
    () async {
      final catalog = Catalog(
        version: 'short-combination',
        drills: [_drill('short', 100), _drill('added', 180)],
      );
      final client = FakeLlmClient([
        _setup(),
        _draft('bad-draft', ['short']),
        (LlmRequest request) {
          final result = _receipt(request, 'bad-draft');
          expect(result['code'], 'duration_fit_failed');
          expect(result['maxEstimatedSec'], 110);
          expect(result['addCandidates'], isNotEmpty);
          expect(result['clarificationAllowed'], isFalse);
          return _draft('fixed-draft', ['short', 'added']);
        },
        (LlmRequest request) => _show(request, 'fixed-draft'),
      ], latency: Duration.zero);
      _expectPlan(await _agent(catalog, client).send(_user), catalog);
      expect(client.requests, hasLength(4));
    },
  );

  test('a confirmed global dose still rebuilds when removal can fit', () async {
    const quote = '每个动作300秒';
    final client = FakeLlmClient([
      _setup(
        dose: [
          {'field': 'seconds', 'value': 300},
        ],
        quote: quote,
      ),
      _draft('bad-draft', ['alpha', 'beta']),
      (LlmRequest request) {
        final result = _receipt(request, 'bad-draft');
        expect(result['code'], 'duration_fit_failed');
        expect(result['clarificationAllowed'], isFalse);
        expect(result['removeCandidates'], isNotEmpty);
        return _draft('fixed-draft', ['alpha']);
      },
      (LlmRequest request) => _show(request, 'fixed-draft'),
    ], latency: Duration.zero);
    final result = await _agent(long, client).send('$_user，$quote');
    _expectPlan(result, long);
    expect(result.plan!.plan.items.single.workSeconds, 300);
  });

  test('a proved unavoidable confirmed action dose may clarify', () async {
    final catalog = Catalog(version: 'locked', drills: [_drill('locked', 400)]);
    const quote = 'locked必须400秒';
    final client = FakeLlmClient([
      _setup(
        dose: [
          {'field': 'seconds', 'value': 400, 'actionId': 'locked'},
        ],
        quote: quote,
      ),
      _draft('locked-draft', ['locked']),
    ], latency: Duration.zero);
    final agent = _agent(catalog, client);
    final result = await agent.send('$_user，$quote');
    expect(
      result.status,
      TurnStatus.ok,
      reason: '${result.error}; ${result.issues}',
    );
    expect(result.question, isNotNull);
    expect(result.plan, isNull);
    expect(
      agent.sessionState.plans.values.expand((versions) => versions),
      isEmpty,
    );
    expect(client.requests, hasLength(2));
  });

  test('an ordinary unrelated ask has no pending-duration guard', () async {
    final client = FakeLlmClient([
      _calls([
        _call('ask', AgentTools.askUser, {
          'question': '你想在家还是办公室练？',
          'mode': 'text',
        }),
      ]),
    ], latency: Duration.zero);
    final result = await _agent(long, client).send('给我安排训练');
    expect(result.status, TurnStatus.ok);
    expect(result.question?.question, '你想在家还是办公室练？');
    expect(client.requests, hasLength(1));
  });

  for (final strategy in [
    'repeated asks',
    'invalid redrafts',
    'alternating retries',
  ]) {
    test(
      '$strategy stop at maxSteps without a question or approximate plan',
      () async {
        const maxSteps = 5;
        final catalog = Catalog(
          version: 'unrepaired-combinations',
          drills: [
            _drill('alpha', 180, maximum: 300),
            _drill('beta', 180, maximum: 300),
            _drill('gamma', 180, maximum: 300),
          ],
        );
        final retries = switch (strategy) {
          'repeated asks' => [
            (id: 'ask-0', ask: true, ids: <String>[]),
            (id: 'ask-1', ask: true, ids: <String>[]),
            (id: 'ask-2', ask: true, ids: <String>[]),
          ],
          'invalid redrafts' => [
            (id: 'draft-0', ask: false, ids: ['alpha', 'gamma']),
            (id: 'draft-1', ask: false, ids: ['beta', 'gamma']),
            (id: 'draft-2', ask: false, ids: ['gamma', 'alpha', 'beta']),
          ],
          _ => [
            (id: 'ask-0', ask: true, ids: <String>[]),
            (id: 'draft-0', ask: false, ids: ['alpha', 'gamma']),
            (id: 'ask-1', ask: true, ids: <String>[]),
          ],
        };
        var previous = 'bad-draft';
        var sentinelConsumed = false;
        var fallbackCalls = 0;
        late final CoachAgent agent;
        final client = FakeLlmClient([
          _setup(),
          _draft(previous, ['alpha', 'beta']),
          for (final retry in retries)
            (LlmRequest request) {
              final rejected = _receipt(request, previous);
              expect(rejected['ok'], isFalse);
              expect(rejected['code'], 'duration_fit_failed');
              expect(rejected['minEstimatedSec'], greaterThan(330));
              expect(rejected['needsDraftRebuild'], isTrue);
              expect(rejected['clarificationAllowed'], isFalse);
              expect(rejected['plan_id'], isNull);
              expect(agent.sessionState.plans.values.expand((v) => v), isEmpty);
              expect(agent.sessionState.task!.nodes.last.status, isNot('done'));
              previous = retry.id;
              return retry.ask
                  ? _calls([
                      _call(retry.id, AgentTools.askUser, {
                        // Identical arguments exercise repeated asks; unique IDs
                        // still preserve the tool-response protocol.
                        'question': '要延长训练时长吗？',
                        'mode': 'text',
                      }),
                    ])
                  : _draft(retry.id, retry.ids);
            },
          (LlmRequest request) {
            sentinelConsumed = true;
            return _draft('must-not-run', ['alpha']);
          },
        ], latency: Duration.zero);
        agent = CoachAgent(
          client: client,
          catalog: () => catalog,
          profile: _profile,
          enableUserMemory: false,
          maxRequestRetries: 0,
          maxSteps: maxSteps,
          // Isolate the step cap from duplicate/idle and rejection budgets.
          maxStallSteps: maxSteps + 3,
          maxResubmits: maxSteps + 3,
          fallback: (_) {
            fallbackCalls++;
            return const SessionFallbackReply(
              'Must not replace the requested plan',
            );
          },
        );
        addTearDown(agent.dispose);
        final events = <AgentEvent>[];
        final sub = agent.events.listen(events.add);
        addTearDown(sub.cancel);

        final result = await agent.send(_user);

        expect(result.status, TurnStatus.error);
        expect(result.error, isA<AgentStepLimitExceeded>());
        expect((result.error! as AgentStepLimitExceeded).maxSteps, maxSteps);
        expect(result.steps, maxSteps);
        expect(client.requests, hasLength(maxSteps));
        expect(client.remaining, 1);
        expect(sentinelConsumed, isFalse);
        expect(fallbackCalls, 0);
        expect(result.plan, isNull);
        expect(result.actions, isNull);
        expect(result.question, isNull);
        expect(result.isPlanningFailure, isTrue);
        expect(agent.sessionState.plans.values.expand((v) => v), isEmpty);
        expect(agent.sessionState.lastDeliveredPlanId, isNull);
        expect(agent.sessionState.lastDeliveredVersion, isNull);
        expect(agent.sessionState.task!.nodes.last.status, isNot('done'));
        expect(
          events.where((event) => event.kind == AgentEventKind.askUser),
          isEmpty,
        );
        expect(
          events.where(
            (event) =>
                event.kind == AgentEventKind.node &&
                event.node?.id == 'output' &&
                event.node?.status == 'done',
          ),
          isEmpty,
        );
        expect(
          events
              .where((event) => event.kind == AgentEventKind.done)
              .single
              .status,
          TurnStatus.error,
        );
      },
    );
  }
}
