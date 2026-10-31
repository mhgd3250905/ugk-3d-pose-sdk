import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/src/agent/structured_tool_handler.dart';
import 'package:ugk_coach/ugk_coach.dart';

const _profile = CoachProfile(
  id: 'executed-duration-gate',
  appName: 'executed-duration-gate',
  minActions: 1,
  limits: PlanLimits(
    sets: IntRange(1, 1),
    rounds: IntRange(1, 1),
    workSeconds: IntRange(1, 1000),
    restSeconds: IntRange(0, 0),
    restBetweenRoundsSeconds: IntRange(0, 0),
    minutes: IntRange(1, 60),
  ),
);

Drill _drill(String id, int work, {IntRange? range}) => Drill(
  id: id,
  name: LocalizedText({'zh': '动作 $id', 'en': id}),
  category: 'core',
  muscleGroups: const ['abs'],
  position: 'standing',
  unilateral: false,
  level: 1,
  scenes: const ['home'],
  defaultDose: Dose(
    mode: DoseMode.time,
    sets: 1,
    seconds: work,
    restSeconds: 0,
  ),
  doseRange: DoseRange(
    sets: const IntRange(1, 1),
    seconds: range ?? IntRange(work, work),
    restSeconds: const IntRange(0, 0),
  ),
);

final _catalog = Catalog(
  version: 'executed-duration-gate',
  drills: [_drill('a', 316, range: const IntRange(240, 320))],
);

CoachParamValue _param(Object value) =>
    CoachParamValue(value: value, source: 'user', quote: '在家练核心五分钟', turn: 1);

CoachSessionState _state({
  List<String> picks = const ['a'],
  bool output = false,
}) => CoachSessionState(
  userTurns: const [CoachUserTurn(turn: 1, text: '在家练核心五分钟')],
  task: CoachTaskState(
    type: 'plan',
    reused: false,
    nodes: [
      for (final id in AgentTask.planNodes)
        CoachNodeState(
          id: id,
          status: output
              ? id == 'output'
                    ? 'current'
                    : 'done'
              : id == 'planning'
              ? 'current'
              : ['understand', 'parameters', 'actions'].contains(id)
              ? 'done'
              : 'pending',
        ),
    ],
  ),
  params: {
    'scene': _param('home'),
    'minutes': _param(5),
    'goal': _param(['body.abs']),
    'equipment': _param(<String>[]),
    'limits': _param(<String>[]),
  },
  seenActionIds: picks.toSet(),
  picks: picks,
  recommendationHintShown: true,
);

Map<String, Object?> _arguments([List<String> ids = const ['a']]) => {
  'title': '执行时间线门禁',
  'blocks': [
    {
      'kind': 'main',
      'items': [
        for (final id in ids) {'id': id},
      ],
    },
  ],
};

TrainingPlan _plan({String id = 'p', int seconds = 316}) => TrainingPlan(
  id: id,
  source: 'ai',
  title: '已保存计划',
  summary: '按已确认条件安排的核心训练。',
  goal: 'core',
  scene: 'home',
  level: 1,
  targetMinutes: 5,
  blocks: [
    PlanBlock(
      id: 'b1',
      name: 'main',
      type: BlockType.main,
      items: [
        PlanItem(
          exerciseId: 'a',
          mode: DoseMode.time,
          sets: 1,
          workSeconds: seconds,
          perSide: false,
          restSeconds: 0,
        ),
      ],
    ),
  ],
);

CoachSessionState _saved({bool focus = false}) {
  final plan = _plan(id: focus ? 'ext:my-plan' : 'p');
  return _state(output: true).copyWith(
    activePlanId: plan.id,
    focusPlanId: focus ? plan.id : null,
    savedRef: focus
        ? const CoachSavedPlanRef(externalId: 'my-plan', baseVersion: 1)
        : null,
    lastDeliveredPlanId: plan.id,
    lastDeliveredVersion: 1,
    lastDeliveredTurn: 1,
    plans: {
      plan.id: [
        CoachPlanVersion(
          version: 1,
          plan: plan.toJson(),
          estimateSec: 300,
          fitLog: const [],
          check: const {'ok': true},
        ),
      ],
    },
  );
}

