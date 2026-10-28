import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/plan_checker.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';
import 'support_v2_plan_flow.dart';

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'host', turn: 0);
  CoachSessionState state({bool exceedRecommendedRange = false}) {
    final envelope = okEnvelope();
    if (exceedRecommendedRange) itemOf(envelope, 1, 1)['workSeconds'] = 19;
    final raw = planOf(envelope)..['id'] = 'host-plan';
    final plan = const PlanCodec().decode(raw);
    return CoachSessionState(
      task: CoachTaskState(
        type: 'plan',
        reused: false,
        nodes: [
          const CoachNodeState(id: 'understand', status: 'done'),
          const CoachNodeState(id: 'parameters', status: 'done'),
          const CoachNodeState(id: 'actions', status: 'done'),
          const CoachNodeState(id: 'planning', status: 'done'),
          const CoachNodeState(id: 'review', status: 'current'),
          const CoachNodeState(id: 'output', status: 'pending'),
        ],
      ),
      params: {
        'scene': param('home'),
        'equipment': param(['equip.mat']),
        'minutes': param(10),
        'level': param(1),
        'limits': param(<String>[]),
        'goal': param(['purpose.stretch']),
      },
      seenActionIds: catalog.ids.toSet(),
      activePlanId: 'host-plan',
      plans: {
        'host-plan': [
          CoachPlanVersion(
            version: 1,
            plan: plan.toJson(),
            estimateSec: 600,
            fitLog: const [],
          ),
        ],
      },
    );
  }

  test(
    'host rejection rule receives actual plan and context and blocks approval',
    () {
      final source = state();
      final baseline = PlanChecker(
        profile,
        catalog,
        minPicks: 3,
      ).check(source, 'host-plan');
      expect(baseline.ok, isTrue, reason: '${baseline.errors}');
      var calls = 0;
      Iterable<PlanIssue> hostRule(
        TrainingPlan plan,
        Catalog catalog,
        CoachContext context,
      ) {
        calls++;
        expect(plan.id, 'host-plan');
        expect(plan.exerciseIds, contains('s-butterfly'));
        expect(context.scene, 'home');
        expect(context.equipment, {'mat', 'wall', 'chair'});
        expect(context.minutes, 10);
        return [
          const PlanIssue(
            'host_safety',
            '宿主限制该动作',
            path: 'plan.blocks',
            expected: '不含该动作',
            actual: 's-butterfly',
            fix: '替换该动作。',
          ),
        ];
      }

      final checked = PlanChecker(
        profile,
        catalog,
        minPicks: 3,
        extraRules: [hostRule],
      ).check(source, 'host-plan');
      expect(calls, 1);
      expect(checked.ok, isFalse);
      expect(checked.errors.any((e) => e['code'] == 'host_safety'), isTrue);
      expect(checked.state.plans['host-plan']!.last.check!['ok'], isFalse);
      expect(
        checked.state.task!.nodes.singleWhere((n) => n.status == 'current').id,
        'planning',
      );
    },
  );

  test(
    'enforceDrillDoseRange turns a catalogue range warning into rejection',
    () {
      final source = state(exceedRecommendedRange: true);
      final advisory = PlanChecker(
        profile,
        catalog,
        minPicks: 3,
      ).check(source, 'host-plan');
      expect(advisory.ok, isTrue, reason: '${advisory.errors}');
      final strict = PlanChecker(
        profile,
        catalog,
        minPicks: 3,
        enforceDrillDoseRange: true,
      ).check(source, 'host-plan');
      expect(strict.ok, isFalse);
      expect(
        strict.errors.any((e) => e['code'] == IssueCodes.workSecondsRange),
        isTrue,
        reason: '${strict.errors}',
      );
      expect(strict.state.plans['host-plan']!.last.check!['ok'], isFalse);
    },
  );

  test('real Agent check_plan invokes the host rejection rule', () async {
    const root = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
    final published = PoseHubAppTestCatalog.fromBytes(
      File('$root/catalog.json').readAsBytesSync(),
      semanticCatalogBytes: File(
        '$root/catalog/catalog.json',
      ).readAsBytesSync(),
    ).toAiCatalog();
    final flow = ScriptedV2PlanFlow(published);
    var ruleCalls = 0;
    Iterable<PlanIssue> denyMat(
      TrainingPlan plan,
      Catalog actualCatalog,
      CoachContext context,
    ) {
      ruleCalls++;
      expect(actualCatalog, same(published));
      expect(plan.exerciseIds, contains('s-butterfly'));
      expect(context.equipment, {'mat', 'wall', 'chair'});
      return [
        const PlanIssue(
          'host_safety',
          '宿主禁止此动作',
          path: 'plan.blocks',
          expected: '不含 s-butterfly',
          actual: 's-butterfly',
          fix: '替换该动作。',
        ),
      ];
    }

    final client = FakeLlmClient([
      ...flow.initial().take(2),
      (LlmRequest request) {
        final toolResult = request.messages.singleWhere(
          (m) => m.toolCallId == 'draft',
        );
        final feedback = jsonDecode(toolResult.content) as Map<String, Object?>;
        flow.planId = feedback['plan_id'] as String;
        expect(feedback['ok'], isFalse);
        expect(feedback['code'], 'plan_check_failed');
        expect((feedback['check'] as Map)['ok'], isFalse);
        final errors = (feedback['errors']! as List<Object?>)
            .cast<Map<String, Object?>>();
        expect(
          errors.any((e) => e['code'] == 'host_safety' && e['fix'] == '替换该动作。'),
          isTrue,
        );
        return LlmResponse(
          content: '',
          finishReason: 'tool_calls',
          model: 'fake',
          toolCalls: [
            LlmToolCall(
              id: 'ask',
              name: AgentTools.askUser,
              arguments: jsonEncode({'question': '需要换一个动作吗？', 'mode': 'text'}),
            ),
          ],
        );
      },
    ], latency: Duration.zero);
    final agent = CoachAgent(
      client: client,
      catalog: () => published,
      profile: loadProfile('smartfit'),
      enableUserMemory: false,
      maxRequestRetries: 0,
      extraRules: [denyMat],
    );
    addTearDown(agent.dispose);
    final turn = await agent.send('在家有瑜伽垫10分钟做髋部放松');
    expect(turn.question, isNotNull, reason: '${turn.issues}; ${turn.error}');
    expect(turn.plan, isNull);
    expect(ruleCalls, 1);
    expect(agent.sessionState.plans[flow.planId]!.last.check!['ok'], isFalse);
    expect(
      agent.sessionState.task!.nodes
          .singleWhere((node) => node.status == 'current')
          .id,
      'planning',
    );
  });
}
