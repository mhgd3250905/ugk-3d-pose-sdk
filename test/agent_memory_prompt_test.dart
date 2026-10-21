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
  // Captured at 712cb7b, whose three memory-disabled real Worker cases passed.
  const fingerprints = <String, ({String system, String tools})>{
    'flarelab': (
      system:
          '3860ef070e9e885247c173a25e949be32fbd547408a733a084b980be2fe4ce13',
      tools: 'b035aa77f112d6cca51f53b9b55e9cf467131c4a5d87b1cb4fe94c8670634c40',
    ),
    'hiplab': (
      system:
          '411c27d298b3ef79a80dfa9c90b33ee4c870f46172a3371700539c282b537153',
      tools: '79ca9c9b1d493bb5d1fd07335fff88eed7f222d8af8e36e2c04ff8c45e70a80a',
    ),
    'smartfit': (
      system:
          '99161e6148497930c4f61957d8a96374a8453c6cae8a8af613b75daf1dd6ee3a',
      tools: '631f46fc38169a6784276c3ac6b2bfb2cbe1901a4ce290e4b07fd130bc91d426',
    ),
  };

  for (final entry in fingerprints.entries) {
    test(
      'memory=false ${entry.key} system/tools remain byte-identical to 712cb7b',
      () {
        final profile = loadProfile(entry.key);
        final system = builder.system(
          profile,
          SkillFiles.build(profile, catalog, memory: false),
          memory: false,
        );
        final tools = jsonEncode([
          for (final tool in AgentTools.build(profile, catalog, memory: false))
            tool.toJson(),
        ]);
        expect(
          sha256.convert(utf8.encode(system)).toString(),
          entry.value.system,
        );
        expect(
          sha256.convert(utf8.encode(tools)).toString(),
          entry.value.tools,
        );
        expect(system, isNot(contains('必须先用 read 读 user-memory')));
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
