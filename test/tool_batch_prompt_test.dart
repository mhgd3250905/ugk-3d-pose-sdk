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
    'actual agent request describes ordered batches and terminal ask',
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
          system,
          contains(
            'start_task + check(understand) + set_params + check(parameters)',
          ),
        );
        expect(
          system,
          contains(
            'check(actions, picks) + draft_plan + check(planning) + check_plan + check(review) + show_plan',
          ),
        );
        expect(system, contains('使用 start_task 返回的 plan_id'));
        expect(system, contains('ask_user 排最后'));
        expect(system, contains('失败后其余跳过'));
        expect(system, contains('show_* 成功即结束'));
        expect(system, isNot(contains('check_plan 仅当前工具列表提供时可用')));
        expect(system, isNot(contains('信息足够或已结束询问后直接 show_plan')));
      }
    },
  );
}