PlanExecutionTiming _measurement(
  TrainingPlan plan,
  double seconds, {
  bool manual = false,
}) => PlanExecutionTiming(
  totalSeconds: seconds,
  blocks: [
    for (final (index, block) in plan.blocks.indexed)
      PlanBlockExecutionTiming(
        blockId: block.id,
        seconds: index == 0 ? seconds : 0,
      ),
  ],
  containsManualCounting: manual,
);

// A deliberately simple test oracle. Production must use the host's builder;
// the trainer fixture test independently covers the real 326/335-second phases.
PlanExecutionTimingCallback _native(
  Catalog catalog, {
  bool manual = false,
  double overhead = 9,
}) =>
    (plan) => _measurement(
      plan,
      const PlanDuration().estimateSeconds(plan, catalog) + overhead,
      manual: manual,
    );

PlanBuilder _builder({
  Catalog? catalog,
  PlanExecutionTimingCallback? executionTiming,
}) => PlanBuilder(
  _profile,
  catalog ?? _catalog,
  minPicks: 1,
  executionTiming: executionTiming,
);

AgentOutputResult _show(
  CoachSessionState state, {
  PlanExecutionTimingCallback? executionTiming,
}) =>
    ToolGate(
      catalog: _catalog,
      profile: _profile,
      executionTiming: executionTiming,
    ).checkAgentOutput(state, CoachTools.showPlan, {
      'plan_id': state.activePlanId,
      'note': '量力而行。',
    });

void _expectDualDuration(TrainingPlan plan, PlanExecutionTiming timing) {
  expect(
    const PlanDuration().estimateSeconds(plan, _catalog),
    inInclusiveRange(270, 330),
  );
  expect(timing.totalSeconds, inInclusiveRange(270, 330));
}

LlmToolCall _call(String id, String name, Map<String, Object?> args) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(args));

LlmResponse _calls(List<LlmToolCall> calls) => LlmResponse(
  content: '',
  toolCalls: calls,
  finishReason: 'tool_calls',
  model: 'fake',
);

