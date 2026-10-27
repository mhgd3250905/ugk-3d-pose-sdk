import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

class _RecordingStore extends InMemoryUserMemoryStore {
  int saves = 0;

  @override
  Future<void> save(List<MemoryEntry> entries) async {
    saves++;
    await super.save(entries);
  }
}

void main() {
  final catalog = loadCatalog();
  final builder = AgentPromptBuilder();
  // Existing parameter-contract snapshots exclude descriptions and the additive
  // 0.4 ask_user tool; its schema is covered separately. Memory isolation is below.
  const fingerprints = <String, String>{
    'flarelab':
        '099569b1c2a18f49db9d04f0985bc0e8273ed7997401e82d980e65acd664d39a',
    'hiplab':
        '4cac33f42e4c6d5a61156527140c7e11e227b8601539022c2e6807ec590b6f82',
    'smartfit':
        'a4de7cabed86983039a0233d8a3e61b20f4696bb5a3f12ca58f686b14d67a100',
  };

  for (final entry in fingerprints.entries) {
    test(
      'memory=false ${entry.key} preserves tool contract and excludes memory',
      () {
        final profile = loadProfile(entry.key);
        final system = builder.system(
          profile,
          SkillFiles.build(profile, catalog, memory: false),
          memory: false,
        );
        final tools = jsonEncode([
          for (final tool in AgentTools.build(profile, catalog, memory: false))
            if (tool.name != AgentTools.askUser &&
                tool.name != AgentTools.setParams &&
                tool.name != AgentTools.startTask &&
                tool.name != AgentTools.check &&
                tool.name != AgentTools.searchActions &&
                tool.name != AgentTools.getAction &&
                tool.name != AgentTools.draftPlan)
              {'name': tool.name, 'parameters': tool.parameters},
        ]);
        expect(sha256.convert(utf8.encode(tools)).toString(), entry.value);
        expect(system, isNot(contains('必须先用 read 读 user-memory')));
        expect(system, isNot(contains('# 用户记忆（')));
        expect(system, isNot(contains('remember')));
        expect(system, isNot(contains('forget')));
        expect(system, contains('排计划快路径'));
      },
    );
  }

  test(
    'memory=true requires reading and remembering stable facts before confirmation, with no unsolicited plan',
    () {
      final profile = loadProfile('smartfit');
      final system = builder.system(
        profile,
        SkillFiles.build(profile, catalog),
        memory: true,
        memorySummary: '- goal：长期提升力量',
      );
      expect(system, contains('必须先用 read 读 user-memory/SKILL.md'));
      expect(system, contains('只有记忆工具返回 ok=true 后才能确认'));
      expect(system, contains('不把 App 条件、预选、模型推断或一次临时请求当作长期习惯'));
      expect(system, contains('历史习惯只能作为预选'));
      expect(system, contains('长期提升力量'));
    },
  );

  test(
    'read → remember(level/equipment) → confirmation persists both facts and later supplies their summary',
    () async {
      final profile = loadProfile('smartfit');
      final store = _RecordingStore();
      LlmToolCall call(String id, String name, Map<String, Object?> args) =>
          LlmToolCall(id: id, name: name, arguments: jsonEncode(args));
      final client = FakeLlmClient([
        LlmResponse(
          content: '',
          toolCalls: [
            call('read-memory', 'read', {'path': 'user-memory/SKILL.md'}),
          ],
        ),
        LlmResponse(
          content: '',
          toolCalls: [
            call('level', 'remember', {'kind': 'level', 'text': '新手'}),
            call('equipment', 'remember', {
              'kind': 'equipment',
              'text': '家里有哑铃',
            }),
          ],
        ),
        '记下了，之后安排训练会参考。',
        '想练哪个部位？',
      ]);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        memoryStore: store,
      );
      addTearDown(agent.dispose);
      final result = await agent.send('我是新手，家里有哑铃');
      expect(result.status, TurnStatus.ok);
      expect(result.steps, 3);
      expect(result.reads, ['user-memory/SKILL.md']);
      expect(result.actions, isNull);
      expect(result.plan, isNull);
      expect(result.text, '记下了，之后安排训练会参考。');
      await Future<void>.delayed(Duration.zero);
      expect(store.saves, 2);
      expect(store.entries.map((e) => e.kind), [
        MemoryKind.level,
        MemoryKind.equipment,
      ]);
      expect(store.entries.map((e) => e.text), ['新手', '家里有哑铃']);
      agent.reset();
      expect((await agent.send('排个计划')).status, TurnStatus.ok);
      final nextSystem = client.requests.last.messages.first.content;
      expect(nextSystem, contains('- level：新手'));
      expect(nextSystem, contains('- equipment：家里有哑铃'));
    },
  );
}
