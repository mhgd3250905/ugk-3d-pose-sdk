// Real HipLab outputs captured at SDK 66dd98a. Fixture provenance records the
// original Coach cards (629/315s) and broken native schedules (446/197s).
// Keep the original plans, catalog drills and action kits unchanged.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

const _root = 'test/fixtures/hiplab/main-rounds';

Map<String, dynamic> _json(String path) =>
    jsonDecode(File('$_root/$path').readAsStringSync()) as Map<String, dynamic>;

// Match the source-object digest recorded during fixture extraction. This is
// independent of indentation and verifies every original plan field and dose.
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

TrainingPlan _plan(Map<String, dynamic> record) {
  // TrainingPlan exposes PlanCodec rather than a fromJson constructor.
  final decoded = const PlanCodec().decodeStrict(
    _json(record['file'] as String),
  );
  if (!decoded.ok) throw StateError('Captured HipLab plan is invalid.');
  return decoded.plan!;
}

double _seconds(Iterable<SessionPhase> phases) =>
    phases.fold(0, (sum, phase) => sum + phase.seconds);

void main() {
  final manifest = _json('manifest.json');
  final records = [
    for (final record in manifest['cases'] as List)
      Map<String, dynamic>.from(record as Map),
  ];
  final catalog = Catalog.fromJson(_json('catalog.json'));
  final ids = (manifest['exerciseIds'] as List).cast<String>();
  final rhythms = {
    for (final id in ids)
      id: Rhythm.fromActionKitJson(_json('action_kits/$id.json')),
  };

  test(
    'real HipLab fixtures retain exact source plans, drills and raw kits',
    () {
      expect(
        manifest['sourceSdkCommit'],
        '66dd98a549c1ff5fedecb626a7c88583090a1440',
      );
      expect(records.map((record) => record['sourceCaseIndex']), [0, 2]);
      expect(records.map((record) => record['cardEstimateSeconds']), [
        629,
        315,
      ]);
      expect(records.map((record) => record['historicalNativePlanSeconds']), [
        446,
        197,
      ]);
      expect(catalog.problems, isEmpty);
      expect(catalog.ids, unorderedEquals(ids));
      expect(catalog.length, 11);
      expect(rhythms.keys, unorderedEquals(ids));
      expect(
        rhythms.values.map((rhythm) => rhythm.source),
        everyElement(RhythmSource.actionKit),
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
      for (final record in records) {
        final raw = _json(record['file'] as String);
        expect(_objectSha256(raw), record['sourcePlanCanonicalSha256']);
        expect(_plan(record).toJson(), raw);
      }
    },
  );

  for (final record in records) {
    final name = record['file'] as String;
    final plan = _plan(record);
    // Ordinary reps in these original kits include one second of lead per
    // performed side. The Coach catalog's repSeconds records the cycle only.
    final expectedKitLead = record['sourceCaseIndex'] == 0 ? 5.0 : 2.0;

    for (final prep in [10, 15]) {
      test('$name: current card and executed clock, prep=$prep', () {
        final raw = _json(name);
        final card = const PlanDuration().estimateSeconds(plan, catalog);
        final builder = SessionBuilder(rhythms: rhythms, prepSeconds: prep);
        final phases = builder.phases(plan);
        final total = _seconds(phases);
        final lead = phases
            .where((phase) => phase.countedOnClock)
            .fold(0.0, (sum, phase) => sum + phase.rhythm!.lead);
        final byKind = {
          for (final kind in PhaseKind.values)
            kind.name: _seconds(phases.where((phase) => phase.kind == kind)),
        };
        printOnFailure(
          jsonEncode({
            'fixture': name,
            'capturedCardSeconds': record['cardEstimateSeconds'],
            'currentCardSeconds': card,
            'historicalNativePlanSeconds':
                record['historicalNativePlanSeconds'],
            'prepSeconds': prep,
            'currentNativePlanSeconds': builder.planSeconds(plan),
            'currentNativeTotalSeconds': total,
            'kitLeadSeconds': lead,
            'phaseSeconds': byKind,
          }),
        );

        expect(phases.first.kind, PhaseKind.prep);
        expect(phases.first.seconds, prep);
        expect(lead, expectedKitLead);
        expect(builder.planSeconds(plan) + prep, total);
        expect(
          total,
          closeTo(card + expectedKitLead + prep - 10, 1e-6),
          reason:
              'Same round/transition contract, plus actual kit leads and '
              'the host prep difference from Coach default 10 seconds.',
        );
        expect(plan.toJson(), raw);
      });
    }

    test('$name: every real main round advances progress and result sets', () {
      final original = plan.toJson();
      final builder = SessionBuilder(rhythms: rhythms, prepSeconds: 15);
      final phases = builder.phases(plan);
      final work = phases.where((phase) => phase.isWork).toList();
      final expectedOccurrences = record['expectedOccurrences'] as int;
      final occurrenceKeys = <(String, int, int, int, int)>[
        for (final (blockIndex, block) in plan.blocks.indexed)
          for (var round = 1; round <= block.rounds; round++)
            for (final (itemIndex, item) in block.items.indexed)
              (
                item.exerciseId,
                blockIndex,
                itemIndex,
                block.rounds > 1 ? round : 0,
                block.rounds > 1 ? block.rounds : 0,
              ),
      ];
      expect(builder.occurrenceCount(plan), expectedOccurrences);
      expect(occurrenceKeys.length, expectedOccurrences);

      final lastWork = <int, SessionPhase>{};
      for (final phase in work) {
        expect(phase.selfPaced, isFalse);
        final expected = occurrenceKeys[phase.itemIndex];
        expect((
          phase.exerciseId,
          phase.blockIndex,
          phase.itemInBlock,
          phase.round,
          phase.rounds,
        ), expected);
        expect(phase.set, 1);
        expect(phase.sets, 1);
        lastWork[phase.itemIndex] = phase;
      }
      expect(
        lastWork.keys,
        orderedEquals(List.generate(expectedOccurrences, (index) => index)),
      );

      final engine = SessionEngine(phases);
      final recorder = SessionRecorder(
        plan: plan,
        totalExercises: expectedOccurrences,
        sessionId: 'hiplab-real-main-rounds-${record['planVersion']}',
      );
      var elapsed = 0.0;
      var completed = 0;
      var checkedFirstMainRound = false;
      for (final phase in phases.where(
        (phase) => phase.kind != PhaseKind.done,
      )) {
        elapsed += phase.seconds;
        engine.update(elapsed);
        if (!identical(lastWork[phase.itemIndex], phase)) continue;
        completed++;
        expect(engine.fullyCompletedExercises, completed);
        expect(engine.completedExercises, completed);
        if (phase.blockIndex == 1 &&
            phase.round == 1 &&
            phase.itemInBlock == plan.blocks[1].items.length - 1) {
          final main = SessionRecorder.itemsOf(
            plan,
            engine,
          ).where((item) => item.blockIndex == 1);
          expect(main.map((item) => item.plannedSets), everyElement(2));
          expect(main.map((item) => item.completedSets), everyElement(1));
          expect(
            main.map((item) => item.status),
            everyElement(ItemStatus.partial),
          );
          checkedFirstMainRound = true;
        }
      }
      expect(checkedFirstMainRound, isTrue);
      expect(engine.done, isTrue);
      expect(engine.endedEarly, isFalse);
      expect(engine.fullyCompletedExercises, expectedOccurrences);
      expect(_seconds(engine.visits.map((visit) => visit.phase)), elapsed);

      final result = recorder.finish(engine, activeSeconds: elapsed);
      expect(result.full, isTrue);
      expect(result.totalExercises, expectedOccurrences);
      expect(result.completedExercises, expectedOccurrences);
      expect(result.items, hasLength(plan.items.length));
      for (final item in result.items) {
        final block = plan.blocks[item.blockIndex];
        final source = block.items[item.itemInBlock];
        final plannedSets = source.sets * block.rounds;
        expect(item.exerciseId, source.exerciseId);
        expect(item.plannedSets, plannedSets);
        expect(item.completedSets, plannedSets);
        expect(item.status, ItemStatus.completed);
        final sideSets = source.perSide
            ? {'right': plannedSets, 'left': plannedSets}
            : <String, int>{};
        expect(item.plannedSideSets, sideSets);
        expect(item.completedSideSets, sideSets);
      }
      expect(plan.toJson(), original);
    });
  }
}
