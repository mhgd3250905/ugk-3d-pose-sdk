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
  // Parameter-contract snapshots exclude tool descriptions, which deliberately
  // change with the fast-path instructions. Memory isolation is semantic below.
  const fingerprints = <String, String>{
    'flarelab':
        '8783e526cfcd5cb2f8ae1d65c95cae9f405c0a098b233fa6a1dae377c9628a01',
    'hiplab':
        '705a48ebbc16ff32852cc0959bc5e6831503dd6b91953d5e8a767b2bdcd3289b',
    'smartfit':
        'bbb6e330b53dfe4c0a9288f2ececdef91efa12863e82de9cb3780ed91bd7da93',
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
      expect(
        system,
        contains('必须先用 read 读 user-memory/SKILL.md，再按类别逐条调用 remember'),
      );
      expect(system, contains('remember(kind=level, text=新手)'));
      expect(system, contains('remember(kind=equipment, text=家里有哑铃)'));
      expect(system, contains('只有记忆工具返回 ok=true 后才能确认'));
      expect(system, contains('未要求找动作/排计划，且对话中没有待完成的训练请求'));
      expect(system, contains('本轮不调用 show_actions / show_plan'));
      expect(system, contains('若用户同时明确要求训练，先记下稳定事实，再继续该训练任务'));
      expect(system, contains('不要从一次训练请求推断长期习惯'));
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
