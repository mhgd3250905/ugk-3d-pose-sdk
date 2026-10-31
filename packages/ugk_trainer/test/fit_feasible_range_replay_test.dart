import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

Map<String, dynamic> _json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void _expectDeliveredClock(
  TrainingPlan plan,
  Catalog catalog,
  List<SessionPhase> phases,
) {
  final card = const PlanDuration().estimateSeconds(plan, catalog);
  final seconds = phases.fold(0.0, (sum, phase) => sum + phase.seconds);
  expect(card, inInclusiveRange(270, 330));
  expect(seconds, inInclusiveRange(270, 330));
  final engine = SessionEngine(phases);
  engine.update(seconds);
  expect(engine.done, isTrue);
  expect(engine.endedEarly, isFalse);
  expect(
    engine.visits.fold(0.0, (sum, visit) => sum + visit.seconds),
    closeTo(seconds, .001),
  );
  final file = File('build/fit-feasible-range/replay-native-seconds.json');
  file.parent.createSync(recursive: true);
  final values = file.existsSync() ? _json(file.path) : <String, dynamic>{};
  values[plan.id] = {'card': card, 'native': seconds};
  file.writeAsStringSync('${jsonEncode(values)}\n');
}

void main() {
  test(
    'SF captured selection can drop its chair and fit the complete clock',
    () {
      const root = '../../test/fixtures/fit-feasible-range/smartfit';
      final catalog = Catalog.fromJson(_json('$root/catalog.json'));
      final profile = CoachProfile.fromJson(_json('$root/profile.json'));
      final original = _json('$root/original-draft-arguments.json');
      final args = {
        ...original,
        'blocks': [
          for (final block
              in (original['blocks'] as List).cast<Map<String, dynamic>>())
            if ((block['items'] as List).any(
              (item) => (item as Map)['id'] != 'h-chair-sit-to-stand',
            ))
              {
                ...block,
                'items': [
                  for (final item in block['items'] as List)
                    if ((item as Map)['id'] != 'h-chair-sit-to-stand') item,
                ],
              },
        ],
      };
      final state = CoachSessionState.fromJson(
        _json('$root/pre-draft-state.json'),
      );
      final gate = NodeGates(profile, catalog, minPicks: profile.minActions);
      final selected = gate.check(
        state,
        'actions',
        picks: [
          for (final block in args['blocks'] as List)
            for (final item in (block as Map)['items'] as List)
              (item as Map)['id'] as String,
        ],
      );
      expect(selected.ok, isTrue, reason: '${selected.error}');
      final result = PlanBuilder(
        profile,
        catalog,
        minPicks: profile.minActions,
      ).draft(selected.state, args, newPlanId: 'sf-repaired-five-minute');
      expect(result.ok, isTrue, reason: '${result.error}');
      final plan = const PlanCodec().decode(
        result.state.plans[result.planId]!.last.plan,
      );
      final execution = _json('$root/execution-rhythms.json');
      final rhythms = {
        for (final item in plan.items)
          item.exerciseId: Rhythm.fromJson(
            Map<String, dynamic>.from(execution[item.exerciseId] as Map),
          ),
      };
      expect(
        plan.items
            .where((item) => item.mode == DoseMode.reps)
            .every((item) => rhythms[item.exerciseId]!.counted),
        isTrue,
      );
      _expectDeliveredClock(
        plan,
        catalog,
        SessionBuilder(prepSeconds: 10, rhythms: rhythms).phases(plan),
      );
    },
  );

  test(
    'HipLab third-turn fixture retains authored lead and voice-aware clock',
    () {
      const root = 'test/fixtures/hiplab/fit-all-blocks';
      final catalog = Catalog.fromJson(_json('$root/catalog.json'));
      final profile = CoachProfile.fromJson(_json('$root/profile.json'));
      final state = CoachSessionState.fromJson(
        _json('$root/state-before-reconstructed.json'),
      );
      final result = PlanBuilder(
        profile,
        catalog,
        minPicks: profile.minActions,
      ).draft(state, _json('$root/draft-arguments.json'), newPlanId: 'unused');
      expect(result.ok, isTrue, reason: '${result.error}');
      final plan = const PlanCodec().decode(
        result.state.plans[result.planId]!.last.plan,
      );
      final kits = {
        for (final item in plan.items)
          item.exerciseId: _json('$root/action_kits/${item.exerciseId}.json'),
      };
      final script = SessionScript(
        lang: 'zh',
        source: ManifestVoiceSource.fromJson(
          _json('$root/voice-manifest.json'),
          kitVoices: {
            for (final entry in kits.entries)
              entry.key: KitVoice.fromActionKitJson(entry.value),
          },
        ),
      );
      _expectDeliveredClock(
        plan,
        catalog,
        SessionBuilder(
          prepSeconds: 15,
          rhythms: {
            for (final entry in kits.entries)
              entry.key: Rhythm.fromActionKitJson(entry.value),
          },
          switchSecondsFor: script.switchSecondsFor,
        ).phases(plan),
      );
    },
  );
}
