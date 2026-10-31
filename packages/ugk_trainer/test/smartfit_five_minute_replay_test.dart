// The SDK-accepted real SmartFit five-minute v3, without changing any dose or
// cadence to make its card agree with execution. This single-round plan also
// exposes a separate historical host/catalog cadence difference.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

const _root = 'test/fixtures/smartfit/five-minute';

Map<String, dynamic> _json(String path) =>
    jsonDecode(File('$_root/$path').readAsStringSync()) as Map<String, dynamic>;

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

void main() {
  final manifest = _json('manifest.json');
  final raw = _json('plan-v3.json');
  final decoded = const PlanCodec().decodeStrict(raw);
  if (!decoded.ok) throw StateError('Captured SmartFit v3 is invalid.');
  final plan = decoded.plan!;
  final catalog = Catalog.fromJson(_json('catalog.json'));
  // Reproduce the actual AppTestContent._executionRhythm overrides. The outer
  // pack rhythm is rendered-media metadata, not an execution rhythm itself.
  final rhythms = rhythmsFromCatalog(
    catalog,
    overrides: {
      for (final drill in catalog.drills)
        drill.id: Rhythm.fromJson(
          Map<String, dynamic>.from(
            (drill.raw['rhythm'] as Map)['execution'] as Map,
          ),
        ),
    },
  );
  final builder = SessionBuilder(rhythms: rhythms);

  test(
    'SmartFit v3 and six actual projected drills retain source identity',
    () {
      expect(
        manifest['sourceSdkCommit'],
        'b490eec43b408a8a35ce81a7830833bc6a3ff278',
      );
      expect(
        (manifest['sourceCapture'] as Map)['sha256'],
        '8c4e11b02d266e94210ac78bee9f8e47fe85b70058704691be7644e39dbb9ef2',
      );
      final files = manifest['files'] as Map;
      for (final entry in files.entries) {
        expect(
          sha256
              .convert(File('$_root/${entry.key}').readAsBytesSync())
              .toString(),
          (entry.value as Map)['sha256'],
          reason: 'Source fixture changed: ${entry.key}',
        );
      }
      expect(
        _objectSha256(raw),
        (manifest['plan'] as Map)['sourcePlanCanonicalSha256'],
      );
      expect(plan.toJson(), raw);
      expect(catalog.problems, isEmpty);
      expect(catalog.length, 6);
      expect(
        catalog.ids,
        unorderedEquals(plan.items.map((item) => item.exerciseId)),
      );
      for (final value in catalog.raw['drills'] as List) {
        final drill = Map<String, dynamic>.from(value as Map);
        final provenance = (manifest['drills'] as Map)[drill['id']] as Map;
        expect(
          _objectSha256(drill),
          provenance['sourceProjectedDrillCanonicalSha256'],
        );
        // SDK _definition adds only the name projection to these raw actions.
        expect(drill.remove('name'), {'zh': drill['nameZh']});
        expect(_objectSha256(drill), provenance['sourceActionCanonicalSha256']);
        expect((drill['defaultDose'] as Map)['holdSeconds'], isNull);
      }
    },
  );

  test('the accepted single-round five-minute card remains exactly 313s', () {
    expect(plan.targetMinutes, 5);
    expect(plan.blocks, hasLength(1));
    expect(plan.blocks.single.type, BlockType.main);
    expect(plan.blocks.single.rounds, 1);
    expect(plan.items.map((item) => item.exerciseId), [
      'h-squat',
      'h-wall-angel',
      'w-dead-bug',
      'h-reverse-crunch',
      's-butterfly',
      's-kneel-hipflex',
    ]);
    expect((manifest['plan'] as Map)['capturedCardEstimateSeconds'], 313);
    expect(const PlanDuration().estimateSeconds(plan, catalog), 313);
    expect(
      builder.phases(plan).where((phase) => phase.kind == PhaseKind.roundRest),
      isEmpty,
    );
    expect(plan.toJson(), raw);
  });

  test(
    'actual SmartFit cadence yields body335 + prep10 = total345, not313',
    () {
      const duration = PlanDuration();
      final phases = builder.phases(plan);
      final card = duration.estimateSeconds(plan, catalog);
      final total = _seconds(phases);
      final cadenceDifferences = <String, double>{};
      for (final item in plan.items.where(
        (item) => item.mode == DoseMode.reps,
      )) {
        final drill = catalog[item.exerciseId]!;
        // These original projected drills have no video cadence. Coach uses 3s;
        // the host separately supplies their authored execution rhythms.
        expect(drill.assets.videos, isEmpty);
        expect(duration.repSeconds(drill), 3);
        expect(item.sets, 1);
        expect(item.perSide, isFalse);
        final actual = _seconds(
          phases.where(
            (phase) => phase.isWork && phase.exerciseId == item.exerciseId,
          ),
        );
        final difference = actual - item.reps! * duration.repSeconds(drill);
        if (difference != 0) cadenceDifferences[item.exerciseId] = difference;
      }
      printOnFailure(
        jsonEncode({
          'capturedCardSeconds': 313,
          'currentCardSeconds': card,
          'nativePlanSeconds': builder.planSeconds(plan),
          'nativePrepSeconds': builder.prepSeconds,
          'nativeTotalSeconds': total,
          'cadenceDifferencesSeconds': cadenceDifferences,
        }),
      );
      expect(cadenceDifferences, {
        'h-squat': 10.0,
        'h-wall-angel': 10.0,
        'h-reverse-crunch': 12.0,
      });
      expect(rhythms['h-squat']!.cycleFor(), 4);
      expect(rhythms['h-squat']!.lead, 1);
      expect(rhythms['h-wall-angel']!.cycleFor(), 4);
      expect(rhythms['h-reverse-crunch']!.cycleFor(), 4);
      expect(rhythms['w-dead-bug']!.cycleFor(), 3);
      expect(builder.prepSeconds, 10);
      expect(builder.planSeconds(plan), 335);
      expect(total, 345);
      expect(
        total - card,
        cadenceDifferences.values.fold(0.0, (sum, value) => sum + value),
      );
      expect(_seconds(phases.where((phase) => phase.isWork)), 255);
      expect(
        _seconds(phases.where((phase) => phase.kind == PhaseKind.switchSide)),
        5,
      );
      expect(
        _seconds(phases.where((phase) => phase.kind == PhaseKind.rest)),
        75,
      );
      expect(plan.toJson(), raw);
    },
  );

  test(
    'the unchanged six occurrences execute fully and retain result sets',
    () {
      final phases = builder.phases(plan);
      final engine = SessionEngine(phases);
      final lastWork = <int, SessionPhase>{};
      for (final phase in phases.where((phase) => phase.isWork)) {
        expect(phase.selfPaced, isFalse);
        expect((phase.round, phase.rounds), (0, 0));
        expect(phase.sets, 1);
        lastWork[phase.itemIndex] = phase;
      }
      expect(builder.occurrenceCount(plan), 6);
      expect(lastWork.keys, orderedEquals([0, 1, 2, 3, 4, 5]));
      var elapsed = 0.0;
      var completed = 0;
      for (final phase in phases.where(
        (phase) => phase.kind != PhaseKind.done,
      )) {
        elapsed += phase.seconds;
        engine.update(elapsed);
        if (!identical(lastWork[phase.itemIndex], phase)) continue;
        completed++;
        expect(engine.fullyCompletedExercises, completed);
        expect(engine.completedExercises, completed);
      }
      expect(engine.done, isTrue);
      expect(engine.endedEarly, isFalse);
      expect(elapsed, 345);
      final result = SessionRecorder(
        plan: plan,
        totalExercises: 6,
        sessionId: 'smartfit-captured-five-minute-v3',
      ).finish(engine, activeSeconds: elapsed);
      expect(result.full, isTrue);
      expect(result.completedExercises, 6);
      expect(result.items, hasLength(6));
      expect(
        result.items.map((item) => (item.plannedSets, item.completedSets)),
        everyElement((1, 1)),
      );
      expect(
        result.items.map((item) => item.status),
        everyElement(ItemStatus.completed),
      );
      final bilateral = result.items.singleWhere(
        (item) => item.exerciseId == 's-kneel-hipflex',
      );
      expect(bilateral.plannedSideSets, {'right': 1, 'left': 1});
      expect(bilateral.completedSideSets, {'right': 1, 'left': 1});
      expect(plan.toJson(), raw);
    },
  );
}
