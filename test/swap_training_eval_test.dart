import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

// Offline protocol evaluations with the real agent/catalog and scripted model
// responses. They do not establish real-model quality or device behavior.
Map<String, Object?> _item(
  String id,
  String mode, {
  int sets = 1,
  int? reps,
  int? seconds,
  bool perSide = false,
  int rest = 0,
}) => {
  'exerciseId': id,
  'mode': mode,
  'sets': sets,
  'reps': ?reps,
  'workSeconds': ?seconds,
  'perSide': perSide,
  'restSeconds': rest,
};
Map<String, Object?> _plan(
  List<Map<String, Object?>> items, {
  int minutes = 10,
  List<String> equipment = const ['mat'],
}) => {
  'schemaVersion': 1,
  'title': '髋部放松训练',
  'summary': '放松髋部',
  'goal': 'relax',
  'scene': 'home',
  'level': 1,
  'targetMinutes': minutes,
  'equipment': equipment,
  'blocks': [
    {'id': 'main', 'name': '训练', 'type': 'main', 'items': items},
  ],
};
Map<String, Object?> _initial() => _plan([
  _item(
    's-kneel-hipflex',
    'time',
    sets: 2,
    seconds: 60,
    perSide: true,
    rest: 60,
  ),
  _item('s-butterfly', 'time', sets: 2, seconds: 80, rest: 60),
]);
Map<String, Object?> _replacement() => _plan([
  _item('h-squat', 'reps', sets: 4, reps: 18, rest: 30),
  _item('adductors-A', 'reps', sets: 3, reps: 8, perSide: true, rest: 20),
], equipment: []);
Map<String, Object?> _replaceSecond() => _plan([
  _item(
    's-kneel-hipflex',
    'time',
    sets: 2,
    seconds: 60,
    perSide: true,
    rest: 60,
  ),
  _item('h-squat', 'reps', sets: 3, reps: 18, rest: 20),
]);
Map<String, Object?> _shorter() => _plan([
  _item('s-kneel-hipflex', 'time', seconds: 60, perSide: true),
  _item('s-butterfly', 'time', sets: 2, seconds: 80, rest: 10),
], minutes: 5);
Map<String, Object?> _shorterReplacement() => _plan(
  [
    _item('h-squat', 'reps', sets: 2, reps: 18, rest: 20),
    _item('adductors-A', 'reps', sets: 2, reps: 8, perSide: true, rest: 15),
  ],
  minutes: 5,
  equipment: [],
);
Map<String, Object?> _three() => _plan([
  _item(
    's-kneel-hipflex',
    'time',
    sets: 2,
    seconds: 60,
    perSide: true,
    rest: 60,
  ),
  _item('s-butterfly', 'time', seconds: 60),
  _item('h-squat', 'reps', sets: 2, reps: 18, rest: 20),
]);
Map<String, Object?> _oneOfThreeChanged() => _plan([
  _item(
    's-kneel-hipflex',
    'time',
    sets: 2,
    seconds: 60,
    perSide: true,
    rest: 60,
  ),
  _item('adductors-A', 'reps', sets: 2, reps: 8, perSide: true, rest: 20),
  _item('h-squat', 'reps', sets: 2, reps: 18, rest: 20),
]);
int _seq = 0;
Map<String, Object?> _user(Object value, String quote) => {
  'value': value,
  'source': 'user',
  'quote': quote,
};
LlmResponse _tool(String name, Object arguments) => LlmResponse(
  content: '',
  toolCalls: [
    LlmToolCall(
      id: 'swap-tool-${_seq++}',
      name: name,
      arguments: jsonEncode(arguments),
    ),
  ],
  finishReason: 'tool_calls',
  model: 'fake',
);
LlmResponse _set(Map<String, Object?> fields) =>
    _tool(AgentTools.setParams, {'fields': fields});
