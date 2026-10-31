import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

const _root = 'test/fixtures/hiplab/executed-duration';
const _ids = [
  'h-butterfly-active',
  'n-pelvis-circle',
  's-butterfly',
  'n-wide-fold',
  'h-adductor-rock',
  'h-wall-straddle',
];

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_root/$name').readAsStringSync()) as Map<String, dynamic>;

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

String _objectSha256(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();

double _seconds(Iterable<SessionPhase> phases) =>
    phases.fold(0, (sum, phase) => sum + phase.seconds);

CoachSessionState _ready(int minutes) {
  final before = CoachSessionState.fromJson(
    _json('state-before-reconstructed.json'),
  );
  return before.copyWith(
    params: {
      ...before.params,
      'minutes': CoachParamValue(
        value: minutes,
        source: 'user',
        quote: '$minutes 分钟',
        turn: 3,
      ),
    },
  );
}

Catalog _fixedDoses(TrainingPlan plan, Catalog original) {
  final raw = _json('catalog.json');
  for (final entry in (raw['drills'] as List).cast<Map<String, dynamic>>()) {
    final items = plan.items.where((item) => item.exerciseId == entry['id']);
    if (items.isEmpty) continue;
    final item = items.single;
    final ranges = original[item.exerciseId]!.doseRange;
    expect(ranges.sets!.contains(item.sets), isTrue);
    final amount = item.mode == DoseMode.reps ? item.reps! : item.workSeconds!;
    final workRange = item.mode == DoseMode.reps
        ? ranges.reps!
        : ranges.seconds!;
    expect(workRange.contains(amount), isTrue);
    expect(ranges.restSeconds!.contains(item.restSeconds), isTrue);
    final field = item.mode == DoseMode.reps ? 'reps' : 'seconds';
    entry['defaultDose'] = {
      'mode': item.mode.name,
      'sets': item.sets,
      field: amount,
      'restSeconds': item.restSeconds,
    };
    entry['doseRange'] = {
      'sets': [item.sets, item.sets],
      field: [amount, amount],
      'restSeconds': [item.restSeconds, item.restSeconds],
    };
  }
  return Catalog.fromJson(raw);
}

CoachProfile _fixedRounds(int rounds, int roundRest) => CoachProfile.fromJson({
  ..._json('profile.json'),
  'limits': {
    'rounds': [rounds, rounds],
    'restBetweenRoundsSeconds': [roundRest, roundRest],
  },
});

void _naturallyCompletes(TrainingPlan plan, SessionBuilder builder) {
  final phases = builder.phases(plan);
  expect(phases.where((phase) => phase.selfPaced), isEmpty);
  final total = _seconds(phases);
  final engine = SessionEngine(phases)..update(total + .001);
  expect(engine.done, isTrue);
  expect(engine.endedEarly, isFalse);
  expect(engine.fullyCompletedExercises, builder.occurrenceCount(plan));
  expect(
    engine.visits.fold(0.0, (sum, visit) => sum + visit.seconds),
    closeTo(total, 1e-6),
  );
}

void main() {
  final manifest = _json('manifest.json');
  final catalog = Catalog.fromJson(_json('catalog.json'));
  final profile = CoachProfile.fromJson(_json('profile.json'));
  final rawKits = {for (final id in _ids) id: _json('action_kits/$id.json')};
  final rhythms = {
    for (final entry in rawKits.entries)
      entry.key: Rhythm.fromActionKitJson(entry.value),
  };
  final script = SessionScript(
    lang: 'zh',
    source: ManifestVoiceSource.fromJson(
      _json('voice-manifest.json'),
      kitVoices: {
        for (final entry in rawKits.entries)
          entry.key: KitVoice.fromActionKitJson(entry.value),
      },
    ),
  );
  final sessionBuilder = SessionBuilder(
    rhythms: rhythms,
    prepSeconds: 15,
    switchSecondsFor: script.switchSecondsFor,
  );
  final captured = const PlanCodec().decode(_json('captured-plan.json'));

  test(
    'original HipLab draft repairs326/335 using the real player callback',
    () {
      final state = _ready(5);
      final before = state.toJson();
      final legacy = PlanBuilder(profile, catalog, minPicks: profile.minActions)
          .draft(
            state,
            _json('draft-arguments.json'),
            newPlanId: 'legacy-regression',
          );
      expect(legacy.ok, isTrue);
      final old = const PlanCodec().decode(
        legacy.state.plans[legacy.planId]!.last.plan,
      );
      expect(old.toJson(), captured.toJson());
      expect(const PlanDuration().estimateSeconds(old, catalog), 326);
      expect(sessionBuilder.executionTiming(old).totalSeconds, 335);

      final result =
          PlanBuilder(
            profile,
            catalog,
            minPicks: profile.minActions,
            executionTiming: sessionBuilder.executionTiming,
          ).draft(
            state,
            _json('draft-arguments.json'),
            newPlanId: 'fixed-regression',
          );
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.feasibility, isNull);
      final version = result.state.plans[result.planId]!.last;
      final plan = const PlanCodec().decode(version.plan);
      final card = const PlanDuration().estimateSeconds(plan, catalog);
      final execution = sessionBuilder.executionTiming(plan);
      expect(result.executionTiming!.totalSeconds, execution.totalSeconds);
      expect(
        (result.toJson()['executionTiming'] as Map)['isEstimate'],
        isFalse,
      );
      printOnFailure(
        jsonEncode({
          'card': card,
          'executed': execution.totalSeconds,
          'fitLog': result.fitLog,
        }),
      );
      expect(card, inInclusiveRange(270, 330));
      expect(execution.totalSeconds, inInclusiveRange(270, 330));
      expect(execution.containsManualCounting, isFalse);
      expect(plan.toJson(), isNot(captured.toJson()));
      expect(result.fitLog, isNotEmpty);
      expect(version.version, 2);
      expect(version.operation, 'replace_all');
      expect([for (final item in plan.items) item.exerciseId], _ids);
      expect(
        result.state.plans[result.planId]!.first.toJson(),
        state.plans[state.activePlanId]!.first.toJson(),
      );
      expect(state.toJson(), before);
      _naturallyCompletes(plan, sessionBuilder);
    },
  );

  for (final minutes in [5, 10, 20]) {
    test(
      'real HipLab$minutes minute matrix fits both card and full timeline',
      () {
        final state = _ready(minutes);
        final result =
            PlanBuilder(
              profile,
              catalog,
              minPicks: profile.minActions,
              executionTiming: sessionBuilder.executionTiming,
            ).draft(
              state,
              _json('draft-arguments.json'),
              newPlanId: 'matrix-$minutes',
            );
        expect(result.ok, isTrue, reason: '${result.error}');
        expect(result.feasibility, isNull);
        final plan = const PlanCodec().decode(
          result.state.plans[result.planId]!.last.plan,
        );
        final card = const PlanDuration().estimateSeconds(plan, catalog);
        final timing = evaluatePlanExecutionTiming(
          plan,
          sessionBuilder.executionTiming,
        );
        final target = minutes * 60;
        printOnFailure(
          jsonEncode({
            'target': target,
            'card': card,
            'executed': timing.totalSeconds,
            'fitLog': result.fitLog,
          }),
        );
        expect(card, inInclusiveRange(target * .9, target * 1.1));
        expect(
          timing.totalSeconds,
          inInclusiveRange(target * .9, target * 1.1),
        );
        expect(timing.containsManualCounting, isFalse);
        expect(timing.totalSeconds, _seconds(sessionBuilder.phases(plan)));
        _naturallyCompletes(plan, sessionBuilder);
      },
    );
  }

  test('a frozen326/335 dose rejects delivery with remove-action bounds', () {
    final state = _ready(5);
    final before = state.toJson();
    final result =
        PlanBuilder(
          _fixedRounds(1, 0),
          _fixedDoses(captured, catalog),
          minPicks: profile.minActions,
          executionTiming: sessionBuilder.executionTiming,
        ).draft(
          state,
          _json('draft-arguments.json'),
          newPlanId: 'frozen-regression',
        );
    expect(result.ok, isFalse);
    expect(result.planId, isNull);
    expect(result.version, isNull);
    expect(result.feasibility, isNull);
    expect(result.error!['code'], 'duration_fit_failed');
    expect(result.error!['direction'], 'remove_action');
    expect(result.error!['minExecutedSec'], 335);
    expect(result.error!['maxExecutedSec'], 335);
    expect(result.error!['minCardSec'], 326);
    expect(result.error!['maxCardSec'], 326);
    expect(result.error!['needsDraftRebuild'], isTrue);
    expect(result.error!['clarificationAllowed'], isFalse);
    expect(result.state, same(state));
    expect(state.toJson(), before);
  });

  // Original kit rhythms and doses narrowed within their original catalog
  // ranges make each boundary immutable. All actions occupy one main block;
  // longer cases also exercise actual main-round repeats and round gaps.
  for (final edge in [
    (
      minutes: 5,
      edge: 'card-lower',
      rounds: 1,
      roundRest: 0,
      butterfly: 24,
      fold: 20,
      wall: 40,
      card: 270,
      executed: 279,
      accept: true,
    ),
    (
      minutes: 5,
      edge: 'card-lower-minus1',
      rounds: 1,
      roundRest: 0,
      butterfly: 23,
      fold: 20,
      wall: 40,
      card: 269,
      executed: 278,
      accept: false,
    ),
    (
      minutes: 5,
      edge: 'execution-upper',
      rounds: 1,
      roundRest: 0,
      butterfly: 40,
      fold: 40,
      wall: 55,
      card: 321,
      executed: 330,
      accept: true,
    ),
    (
      minutes: 5,
      edge: 'execution-upper-plus1',
      rounds: 1,
      roundRest: 0,
      butterfly: 40,
      fold: 40,
      wall: 56,
      card: 322,
      executed: 331,
      accept: false,
    ),
    (
      minutes: 10,
      edge: 'card-lower',
      rounds: 2,
      roundRest: 16,
      butterfly: 21,
      fold: 20,
      wall: 40,
      card: 540,
      executed: 553,
      accept: true,
    ),
    (
      minutes: 10,
      edge: 'card-lower-minus1',
      rounds: 2,
      roundRest: 15,
      butterfly: 21,
      fold: 20,
      wall: 40,
      card: 539,
      executed: 552,
      accept: false,
    ),
    (
      minutes: 10,
      edge: 'execution-upper',
      rounds: 2,
      roundRest: 15,
      butterfly: 40,
      fold: 40,
      wall: 55,
      card: 647,
      executed: 660,
      accept: true,
    ),
    (
      minutes: 10,
      edge: 'execution-upper-plus1',
      rounds: 2,
      roundRest: 16,
      butterfly: 40,
      fold: 40,
      wall: 55,
      card: 648,
      executed: 661,
      accept: false,
    ),
    (
      minutes: 20,
      edge: 'card-lower',
      rounds: 3,
      roundRest: 16,
      butterfly: 50,
      fold: 50,
      wall: 70,
      card: 1080,
      executed: 1097,
      accept: true,
    ),
    (
      minutes: 20,
      edge: 'card-lower-minus1',
      rounds: 3,
      roundRest: 17,
      butterfly: 49,
      fold: 50,
      wall: 70,
      card: 1079,
      executed: 1096,
      accept: false,
    ),
    (
      minutes: 20,
      edge: 'execution-upper',
      rounds: 3,
      roundRest: 15,
      butterfly: 70,
      fold: 65,
      wall: 110,
      card: 1303,
      executed: 1320,
      accept: true,
    ),
    (
      minutes: 20,
      edge: 'execution-upper-plus1',
      rounds: 3,
      roundRest: 17,
      butterfly: 70,
      fold: 65,
      wall: 109,
      card: 1304,
      executed: 1321,
      accept: false,
    ),
  ]) {
    test('real timeline${edge.minutes}min ${edge.edge} dual-clock gate', () {
      final plan = captured.copyWith(
        targetMinutes: edge.minutes,
        blocks: [
          PlanBlock(
            id: 'b1',
            name: '主训练',
            type: BlockType.main,
            rounds: edge.rounds,
            restBetweenRoundsSeconds: edge.roundRest,
            items: [
              for (final item in captured.items)
                switch (item.exerciseId) {
                  's-butterfly' => item.copyWith(workSeconds: edge.butterfly),
                  'n-wide-fold' => item.copyWith(workSeconds: edge.fold),
                  'h-wall-straddle' => item.copyWith(workSeconds: edge.wall),
                  _ => item,
                },
            ],
          ),
        ],
      );
      expect(const PlanDuration().estimateSeconds(plan, catalog), edge.card);
      final timing = evaluatePlanExecutionTiming(
        plan,
        sessionBuilder.executionTiming,
      );
      expect(timing.totalSeconds, edge.executed);
      expect(timing.containsManualCounting, isFalse);
      _naturallyCompletes(plan, sessionBuilder);

      final ready = _ready(edge.minutes);
      final state = ready.copyWith(
        params: {...ready.params}..remove('operation'),
        plans: {},
        clearActivePlanId: true,
        clearLastDelivered: true,
        clearCompletedContextLedger: true,
      );
      final before = state.toJson();
      final result =
          PlanBuilder(
            _fixedRounds(edge.rounds, edge.roundRest),
            _fixedDoses(plan, catalog),
            minPicks: profile.minActions,
            executionTiming: sessionBuilder.executionTiming,
          ).draft(state, {
            'title': 'HipLab duration boundary',
            'blocks': [
              {
                'kind': 'main',
                'items': [
                  for (final id in _ids) {'id': id},
                ],
              },
            ],
          }, newPlanId: 'boundary-${edge.minutes}-${edge.edge}');
      printOnFailure('${edge.minutes} ${edge.edge}: ${result.toJson()}');
      expect(result.feasibility, isNull);
      expect(result.ok, edge.accept);
      if (edge.accept) {
        final admitted = const PlanCodec().decode(
          result.state.plans[result.planId]!.last.plan,
        );
        expect(
          const PlanDuration().estimateSeconds(admitted, catalog),
          edge.card,
        );
        expect(
          sessionBuilder.executionTiming(admitted).totalSeconds,
          edge.executed,
        );
        expect(result.toJson()['withinTolerance'], isTrue);
      } else {
        expect(result.planId, isNull);
        expect(result.error!['code'], 'duration_fit_failed');
        expect(
          result.error!['direction'],
          edge.edge.startsWith('card-') ? 'add_action' : 'remove_action',
        );
        expect(result.error!['needsDraftRebuild'], isTrue);
        expect(result.error!['clarificationAllowed'], isFalse);
        expect(result.state, same(state));
      }
      expect(state.toJson(), before);
    });
  }

  test('HipLab +26 trial03 immutable captured inputs retain source hashes', () {
    expect(
      manifest['baselineSdkCommit'],
      '700d0100f1cb42ef122e774a6ee0076d1916b5e5',
    );
    expect(
      (manifest['sourceCapture'] as Map)['sha256'],
      'caef5fcfe676a6bf374f83106b54db351376cbaee9313ab9362551661c9924b7',
    );
    expect(catalog.problems, isEmpty);
    expect(catalog.length, 21);
    expect(
      _objectSha256(_json('captured-plan.json')),
      manifest['capturedPlanCanonicalSha256'],
    );
    for (final entry in (manifest['files'] as Map).entries) {
      expect(
        sha256
            .convert(File('$_root/${entry.key}').readAsBytesSync())
            .toString(),
        (entry.value as Map)['sha256'],
        reason: 'Immutable fixture changed: ${entry.key}',
      );
    }
    final receipt = _json('captured-draft-receipt.json')['receipt'] as Map;
    expect(receipt['ok'], isTrue);
    expect(receipt['withinTolerance'], isTrue);
    expect(receipt['version'], 2);
    final versions =
        (_json('captured-state.json')['plans'] as Map)[captured.id] as List;
    expect((versions.last as Map)['fitLog'], isEmpty);
    expect((versions.last as Map)['estimateSec'], 326);
  });

  test(
    'captured326s card naturally executes all335s with original HipLab kits',
    () {
      expect(captured.toJson(), _json('captured-plan.json'));
      expect(const PlanDuration().estimateSeconds(captured, catalog), 326);
      final phases = sessionBuilder.phases(captured);
      // Report's independently reconstructed phase table is verified against
      // the SDK's real builder, authored action kits and Chinese voice source.
      expect(
        [
          for (final phase in phases)
            (phase.kind, phase.exerciseId, phase.side, phase.seconds),
        ],
        [
          (PhaseKind.prep, 'h-butterfly-active', null, 15.0),
          (PhaseKind.work, 'h-butterfly-active', null, 25.0),
          (PhaseKind.rest, 'n-pelvis-circle', null, 15.0),
          (PhaseKind.work, 'n-pelvis-circle', null, 33.0),
          (PhaseKind.rest, 's-butterfly', null, 15.0),
          (PhaseKind.work, 's-butterfly', null, 40.0),
          (PhaseKind.rest, 'n-wide-fold', null, 15.0),
          (PhaseKind.work, 'n-wide-fold', null, 40.0),
          (PhaseKind.rest, 'h-adductor-rock', null, 15.0),
          (PhaseKind.work, 'h-adductor-rock', Side.right, 21.0),
          (PhaseKind.switchSide, 'h-adductor-rock', Side.left, 5.0),
          (PhaseKind.work, 'h-adductor-rock', Side.left, 21.0),
          (PhaseKind.rest, 'h-wall-straddle', null, 15.0),
          (PhaseKind.work, 'h-wall-straddle', null, 60.0),
          (PhaseKind.done, null, null, 0.0),
        ],
      );
      expect(phases.where((phase) => phase.selfPaced), isEmpty);
      expect(_seconds(phases), 335);
      expect(_seconds(phases.where((phase) => phase.isWork)), 240);
      expect(phases.where((phase) => phase.isWork), hasLength(7));
      expect(sessionBuilder.occurrenceCount(captured), 6);
      final engine = SessionEngine(phases)..update(335.001);
      expect(engine.done, isTrue);
      expect(engine.endedEarly, isFalse);
      expect(engine.fullyCompletedExercises, 6);
      expect(
        engine.visits.fold(0.0, (sum, visit) => sum + visit.seconds),
        closeTo(335, 1e-6),
      );
      final measured = _json('captured-native-timing.json');
      expect(measured['isEstimate'], isFalse);
      expect(measured['manualCountingPhases'], isEmpty);
      expect(measured['engineNaturallyCompleted'], isTrue);
      expect(measured['fullyCompletedOccurrences'], 6);
      expect(measured['nativeEngineVisitSeconds'], 335);
      expect(measured['nativeWithinTolerance'], isFalse);
    },
  );

  test('335s includes prep5s and four real authored lead seconds', () {
    final phases = sessionBuilder.phases(captured);
    expect(phases.first.seconds - const PlanDuration().prepSeconds, 5);
    final plain = SessionBuilder(rhythms: rhythms, prepSeconds: 15);
    expect(_seconds(phases) - _seconds(plain.phases(captured)), 0);
    // Derive the comparison from each side's actual SessionBuilder phase;
    // the test never replaces authored lead values or supplies a calculator.
    for (final (id, workSeconds, expectedLead) in [
      ('h-butterfly-active', 24, 1),
      ('n-pelvis-circle', 32, 1),
      ('h-adductor-rock', 40, 2),
    ]) {
      expect(
        _seconds(
              phases.where((phase) => phase.isWork && phase.exerciseId == id),
            ) -
            workSeconds,
        expectedLead,
      );
    }
    expect(_seconds(phases) - 326, 9);
  });

  test(
    'explicit manual counting remains an estimate and cannot auto-complete',
    () {
      final manualBuilder = SessionBuilder(
        rhythms: {...rhythms, _ids.first: Rhythm.selfPacedReps},
        prepSeconds: 15,
        switchSecondsFor: script.switchSecondsFor,
      );
      final phases = manualBuilder.phases(captured);
      final manual = phases.where((phase) => phase.selfPaced).toList();
      expect(manual, hasLength(1));
      expect(manual.single.exerciseId, _ids.first);
      expect(manual.single.kind, PhaseKind.work);
      expect(manual.single.seconds, greaterThan(0));
      final timing = evaluatePlanExecutionTiming(
        captured,
        manualBuilder.executionTiming,
      );
      expect(timing.containsManualCounting, isTrue);
      expect(timing.totalSeconds, _seconds(phases));
      final result =
          PlanBuilder(
            profile,
            catalog,
            minPicks: profile.minActions,
            executionTiming: manualBuilder.executionTiming,
          ).draft(
            _ready(5),
            _json('draft-arguments.json'),
            newPlanId: 'manual-estimate',
          );
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.executionTiming!.containsManualCounting, isTrue);
      final json = result.toJson()['executionTiming'] as Map;
      expect(json['containsManualCounting'], isTrue);
      expect(json['isEstimate'], isTrue);
      expect(json['label'], '估算');
      final admitted = const PlanCodec().decode(
        result.state.plans[result.planId]!.last.plan,
      );
      expect(
        const PlanDuration().estimateSeconds(admitted, catalog),
        inInclusiveRange(270, 330),
      );
      expect(
        manualBuilder.executionTiming(admitted).totalSeconds,
        inInclusiveRange(270, 330),
      );
      final engine = SessionEngine(phases)..update(_seconds(phases) + 1);
      expect(engine.done, isFalse);
      expect(engine.phase.selfPaced, isTrue);
      expect(engine.fullyCompletedExercises, 0);
    },
  );

  test(
    'manual estimates still enforce full execution bounds without exemption',
    () {
      final manualBuilder = SessionBuilder(
        rhythms: {...rhythms, _ids.first: Rhythm.selfPacedReps},
        prepSeconds: 20,
        switchSecondsFor: script.switchSecondsFor,
      );
      final timing = manualBuilder.executionTiming(captured);
      expect(timing.containsManualCounting, isTrue);
      expect(timing.totalSeconds, greaterThan(330));
      final state = _ready(5);
      final result =
          PlanBuilder(
            _fixedRounds(1, 0),
            _fixedDoses(captured, catalog),
            minPicks: profile.minActions,
            executionTiming: manualBuilder.executionTiming,
          ).draft(
            state,
            _json('draft-arguments.json'),
            newPlanId: 'manual-too-long',
          );
      expect(result.ok, isFalse);
      expect(result.planId, isNull);
      expect(result.error!['code'], 'duration_fit_failed');
      expect(result.error!['direction'], 'remove_action');
      expect(result.error!['minExecutedSec'], timing.totalSeconds);
      expect(result.error!['maxExecutedSec'], timing.totalSeconds);
      final minimum = result.error!['minimumExecutionTiming'] as Map;
      expect(minimum['containsManualCounting'], isTrue);
      expect(minimum['isEstimate'], isTrue);
      expect(minimum['label'], '估算');
      expect(result.state, same(state));
    },
  );
}
