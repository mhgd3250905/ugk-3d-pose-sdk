import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

// Scripted model responses exercise the real controller, agent and catalog.
// They are not a real-model or native-device evaluation.
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
Map<String, Object?> _plan({
  required int minutes,
  required List<String> equipment,
  required List<Map<String, Object?>> items,
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
Map<String, Object?> _initial() => _plan(
  minutes: 10,
  equipment: ['mat'],
  items: [
    _item(
      's-kneel-hipflex',
      'time',
      sets: 2,
      seconds: 60,
      perSide: true,
      rest: 60,
    ),
    _item('s-butterfly', 'time', sets: 2, seconds: 80, rest: 60),
  ],
);
Map<String, Object?> _seven() => _plan(
  minutes: 7,
  equipment: ['mat'],
  items: [
    _item(
      's-kneel-hipflex',
      'time',
      sets: 2,
      seconds: 60,
      perSide: true,
      rest: 30,
    ),
    _item('s-butterfly', 'time', seconds: 80),
  ],
);
Map<String, Object?> _shorter() => _plan(
  minutes: 5,
  equipment: ['mat'],
  items: [
    _item('s-kneel-hipflex', 'time', seconds: 60, perSide: true),
    _item('s-butterfly', 'time', sets: 2, seconds: 80, rest: 10),
  ],
);
Map<String, Object?> _bodyweight({bool short = false}) => _plan(
  minutes: short ? 5 : 10,
  equipment: [],
  items: short
      ? [
          _item('h-squat', 'reps', sets: 2, reps: 18, rest: 20),
          _item(
            'adductors-A',
            'reps',
            sets: 2,
            reps: 8,
            perSide: true,
            rest: 15,
          ),
        ]
      : [
          _item('h-squat', 'reps', sets: 4, reps: 18, rest: 30),
          _item(
            'adductors-A',
            'reps',
            sets: 3,
            reps: 8,
            perSide: true,
            rest: 20,
          ),
        ],
);
var _seq = 0;
Map<String, Object?> _user(Object value, String quote) => {
  'value': value,
  'source': 'user',
  'quote': quote,
};
LlmResponse _tool(String name, Object arguments) => LlmResponse(
  content: '',
  toolCalls: [
    LlmToolCall(
      id: 'restore-tool-${_seq++}',
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
LlmResponse _show(Map<String, Object?> p) => LlmResponse(
  content: '调整后的计划',
  toolCalls: [
    LlmToolCall(
      id: 'restore-${_seq++}',
      name: AgentTools.showPlan,
      arguments: jsonEncode(p),
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
  final duration = const PlanDuration();
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

  Future<List<CoachConversationMessage>> history() async {
    final c = controller(FakeLlmClient([_initialFacts(), _show(_initial())]));
    final result = await c.send('在家有瑜伽垫，10分钟做髋部放松');
    expect(result!.plan, isNotNull, reason: '${result.issues} ${result.error}');
    return c.state.messages;
  }

  List<CoachConversationMessage> legacy(
    List<CoachConversationMessage> messages,
  ) => [
    for (final message in messages)
      CoachConversationMessage(
        id: message.id,
        at: message.at,
        isUser: message.isUser,
        text: message.text,
        plan: message.plan,
        question: message.question,
        questionAnswered: message.questionAnswered,
        answeredChoices: message.answeredChoices,
        answeredForm: message.answeredForm,
        actions: message.actions,
      ),
  ];

  for (final sample in [
    ('短一点', _shorter, 5),
    ('缩短到 7 分钟', _seven, 7),
    ('换成徒手', _bodyweight, 10),
  ]) {
    test(
      'restored plan: ${sample.$1} is an adjustment without asking',
      () async {
        final previous = await history();
        final oldPlan = previous.lastWhere((m) => m.plan != null).plan!.plan;
        final client = FakeLlmClient([
          _set(
            sample.$1 == '换成徒手'
                ? {'equipment': _user(<String>[], '徒手')}
                : {
                    'minutes': _user(
                      sample.$3,
                      sample.$1 == '短一点' ? '短一点' : '7 分钟',
                    ),
                  },
          ),
          _show(sample.$2()),
        ]);
        final c = controller(client)..restoreHistory(previous);
        final result = await c.send(sample.$1);
        expect(result!.question, isNull);
        expect(
          result.plan,
          isNotNull,
          reason: '${result.issues} ${result.error}',
        );
        final plan = result.plan!.plan;
        expect(plan.targetMinutes, sample.$3);
        expect(plan.scene, 'home');
        expect(plan.equipment, sample.$1 == '换成徒手' ? isEmpty : ['mat']);
        if (sample.$1 == '短一点') {
          expect(
            duration.estimateSeconds(plan, catalog),
            lessThan(duration.estimateSeconds(oldPlan, catalog)),
          );
        }
        final requestText = client.requests.first.messages
            .map((m) => m.content)
            .join('\n');
        expect(
          requestText,
          contains('s-kneel-hipflex'),
          reason: 'model must see the previous plan, including actions',
        );
        expect(
          requestText,
          contains('workSeconds'),
          reason: 'previous doses must be restored too',
        );
      },
    );
  }

  test(
    'legacy history without plan conditions infers them from the last card',
    () async {
      final previous = legacy(
        await history(),
      ).where((message) => message.plan != null).toList();
      final client = FakeLlmClient([
        _set({'minutes': _user(7, '7 分钟')}),
        _show(_seven()),
      ]);
      final c = controller(client)..restoreHistory(previous);
      final result = await c.send('缩短到 7 分钟');
      expect(result!.question, isNull);
      expect(
        result.plan,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expect(result.plan!.plan.scene, 'home');
      expect(result.plan!.plan.equipment, ['mat']);
      expect(result.plan!.plan.targetMinutes, 7);
    },
  );

  test(
    'restored plan followed by a new focus may be clarified by the model',
    () async {
      final previous = await history();
      final client = FakeLlmClient([
        _tool(AgentTools.askUser, {'question': '肩膀有疼痛吗？', 'mode': 'text'}),
      ]);
      final c = controller(client)..restoreHistory(previous);
      final result = await c.send('我想针对肩膀拉伸');
      expect(result!.plan, isNull);
      expect(result.question, isNotNull);
      expect(result.question!.mode, AskUserMode.text);
      expect(result.question!.question, '肩膀有疼痛吗？');
      expect(client.requests, hasLength(1));
    },
  );

  test(
    'host-provided snapshot retains unused equipment and safety constraints',
    () async {
      final previous = legacy(await history());
      final plan = previous.lastWhere((m) => m.plan != null).plan!.plan;
      final snapshot = CoachPlanState(
        planId: plan.id,
        context: const CoachContext(
          scene: 'home',
          equipment: {'mat', 'chair'},
          minutes: 10,
          avoid: {'wrist'},
          notes: ['保护手腕'],
        ),
        focus: '髋部',
      );
      final restoredSnapshot = CoachPlanState.fromJson(
        jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, dynamic>,
      );
      expect(restoredSnapshot.toJson(), snapshot.toJson());
      final client = FakeLlmClient([
        _set({'minutes': _user(7, '7 分钟')}),
        _show(_seven()),
      ]);
      final c = controller(client)
        ..restoreHistory(previous, planState: restoredSnapshot);
      final result = await c.send('缩短到 7 分钟');
      expect(result!.question, isNull);
      expect(
        result.plan,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expect(
        c.agent.lastConfirmedForm?['equipment'],
        containsAll(['瑜伽垫', '椅子/凳子']),
      );
      final requestText = client.requests.first.messages
          .map((m) => m.content)
          .join('\n');
      expect(requestText, contains('wrist'));
      expect(requestText, contains('保护手腕'));
    },
  );

  for (final oldHistory in [false, true]) {
    test(
      'relative duration remains within 10% after restore; legacy=$oldHistory',
      () async {
        final original = controller(
          FakeLlmClient([
            _initialFacts(),
            _show(_initial()),
            _set({'minutes': _user(5, '短一点')}),
            _show(_shorter()),
          ]),
        );
        expect((await original.send('在家有瑜伽垫，10分钟做髋部放松'))!.plan, isNotNull);
        final short = (await original.send('短一点'))!;
        expect(short.plan, isNotNull);
        final before = short.plan!.plan;
        expect(
          (duration.estimateSeconds(before, catalog) / 60 -
                      before.targetMinutes)
                  .abs() /
              before.targetMinutes,
          lessThanOrEqualTo(.10),
        );
        final messages = oldHistory
            ? legacy(original.state.messages)
            : original.state.messages;
        final bodyweight = _bodyweight(short: true);
        final client = FakeLlmClient([
          _set({'equipment': _user(<String>[], '徒手')}),
          _show(bodyweight),
        ]);
        final c = controller(client)..restoreHistory(messages);
        final result = await c.send('换成徒手');
        expect(result!.question, isNull);
        expect(
          result.plan,
          isNotNull,
          reason: '${result.issues} ${result.error}',
        );
        expect(result.plan!.plan.targetMinutes, 5);
        expect(result.plan!.plan.equipment, isEmpty);
        expect(
          (duration.estimateSeconds(result.plan!.plan, catalog) / 60 - 5)
                  .abs() /
              5,
          lessThanOrEqualTo(.10),
        );
      },
    );
  }

  test(
    'snapshot of a different plan is never applied to the latest card',
    () async {
      final previous = legacy(await history());
      const mismatched = CoachPlanState(
        planId: 'other-plan',
        context: CoachContext(
          scene: 'office',
          equipment: {'chair'},
          minutes: 20,
        ),
        focus: '肩膀',
      );
      final c = controller(
        FakeLlmClient([
          _set({'minutes': _user(7, '7 分钟')}),
          _show(_seven()),
        ]),
      )..restoreHistory(previous, planState: mismatched);
      final result = await c.send('缩短到 7 分钟');
      expect(result!.question, isNull);
      expect(
        result.plan,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expect(result.plan!.plan.scene, 'home');
      expect(result.plan!.plan.equipment, ['mat']);
      expect(result.plan!.plan.targetMinutes, 7);
    },
  );

  test(
    'the last of multiple plan cards becomes the adjustment baseline',
    () async {
      final original = controller(
        FakeLlmClient([
          _initialFacts(),
          _show(_initial()),
          _set({'minutes': _user(7, '7 分钟')}),
          _show(_seven()),
        ]),
      );
      expect((await original.send('在家有瑜伽垫，10分钟做髋部放松'))!.plan, isNotNull);
      expect((await original.send('缩短到 7 分钟'))!.plan, isNotNull);
      final restored = original.state.messages;
      final eight = _seven()..['targetMinutes'] = 8;
      final client = FakeLlmClient([
        _show(eight),
        _set({'minutes': _user(5, '短一点')}),
        _show(_shorter()),
      ]);
      final c = controller(client)..restoreHistory(restored);
      final result = await c.send('短一点');
      expect(result!.question, isNull);
      expect(
        result.plan,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expect(result.plan!.plan.targetMinutes, 5);
      expect(
        client.requests,
        hasLength(3),
        reason:
            '8 minutes is shorter than the older card, but not the latest 7-minute card',
      );
    },
  );
}
