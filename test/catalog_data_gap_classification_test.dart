import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_search.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/catalog_data_gaps.dart';
import 'package:ugk_coach/src/agent/context_compactor.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/plan_checker.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final original = loadCatalog();
  const profile = CoachProfile(id: 'test', appName: 'test');
  Drill drill(String id, {bool knownRisk = false}) => Drill(
    id: id,
    name: original.drills.first.name,
    category: 'strength',
    muscleGroups: const ['abs'],
    position: 'standing',
    unilateral: false,
    level: 1,
    scenes: const ['home'],
    defaultDose: const Dose(
      mode: DoseMode.time,
      sets: 1,
      seconds: 60,
      restSeconds: 0,
    ),
    contraindications: knownRisk ? ['膝'] : const [],
    raw: const {
      'trainingSemantics': {
        'unknownFields': [
          {'field': 'cautions'},
          {'field': 'contraindications'},
          {'field': 'level'},
        ],
      },
    },
  );
  final catalog = Catalog(
    version: 'classification-test',
    taxonomy: original.taxonomy,
    drills: [drill('missing'), drill('known-risk', knownRisk: true)],
  );
  final gates = NodeGates(profile, catalog, minPicks: 3);
  final search = ActionSearch(profile, catalog, minPicks: 3);
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'host', turn: 0);
  CoachSessionState state({
    List<String> limits = const [],
    List<String>? savedWarnings,
  }) {
    final plan = TrainingPlan(
      id: 'p',
      source: 'ai',
      title: '训练',
      summary: '训练',
      goal: 'strength',
      scene: 'home',
      level: 1,
      targetMinutes: 3,
      blocks: const [
        PlanBlock(
          id: 'b1',
          name: '主体',
          type: BlockType.main,
          items: [
            PlanItem(
              exerciseId: 'missing',
              mode: DoseMode.time,
              sets: 3,
              workSeconds: 60,
              perSide: false,
              restSeconds: 0,
            ),
          ],
        ),
      ],
    );
    return CoachSessionState(
      task: CoachTaskState(
        type: 'plan',
        reused: false,
        nodes: [
          for (final id in AgentTask.planNodes)
            CoachNodeState(id: id, status: id == 'output' ? 'current' : 'done'),
        ],
      ),
      params: {
        'scene': param('home'),
        'goal': param(['purpose.strength']),
        'minutes': param(3),
        'equipment': param(<String>[]),
        'limits': param(limits),
        'level': param(1),
      },
      seenActionIds: const {'missing'},
      picks: const ['missing'],
      activePlanId: 'p',
      plans: {
        'p': [
          CoachPlanVersion(
            version: 1,
            plan: plan.toJson(),
            estimateSec: const PlanDuration().estimateSeconds(plan, catalog),
            fitLog: const [],
            check: savedWarnings == null
                ? null
                : {'ok': true, 'warnings': savedWarnings},
          ),
        ],
      },
    );
  }

  const oldCaution = 'missing 的 cautions 尚未明确，不能视为已验证。';
  const oldContraindication = 'missing 的 contraindications 尚未明确，不能视为已验证。';
  const oldLevel = 'missing 的 level 尚未明确，不能视为已验证。';

  test(
    'no limits: search and get retain developer diagnostics without model warnings',
    () {
      final logs = <Map<String, Object?>>[];
      CatalogDataGapLog.capture(logs.add, () {
        expect(search.search(state()).warnings, isEmpty);
        final detail = search.getActions(state(), ['missing']);
        expect(detail.warnings, isEmpty);
        expect(jsonEncode(detail.toJson()), isNot(contains('尚未明确')));
      });
      expect(logs.map((entry) => entry['field']).toSet(), {
        'cautions',
        'contraindications',
        'level',
      });
      expect(logs.every((entry) => entry['modelVisible'] == false), isTrue);
      expect(
        logs.every((entry) => entry['code'] == 'catalog_data_gap'),
        isTrue,
      );
    },
  );

  test(
    'node and plan validation do not turn unrelated completeness gaps into card warnings',
    () {
      final logs = <Map<String, Object?>>[];
      CatalogDataGapLog.capture(logs.add, () {
        final source = state();
        expect(gates.catalogWarnings(source, ['missing']), isEmpty);
        final checked = PlanChecker(
          profile,
          catalog,
          minPicks: 3,
        ).check(source, 'p');
        expect(checked.ok, isTrue, reason: '${checked.errors}');
        expect(checked.warnings, isEmpty);
        final output = ToolGate(catalog: catalog, profile: profile)
            .checkAgentOutput(source, CoachTools.showPlan, {
              'plan_id': 'p',
              'note': '安排好了。',
            });
        expect(output.ok, isTrue, reason: '${output.error}');
        expect(output.card!.plan!.warnings, isEmpty);
      });
      expect(logs, isNotEmpty);
    },
  );

  test(
    'restored card drops old irrelevant directory warnings and preserves unknown safety text',
    () {
      final source = state(
        savedWarnings: [
          oldCaution,
          oldContraindication,
          oldLevel,
          '保持这条宿主安全提示。',
        ],
      );
      final restored = CoachSessionState.fromJson(source.toJson());
      final before = jsonEncode(restored.toJson());
      final output = ToolGate(catalog: catalog, profile: profile)
          .checkAgentOutput(restored, CoachTools.showPlan, {
            'plan_id': 'p',
            'note': '继续训练。',
          });
      expect(output.ok, isTrue, reason: '${output.error}');
      expect(output.card!.plan!.warnings.map((warning) => warning.message), [
        '保持这条宿主安全提示。',
      ]);
      expect(jsonEncode(restored.toJson()), before);
    },
  );

  test(
    'restored raw and compacted warnings are filtered only in request view',
    () {
      for (final warnings in <Object>[
        [oldCaution, oldLevel, '保留未识别的安全提示。'],
        {
          'template': '{id} 的 {field} 尚未明确，不能视为已验证。',
          'fields': ['cautions', 'level'],
          'rows': [
            ['missing', 0],
            ['missing', 1],
            '保留未识别的安全提示。',
          ],
        },
      ]) {
        final history = [
          LlmMessage.assistant(
            '',
            toolCalls: [
              const LlmToolCall(
                id: 'old',
                name: 'search_actions',
                arguments: '{"tags":[]}',
              ),
            ],
          ),
          LlmMessage.tool(
            'old',
            jsonEncode({
              'ok': true,
              'items': [
                {'id': 'missing'},
              ],
              'warnings': warnings,
            }),
          ),
        ];
        final before = jsonEncode(
          history.map((message) => message.toJson()).toList(),
        );
        final restored = CoachSessionState.fromJson(state().toJson());
        final request = const ContextCompactor().compose(
          system: const LlmMessage.system('角色'),
          state: restored,
          catalog: catalog,
          profile: profile,
          history: history,
        );
        final receipt = request
            .singleWhere((message) => message.toolCallId == 'old')
            .content;
        expect(receipt, isNot(contains('尚未明确')));
        expect(receipt, contains('保留未识别的安全提示。'));
        expect(
          jsonEncode(history.map((message) => message.toJson()).toList()),
          before,
        );
      }
    },
  );

  test('non-safety gaps remain developer-only when limits are present', () {
    final result = search.getActions(state(limits: ['limit.knee']), [
      'missing',
    ]);
    expect(result.ok, isTrue);
    expect(result.warnings, containsAll([oldCaution, oldContraindication]));
    expect(result.warnings, isNot(contains(oldLevel)));
  });

  for (final limit in ['limit.knee', 'limit.shoulder']) {
    test(
      'any $limit makes missing general safety fields relevant without a new rejection',
      () {
        final source = state(limits: [limit]);
        final logs = <Map<String, Object?>>[];
        CatalogDataGapLog.capture(logs.add, () {
          final detail = search.getActions(source, ['missing']);
          expect(detail.ok, isTrue);
          expect(detail.warnings, [oldCaution, oldContraindication]);
          final output = ToolGate(catalog: catalog, profile: profile)
              .checkAgentOutput(source, CoachTools.showPlan, {
                'plan_id': 'p',
                'note': '按限制安排。',
              });
          expect(output.ok, isTrue, reason: '${output.error}');
          expect(
            output.card!.plan!.warnings.map((warning) => warning.message),
            containsAll([oldCaution, oldContraindication]),
          );
          expect(
            output.card!.plan!.warnings.map((warning) => warning.message),
            isNot(contains(oldLevel)),
          );
        });
        expect(
          logs
              .where((entry) => entry['field'] != 'level')
              .every((entry) => entry['modelVisible'] == true),
          isTrue,
        );
        expect(
          logs
              .where((entry) => entry['field'] == 'level')
              .every((entry) => entry['modelVisible'] == false),
          isTrue,
        );
      },
    );
  }

  test(
    'restore retains relevant safety warnings in model and card, not other completeness gaps',
    () {
      final source = state(
        limits: ['limit.shoulder'],
        savedWarnings: [oldCaution, oldContraindication, oldLevel],
      );
      final restored = CoachSessionState.fromJson(source.toJson());
      final output = ToolGate(catalog: catalog, profile: profile)
          .checkAgentOutput(restored, CoachTools.showPlan, {
            'plan_id': 'p',
            'note': '继续训练。',
          });
      expect(output.ok, isTrue, reason: '${output.error}');
      expect(output.card!.plan!.warnings.map((warning) => warning.message), [
        oldCaution,
        oldContraindication,
      ]);
      final history = [
        LlmMessage.assistant(
          '',
          toolCalls: [
            const LlmToolCall(
              id: 'old',
              name: 'get_action',
              arguments: '{"ids":["missing"]}',
            ),
          ],
        ),
        LlmMessage.tool(
          'old',
          jsonEncode({
            'ok': true,
            'warnings': [oldCaution, oldContraindication, oldLevel],
          }),
        ),
      ];
      final before = jsonEncode(
        history.map((message) => message.toJson()).toList(),
      );
      final request = const ContextCompactor().compose(
        system: const LlmMessage.system('角色'),
        state: restored,
        catalog: catalog,
        profile: profile,
        history: history,
      );
      final receipt = request
          .singleWhere((message) => message.toolCallId == 'old')
          .content;
      expect(receipt, contains(oldCaution));
      expect(receipt, contains(oldContraindication));
      expect(receipt, isNot(contains(oldLevel)));
      expect(
        jsonEncode(history.map((message) => message.toJson()).toList()),
        before,
      );
    },
  );

  test(
    'known contraindications remain an A rejection and opaque limits stay visible',
    () {
      final limited = state(limits: ['limit.knee']);
      expect(gates.actionProblem(limited, 'known-risk'), '触及伤痛限制');
      expect(search.getActions(limited, ['known-risk']).ok, isFalse);
      final opaque = state(limits: ['limit.u_1234']).copyWith(
        hostValues: {
          'limitsOpaque': ['limit.u_1234'],
        },
      );
      expect(search.search(opaque).warnings, contains(contains('不能确认其安全性')));
    },
  );
}
