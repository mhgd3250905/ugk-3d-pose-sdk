import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_search.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/src/agent/plan_checker.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$pack/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$pack/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', turn: 1);

  for (final name in ['smartfit', 'hiplab', 'flarelab']) {
    test('$name body hierarchy survives profile JSON round trip', () {
      final original = loadProfile(name);
      final restored = CoachProfile.fromJson(original.toJson());
      expect(restored.bodyGroups, original.bodyGroups);
      expect(
        restored.bodyGroups['body.core'],
        containsAll(['body.abs', 'body.obliques', 'body.erectors']),
      );
    });
  }

  test('parent search matches descendants without altering catalogue tags', () {
    final search = ActionSearch(profile, catalog, minPicks: 3);
    final tags = search.gate.tags;
    final drill = catalog['rotator-cuff-A']!;
    expect(tags.forAction(drill), contains('body.abs'));
    expect(tags.forAction(drill), isNot(contains('body.core')));
    final found = search.search(
      CoachSessionState(
        params: {'scene': param('home'), 'equipment': param(<String>[])},
      ),
      tags: ['body.core'],
      keywords: drill.name.of('zh'),
    );
    expect(found.ok, isTrue, reason: '${found.error}');
    expect(found.items.map((row) => row['id']), contains(drill.id));
    for (final row in found.items) {
      expect(
        tags
            .forActionId(row['id'] as String)
            .intersection(tags.expandCodes(['body.core'])),
        isNotEmpty,
      );
    }
  });

  test('nested configurable groups terminate and do not widen scope', () {
    const custom = CoachProfile(
      id: 'custom',
      appName: 'custom',
      select: DrillSelector(ids: {'rotator-cuff-A'}),
      bodyGroups: {
        'body.custom_parent': ['body.custom_child'],
        'body.custom_child': ['body.abs', 'body.custom_parent'],
        'body.unavailable': ['body.calves'],
      },
    );
    final tags = ActionTags(custom, catalog);
    expect(tags.tags, contains('body.custom_parent'));
    expect(tags.goalCodes, contains('body.custom_child'));
    expect(tags.tags, isNot(contains('body.unavailable')));
    expect(tags.expandCodes(['body.custom_parent']), {
      'body.custom_parent',
      'body.custom_child',
      'body.abs',
    });
    expect(tags.forActionId('erectors-A'), isEmpty);
  });

  test('R3 ten-action plan passes focus with only body.core in ledger', () {
    const warmup = ['h-step-jack', 'forearms-A', 'n-pelvis-circle'];
    const main = [
      'erectors-A',
      'rotator-cuff-A',
      'deltoids-A',
      'h-kneeling-pushup',
      'h-good-morning',
    ];
    const cooldown = ['o-stand-sidebend', 'h-bilateral-upper-back-hug'];
    const selected = [...warmup, ...main, ...cooldown];
    final gates = NodeGates(profile, catalog, minPicks: 3);
    var state = CoachSessionState(
      userTurns: [const CoachUserTurn(turn: 1, text: '在家徒手20分钟练核心')],
      params: {
        'scene': param('home'),
        'goal': param(<String>['body.core']),
        'minutes': param(20),
        'equipment': param(<String>[]),
        'level': param(1),
        'limits': param(<String>[]),
      },
    );
    state = AgentTask.start(
      state,
      'plan',
    ).state.copyWith(seenActionIds: selected.toSet());
    state = gates.check(state, 'understand').state;
    state = gates.check(state, 'parameters').state;
    final actions = gates.check(state, 'actions', picks: selected);
    expect(actions.ok, isTrue, reason: '${actions.error}');
    final draft = PlanBuilder(profile, catalog, minPicks: 3).draft(
      actions.state,
      {
        'title': '居家核心',
        'blocks': [
          for (final block in [
            ('warmup', warmup),
            ('main', main),
            ('cooldown', cooldown),
          ])
            {
              'kind': block.$1,
              if (block.$1 == 'main') 'rounds': 2,
              'items': [
                for (final id in block.$2) {'id': id},
              ],
            },
        ],
      },
      newPlanId: 'r3',
    );
    expect(draft.ok, isTrue, reason: '${draft.error}');
    final planning = gates.check(draft.state, 'planning');
    expect(planning.ok, isTrue, reason: '${planning.error}');
    final checked = PlanChecker(
      profile,
      catalog,
      minPicks: 3,
    ).check(planning.state, 'r3');
    expect(checked.ok, isTrue, reason: '${checked.errors}');
    expect((checked.rules['focus_body'] as Map)['ok'], isTrue);
    expect(
      (checked.rules['focus_body'] as Map)['expected'],
      contains('body.core'),
    );
    expect(checked.state.params['goal']!.value, ['body.core']);
    final plan = PlanCodec().decode(checked.state.plans['r3']!.last.plan);
    expect(plan.exerciseIds, hasLength(10));
  });
}
