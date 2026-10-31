import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/ugk_coach.dart';

const _profile = CoachProfile(
  id: 'recovery-candidates',
  appName: 'recovery-candidates',
  minActions: 1,
  limits: PlanLimits(
    sets: IntRange(1, 6),
    workSeconds: IntRange(1, 1000),
    restSeconds: IntRange(0, 0),
    rounds: IntRange(1, 1),
    restBetweenRoundsSeconds: IntRange(0, 0),
    minutes: IntRange(1, 60),
  ),
);

Drill _drill(
  String id,
  int work, {
  List<String> equipment = const [],
  List<String> scenes = const ['home'],
  List<String> cautions = const [],
  IntRange sets = const IntRange(1, 1),
}) => Drill(
  id: id,
  name: LocalizedText({'zh': '动作 $id', 'en': id}),
  category: 'core',
  muscleGroups: const ['abs'],
  equipment: equipment,
  position: 'standing',
  unilateral: false,
  level: 1,
  scenes: scenes,
  cautions: cautions,
  defaultDose: Dose(
    mode: DoseMode.time,
    sets: sets.min,
    seconds: work,
    restSeconds: 0,
  ),
  doseRange: DoseRange(
    sets: sets,
    seconds: IntRange(work, work),
    restSeconds: const IntRange(0, 0),
  ),
);

CoachSessionState _state(
  List<String> selected, {
  int minutes = 5,
  List<Map<String, Object?>>? dose,
  String quote = '每个动作两组，安排五分钟',
  String userText = '每个动作两组，安排五分钟',
  List<String> limits = const [],
}) {
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', quote: userText, turn: 1);
  return CoachSessionState(
    userTurns: [CoachUserTurn(turn: 1, text: userText)],
    task: CoachTaskState(
      type: 'plan',
      reused: false,
      nodes: [
        for (final id in [
          'understand',
          'parameters',
          'actions',
          'planning',
          'review',
          'output',
        ])
          CoachNodeState(
            id: id,
            status: id == 'planning'
                ? 'current'
                : ['understand', 'parameters', 'actions'].contains(id)
                ? 'done'
                : 'pending',
          ),
      ],
    ),
    params: {
      'scene': param('home'),
      'minutes': param(minutes),
      'goal': param(['body.abs']),
      'equipment': param(<String>[]),
      'limits': param(limits),
      if (dose != null)
        'dose': CoachParamValue(
          value: dose,
          source: 'user',
          quote: quote,
          turn: 1,
        ),
    },
    seenActionIds: selected.toSet(),
    picks: selected,
  );
}

Map<String, Object?> _draft(List<List<String>> blocks) => {
  'title': '有界配时',
  'blocks': [
    for (final ids in blocks)
      {
        'kind': 'main',
        'items': [
          for (final id in ids) {'id': id},
        ],
      },
  ],
};

Map<String, Object?> _diagnostic(DraftResult result) {
  expect(result.planId, isNull);
  expect(result.version, isNull);
  final json = result.toJson();
  return {
    ...json,
    if (json['recovery'] is Map)
      ...Map<String, Object?>.from(json['recovery']! as Map),
    if (json['feasibility'] is Map)
      ...Map<String, Object?>.from(json['feasibility']! as Map),
  };
}

List<Map<String, Object?>> _candidates(
  Map<String, Object?> diagnostic,
  String key,
) => [
  for (final value in diagnostic[key]! as List)
    Map<String, Object?>.from(value as Map),
];

