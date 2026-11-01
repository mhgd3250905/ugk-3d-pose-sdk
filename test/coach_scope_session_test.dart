import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support/coach_scope_fixture.dart';

LlmToolCall _call(String id, String name, Object arguments) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments));

LlmResponse _calls(List<LlmToolCall> tools) =>
    LlmResponse(content: '', toolCalls: tools, finishReason: 'tool_calls');

Map<String, Object?> _receipt(LlmRequest request, String id) =>
    Map<String, Object?>.from(
      jsonDecode(request.messages.lastWhere((m) => m.toolCallId == id).content)
          as Map,
    );

Map<String, Object?> _params({Map<String, Object?>? scope}) => {
  'fields': {
    'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
    'goal': {
      'value': ['purpose.stretch'],
      'source': 'user',
      'quote': '拉伸',
    },
    'minutes': {'value': 5, 'source': 'user', 'quote': '5分钟'},
  },
  'scope_request': ?scope,
};

LlmResponse _setup({Map<String, Object?>? scope}) => _calls([
  _call('start', AgentTools.startTask, {'type': 'plan'}),
  _call('params', AgentTools.setParams, _params(scope: scope)),
  _call('search', AgentTools.searchActions, {'tags': <String>[], 'limit': 20}),
]);

Map<String, Object?> _draft(List<String> ids) => {
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

void _expectAllowed(CoachTurnResult result, Set<String> allowed) {
  expect(
    result.status,
    TurnStatus.ok,
    reason: '${result.error} ${result.issues}',
  );
  expect(result.plan, isNotNull, reason: '${result.error} ${result.issues}');
  final plan = result.plan!.plan;
  expect(plan.items, isNotEmpty);
  expect(plan.exerciseIds, isNotEmpty);
  expect(plan.exerciseIds.difference(allowed), isEmpty);
}

void main() {
  late Catalog catalog;
  late CoachActionScopeManifest manifest;
  setUp(() {
    final source = coachScopeFixtureCatalog(cautions: ['hip']);
    final extra = Map<String, Object?>.from(source['inside-c']!.raw)
      ..['id'] = 'inside-d'
      ..['name'] = {'zh': '另一臀部放松'};
    catalog = Catalog.fromJson({
      ...source.toJson(),
      'drills': [for (final drill in source.drills) drill.raw, extra],
    });
    manifest = coachScopeFixtureManifest(
      catalog,
      ids: {...coachScopeFixtureIds, 'inside-d'},
    );
  });

  CoachAgent agent(FakeLlmClient client, {bool scoped = true}) {
    final value = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: coachScopeFixtureProfile,
      scopeManifest: scoped ? manifest : null,
      scopePolicy: scoped ? coachScopeFixturePolicy : null,
      enableUserMemory: false,
      maxRequestRetries: 0,
    );
    addTearDown(value.dispose);
    return value;
  }

  CoachConversationController controller({bool scoped = true}) {
    final value = CoachConversationController(
      agent: agent(
        FakeLlmClient(const [], latency: Duration.zero),
        scoped: scoped,
      ),
    );
    addTearDown(value.dispose);
    return value;
  }

  test(
    'a prior in-scope goal is usable when the next turn only changes time',
    () async {
      final client = FakeLlmClient([
        _calls([
          _call('first-params', AgentTools.setParams, {
            'fields': {
              'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
              'goal': {
                'value': ['purpose.stretch'],
                'source': 'user',
                'quote': '大腿内侧拉伸',
              },
            },
          }),
        ]),
        '可以按这个重点安排。',
        _setup(scope: {'quote': '改成5分钟', 'inScopeQuote': '大腿内侧拉伸'}),
        (LlmRequest request) {
          expect(_receipt(request, 'params')['ok'], isTrue);
          expect(_receipt(request, 'params').containsKey('scope'), isFalse);
          return _calls([
            _call(
              'draft',
              AgentTools.draftPlan,
              _draft(coachScopeFixtureIds.toList()),
            ),
            _call('show', AgentTools.showPlan, {'note': '按前面的目标安排。'}),
          ]);
        },
      ], latency: Duration.zero);
      final value = agent(client);
      expect((await value.send('在家做大腿内侧拉伸，先讨论')).status, TurnStatus.ok);
      final result = await value.send('改成5分钟');
      _expectAllowed(result, value.actionScope!.plannableIds);
      expect(value.sessionState.scopeDecisionRecords, isEmpty);
    },
  );

  test(
    'the selected substitute is required before draft and a missing one is rebuilt',
    () async {
      late CoachAgent value;
      final client = FakeLlmClient([
        _setup(
          scope: {'sourceActionId': 'outside-a', 'hasInScopeContent': true},
        ),
        (LlmRequest request) {
          for (final id in ['params', 'search']) {
            expect(_receipt(request, id)['requiredActionIds'], ['inside-a']);
            expect(
              _receipt(request, id)['requiredActionsNotice'],
              contains('必须'),
            );
          }
          return _calls([
            _call(
              'missing-substitute',
              AgentTools.draftPlan,
              _draft(['inside-b', 'inside-c', 'inside-d']),
            ),
          ]);
        },
        (LlmRequest request) {
          expect(
            _receipt(request, 'missing-substitute')['code'],
            'adopted_action_missing',
          );
          expect(_receipt(request, 'missing-substitute')['requiredActionIds'], [
            'inside-a',
          ]);
          expect(value.sessionState.plans, isEmpty);
          return _calls([
            _call(
              'fixed-draft',
              AgentTools.draftPlan,
              _draft(coachScopeFixtureIds.toList()),
            ),
            _call('show', AgentTools.showPlan, {'note': '温和完成。'}),
          ]);
        },
      ], latency: Duration.zero);
      value = agent(client);
      final result = await value.send('在家拉伸5分钟，做外部内侧伸展');
      _expectAllowed(result, value.actionScope!.plannableIds);
      expect(result.plan!.plan.exerciseIds, contains('inside-a'));
      expect(result.text, contains('本 App 没有外部内侧伸展，用内侧放松练同一部位'));
    },
  );

  test(
    'external focus rejects an out-of-scope plan without changing the current plan',
    () {
      final value = controller();
      expect(
        value
            .focusExternalPlan(
              externalId: 'inside',
              plan: coachScopeFixturePlan(),
            )
            .ok,
        isTrue,
      );
      final before = value.agent.sessionState.toJson();
      final result = value.focusExternalPlan(
        externalId: 'outside',
        plan: coachScopeFixturePlan(first: coachScopeFixtureItem('outside-a')),
      );
      expect(result.ok, isFalse);
      expect(value.agent.sessionState.toJson(), before);
      expect(value.focus!.planId, 'ext:inside');
    },
  );

  test(
    'cross-App snapshot admission checks the actual plan and preserves the destination on rejection',
    () {
      final source = controller(scoped: false);
      expect(
        source
            .focusExternalPlan(
              externalId: 'other-app',
              plan: coachScopeFixturePlan(
                first: coachScopeFixtureItem('outside-a'),
              ),
            )
            .ok,
        isTrue,
      );
      final target = controller();
      expect(
        target
            .focusExternalPlan(
              externalId: 'inside',
              plan: coachScopeFixturePlan(),
            )
            .ok,
        isTrue,
      );
      final before = target.agent.sessionState.toJson();
      target.restoreSession(source.exportSession(), const []);
      expect(target.agent.sessionState.toJson(), before);
      expect(target.focus!.planId, 'ext:inside');
    },
  );

  test(
    'a compatible snapshot restores focus without scope hashes or version bindings',
    () {
      final source = controller();
      expect(
        source
            .focusExternalPlan(
              externalId: 'saved',
              plan: coachScopeFixturePlan(),
            )
            .ok,
        isTrue,
      );
      final snapshot = CoachSessionSnapshot.fromJson(
        source.exportSession().toJson(),
      );
      final target = controller();
      target.restoreSession(snapshot, const []);
      expect(target.focus!.planId, 'ext:saved');
      final admitted = target.prepareTraining(
        coachScopeFixturePlan(id: 'ext:saved'),
      );
      expect(admitted, isNotNull);
      expect(admitted!.plan.items, isNotEmpty);
      expect(
        admitted.plan.exerciseIds.difference(
          target.agent.actionScope!.plannableIds,
        ),
        isEmpty,
      );
    },
  );

  test(
    'confirmed movement pain takes priority over an outside-action substitution',
    () async {
      final client = FakeLlmClient([
        _calls([
          _call('start', AgentTools.startTask, {'type': 'plan'}),
          _call('params', AgentTools.setParams, {
            ..._params(
              scope: {'sourceActionId': 'outside-a', 'hasInScopeContent': true},
            ),
            'fields': {
              ...(_params()['fields']! as Map),
              'limits': {
                'value': ActionTags(
                  coachScopeFixtureProfile,
                  catalog,
                ).limitCodes,
                'source': 'user',
                'quote': '动作会痛',
              },
            },
          }),
          _call(
            'draft',
            AgentTools.draftPlan,
            _draft(coachScopeFixtureIds.toList()),
          ),
        ]),
        (LlmRequest request) {
          expect(
            _receipt(request, 'params')['ok'],
            isTrue,
            reason: '${_receipt(request, 'params')}',
          );
          expect(
            _receipt(request, 'draft')['code'],
            'scope_request_refuses_plan',
          );
          return const LlmResponse(
            content: '先暂停训练并处理疼痛。',
            toolCalls: [],
            finishReason: 'stop',
          );
        },
      ], latency: Duration.zero);
      final value = agent(client);
      final result = await value.send('在家拉伸5分钟，做外部内侧伸展，但动作会痛');
      expect(
        result.status,
        TurnStatus.ok,
        reason: '${result.error} ${result.issues}',
      );
      expect(result.plan, isNull);
      expect(value.sessionState.plans, isEmpty);
      expect(
        value.sessionState.scopeDecisionRecords.single['kind'],
        'safetyBlocked',
      );
      expect(
        value.sessionState.scopeDecisionRecords.single['adoptedActionId'],
        isNull,
      );
    },
  );
}
