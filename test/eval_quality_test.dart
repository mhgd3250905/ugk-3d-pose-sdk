import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import '../tool/eval_quality.dart';
import 'support.dart';

void main() {
  EvaluationJson delivered({
    List<String> required = const ['mat'],
    List<String> excluded = const [],
  }) => {
    'turn': 1,
    'plan': {
      'blocks': [
        {
          'items': [
            {'exerciseId': 'action'},
          ],
        },
      ],
    },
    'params': {
      'equipment': {'value': [], 'source': 'user'},
      'equipment_exclude': {'value': excluded, 'source': 'user'},
    },
    'ambientEquipmentCodes': ['equip.mat', 'equip.wall', 'equip.chair'],
    'actionFacts': [
      {'id': 'action', 'equipment': required},
    ],
  };

  test('stale nonambient exclusions cannot veto explicit extra equipment', () {
    final t = delivered(required: ['dumbbell'], excluded: ['equip.dumbbell']);
    expect(
      evaluationEquipmentQuality(
        [t],
        expectedEquipment: ['dumbbell'],
      )['status'],
      'pass',
    );
  });

  test(
    'fixture bodyweight allows ambient but cannot authorize extra or excluded gear',
    () {
      final mat = delivered();
      expect(
        evaluationEquipmentQuality([mat], expectedEquipment: [])['status'],
        'pass',
      );
      expect(evaluationEquipmentQuality([mat])['status'], 'pass');
      expect(
        evaluationEquipmentQuality([
          delivered(excluded: ['equip.mat']),
        ], expectedEquipment: [])['status'],
        'fail',
      );
      expect(
        evaluationEquipmentQuality(
          [
            delivered(excluded: ['equip.mat']),
          ],
          expectedEquipment: ['mat'],
        )['status'],
        'fail',
      );
      final invented = delivered(required: ['dumbbell']);
      invented['params'] = {
        'equipment': {
          'value': ['equip.dumbbell'],
          'source': 'user',
        },
      };
      expect(
        evaluationEquipmentQuality([invented], expectedEquipment: [])['status'],
        'fail',
      );
      expect(evaluationEquipmentQuality([])['status'], 'not_observed');
    },
  );

  test(
    'profile-wide missing English list uses raw names and includes published omissions',
    () {
      const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
      final catalog = PoseHubAppTestCatalog.fromBytes(
        File('$pack/catalog.json').readAsBytesSync(),
        semanticCatalogBytes: File(
          '$pack/catalog/catalog.json',
        ).readAsBytesSync(),
      ).toAiCatalog();
      final missing = evaluationMissingEnglishNames(
        loadProfile('smartfit'),
        catalog,
      );
      final ids = missing.map((row) => row['id']).toSet();
      expect(
        ids,
        containsAll(['h-bilateral-upper-back-hug', 'h-sleeper-stretch']),
      );
      expect(ids, isNot(contains('h-squat')));
      expect(ids.length, missing.length);
      final checks = evaluationRequestedEnglishNameChecks(
        loadProfile('smartfit'),
        catalog,
      );
      expect(checks.map((row) => row['id']), [
        'h-bilateral-upper-back-hug',
        'h-overhead-triceps-stretch',
      ]);
      expect(
        checks.every((row) => row['status'] == 'present_missing_en'),
        isTrue,
      );
      expect(checks.every((row) => row['inProfileScope'] == true), isTrue);
      final allStatuses = evaluationRequestedEnglishNameChecks(
        loadProfile('smartfit'),
        catalog,
        ids: ['h-overhead-triceps-stretch', 'h-squat', 'not-in-the-catalog'],
      );
      expect(allStatuses.map((row) => row['status']), [
        'present_missing_en',
        'present_translated',
        'missing_from_catalog',
      ]);
      expect(allStatuses.last['nameZh'], isNull);
      expect(allStatuses.last['nameEn'], isNull);
    },
  );

  test(
    'counts usage failures including last missing receipt, excluding skipped and non-tool records',
    () {
      EvaluationJson tool(String id) => {
        'id': id,
        'function': {'name': 'check', 'arguments': '{}'},
      };
      final messages = [
        {
          'role': 'assistant',
          'tool_calls': [tool('a'), tool('b'), tool('c'), tool('last')],
        },
        {
          'role': 'tool',
          'tool_call_id': 'a',
          'content': jsonEncode({'ok': false, 'code': 'wrong_node'}),
        },
        {
          'role': 'tool',
          'tool_call_id': 'b',
          'content': jsonEncode({'ok': false, 'code': 'skipped_after_error'}),
        },
        {
          'role': 'tool',
          'tool_call_id': 'c',
          'content': jsonEncode({
            'ok': false,
            'code': 'skipped_after_completion',
          }),
        },
      ];
      EvaluationJson record(String id, String code, {bool hadTools = true}) => {
        'id': id,
        'outcome': 'toolStep',
        'issueCodes': [code],
        'hadToolCalls': hadTools,
      };
      final turn = <String, Object?>{
        'turn': 1,
        'calls': [
          {
            'request': {'messages': messages},
          },
        ],
        'agentHistoryAfterTurn': messages,
        'toolUsageRecords': [
          record('r1', 'wrong_node'),
          record('r1', 'wrong_node'),
          record('r2', 'invalid_picks'),
          record('r3', 'skipped_after_error'),
          record('r6', 'skipped_after_completion'),
          record('r4', 'canary_leak'),
          record('r5', 'missing_plan', hadTools: false),
        ],
      };
      final stats = evaluationToolRejections([turn]);
      expect(stats['count'], 2);
      expect(stats['observedCount'], 1);
      expect(stats['skippedBatchCallsObserved'], 2);
      expect(stats['coverage'], 'usage-records-first-failure-per-batch');
      expect(
        (stats['unobservedToolCalls'] as List).single,
        containsPair('toolCallId', 'last'),
      );
      final legacy = {...turn}..remove('toolUsageRecords');
      expect(evaluationToolRejections([legacy])['count'], isNull);
      expect(evaluationToolRejections([legacy])['observedCount'], 1);
    },
  );
}
