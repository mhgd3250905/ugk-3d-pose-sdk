import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

const _root = 'test/fixtures/hiplab/fit-all-blocks';
const _sourceIds = [
  'n-leg-circles',
  'h-hip-gate',
  's-9090',
  'h-adductor-rock',
  'o-stand-lunge',
  'n-seated-ir-drop',
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

List<String> _ids(TrainingPlan plan) => [
  for (final block in plan.blocks)
    for (final item in block.items) item.exerciseId,
];

double _seconds(Iterable<SessionPhase> phases) =>
    phases.fold(0, (sum, phase) => sum + phase.seconds);

({double total, double visited, double voiceExtension, int occurrences})
_native(TrainingPlan plan, Map<String, Rhythm> rhythms, SessionScript script) {
  final plain = SessionBuilder(rhythms: rhythms, prepSeconds: 15);
  final native = SessionBuilder(
    rhythms: rhythms,
    prepSeconds: 15,
    switchSecondsFor: script.switchSecondsFor,
  );
  final phases = native.phases(plan);
  final total = _seconds(phases);
  expect(phases.first.kind, PhaseKind.prep);
  expect(phases.first.seconds, 15);
  expect(phases.where((phase) => phase.selfPaced), isEmpty);
  final engine = SessionEngine(phases)..update(total + .001);
  expect(engine.done, isTrue);
  expect(engine.endedEarly, isFalse);
  expect(engine.fullyCompletedExercises, native.occurrenceCount(plan));
  final visited = engine.visits.fold(0.0, (sum, visit) => sum + visit.seconds);
  expect(visited, closeTo(total, 1e-6));
  return (
    total: total,
    visited: visited,
    voiceExtension: total - _seconds(plain.phases(plan)),
    occurrences: native.occurrenceCount(plan),
  );
}

void _bounds(TrainingPlan plan, Catalog catalog, CoachProfile profile) {
  for (final block in plan.blocks) {
    expect(profile.limits.rounds.contains(block.rounds), isTrue);
    for (final item in block.items) {
      final drill = catalog[item.exerciseId]!;
      expect(profile.limits.sets.contains(item.sets), isTrue);
      if (drill.doseRange.sets case final range?) {
        expect(range.contains(item.sets), isTrue);
      }
      expect(profile.limits.restSeconds.contains(item.restSeconds), isTrue);
      if (drill.doseRange.restSeconds case final range?) {
        expect(range.contains(item.restSeconds), isTrue);
      }
      if (item.mode == DoseMode.reps) {
        expect(profile.limits.reps.contains(item.reps!), isTrue);
        if (drill.doseRange.reps case final range?) {
          expect(range.contains(item.reps!), isTrue);
        }
      } else {
        expect(profile.limits.workSeconds.contains(item.workSeconds!), isTrue);
        if (drill.doseRange.seconds case final range?) {
          expect(range.contains(item.workSeconds!), isTrue);
        }
      }
    }
  }
}

void main() {
  final manifest = _json('manifest.json');
  final catalog = Catalog.fromJson(_json('catalog.json'));
  final profile = CoachProfile.fromJson(_json('profile.json'));
  final kitIds = <String>{..._sourceIds, 'n-pelvis-circle', 's-butterfly'};
  final rawKits = {for (final id in kitIds) id: _json('action_kits/$id.json')};
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
  final builder = PlanBuilder(profile, catalog, minPicks: profile.minActions);

  test('HipLab +24 replay fixtures preserve their exact source objects', () {
    expect(
      manifest['baselineSdkCommit'],
      'caa6817c51b3cb09c46909288d83aa88bdc2dbd4',
    );
    expect(
      (manifest['sourceCapture'] as Map)['sha256'],
      '82dab1f1055003772682c06171f929b1e15b49dec6ecf7ece12c3404fba6eaf4',
    );
    expect(catalog.problems, isEmpty);
    expect(catalog.length, 21);
    expect(
      _objectSha256(_json('captured-plan.json')),
      manifest['capturedPlanCanonicalSha256'],
    );
    final files = manifest['files'] as Map;
    for (final entry in files.entries) {
      expect(
        sha256
            .convert(File('$_root/${entry.key}').readAsBytesSync())
            .toString(),
        (entry.value as Map)['sha256'],
        reason: 'Immutable fixture changed: ${entry.key}',
      );
    }
    final log =
        jsonDecode(File('$_root/captured-fit-log.json').readAsStringSync())
            as List;
    expect(log.length, 49);
    expect((log.first as Map)['beforeEstimatedSec'], 457);
    expect((log.last as Map)['afterEstimatedSec'], 335);
  });

  test('captured failed card remains335s and actual voice-aware clock349s', () {
    final raw = _json('captured-plan.json');
    final plan = const PlanCodec().decode(raw);
    expect(plan.toJson(), raw);
    expect(_ids(plan), _sourceIds);
    expect(const PlanDuration().estimateSeconds(plan, catalog), 335);
    final native = _native(plan, rhythms, script);
    expect(native.total, 349);
    expect(native.visited, 349);
    expect(native.voiceExtension, 3);
    expect(native.occurrences, 6);
  });

  test(
    'same third-turn draft fits card and actual15s-prep clock within10%',
    () {
      final state = CoachSessionState.fromJson(
        _json('state-before-reconstructed.json'),
      );
      final before = state.toJson();
      final result = builder.draft(
        state,
        _json('draft-arguments.json'),
        newPlanId: 'offline-duration-repro',
      );
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.feasibility, isNull, reason: '${result.feasibility}');
      final version = result.state.plans[result.planId]!.last;
      final plan = const PlanCodec().decode(version.plan);
      final native = _native(plan, rhythms, script);
      final card = const PlanDuration().estimateSeconds(plan, catalog);
      printOnFailure(
        jsonEncode({
          'card': card,
          'native': native.total,
          'voiceExtension': native.voiceExtension,
          'fitLog': result.fitLog,
        }),
      );
      expect(card, inInclusiveRange(270, 330));
      expect(native.total, inInclusiveRange(270, 330));
      expect(result.toJson()['withinTolerance'], isTrue);
      expect(version.version, 2);
      expect(version.operation, 'replace_all');
      expect(_ids(plan), _sourceIds);
      expect(state.toJson(), before);
      expect(
        result.state.plans[result.planId]!.first.toJson(),
        state.plans[state.activePlanId]!.first.toJson(),
      );
      expect(
        result.fitLog.any(
          (edit) => edit['blockId'] == 'b1' && edit['field'] == 'reps',
        ),
        isTrue,
      );
      _bounds(plan, catalog, profile);
    },
  );

  for (final (warmup, mode, bilateral) in [
    ('n-pelvis-circle', DoseMode.reps, false),
    ('s-butterfly', DoseMode.time, false),
    ('h-hip-gate', DoseMode.reps, true),
  ]) {
    for (final minutes in [5, 10, 20, 30]) {
      test('HipLab $minutes min with $warmup warmup fits card and native', () {
        final ids = [warmup, ..._sourceIds.skip(2)];
        CoachParamValue user(Object value) => CoachParamValue(
          value: value,
          source: 'user',
          quote: 'HipLab $minutes minute matrix',
          turn: 1,
        );
        final baseline = CoachSessionState.fromJson(
          _json('state-before-reconstructed.json'),
        );
        final state = CoachSessionState(
          userTurns: [
            CoachUserTurn(turn: 1, text: 'HipLab $minutes minute matrix'),
          ],
          task: baseline.task,
          params: {
            'scene': user('home'),
            'minutes': user(minutes),
            'goal': user([
              'purpose.mobility',
              'purpose.stretch',
              'body.inner_thigh',
            ]),
            'level': user(1),
            'equipment': user(['equip.mat', 'equip.chair']),
            'limits': user(<String>[]),
          },
          seenActionIds: ids.toSet(),
          picks: ids,
        );
        final arguments = <String, Object?>{
          'title': 'HipLab $minutes matrix',
          'blocks': [
            {
              'kind': 'warmup',
              'items': [
                {'id': warmup},
              ],
            },
            {
              'kind': 'main',
              'items': [
                for (final id in _sourceIds.skip(2).take(3)) {'id': id},
              ],
            },
            {
              'kind': 'cooldown',
              'items': [
                {'id': _sourceIds.last},
              ],
            },
          ],
        };
        final result = builder.draft(
          state,
          arguments,
          newPlanId: 'matrix-$warmup-$minutes',
        );
        expect(result.ok, isTrue, reason: '${result.error}');
        expect(result.feasibility, isNull, reason: '${result.feasibility}');
        final plan = const PlanCodec().decode(
          result.state.plans[result.planId]!.last.plan,
        );
        final first = plan.blocks.first.items.single;
        expect(first.exerciseId, warmup);
        expect(first.mode, mode);
        expect(first.perSide, bilateral);
        final native = _native(plan, rhythms, script);
        final card = const PlanDuration().estimateSeconds(plan, catalog);
        final target = minutes * 60;
        printOnFailure(
          jsonEncode({
            'warmup': warmup,
            'target': target,
            'card': card,
            'native': native.total,
            'fitLog': result.fitLog,
          }),
        );
        expect((card - target).abs(), lessThanOrEqualTo(target * .1));
        expect((native.total - target).abs(), lessThanOrEqualTo(target * .1));
        expect(result.toJson()['withinTolerance'], isTrue);
        expect(_ids(plan), ids);
        _bounds(plan, catalog, profile);
      });
    }
  }
}