void main() {
  test(
    'omitted callback and explicit null preserve legacy draft and receipt',
    () {
      final source = _state();
      final implicit = PlanBuilder(
        _profile,
        _catalog,
        minPicks: 1,
      ).draft(source, _arguments(), newPlanId: 'same-id');
      final explicit = _builder().draft(
        source,
        _arguments(),
        newPlanId: 'same-id',
      );
      expect(implicit.ok, isTrue, reason: '${implicit.error}');
      expect(implicit.toJson(), explicit.toJson());
      expect(implicit.state.toJson(), explicit.state.toJson());
      expect(implicit.toJson().containsKey('executionTiming'), isFalse);
      expect(implicit.executionTiming, isNull);
      expect(implicit.state.plans['same-id']!.single.estimateSec, 326);
    },
  );

  test(
    'draft repairs in-range card when executed duration exceeds upper limit',
    () {
      final source = _state();
      final before = source.toJson();
      final result = _builder(
        executionTiming: _native(_catalog),
      ).draft(source, _arguments(), newPlanId: 'repaired');
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.fitLog, isNotEmpty);
      final plan = const PlanCodec().decode(
        result.state.plans['repaired']!.single.plan,
      );
      _expectDualDuration(plan, result.executionTiming!);
      expect(result.executionTiming!.totalSeconds, lessThan(335));
      expect(result.toJson()['executionTiming'], isA<Map<String, Object?>>());
      expect(source.toJson(), before);
    },
  );

  test('refit repairs the native clock before appending one version', () {
    final source = _saved();
    final before = source.toJson();
    final result = _builder(
      executionTiming: _native(_catalog),
    ).refit(source, _plan());
    expect(result.ok, isTrue, reason: '${result.error}');
    expect(result.version, 2);
    expect(result.state.plans['p']!.map((version) => version.version), [1, 2]);
    _expectDualDuration(
      const PlanCodec().decode(result.state.plans['p']!.last.plan),
      result.executionTiming!,
    );
    expect(source.toJson(), before);
  });

  test(
    'focused edit repairs the native clock and preserves saved reference',
    () {
      final saved = _saved(focus: true);
      final source = saved.copyWith(
        task: saved.task!.copyWith(
          nodes: [
            for (final node in saved.task!.nodes) node.copyWith(status: 'done'),
          ],
        ),
      );
      final before = source.toJson();
      final result = _builder(
        executionTiming: _native(_catalog),
      ).draft(source, _arguments(), newPlanId: 'must-not-replace-focus');
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.planId, 'ext:my-plan');
      expect(result.version, 2);
      expect(result.state.plans['ext:my-plan'], hasLength(2));
      expect(result.state.focusPlanId, source.focusPlanId);
      expect(result.state.savedRef, source.savedRef);
      _expectDualDuration(
        const PlanCodec().decode(result.state.plans['ext:my-plan']!.last.plan),
        result.executionTiming!,
      );
      expect(source.toJson(), before);
    },
  );

  for (final focus in [false, true]) {
    test('restored check cannot bypass execution gate (focus=$focus)', () {
      final source = CoachSessionState.fromJson(
        (jsonDecode(jsonEncode(_saved(focus: focus).toJson())) as Map)
            .cast<String, Object?>(),
      );
      final before = source.toJson();
      var callbacks = 0;
      final result = _show(
        source,
        executionTiming: (plan) {
          callbacks++;
          return _native(_catalog)(plan);
        },
      );
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(callbacks, greaterThan(0));
      final admitted = result.card!.plan!;
      _expectDualDuration(admitted.plan, admitted.executionTiming!);
      expect(admitted.version, 2);
      expect(result.state.plans[source.activePlanId], hasLength(2));
      expect(source.toJson(), before);
      if (focus) expect(admitted.savedRef, source.savedRef);
    });
  }

  test('a valid native duration does not waive the card-duration gate', () {
    final shortCatalog = Catalog(
      version: 'short-card-valid-player',
      drills: [_drill('a', 240, range: const IntRange(240, 320))],
    );
    final result = _builder(
      catalog: shortCatalog,
      executionTiming: (plan) => _measurement(plan, 300),
    ).draft(_state(), _arguments(), newPlanId: 'dual-clock');
    expect(result.ok, isTrue, reason: '${result.error}');
    _expectDualDuration(
      const PlanCodec().decode(result.state.plans['dual-clock']!.single.plan),
      result.executionTiming!,
    );
    final cannotFit = _builder(
      executionTiming: (plan) => _measurement(
        plan,
        const PlanDuration().estimateSeconds(plan, _catalog) - 100,
      ),
    ).draft(_state(), _arguments(), newPlanId: 'must-not-save');
    expect(cannotFit.ok, isFalse);
    expect(cannotFit.error!['code'], 'duration_fit_failed');
    expect(cannotFit.state.plans, isEmpty);
  });

  test('manual work is labelled estimated and still obeys the hard gate', () {
    final repaired = _builder(
      executionTiming: _native(_catalog, manual: true),
    ).draft(_state(), _arguments(), newPlanId: 'manual');
    expect(repaired.ok, isTrue, reason: '${repaired.error}');
    expect(repaired.fitLog, isNotEmpty);
    final metadata = repaired.toJson()['executionTiming']! as Map;
    expect(metadata['containsManualCounting'], isTrue);
    expect(metadata['isEstimate'], isTrue);
    expect(metadata['label'], '估算');
    _expectDualDuration(
      const PlanCodec().decode(repaired.state.plans['manual']!.single.plan),
      repaired.executionTiming!,
    );
    final rejected = _builder(
      executionTiming: (plan) => _measurement(plan, 400, manual: true),
    ).draft(_state(), _arguments(), newPlanId: 'must-not-save');
    expect(rejected.ok, isFalse);
    expect(rejected.error!['code'], 'duration_fit_failed');
    expect(rejected.state.plans, isEmpty);
  });

  test('native lower bound drives removal, with both clocks on candidates', () {
    final catalog = Catalog(
      version: 'fixed-native-lower',
      drills: [_drill('a', 251), _drill('b', 50)],
    );
    final source = _state(picks: ['a', 'b']);
    final result = _builder(
      catalog: catalog,
      executionTiming: _native(catalog),
    ).draft(source, _arguments(['a', 'b']), newPlanId: 'must-not-save');
    expect(result.ok, isFalse);
    final error = result.error!;
    expect(error['code'], 'duration_fit_failed');
    expect(error['minEstimatedSec'], 335);
    expect(error['maxEstimatedSec'], 335);
    expect(error['minExecutedSec'], 335);
    expect(error['maxExecutedSec'], 335);
    expect(error['minCardSec'], 326);
    expect(error['maxCardSec'], 326);
    expect(error['direction'], 'remove_action');
    final removedB = (error['removeCandidates']! as List)
        .cast<Map<String, Object?>>()
        .singleWhere((candidate) => candidate['actionId'] == 'b');
    expect(removedB['minExecutedSec'], 270);
    expect(removedB['maxExecutedSec'], 270);
    expect(removedB['minCardSec'], 261);
    expect(removedB['rangeOverlapsTarget'], isFalse);
    expect(result.state.toJson(), source.toJson());
  });

  test('native upper bound drives addition and measures unseen candidates', () {
    final catalog = Catalog(
      version: 'fixed-native-upper',
      drills: [_drill('a', 100), _drill('b', 175)],
    );
    final result = _builder(
      catalog: catalog,
      executionTiming: _native(catalog),
    ).draft(_state(), _arguments(), newPlanId: 'must-not-save');
    expect(result.ok, isFalse);
    final error = result.error!;
    expect(error['code'], 'duration_fit_failed');
    expect(error['minEstimatedSec'], 119);
    expect(error['maxEstimatedSec'], 119);
    expect(error['direction'], 'add_action');
    final addedB = (error['addCandidates']! as List)
        .cast<Map<String, Object?>>()
        .singleWhere((candidate) => candidate['actionId'] == 'b');
    expect(addedB['minExecutedSec'], 309);
    expect(addedB['maxExecutedSec'], 309);
    expect(addedB['minCardSec'], 300);
    expect(addedB['maxCardSec'], 300);
    expect(addedB['rangeOverlapsTarget'], isTrue);
    expect(addedB['requiresSearch'], isTrue);
    expect(result.state.seenActionIds, {'a'});
    expect(result.state.plans, isEmpty);
  });

  final badCallbacks = <(String, PlanExecutionTimingCallback, String)>[
    (
      'Exception',
      (_) => throw Exception('private callback detail'),
      'execution_timing_callback_failed',
    ),
    (
      'Error',
      (_) => throw StateError('private callback detail'),
      'execution_timing_callback_failed',
    ),
    (
      'NaN',
      (plan) => _measurement(plan, double.nan),
      'invalid_execution_timing',
    ),
    (
      'infinity',
      (plan) => _measurement(plan, double.infinity),
      'invalid_execution_timing',
    ),
    (
      'negative duration',
      (plan) => _measurement(plan, -1),
      'invalid_execution_timing',
    ),
    (
      'wrong block',
      (_) => const PlanExecutionTiming(
        totalSeconds: 300,
        blocks: [
          PlanBlockExecutionTiming(blockId: 'not-in-plan', seconds: 300),
        ],
      ),
      'invalid_execution_timing',
    ),
  ];
  for (final (description, callback, expectedCode) in badCallbacks) {
    for (final path in ['draft', 'refit', 'focus', 'show_plan']) {
      test('$path rejects $description atomically instead of falling back', () {
        final saved = _saved(focus: path == 'focus');
        final source = path == 'draft'
            ? _state()
            : path == 'focus'
            ? saved.copyWith(
                task: saved.task!.copyWith(
                  nodes: [
                    for (final node in saved.task!.nodes)
                      node.copyWith(status: 'done'),
                  ],
                ),
              )
            : saved;
        final before = source.toJson();
        final builder = _builder(executionTiming: callback);
        final Map<String, Object?>? error;
        final CoachSessionState returnedState;
        if (path == 'show_plan') {
          final output = _show(source, executionTiming: callback);
          expect(output.ok, isFalse);
          expect(output.card, isNull);
          expect(output.changes, isEmpty);
          error = output.error;
          returnedState = output.state;
        } else {
          final result = path == 'refit'
              ? builder.refit(source, _plan())
              : builder.draft(source, _arguments(), newPlanId: 'must-not-save');
          expect(result.ok, isFalse);
          expect(result.planId, isNull);
          expect(result.version, isNull);
          error = result.error;
          returnedState = result.state;
        }
        expect(error!['code'], expectedCode);
        expect(jsonEncode(error), isNot(contains('private callback detail')));
        expect(returnedState.toJson(), before);
        expect(source.toJson(), before);
      });
    }
  }

  test(
    'structured draft handler forwards the callback and manual metadata',
    () {
      var callbacks = 0;
      final result = StructuredToolHandler(
        _profile,
        _catalog,
        newPlanId: () => 'structured',
        executionTiming: (plan) {
          callbacks++;
          return _native(_catalog, manual: true)(plan);
        },
      ).draft(_state(), jsonEncode(_arguments()), 'zh');
      final receipt = jsonDecode(result.response) as Map;
      expect(receipt['ok'], isTrue, reason: '$receipt');
      expect(callbacks, greaterThan(0));
      expect((receipt['executionTiming']! as Map)['label'], '估算');
      expect(result.state.plans['structured'], hasLength(1));
      _expectDualDuration(
        const PlanCodec().decode(result.state.plans['structured']!.single.plan),
        _native(_catalog)(
          const PlanCodec().decode(
            result.state.plans['structured']!.single.plan,
          ),
        ),
      );
    },
  );

  test(
    'Agent forwards callback to structured drafting and final output',
    () async {
      final client = FakeLlmClient([
        _calls([_call('draft', AgentTools.draftPlan, _arguments())]),
        (LlmRequest request) {
          final receipt =
              jsonDecode(
                    request.messages
                        .lastWhere((message) => message.toolCallId == 'draft')
                        .content,
                  )
                  as Map;
          expect(receipt['ok'], isTrue, reason: '$receipt');
          expect(receipt['executionTiming'], isA<Map<String, Object?>>());
          return _calls([
            _call('show', CoachTools.showPlan, {
              'plan_id': receipt['plan_id'],
              'note': '量力而行。',
            }),
          ]);
        },
      ], latency: Duration.zero);
      var callbacks = 0;
      final agent = CoachAgent(
        client: client,
        catalog: () => _catalog,
        profile: _profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
        executionTiming: (plan) {
          callbacks++;
          return _native(_catalog)(plan);
        },
      );
      addTearDown(agent.dispose);
      expect(
        agent.restoreSessionSnapshot(
          CoachSessionSnapshot(
            sessionState: _state(),
            ledger: ContextTurnLedger(const []),
          ),
        ),
        isTrue,
      );
      final result = await agent.send('按已确认条件生成');
      expect(
        result.status,
        TurnStatus.ok,
        reason: '${result.error}; ${result.issues}',
      );
      expect(result.plan, isNotNull);
      expect(callbacks, greaterThan(0));
      _expectDualDuration(result.plan!.plan, result.plan!.executionTiming!);
      expect(client.requests, hasLength(2));
    },
  );

  test(
    'export and restore require fresh execution validation before show_plan',
    () async {
      final exporter = CoachAgent(
        client: FakeLlmClient([]),
        catalog: () => _catalog,
        profile: _profile,
        enableUserMemory: false,
      );
      addTearDown(exporter.dispose);
      expect(
        exporter.restoreSessionSnapshot(
          CoachSessionSnapshot(
            sessionState: _saved(focus: true),
            ledger: ContextTurnLedger(const []),
          ),
        ),
        isTrue,
      );
      final snapshot = CoachSessionSnapshot.fromJson(
        jsonDecode(jsonEncode(exporter.exportSession().toJson())),
      );
      expect(snapshot.isValid, isTrue, reason: snapshot.invalidReason);
      final client = FakeLlmClient([
        _calls([
          _call('show-restored', CoachTools.showPlan, {
            'plan_id': 'ext:my-plan',
            'note': '量力而行。',
          }),
        ]),
      ], latency: Duration.zero);
      final restored = CoachAgent(
        client: client,
        catalog: () => _catalog,
        profile: _profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
        executionTiming: _native(_catalog),
      );
      addTearDown(restored.dispose);
      expect(restored.restoreSessionSnapshot(snapshot), isTrue);
      final result = await restored.send('展示已确认的计划');
      expect(
        result.status,
        TurnStatus.ok,
        reason: '${result.error}; ${result.issues}',
      );
      expect(result.plan, isNotNull);
      expect(result.plan!.version, 2);
      expect(result.plan!.savedRef, _saved(focus: true).savedRef);
      _expectDualDuration(result.plan!.plan, result.plan!.executionTiming!);
      expect(client.requests, hasLength(1));
    },
  );

  test('validated version refresh retains the fresh execution measurement', () {
    final output = _show(_saved(), executionTiming: _native(_catalog));
    expect(output.ok, isTrue, reason: '${output.error}');
    final admitted = output.card!.plan!;
    final refreshed = admitted.withSessionVersion(output.state);
    expect(refreshed.executionTiming, same(admitted.executionTiming));
    _expectDualDuration(refreshed.plan, refreshed.executionTiming!);
  });

  test(
    'delivery validates the normalized final metadata, not stale equipment',
    () {
      final stalePlan = const PlanCodec().decode({
        ..._plan(seconds: 290).toJson(),
        'equipment': ['stale-equipment'],
      });
      final source = _saved().copyWith(
        plans: {
          'p': [
            CoachPlanVersion(
              version: 1,
              plan: stalePlan.toJson(),
              estimateSec: 300,
              fitLog: const [],
              check: const {'ok': true},
            ),
          ],
        },
      );
      final before = source.toJson();
      final measuredEquipment = <List<String>>[];
      final output = _show(
        source,
        executionTiming: (candidate) {
          measuredEquipment.add(List.of(candidate.equipment));
          return _measurement(
            candidate,
            candidate.equipment.contains('stale-equipment') ? 300 : 400,
          );
        },
      );
      expect(output.ok, isFalse);
      expect(output.card, isNull);
      expect(output.error!['code'], 'duration_fit_failed');
      expect(measuredEquipment, contains(isEmpty));
      expect(output.state.toJson(), before);
      expect(source.toJson(), before);
    },
  );

  for (final path in ['draft_plan', 'show_plan']) {
    for (final (description, callback, expectedCode) in badCallbacks.take(3)) {
      test(
        'Agent stops $path $description failure before another request',
        () async {
          final source = path == 'draft_plan' ? _state() : _saved();
          final originalPlans = source.toJson()['plans'];
          final client = FakeLlmClient([
            _calls([
              _call(
                'bad-callback',
                path == 'draft_plan'
                    ? AgentTools.draftPlan
                    : CoachTools.showPlan,
                path == 'draft_plan'
                    ? _arguments()
                    : {'plan_id': 'p', 'note': '量力而行。'},
              ),
            ]),
            const LlmResponse(content: 'Unconsumed sentinel'),
          ], latency: Duration.zero);
          final agent = CoachAgent(
            client: client,
            catalog: () => _catalog,
            profile: _profile,
            enableUserMemory: false,
            maxRequestRetries: 0,
            executionTiming: callback,
          );
          addTearDown(agent.dispose);
          expect(
            agent.restoreSessionSnapshot(
              CoachSessionSnapshot(
                sessionState: source,
                ledger: ContextTurnLedger(const []),
              ),
            ),
            isTrue,
          );
          final result = await agent.send('按已确认条件继续');
          expect(result.status, TurnStatus.error);
          expect(result.plan, isNull);
          expect(result.actions, isNull);
          expect(result.question, isNull);
          expect(
            result.error,
            isA<PlanExecutionTimingException>().having(
              (error) => error.code,
              'code',
              expectedCode,
            ),
          );
          expect(
            result.issues.map((issue) => issue.code),
            contains(expectedCode),
          );
          expect(client.requests, hasLength(1));
          expect(client.remaining, 1);
          expect(agent.sessionState.toJson()['plans'], originalPlans);
          expect(agent.sessionState.activePlanId, source.activePlanId);
        },
      );
    }
  }
}
