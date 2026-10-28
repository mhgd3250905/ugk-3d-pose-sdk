import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/prompt/prompts.g.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  test('embedded prompt and plan skill match their sources', () {
    expect(
      agentKernelMarkdown,
      File('prompts/agent_kernel.md').readAsStringSync(),
    );
    expect(
      builtinSkillMarkdown['plan-training'],
      File('skills/plan-training/SKILL.md').readAsStringSync(),
    );
  });

  test(
    'first request defines types and each task skill owns its batch path',
    () async {
      final catalog = loadCatalog();
      for (final name in ['smartfit', 'hiplab', 'flarelab']) {
        final client = FakeLlmClient(['你好。'], latency: Duration.zero);
        final coach = CoachAgent(
          client: client,
          catalog: () => catalog,
          profile: loadProfile(name),
          enableUserMemory: false,
          maxRequestRetries: 0,
        );
        addTearDown(coach.dispose);
        await coach.send('你好');
        final system = client.requests.single.messages.first.content;
        expect(
          builtinSkillMarkdown['action-coaching'],
          contains(
            '推荐标准路径 start_task(recommend) → set_params → search_actions → show_actions',
          ),
        );
        expect(
          builtinSkillMarkdown['plan-training'],
          contains(
            '标准路径 start_task → set_params → search_actions → draft_plan → show_plan',
          ),
        );
        expect(
          builtinSkillMarkdown['plan-training'],
          contains('代码绑定当前 plan_id'),
        );
        expect(
          builtinSkillMarkdown['action-library'],
          isNot(contains('推荐标准路径')),
        );
        final start = client.requests.single.tools.singleWhere(
          (tool) => tool.name == 'start_task',
        );
        final type = (start.parameters['properties'] as Map)['type'] as Map;
        expect(type['description'], contains('两者都合理时由模型判断'));
        expect(system, contains('show_* 成功即结束'));
        expect(system, isNot(contains('check_plan 仅当前工具列表提供时可用')));
        expect(system, isNot(contains('信息足够或已结束询问后直接 show_plan')));
      }
    },
  );
}
