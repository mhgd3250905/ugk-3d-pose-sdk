import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

var _seq = 0;
LlmToolCall _call(String name, Object args) =>
    LlmToolCall(id: 'c${_seq++}', name: name, arguments: args is String ? args : jsonEncode(args));

LlmResponse _tools(List<LlmToolCall> calls, [String text = '']) =>
    LlmResponse(content: text, toolCalls: calls, finishReason: 'tool_calls', model: 'fake');

LlmResponse _read(String path) => _tools([
  _call('read', {'path': path}),
]);

LlmResponse _showActions(List<String> ids, [String text = '这几个动作可以看看。']) => _tools([
  _call('show_actions', {
    'items': [
      for (final id in ids) {'actionId': id},
    ],
  }),
], text);

Map<String, Object?> _okPlan() => planOf(okEnvelope())..remove('source');

void main() {
  final catalog = loadCatalog();
  final hiplab = loadProfile('hiplab');

  CoachAgent agent(
    FakeLlmClient c, {
    bool memory = true,
    UserMemoryStore? store,
    int maxSteps = 10,
    SessionFallback? fallback,
  }) => CoachAgent(
    client: c,
    catalog: () => catalog,
    profile: hiplab,
    enableUserMemory: memory,
    memoryStore: store,
    maxSteps: maxSteps,
    fallback: fallback,
  );

  group('虚拟文件系统', () {
    final fs = SkillFiles.build(hiplab, catalog);
    final scope = {for (final d in hiplab.scope(catalog)) d.id};

    Set<String> idsIn(String path) => {for (final l in fs.read(path)!.split('\n').skip(2)) l.split('｜').first};

    test('只出现白名单内的动作', () {
      final outside = catalog.drills.where((d) => !scope.contains(d.id)).map((d) => d.id).toList();
      expect(outside, isNotEmpty);
      final details = {
        for (final p in fs.files.keys)
          if (p.startsWith('action-library/details/')) p.split('/').last.replaceAll('.md', ''),
      };
      expect(details, scope);
      for (final p in fs.files.keys.where((p) => p.contains('/index/'))) {
        expect(scope.containsAll(idsIn(p)), isTrue, reason: p);
      }
      expect(fs.read('action-library/details/abs-A.md'), isNull);
    });

    test('索引取交集与直接按标签筛选一致', () {
      final both = idsIn(
        'action-library/index/scene/office.md',
      ).intersection(idsIn('action-library/index/equipment/chair.md'));
      final expected = {
        for (final d in hiplab.scope(catalog))
          if (d.scenes.contains('office') && d.equipment.contains('chair')) d.id,
      };
      expect(both, expected);
      expect(both, isNotEmpty);
      final knee = idsIn('action-library/index/caution/knee.md');
      expect(knee, {
        for (final d in hiplab.scope(catalog))
          if (d.cautions.contains('膝')) d.id,
      });
      expect(idsIn('action-library/index/equipment/none.md'), {
        for (final d in hiplab.scope(catalog))
          if (d.equipment.isEmpty) d.id,
      });
    });

    test('SKILL.md 列出维度取值；ls / 路径规范化；记忆关时没有 user-memory', () {
      final lib = fs.read('/action-library/SKILL.md')!;
      expect(lib, contains('knee=膝'));
      expect(lib, contains('scene（场所'));
      expect(lib, isNot(contains('{{')));
      expect(fs.ls(''), containsAll(['action-library/', 'plan-training/', 'user-memory/']));
      expect(fs.ls('action-library/index'), contains('scene/'));
      final off = SkillFiles.build(hiplab, catalog, memory: false);
      expect(off.read('user-memory/SKILL.md'), isNull);
      expect(off.skills.map((s) => s.name), isNot(contains('user-memory')));
    });

    test('profile.skills 挂成 App 专属 skill', () {
      final p = CoachProfile.fromJson({
        ...hiplab.toJson(),
        'skills': [
          {
            'name': 'sleep-routine',
            'description': '睡前流程',
            'content': '# 睡前',
            'files': {'notes.md': 'x'},
          },
        ],
      });
      final f = SkillFiles.build(p, catalog);
      expect(f.read('sleep-routine/SKILL.md'), '# 睡前');
      expect(f.read('sleep-routine/notes.md'), 'x');
      expect(
        AgentPromptBuilder().system(p, f, memory: true),
        contains('sleep-routine — 睡前流程 — sleep-routine/SKILL.md'),
      );
    });
  });

  group('第 1 层', () {
    test('系统提示词不含动作表，工具不带 id enum；记忆开关控制工具和摘要', () {
      final fs = SkillFiles.build(hiplab, catalog);
      final sys = AgentPromptBuilder().system(hiplab, fs, memory: true, memorySummary: '- injury：左膝疼');
      expect(sys, isNot(contains('s-figure4')));
      expect(sys, contains(defaultPromptCanary));
      expect(sys, contains('左膝疼'));
      final tools = jsonEncode([for (final t in AgentTools.build(hiplab, catalog, memory: true)) t.toJson()]);
      expect(tools, isNot(contains('s-figure4')));
      expect(tools, contains('"remember"'));
      final off = AgentPromptBuilder().system(
        hiplab,
        SkillFiles.build(hiplab, catalog, memory: false),
        memory: false,
        memorySummary: '- injury：左膝疼',
      );
      expect(off, isNot(contains('左膝疼')));
      expect(off, isNot(contains('remember')));
      final offTools = AgentTools.build(hiplab, catalog, memory: false).map((t) => t.name);
      expect(offTools, ['read', 'ls', 'check_plan', 'show_actions', 'show_plan']);
    });
  });

  group('循环', () {
    test('多步：读 SKILL → 读索引 → show_actions，事件、reads、历史只留最终交付', () async {
      final c = FakeLlmClient([
        _read('action-library/SKILL.md'),
        _tools([
          _call('read', {'path': 'action-library/index/muscle/glute-max.md'}),
          _call('read', {'path': 'action-library/SKILL.md'}),
        ]),
        _showActions(['s-figure4', 'h-knee-hug']),
      ]);
      final a = agent(c);
      final events = <AgentEvent>[];
      a.events.listen(events.add);
      final r = await a.send('练臀有哪些动作？');
      expect(r.status, TurnStatus.ok);
      expect(r.actions!.items.map((i) => i.id), ['s-figure4', 'h-knee-hug']);
      expect(r.steps, 3);
      expect(r.reads, ['action-library/SKILL.md', 'action-library/index/muscle/glute-max.md']);
      expect(r.records.map((x) => x.outcome), [CallOutcome.toolStep, CallOutcome.toolStep, CallOutcome.passed]);
      // 重复读返回简短提示。
      final third = c.requests[2].messages.where((m) => m.role == LlmRole.tool).map((m) => m.content).toList();
      expect(third.last, contains('已读过'));
      expect(events.map((e) => e.kind), [
        AgentEventKind.thinking,
        AgentEventKind.reading,
        AgentEventKind.thinking,
        AgentEventKind.reading,
        AgentEventKind.reading,
        AgentEventKind.thinking,
        AgentEventKind.done,
      ]);
      expect(a.history.length, 3); // user + assistant(show_actions) + tool
      expect(a.history[1].toolCalls.single.name, 'show_actions');
      expect(a.turnCount, 1);
    });

    test('纯文字直接结束', () async {
      final a = agent(FakeLlmClient(['想练哪个部位？在家还是办公室？']));
      final r = await a.send('练练');
      expect(r.status, TurnStatus.ok);
      expect(r.text, contains('部位'));
      expect(r.steps, 1);
    });

    test('步数超限回落', () async {
      final c = FakeLlmClient([for (var i = 0; i < 3; i++) _read('action-library/details/s-figure4.md')]);
      final a = agent(c, maxSteps: 3, fallback: (req) => const SessionFallbackReply('模板回复'));
      final r = await a.send('排个计划');
      expect(r.status, TurnStatus.fallback);
      expect(r.text, '模板回复');
      expect(r.error, isA<AgentStepLimitExceeded>());
      expect(c.requests.length, 3);
    });

    test('网络错回落；没配回落返回 error', () async {
      final a = agent(FakeLlmClient([const LlmException(LlmErrorKind.network, 'down')]));
      final r = await a.send('排个计划');
      expect(r.status, TurnStatus.error);
      expect(r.fallbackReason, FallbackReason.offline);
      expect(a.history, isEmpty);
    });

    test('门禁不过：错误回给模型，读索引后重交通过', () async {
      final c = FakeLlmClient([
        _showActions(['made-up-id']),
        _read('action-library/index/scene/home.md'),
        _showActions(['s-figure4']),
      ]);
      final r = await agent(c).send('臀部拉伸怎么做');
      expect(r.status, TurnStatus.ok);
      expect(r.submissions, 2);
      expect(r.records.map((x) => x.turnOutcome).toSet(), {TurnOutcome.rewritten});
      final fb = jsonDecode(c.requests[1].messages.last.content) as Map;
      expect(fb['ok'], false);
      expect(jsonEncode(fb), contains('unknown_exercise'));
      expect(jsonEncode(fb), contains('action-library'));
    });

    test('白名单外的 id 也被门禁拦下（重交用尽回落）', () async {
      final c = FakeLlmClient([
        for (var i = 0; i < 3; i++) _showActions(['abs-A']),
      ]);
      final r = await agent(c, fallback: (_) => const SessionFallbackReply('t')).send('x');
      expect(r.status, TurnStatus.fallback);
      expect(r.issues.map((i) => i.code), contains(IssueCodes.outOfProfile));
    });

    test('暗号泄露回落', () async {
      final r = await agent(
        FakeLlmClient(['好的 $defaultPromptCanary']),
        fallback: (_) => const SessionFallbackReply('t'),
      ).send('x');
      expect(r.status, TurnStatus.fallback);
      expect(r.leaked, isTrue);
    });
  });

  group('check_plan', () {
    test('合法计划返回 ok、估算时长与差值；坏 id 返回错误', () async {
      final bad = _okPlan();
      (((bad['blocks']! as List)[0] as Map)['items'] as List)[0] = {
        'exerciseId': 'nope',
        'mode': 'reps',
        'sets': 1,
        'reps': 8,
        'perSide': false,
        'restSeconds': 10,
      };
      final c = FakeLlmClient([
        _tools([_call('check_plan', bad)]),
        _tools([
          _call('check_plan', {'plan': _okPlan()}),
        ]),
        _tools([_call('show_plan', _okPlan())], '给你排了 10 分钟。'),
      ]);
      final events = <AgentEventKind>[];
      final a = agent(c)..events.listen((e) => events.add(e.kind));
      final r = await a.send('睡前开胯 10 分钟');
      expect(r.status, TurnStatus.ok);
      expect(r.plan, isNotNull);
      final first = jsonDecode(c.requests[1].messages.last.content) as Map;
      expect(first['ok'], false);
      expect(jsonEncode(first['errors']), contains('unknown_exercise'));
      final second = jsonDecode(c.requests[2].messages.last.content) as Map;
      expect(second['ok'], true);
      expect(second['targetMinutes'], 10);
      expect(second['estimatedMinutes'], isA<num>());
      expect(second['diffMinutes'], closeTo((second['estimatedMinutes'] as num) - 10, 0.11));
      expect(events.where((e) => e == AgentEventKind.checking).length, 2);
    });
  });

  group('并发 / 取消', () {
    test('busy：进行中再 send 被拒', () async {
      final gate = Completer<Object>();
      final a = agent(FakeLlmClient([(_) => gate.future]));
      final first = a.send('a');
      expect(a.isBusy, isTrue);
      final second = await a.send('b');
      expect(second.status, TurnStatus.busy);
      gate.complete('好');
      expect((await first).status, TurnStatus.ok);
    });

    test('reset 后旧轮不回写（含记忆）', () async {
      final gate = Completer<Object>();
      final store = InMemoryUserMemoryStore();
      final c = FakeLlmClient([
        _tools([
          _call('remember', {'kind': 'injury', 'text': '左膝疼'}),
        ]),
        (_) => gate.future,
      ]);
      final a = agent(c, store: store);
      final events = <AgentEvent>[];
      a.events.listen(events.add);
      final f = a.send('我左膝疼');
      while (c.requests.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      a.reset();
      gate.complete('好的');
      final r = await f;
      expect(r.status, TurnStatus.cancelled);
      expect(a.history, isEmpty);
      expect(a.turnCount, 0);
      expect(store.entries, isEmpty);
      expect(events.where((e) => e.kind == AgentEventKind.done), isEmpty);
    });

    test('取消令牌：返回 cancelled、不写历史', () async {
      final token = CancelToken();
      final c = FakeLlmClient([
        (_) {
          token.cancel();
          return _read('action-library/SKILL.md');
        },
      ]);
      final a = agent(c);
      final r = await a.send('x', cancel: token);
      expect(r.status, TurnStatus.cancelled);
      expect(a.history, isEmpty);
    });
  });

  group('用户记忆', () {
    test('开：remember 在本轮提交后写入，下一轮进系统提示词；forget 删除', () async {
      final store = InMemoryUserMemoryStore();
      final c = FakeLlmClient([
        _tools([
          _call('remember', {'kind': 'injury', 'text': '左膝跑步后疼'}),
          _call('remember', {'kind': 'goal', 'text': '想劈叉'}),
        ]),
        '记住了，之后排课会避开膝盖负担大的动作。',
        _tools([
          _call('forget', {'kind': 'goal'}),
        ]),
        '好的。',
      ]);
      final a = agent(c, store: store);
      await a.send('我左膝跑步后疼，想劈叉');
      await Future<void>.delayed(Duration.zero);
      expect(store.entries.map((e) => e.text), ['左膝跑步后疼', '想劈叉']);
      await a.send('不想劈叉了');
      expect(c.requests[2].messages.first.content, contains('左膝跑步后疼'));
      await Future<void>.delayed(Duration.zero);
      expect(store.entries.map((e) => e.kind), [MemoryKind.injury]);
      await a.clearMemory();
      expect(store.entries, isEmpty);
    });

    test('关：没有 remember 工具，调用被当成未知工具，不写记忆', () async {
      final store = InMemoryUserMemoryStore([MemoryEntry(MemoryKind.goal, '想劈叉', at: DateTime.utc(2026))]);
      final c = FakeLlmClient([
        _tools([
          _call('remember', {'kind': 'injury', 'text': '左膝疼'}),
        ]),
        '好的。',
      ]);
      final a = agent(c, store: store, memory: false);
      final r = await a.send('我左膝疼');
      expect(r.status, TurnStatus.ok);
      expect(c.requests.first.tools.map((t) => t.name), isNot(contains('remember')));
      expect(c.requests.first.messages.first.content, isNot(contains('想劈叉')));
      expect(c.requests[1].messages.last.content, contains('没有工具'));
      expect(store.entries.map((e) => e.text), ['想劈叉']);
      // 运行时打开
      a.enableUserMemory = true;
      expect(a.files().read('user-memory/SKILL.md'), isNotNull);
    });

    test('去重替换、每类条数与总长度上限', () {
      const lim = MemoryLimits(perKind: 2, maxTotalChars: 20, maxEntryChars: 10);
      final t = DateTime.utc(2026);
      var m = <MemoryEntry>[];
      m = UserMemoryOps.remember(m, MemoryEntry(MemoryKind.injury, '左膝疼', at: t), lim);
      m = UserMemoryOps.remember(m, MemoryEntry(MemoryKind.injury, '左膝疼，跑步后', at: t), lim);
      expect(m.map((e) => e.text), ['左膝疼，跑步后']);
      m = UserMemoryOps.remember(m, MemoryEntry(MemoryKind.injury, '腰酸', at: t), lim);
      m = UserMemoryOps.remember(m, MemoryEntry(MemoryKind.injury, '肩紧', at: t), lim);
      expect(m.map((e) => e.text), ['腰酸', '肩紧']);
      m = UserMemoryOps.remember(m, MemoryEntry(MemoryKind.goal, '一二三四五六七八九十十一', at: t), lim);
      expect(m.last.text.length, 10);
      expect(m.fold(0, (s, e) => s + e.text.length), lessThanOrEqualTo(20));
      expect(UserMemoryOps.forget(m, text: '腰酸').map((e) => e.text), isNot(contains('腰酸')));
    });
  });
}
