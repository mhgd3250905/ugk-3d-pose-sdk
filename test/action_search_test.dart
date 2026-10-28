import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_search.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/coach_agent.dart';
import 'package:ugk_coach/src/agent/session_state.dart';
import 'package:ugk_coach/src/catalog/catalog.dart';
import 'package:ugk_coach/src/catalog/pose_hub_app_test_pack.dart';
import 'package:ugk_coach/src/profile/coach_profile.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');
  final search = ActionSearch(profile, catalog, minPicks: 3);
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'host', turn: 0);
  CoachSessionState active({
    Map<String, CoachParamValue> params = const {},
    Map<String, Object?> hostValues = const {},
  }) => AgentTask.start(
    CoachSessionState(params: params, hostValues: hostValues),
    'recommend',
  ).state;

  test('reject invalid tags and bounds without mutating state', () {
    final state = active();
    expect(
      search.search(state, tags: ['purpose.warmup']).error!['code'],
      'invalid_tags',
    );
    expect(search.search(state, limit: 21).ok, isTrue);
    expect(search.search(state, limit: 21).notes, isNotEmpty);
    expect(search.search(state, limit: 0).items, hasLength(1));
    expect(state.seenActionIds, isEmpty);
  });

  test(
    'bodyweight default allows ambient wall and mat and records only returned ids',
    () {
      final state = active();
      final result = search.search(state, limit: 20);
      expect(result.ok, isTrue);
      expect(result.items.length, inInclusiveRange(1, 20));
      expect(result.filter['equipment'], '徒手（默认）');
      expect(result.filter['hiddenEquipmentCount'], greaterThan(0));
      for (final row in result.items) {
        expect(
          catalog[row['id'] as String]!.equipment.where((e) => e != 'none'),
          everyElement(isIn(['wall', 'mat'])),
        );
        final returnedGear = ((row['data'] as List)[1] as List).map(
          (index) => (result.format['equipment'] as List)[index as int],
        );
        expect(returnedGear, everyElement(isIn(['equip.wall', 'equip.mat'])));
        expect(row.keys, containsAll(['id', 'name', 'summary', 'data']));
        expect(row['data'], hasLength(8));
      }
      expect(
        result.state.seenActionIds,
        result.items.map((r) => r['id']).toSet(),
      );
      expect(state.seenActionIds, isEmpty);
    },
  );

  test(
    'real catalogue rows are compact and default-dose time has both sides',
    () {
      final result = search.search(active(), limit: 20);
      final lengths = result.items
          .map((row) => utf8.encode(jsonEncode(row)).length)
          .toList();
      expect(lengths.every((n) => n <= 240), isTrue, reason: '$lengths');
      Map<String, Object?> rowFor(String id) => search
          .search(active(), keywords: catalog[id]!.name.of('en'))
          .items
          .singleWhere((row) => row['id'] == id);
      expect((rowFor('h-squat')['data'] as List)[7], 48);
      expect((rowFor('h-side-leg-raise')['data'] as List)[7], 101);
      expect(
        result.items.every((row) => (row['summary'] as String).isNotEmpty),
        isTrue,
      );
    },
  );

  test('repeated search returns only IDs with the exact repeat count', () {
    final first = search.search(active(), limit: 3);
    expect(first.ok, isTrue);
    expect(first.items, hasLength(3));
    for (final row in first.items) {
      expect(row.keys, containsAll(['id', 'name', 'summary', 'data']));
    }
    final repeated = search.search(first.state, limit: 3);
    expect(repeated.ok, isTrue);
    expect(repeated.items, [
      for (final row in first.items)
        {'id': row['id'], 'doseMode': row['doseMode'], 'level': row['level']},
    ]);
    expect(repeated.summary, contains('以下 3 个之前已返回，仅列 id'));
    expect(repeated.state.seenActionIds, first.state.seenActionIds);
  });

  test('repeated search rechecks equipment after the user removes it', () {
    final extraAction = profile
        .scope(catalog)
        .firstWhere((drill) => drill.equipment.contains('dumbbell'));
    final equipment = [
      for (final raw in extraAction.equipment)
        ?search.gate.tags.equipmentCode(raw),
    ];
    final first = search.search(
      active(params: {'equipment': param(equipment)}),
      keywords: extraAction.name.of('zh'),
    );
    expect(first.ok, isTrue);
    expect(first.items.map((row) => row['id']), contains(extraAction.id));
    final reduced = first.state.copyWith(
      params: {...first.state.params, 'equipment': param(<String>[])},
    );
    final repeated = search.search(
      reduced,
      keywords: extraAction.name.of('zh'),
    );
    expect(repeated.ok, isTrue);
    expect(
      repeated.items.map((row) => row['id']),
      isNot(contains(extraAction.id)),
    );
    expect(repeated.filter['hiddenEquipmentCount'], greaterThan(0));
    for (final row in repeated.items) {
      expect(search.gate.actionProblem(reduced, row['id'] as String), isNull);
    }
    expect(repeated.state.seenActionIds, contains(extraAction.id));
  });

  test('planState restore preserves seen IDs for search deduplication', () {
    final first = search.search(active(), limit: 3);
    final saved = CoachPlanState(planId: 'saved', sessionState: first.state);
    final restored = CoachPlanState.fromJson(
      jsonDecode(jsonEncode(saved.toJson())) as Map<String, dynamic>,
    );
    final repeated = search.search(restored.sessionState!, limit: 3);
    expect(repeated.items, [
      for (final row in first.items)
        {'id': row['id'], 'doseMode': row['doseMode'], 'level': row['level']},
    ]);
    expect(repeated.summary, contains('以下 3 个之前已返回，仅列 id'));
    expect(repeated.state.seenActionIds, first.state.seenActionIds);
  });

  test(
    'every published profile action has a compact nonempty Chinese and English search row',
    () {
      const root = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
      final manifest =
          jsonDecode(File('$root/catalog.json').readAsStringSync())
              as Map<String, Object?>;
      final canonical =
          jsonDecode(File('$root/catalog/catalog.json').readAsStringSync())
              as Map<String, Object?>;
      final published = PoseHubAppTestCatalog.fromJson(
        manifest,
        semanticCatalog: canonical,
      ).toAiCatalog();
      final failures = <String>[];
      final measurements = <({String key, int bytes})>[];
      var tested = 0;
      var equipmentTested = 0;
      for (final profileId in ['smartfit', 'hiplab', 'flarelab']) {
        final p = loadProfile(profileId);
        final finder = ActionSearch(p, published, minPicks: 3);
        final allEquipment = <String>{
          for (final drill in p.scope(published))
            for (final raw in drill.equipment)
              ?finder.gate.tags.equipmentCode(raw),
        }.toList();
        final state = active(params: {'equipment': param(allEquipment)});
        for (final drill in p.scope(published)) {
          for (final language in ['zh', 'en']) {
            final result = finder.search(
              state,
              keywords: drill.name.of(language),
              language: language,
            );
            final candidates = result.items;
            final rows = candidates
                .where((row) => row['id'] == drill.id)
                .toList();
            if (rows.length != 1) {
              failures.add(
                '$profileId/$language/${drill.id}: 无法通过名称获取唯一行，匹配数 ${rows.length}',
              );
              continue;
            }
            tested++;
            if (drill.equipment.isNotEmpty &&
                !drill.equipment.every((item) => item == 'none')) {
              equipmentTested++;
            }
            final row = rows.single;
            final data = row['data']! as List<Object?>;
            final format = result.format;
            final body = data[0] as int?;
            if (body != null) {
              final code = (format['body']! as List<String>)[body];
              expect(finder.gate.tags.forAction(drill), contains(code));
            }
            expect(
              (data[1]! as List<Object?>)
                  .map((v) => (format['equipment']! as List<String>)[v! as int])
                  .toList(),
              [
                for (final raw in drill.equipment)
                  ?finder.gate.tags.equipmentCode(raw),
              ],
            );
            expect(
              (format['position']! as List<String>)[data[2]! as int],
              drill.position,
            );
            expect(
              (data[3]! as List<Object?>)
                  .map((v) => (format['scene']! as List<String>)[v! as int])
                  .toList(),
              drill.scenes,
            );
            expect(
              (format['mode']! as List<String>)[data[4]! as int],
              drill.defaultDose.mode == DoseMode.reps ? 'reps' : 'seconds',
            );
            final bytes = utf8.encode(jsonEncode(row)).length;
            measurements.add((
              key: '$profileId/$language/${drill.id}',
              bytes: bytes,
            ));
            final summary = row['summary'];
            if (summary is! String || summary.trim().isEmpty) {
              failures.add(
                '$profileId/$language/${drill.id}: $bytes 字节，summary=$summary',
              );
            }
          }
        }
      }
      expect(tested, greaterThan(0));
      expect(equipmentTested, greaterThan(0));
      measurements.sort((a, b) => a.bytes.compareTo(b.bytes));
      final p50 = measurements[(measurements.length * .5).ceil() - 1].bytes;
      final p90 = measurements[(measurements.length * .9).ceil() - 1].bytes;
      final max = measurements.last;
      // This distribution is useful for checking the request budget in CI.
      // ignore: avoid_print
      print(
        'search row bytes: count=$tested equipment=$equipmentTested p50=$p50 p90=$p90 max=${max.bytes} (${max.key}) over240=${measurements.where((m) => m.bytes > 240).length}',
      );
      // ignore: avoid_print
      print(
        'rows over 240 bytes: ${measurements.where((m) => m.bytes > 240).map((m) => '${m.key}=${m.bytes}').join(', ')}',
      );
      expect(p50, lessThanOrEqualTo(200));
      expect(p90, lessThanOrEqualTo(230));
      expect(max.bytes, lessThanOrEqualTo(280));
      expect(
        measurements.where((m) => m.bytes > 240).length,
        lessThanOrEqualTo((tested * .05).ceil()),
      );
      expect(failures, isEmpty, reason: failures.join('\n'));
    },
  );

  test('matching tags, scene, equipment and known injury are all enforced', () {
    final state = active(
      params: {
        'scene': param('office'),
        'equipment': param(<String>[]),
        'limits': param(['limit.knee']),
      },
    );
    final result = search.search(state, tags: ['body.core']);
    expect(result.ok, isTrue);
    for (final row in result.items) {
      final id = row['id'] as String;
      expect(
        search.gate.tags
            .forActionId(id)
            .intersection(search.gate.tags.expandCodes(['body.core'])),
        isNotEmpty,
      );
      expect(search.gate.actionProblem(state, id), isNull);
      expect(catalog[id]!.cautions, isNot(contains('膝')));
    }
  });

  test('get_action rejects unsafe or unknown ids and caps at ten', () {
    final state = active();
    final extra = profile
        .scope(catalog)
        .firstWhere((d) => d.equipment.contains('dumbbell'));
    expect(
      search.getActions(state, [extra.id]).error!['code'],
      'incompatible_actions',
    );
    expect(search.getActions(state, ['not-in-catalog']).ok, isFalse);
    expect(search.getActions(state, []).ok, isTrue);
    expect(search.getActions(state, []).notes, isNotEmpty);
    expect(
      search.getActions(state, List.generate(11, (i) => 'id$i')).ok,
      isFalse,
    );
    final ids = search
        .search(state, limit: 2)
        .items
        .map((r) => r['id'] as String)
        .toList();
    final details = search.getActions(state, ids);
    expect(details.ok, isTrue);
    expect(details.state.seenActionIds, isEmpty);
    expect(
      details.items.first.keys,
      containsAll(['id', 'name', 'cues', 'cautions', 'contraindications']),
    );
  });

  test('localized aliases match without interpreting surrounding messages', () {
    final base = catalog.drills.first;
    final drill = Drill(
      id: 'custom',
      name: base.name,
      category: base.category,
      position: base.position,
      unilateral: base.unilateral,
      level: base.level,
      defaultDose: base.defaultDose,
      raw: const {
        'aliases': {
          'en': ['unusual widget'],
          'zh': ['特别动作'],
        },
        'trainingSemantics': {
          'unknownFields': [
            {'field': 'contraindications'},
          ],
        },
      },
    );
    final customCatalog = Catalog(
      version: catalog.version,
      drills: [drill],
      taxonomy: catalog.taxonomy,
    );
    final custom = ActionSearch(
      const CoachProfile(id: 'all', appName: 'all'),
      customCatalog,
      minPicks: 3,
    );
    final result = custom.search(
      active(),
      keywords: 'UNUSUAL WIDGET',
      language: 'en',
    );
    expect(result.items.single['id'], 'custom');
    expect(result.warnings, isEmpty);
    expect(custom.search(active(), keywords: '特别动作').items, hasLength(1));
    expect(custom.search(active(), keywords: '不相关的句子').items, isEmpty);
  });

  test('unknown host limit is retained and explicitly reported', () {
    final code = search.gate.tags.limitCode('特殊伤痛')!;
    final state = active(
      params: {
        'limits': param([code]),
      },
      hostValues: {
        'limitsOpaque': [code],
      },
    );
    final result = search.search(state, limit: 1);
    expect(result.state.params['limits']!.value, [code]);
    expect(result.warnings.single, contains('不能确认其安全性'));
  });
}
