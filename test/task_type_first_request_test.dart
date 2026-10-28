import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  test(
    'first model request explains both task types before any skill read',
    () async {
      final client = FakeLlmClient([const LlmResponse(content: '先了解一下。')]);
      final agent = CoachAgent(
        client: client,
        catalog: loadCatalog,
        profile: loadProfile('smartfit'),
      );
      addTearDown(agent.dispose);
      await agent.send('在家徒手 20 分钟练核心');
      final first = client.requests.single;
      final start = first.tools.singleWhere(
        (t) => t.name == AgentTools.startTask,
      );
      final type = (start.parameters['properties'] as Map)['type'] as Map;
      expect(type['enum'], ['recommend', 'plan']);
      expect(type['description'], contains('给几个动作让用户挑选或尝试'));
      expect(type['description'], contains('有时长和结构、可以跟练的一整套训练'));
      expect(type['description'], contains('两者都合理时由模型判断'));
      expect(first.messages.where((m) => m.role == LlmRole.tool), isEmpty);
      expect(first.messages.first.content, isNot(contains('推荐标准路径')));
      final draft = first.tools.singleWhere(
        (t) => t.name == AgentTools.draftPlan,
      );
      final title = (draft.parameters['properties'] as Map)['title'] as Map;
      expect(title['description'], contains('不写时长、动作数、组数'));
    },
  );

  test(
    'title guidance is disclosed in the plan skill without numeric rewriting',
    () {
      final files = SkillFiles.build(loadProfile('smartfit'), loadCatalog());
      expect(
        files.read('plan-training/SKILL.md'),
        contains('标题只写名称，不写时长、动作数、组数'),
      );
      final start = AgentTools.build(
        loadProfile('smartfit'),
        loadCatalog(),
        memory: false,
      ).singleWhere((t) => t.name == AgentTools.startTask);
      expect(jsonEncode(start.parameters), isNot(contains('minutes')));
    },
  );
}
