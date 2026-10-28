import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/src/agent/structured_tool_handler.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$pack/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$pack/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  const ids = [
    's-figure4',
    's-butterfly',
    's-kneel-hipflex',
    'forearms-A',
    'erectors-A',
    'deltoids-A',
  ];
  final draft = jsonEncode({
    'plan_id': 'defaults',
    'title': '拉伸',
    'blocks': [
      {
        'kind': 'main',
        'items': [
          for (final id in ids.take(3)) {'id': id},
        ],
      },
    ],
  });
  StructuredToolHandler handler(String id) => StructuredToolHandler(
    loadProfile(id),
    catalog,
    newPlanId: () => 'defaults',
    files: SkillFiles.build(loadProfile(id), catalog),
  );
  CoachSessionState start(StructuredToolHandler h, {bool goal = true}) {
    var state = h
        .task(
          CoachSessionState().appendUserTurn('拉伸练核心'),
          'start_task',
          '{"type":"plan"}',
          'zh',
        )
        .state;
    if (goal) {
      state = h
          .setParams(
            state,
            {
              'fields': {
                'goal': {
                  'value': [
                    h.profile.id == 'flarelab'
                        ? 'body.core'
                        : 'purpose.stretch',
                  ],
                  'source': 'user',
                  'quote': h.profile.id == 'flarelab' ? '核心' : '拉伸',
                },
              },
            },
            'zh',
            [],
          )
          .state;
    }
    return state.copyWith(seenActionIds: ids.toSet());
  }

  for (final name in ['smartfit', 'hiplab', 'flarelab']) {
    test(
      '$name draft fills its own scene/minutes defaults with genuine stamps',
      () {
        final h = handler(name);
        final payload = name == 'flarelab'
            ? jsonEncode({
                'plan_id': 'defaults',
                'title': '核心',
                'blocks': [
                  {
                    'kind': 'main',
                    'items': [
                      for (final id in ids.skip(3)) {'id': id},
                    ],
                  },
                ],
              })
            : draft;
        final result = h.draft(start(h), payload, 'zh');
        final receipt = jsonDecode(result.response) as Map;
        expect(
          receipt['code'],
          isNot('missing_parameters'),
          reason: result.response,
        );
        expect(
          result.state.plans['defaults'],
          isNotEmpty,
          reason: result.response,
        );
        final p = loadProfile(name);
        expect(result.state.params['scene']!.value, p.defaultScene);
        expect(
          result.state.params['minutes']!.value,
          int.parse(p.vars['defaultMinutes']!),
        );
        expect(result.state.params['scene']!.source, 'default');
        expect(result.state.params['minutes']!.source, 'default');
        expect(result.state.params['goal']!.source, 'user');
        final stamp = result.changes
            .singleWhere((n) => n.id == 'parameters')
            .stamp;
        expect(stamp, contains('默认'));
        expect(stamp, contains('${p.vars['defaultMinutes']} 分钟'));
      },
    );
  }
  test(
    'defaults preserve an existing host duration and failed drafts stay atomic',
    () {
      final h = handler('smartfit');
      final initial = start(h);
      final state = initial.copyWith(
        params: {
          ...initial.params,
          'minutes': CoachParamValue(value: 10, source: 'host', turn: 1),
        },
      );
      final result = h.draft(state, draft, 'zh');
      expect(
        result.state.plans['defaults'],
        isNotEmpty,
        reason: result.response,
      );
      expect(result.state.params['minutes'], same(state.params['minutes']));
      expect(result.state.params['scene']!.source, 'default');
      final invalid = jsonDecode(draft) as Map<String, Object?>;
      invalid['title'] = 3;
      final rejected = h.draft(state, jsonEncode(invalid), 'zh');
      expect((jsonDecode(rejected.response) as Map)['ok'], isFalse);
      expect(rejected.state, same(state));
      expect(rejected.changes, isEmpty);
    },
  );

  test(
    'only goal remains missing after available defaults, with identical field names',
    () {
      final h = handler('smartfit');
      final before = start(h, goal: false);
      final result = h.draft(before, draft, 'zh');
      final receipt = jsonDecode(result.response) as Map;
      expect(receipt['code'], 'missing_parameters');
      expect(receipt['expected'], ['scene', 'goal', 'minutes']);
      expect(receipt['actual'], ['goal']);
      expect(result.state, same(before));
      expect(result.changes, isEmpty);
    },
  );
  test(
    'builder reports names of genuinely missing fields, not values or placeholders',
    () {
      final h = handler('smartfit');
      final state = start(h);
      final result = PlanBuilder(loadProfile('smartfit'), catalog, minPicks: 3)
          .draft(
            state,
            jsonDecode(draft) as Map<String, Object?>,
            newPlanId: 'direct',
          );
      expect(result.toJson()['code'], 'missing_parameters');
      expect(result.toJson()['actual'], ['scene', 'minutes']);
      expect(result.toJson()['expected'], ['scene', 'goal', 'minutes']);
    },
  );
}