void main() {
  test(
    'catalogue-fixed 336 second combination recommends removal, not user choice',
    () {
      const ids = ['chair', 'squat', 'pushup', 'hinge', 'stretch'];
      final catalog = Catalog(
        version: 'synthetic-sf',
        drills: [
          for (final (index, work) in [168, 24, 20, 24, 30].indexed)
            _drill(ids[index], work),
        ],
      );
      final before = _state(ids, userText: '在家徒手五分钟全身训练');
      final snapshot = before.toJson();
      final result = PlanBuilder(
        _profile,
        catalog,
        minPicks: 1,
      ).draft(before, _draft([ids]), newPlanId: 'must-not-save');
      final diagnostic = _diagnostic(result);
      expect(diagnostic['minEstimatedSec'], 336);
      expect(diagnostic['maxEstimatedSec'], 336);
      expect(diagnostic['direction'], 'remove_action');
      expect(diagnostic['userConfirmedDose'], isFalse);
      expect(diagnostic['clarificationAllowed'], isFalse);
      expect(diagnostic['needsDraftRebuild'], isTrue);
      expect(diagnostic['structuralRepairPossible'], isTrue);
      final pushup = _candidates(
        diagnostic,
        'removeCandidates',
      ).singleWhere((value) => value['actionId'] == 'pushup');
      expect(pushup['minEstimatedSec'], 301);
      expect(pushup['maxEstimatedSec'], 301);
      expect(pushup['rangeOverlapsTarget'], isTrue);
      expect(pushup['index'], 3);
      expect(before.toJson(), snapshot);
      expect(result.state.plans, isEmpty);
    },
  );

  test('all removals are evaluated before the response list is bounded', () {
    final ids = [for (var i = 0; i < 12; i++) 'a$i'];
    final catalog = Catalog(
      version: 'many-removals',
      drills: [for (final id in ids) _drill(id, 30)],
    );
    final result = PlanBuilder(_profile, catalog, minPicks: 1).draft(
      _state(ids, userText: '只安排五分钟'),
      _draft([ids]),
      newPlanId: 'not-saved',
    );
    final diagnostic = _diagnostic(result);
    expect(diagnostic['removeCandidateCount'], 12);
    expect(_candidates(diagnostic, 'removeCandidates'), hasLength(8));
    expect(diagnostic['structuralRepairPossible'], isFalse);
    expect(
      diagnostic['clarificationAllowed'],
      isFalse,
      reason: 'A single deletion missing the interval is not a global proof.',
    );
    expect(diagnostic['needsDraftRebuild'], isTrue);
  });

  test('short upper bound offers safe additions and marks unsearched IDs', () {
    final catalog = Catalog(
      version: 'safe-additions',
      taxonomy: const Taxonomy(equipment: {'chair': '椅子'}, cautions: ['knee']),
      drills: [
        _drill('selected', 100),
        _drill('new-safe', 175),
        _drill('wrong-gear', 175, equipment: ['chair']),
        _drill('wrong-scene', 175, scenes: ['gym']),
        _drill('knee-conflict', 175, cautions: ['knee']),
      ],
    );
    final state = _state(['selected'], limits: ['limit.knee']);
    final result = PlanBuilder(_profile, catalog, minPicks: 1).draft(
      state,
      _draft([
        ['selected'],
      ]),
      newPlanId: 'not-saved',
    );
    final diagnostic = _diagnostic(result);
    expect(diagnostic['minEstimatedSec'], 110);
    expect(diagnostic['maxEstimatedSec'], 110);
    expect(diagnostic['direction'], 'add_action');
    final additions = _candidates(diagnostic, 'addCandidates');
    expect(additions.map((value) => value['actionId']), ['new-safe']);
    expect(additions.single['minEstimatedSec'], 300);
    expect(additions.single['maxEstimatedSec'], 300);
    expect(additions.single['rangeOverlapsTarget'], isTrue);
    expect(additions.single['requiresSearch'], isTrue);
    expect(result.state.seenActionIds, {'selected'});
  });

  test('one user-locked action leaves other model choices removable', () {
    final catalog = Catalog(
      version: 'partial-lock',
      drills: [_drill('locked', 168), _drill('other', 143)],
    );
    final state = _state(
      ['locked', 'other'],
      dose: [
        {'field': 'seconds', 'value': 168, 'actionId': 'locked'},
      ],
    );
    final result = PlanBuilder(_profile, catalog, minPicks: 1).draft(
      state,
      _draft([
        ['locked', 'other'],
      ]),
      newPlanId: 'not-saved',
    );
    final diagnostic = _diagnostic(result);
    expect(diagnostic['minEstimatedSec'], 336);
    expect(diagnostic['userConfirmedDose'], isTrue);
    expect(diagnostic['confirmedActionIds'], ['locked']);
    expect(
      _candidates(
        diagnostic,
        'removeCandidates',
      ).map((candidate) => candidate['actionId']),
      ['other'],
    );
    expect(diagnostic['clarificationAllowed'], isFalse);
    expect(diagnostic['needsDraftRebuild'], isTrue);
  });

  test('only a proven required-action minimum authorizes clarification', () {
    final catalog = Catalog(
      version: 'locked-proof',
      drills: [_drill('locked', 500), _drill('other', 20)],
    );
    final before = _state(
      ['locked', 'other'],
      dose: [
        {'field': 'seconds', 'value': 500, 'actionId': 'locked'},
      ],
    );
    final result = PlanBuilder(_profile, catalog, minPicks: 1).draft(
      before,
      _draft([
        ['locked', 'other'],
      ]),
      newPlanId: 'not-saved',
    );
    final diagnostic = _diagnostic(result);
    expect(diagnostic['lockedMinimumSec'], 510);
    expect(diagnostic['clarificationAllowed'], isTrue);
    expect(
      diagnostic['clarificationProof'],
      'confirmed_action_minimum_exceeds_target',
    );
    expect(diagnostic['needsDraftRebuild'], isFalse);
    expect(result.state.plans, isEmpty);
  });

  test(
    'restored source=user text without a real quote is not confirmation',
    () {
      final catalog = Catalog(
        version: 'forged-source',
        drills: [_drill('large', 500), _drill('other', 20)],
      );
      final result = PlanBuilder(_profile, catalog, minPicks: 1).draft(
        _state(
          ['large', 'other'],
          dose: [
            {'field': 'seconds', 'value': 500, 'actionId': 'large'},
          ],
          quote: 'not said by the user',
          userText: '五分钟',
        ),
        _draft([
          ['large', 'other'],
        ]),
        newPlanId: 'not-saved',
      );
      final diagnostic = _diagnostic(result);
      expect(diagnostic['userConfirmedDose'], isFalse);
      expect(diagnostic['confirmedActionIds'], isEmpty);
      expect(diagnostic['clarificationAllowed'], isFalse);
    },
  );

  test(
    'addition candidates honor global user dose and catalogue intersections',
    () {
      final catalog = Catalog(
        version: 'global-dose',
        drills: [
          _drill('selected', 100, sets: const IntRange(1, 3)),
          _drill('new-safe', 190, sets: const IntRange(1, 3)),
          _drill('wrong-sets', 190),
        ],
      );
      final result = PlanBuilder(_profile, catalog, minPicks: 1).draft(
        _state(
          ['selected'],
          minutes: 10,
          dose: [
            {'field': 'sets', 'value': 2},
          ],
        ),
        _draft([
          ['selected'],
        ]),
        newPlanId: 'not-saved',
      );
      final diagnostic = _diagnostic(result);
      expect(diagnostic['maxEstimatedSec'], 210);
      final additions = _candidates(diagnostic, 'addCandidates');
      expect(additions.map((candidate) => candidate['actionId']), ['new-safe']);
      expect(additions.single['minEstimatedSec'], 605);
      expect(additions.single['maxEstimatedSec'], 605);
      expect(additions.single['rangeOverlapsTarget'], isTrue);
      expect(diagnostic['clarificationAllowed'], isFalse);
    },
  );

  test(
    'removal cannot erase the block named by a confirmed round constraint',
    () {
      final catalog = Catalog(
        version: 'block-lock',
        drills: [_drill('large', 500), _drill('other', 20)],
      );
      final result = PlanBuilder(_profile, catalog, minPicks: 1).draft(
        _state(
          ['large', 'other'],
          dose: [
            {'field': 'rounds', 'value': 1, 'blockId': 'b1'},
          ],
        ),
        _draft([
          ['large'],
          ['other'],
        ]),
        newPlanId: 'not-saved',
      );
      final diagnostic = _diagnostic(result);
      expect(
        _candidates(
          diagnostic,
          'removeCandidates',
        ).map((candidate) => candidate['actionId']),
        ['other'],
      );
      expect(
        diagnostic['clarificationAllowed'],
        isFalse,
        reason:
            'A block-scoped round does not lock this model-selected action.',
      );
    },
  );
}