LlmResponse _initialFacts() => _set({
  'scene': _user('home', '在家'),
  'equipment': _user(['equip.mat'], '瑜伽垫'),
  'minutes': _user(10, '10分钟'),
});
LlmResponse _show(Map<String, Object?> plan) => LlmResponse(
  content: '调整后的计划',
  toolCalls: [
    LlmToolCall(
      id: 'swap-${_seq++}',
      name: AgentTools.showPlan,
      arguments: jsonEncode(plan),
    ),
  ],
  finishReason: 'tool_calls',
  model: 'fake',
);

void main() {
  const base = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final app = PoseHubAppTestCatalog.fromBytes(
    File('$base/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$base/catalog/catalog.json').readAsBytesSync(),
  );
  final catalog = app.toAiCatalog();
  final profile = loadProfile('smartfit');
  CoachConversationController controller(FakeLlmClient client) {
    final c = CoachConversationController(
      agent: CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      ),
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<CoachConversationController> started(FakeLlmClient client) async {
    final c = controller(client);
    final first = await c.send('在家有瑜伽垫，10分钟做髋部放松');
    expect(first!.plan, isNotNull, reason: '${first.issues} ${first.error}');
    return c;
  }

  test('swap fixtures use catalogue doses and remain within 10%', () {
    const available = CoachContext(scene: 'home', equipment: {'mat'});
    final duration = const PlanDuration();
    final validator = PlanValidator(
      catalog: catalog,
      profile: profile,
      enforceDrillDoseRange: true,
    );
    for (final raw in [
      _initial(),
      _replacement(),
      _replaceSecond(),
      _shorter(),
      _shorterReplacement(),
      _three(),
      _oneOfThreeChanged(),
    ]) {
      final plan = const PlanCodec().decode(raw);
      final checked = validator.validate(plan, available);
      expect(
        checked.errors,
        isEmpty,
        reason: '${plan.targetMinutes}: ${checked.errors}',
      );
      expect(
        (duration.estimateSeconds(plan, catalog) / 60 - plan.targetMinutes)
                .abs() /
            plan.targetMinutes,
        lessThanOrEqualTo(.10),
        reason: '${plan.targetMinutes}-minute scripted plan',
      );
    }
  });

  for (final phrase in ['换一套', '换个别的', '再来一套']) {
    for (final restore in [false, true]) {
      test(
        '$phrase after ${restore ? 'restore' : 'live session'} replaces the plan',
        () async {
          final client = FakeLlmClient([
            _initialFacts(),
            _show(_initial()),
            _show(_initial()),
            _show(_replacement()),
          ]);
          var c = await started(client);
          final previous = c.state.messages
              .lastWhere((m) => m.plan != null)
              .plan!
              .plan;
          if (restore) c = controller(client)..restoreHistory(c.state.messages);
          final beforeRequests = client.requests.length;
          final result = await c.send(phrase);
          expect(result!.question, isNull);
          expect(
            result.plan,
            isNotNull,
            reason: '${result.issues} ${result.error}',
          );
          final updated = result.plan!.plan;
          expect(updated.scene, 'home');
          expect(updated.targetMinutes, 10);
          expect(
            (const PlanDuration().estimateSeconds(updated, catalog) / 60 - 10)
                    .abs() /
                10,
            lessThanOrEqualTo(.10),
          );
          expect(
            updated.exerciseIds.intersection(previous.exerciseIds),
            isEmpty,
          );
          expect(c.agent.lastConfirmedForm?['scene'], ['家里']);
          expect(c.agent.lastConfirmedForm?['equipment'], contains('瑜伽垫'));
          expect(
            client.requests.length - beforeRequests,
            2,
            reason: 'identical first proposal should be rejected',
          );
          final retryText = client.requests.last.messages
              .map((m) => m.content)
              .join('\n');
          expect(retryText, isNot(contains('plan_not_requested')));
        },
      );
    }
  }

  test('a replacement can also request a shorter plan', () async {
    final shorterReplacement = _shorterReplacement();
    final client = FakeLlmClient([
      _initialFacts(),
      _show(_initial()),
      _set({'minutes': _user(5, '短一点')}),
      _show(shorterReplacement),
    ]);
    final c = await started(client);
    final result = await c.send('换一套，再短一点');
    expect(result!.question, isNull);
    expect(result.plan, isNotNull, reason: '${result.issues} ${result.error}');
    expect(result.plan!.plan.targetMinutes, 5);
    expect(
      (const PlanDuration().estimateSeconds(result.plan!.plan, catalog) / 60 -
                  5)
              .abs() /
          5,
      lessThanOrEqualTo(.10),
    );
    final request = client.requests.last.messages
        .map((m) => m.content)
        .join('\n');
    expect(request, contains('至少一半动作须为新动作'));
    expect(request, contains('上一套动作'));
  });

  test(
    'a whole replacement retries when fewer than half the actions are new',
    () async {
      final client = FakeLlmClient([
        _initialFacts(),
        _show(_three()),
        _show(_oneOfThreeChanged()),
        _show(_replacement()),
      ]);
      final c = controller(client);
      expect((await c.send('在家有瑜伽垫，10分钟做髋部放松'))!.plan, isNotNull);
      final result = await c.send('换一套');
      expect(
        result!.plan,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expect(client.requests, hasLength(4));
      final feedback = client.requests.last.messages
          .map((m) => m.content)
          .join('\n');
      expect(feedback, contains('plan_too_similar'));
    },
  );

  for (final sample in [
    ('换掉第 2 个', _replaceSecond),
    ('难一点', _initial),
    ('再短一点', _shorter),
  ]) {
    for (final restore in [false, true]) {
      test(
        'shortcut ${sample.$1} is an adjustment; restore=$restore',
        () async {
          final client = FakeLlmClient([
            _initialFacts(),
            _show(_initial()),
            if (sample.$1 == '再短一点') _set({'minutes': _user(5, '短一点')}),
            _show(sample.$2()),
          ]);
          var c = await started(client);
          if (restore) c = controller(client)..restoreHistory(c.state.messages);
          final result = await c.send(sample.$1);
          expect(result!.question, isNull);
          expect(
            result.plan,
            isNotNull,
            reason: '${result.issues} ${result.error}',
          );
          expect(result.plan!.plan.scene, 'home');
          expect(result.plan!.plan.targetMinutes, sample.$1 == '再短一点' ? 5 : 10);
          expect(c.agent.lastConfirmedForm?['equipment'], contains('瑜伽垫'));
        },
      );
    }
  }

  test('the model may ask about a different focus', () async {
    final client = FakeLlmClient([
      _initialFacts(),
      _show(_initial()),
      _tool(AgentTools.askUser, {'question': '肩膀有疼痛吗？', 'mode': 'text'}),
    ]);
    final c = await started(client);
    final requests = client.requests.length;
    final result = await c.send('再来一套练肩膀');
    expect(result!.plan, isNull);
    expect(result.question?.mode, AskUserMode.text);
    expect(result.question!.question, '肩膀有疼痛吗？');
    expect(client.requests, hasLength(requests + 1));
  });

  test(
    'swap without any plan does not inherit previous plan conditions',
    () async {
      final client = FakeLlmClient(['请先告诉我你想练什么。']);
      final c = controller(client);
      final result = await c.send('换一套');
      expect(result, isNotNull);
      expect(result!.plan, isNull);
      expect(c.agent.lastConfirmedForm, isNull);
    },
  );

  for (final text in ['换一个动作', '换个别的动作', '换掉第 2 个']) {
    test(
      '$text does not trigger a whole-plan replacement requirement',
      () async {
        final client = FakeLlmClient([
          _initialFacts(),
          _show(_three()),
          _show(_oneOfThreeChanged()),
        ]);
        final c = controller(client);
        final original = (await c.send('在家有瑜伽垫，10分钟做髋部放松'))!;
        expect(original.plan, isNotNull, reason: '${original.issues}');
        final result = await c.send(text);
        expect(result!.question, isNull);
        expect(
          result.plan,
          isNotNull,
          reason: '${result.issues} ${result.error}',
        );
        expect(
          result.plan!.plan.exerciseIds.intersection(
            original.plan!.plan.exerciseIds,
          ),
          hasLength(2),
        );
        expect(client.requests, hasLength(3));
      },
    );
  }
}
