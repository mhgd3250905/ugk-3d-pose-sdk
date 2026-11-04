import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_coach/ugk_coach_qa_v2.dart';

// 宿主的 QA 状态持久化（packages/ugk_coach_chat 里的纯 Dart 文件，按路径引用以验证存取兼容；
// 该包依赖 Flutter，SDK 根目录的 dart test 无法以 package: 方式引用）。
// ignore: avoid_relative_lib_imports
import '../../packages/ugk_coach_chat/lib/src/core/qa_state.dart';

/// 模型的一步：调用工具 (name, args)，或直接输出文字（String）。
typedef _Act = Object Function(LlmRequest request);

/// 桩模型：按脚本顺序一步一步回；每步可以读到整份请求（含之前的 tool result）。只验证代码路径。
class _Stub implements LlmClient {
  _Stub(List<_Act> script) : _script = [...script];
  final List<_Act> _script;
  final requests = <LlmRequest>[];
  @override
  String get model => 'stub';
  @override
  Pricing? get pricing => null;
  @override
  Future<LlmResponse> complete(LlmRequest r, {CancelToken? cancel}) async {
    requests.add(r);
    if (_script.isEmpty) throw StateError('stub script exhausted at call ${requests.length}');
    final out = _script.removeAt(0)(r);
    if (out is String) return LlmResponse(content: out);
    final (name, args) = out as (String, Map<String, Object?>);
    return LlmResponse(content: '', toolCalls: [LlmToolCall(id: 'c${requests.length}', name: name, arguments: jsonEncode(args))]);
  }

  int get left => _script.length;
}

_Act _do(String tool, [Map<String, Object?> args = const {}]) => (_) => (tool, args);
_Act _fn(Object Function(LlmRequest r) f) => f;

/// 最后一条 tool result（上一次工具调用的结果或退回原因）。
String _lastResult(LlmRequest r) => r.messages.lastWhere((m) => m.role == LlmRole.tool).content;

/// 本轮上下文（带 [用户这句话] 的那条 user 消息）。
String _ctx(LlmRequest r) => r.messages.lastWhere((m) => m.role == LlmRole.user && m.content.contains('[用户这句话]')).content;

/// 文本里的动作行 id（`id | …`）。
List<String> _rows(String text) => [
  for (final l in const LineSplitter().convert(text))
    if (RegExp(r'^[\w-]+ \| ').hasMatch(l)) l.split(' | ').first,
];

/// 最后一次搜索结果里的 id。
List<String> _found(LlmRequest r) => _rows(_lastResult(r));

/// 预选候选里的 id。
List<String> _pre(LlmRequest r) {
  final c = _ctx(r);
  return _rows(c.substring(c.indexOf('[预选候选]'), c.indexOf('[用户这句话]')));
}

Map<String, Object?> _items(List<String> ids) => {
  'text': 'ok',
  'items': [for (final id in ids) {'id': id, 'why': 'w'}],
  'chips': ['c'],
};

String _rejection(LlmRequest r) {
  final t = _lastResult(r);
  expect(t, startsWith('不合规：'));
  return t;
}

void main() {
  final meta = File('packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json');
  if (!meta.existsSync()) return;
  final m = PoseHubAppTestCatalog.fromBytes(meta.readAsBytesSync());
  final sem = File('${meta.parent.path}/${m.semanticCatalogFile.path}').readAsBytesSync();
  final catalog = PoseHubAppTestCatalog.fromBytes(meta.readAsBytesSync(), semanticCatalogBytes: sem).toAiCatalog();
  final profile = CoachProfile.fromJson(jsonDecode(File('profiles/smartfit.json').readAsStringSync()));
  final tagDir = Directory('../../pose-hub/catalog/ai-tags/actions');
  final tags = !tagDir.existsSync()
      ? const <String, Map<String, Object?>>{}
      : {
          for (final f in tagDir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')))
            for (final j in [jsonDecode(f.readAsStringSync()) as Map<String, Object?>]) j['id'] as String: j,
        };
  CoachQaAgent make(_Stub c, {CoachQaMemory memory = const CoachQaMemory()}) =>
      CoachQaAgent(client: c, catalog: catalog, profile: profile, aiTags: tags, memory: memory);

  /// 让 [ids] 配时落进 ±12% 的分钟数（模型看到时长退回后会这样改 minutes）。
  int fitMinutes(CoachQaAgent agent, List<String> ids, {List<String> warm = const [], List<String> cool = const []}) {
    for (var minutes = 3; minutes <= 60; minutes++) {
      final r = agent.builder.build(mainIds: ids, minutes: minutes, base: QaQuery(scene: 'gym', equipment: const {}, strict: true), warmIds: warm, coolIds: cool);
      if (QaPlanBuilder.deviation(r).abs() <= 0.12) return minutes;
    }
    throw StateError('no fitting minutes for $ids');
  }

  /// 健身房里的一套：先 search，再 build_plan（时长按 [fitMinutes]）。
  Future<(CoachQaAgent, _Stub, CoachQaReply)> gymPlan({List<String> Function(List<String> found)? pick, Map<String, Object?> extra = const {}}) async {
    late CoachQaAgent agent;
    final c = _Stub([
      _do('set_conditions', {'place': 'gym'}),
      _do('search_actions', {'muscles': ['quadriceps', 'glute-max'], 'limit': 12}),
      _fn((r) {
        final ids = (pick ?? (f) => f.take(4).toList())(_found(r));
        return ('build_plan', {'mode': 'new', 'title': 't', 'text': 'x', 'minutes': fitMinutes(agent, ids), 'main_ids': ids, 'chips': <String>[], ...extra});
      }),
    ]);
    agent = make(c);
    final r = await agent.send('健身房练腿');
    return (agent, c, r);
  }

  // ------------------------------------------------------------------ 基础

  test('SOP markdown and generated constant are identical', () {
    expect(coachQaSop, File('lib/src/qa_v2/coach_qa_sop.md').readAsStringSync());
  });

  test('no language-dependent matching in qa_v2 code', () {
    final cjk = RegExp(r'[\u3040-\u30ff\u3400-\u9fff]');
    for (final f in Directory('lib/src/qa_v2').listSync().whereType<File>().where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'))) {
      for (final line in f.readAsLinesSync()) {
        if (RegExp(r'RegExp\(|\.contains\(|\.startsWith\(|\.hasMatch\(').hasMatch(line)) {
          expect(cjk.hasMatch(line), isFalse, reason: '${f.path}: $line');
        }
      }
    }
  });

  test('every request carries all tools, toolChoice auto and max thinking; OpenAI body merges extraBody last', () async {
    final c = _Stub([_do('reply', {'text': '30 到 60 秒。', 'chips': <String>[]})]);
    await make(c).send('平板支撑多久合适');
    expect(c.requests, hasLength(1));
    for (final r in c.requests) {
      expect(r.tools.map((t) => t.name), ['set_conditions', 'search_actions', 'ask_user', 'show_actions', 'build_plan', 'swap', 'reply']);
      expect(r.toolChoice, 'auto');
      expect(r.extraBody['reasoning_effort'], 'max');
      expect(r.extraBody['thinking'], {'type': 'enabled'});
      expect(r.messages.first.content, contains(coachQaSop));
    }
    final client = OpenAiCompatibleClient(
      config: LlmConfig(baseUrl: 'https://x', model: 'm', extraBody: {'thinking': {'type': 'disabled'}}),
      auth: ApiKeyAuth('k'),
    );
    final body = client.buildBody(LlmRequest(messages: [LlmMessage.user('hi')], extraBody: const {'thinking': {'type': 'enabled'}, 'reasoning_effort': 'max'}));
    expect(body['reasoning_effort'], 'max');
    expect(body['thinking'], {'type': 'enabled'});
  });

  // ------------------------------------------------------------------ 规格「测试」1–19

  test('1. place unknown → ask place; asking place again next turn is sent back', () async {
    final c = _Stub([
      _do('ask_user', {'step': 'place', 'question': 'Q-place', 'options': ['A', 'B', 'C', 'D']}),
      _do('ask_user', {'step': 'place', 'question': 'Q-again', 'options': ['A', 'B', 'C', 'D']}),
      _do('search_actions', {'muscles': ['quadriceps', 'glute-max'], 'limit': 12}),
      _fn((r) => ('show_actions', _items(_found(r).take(3).toList()))),
    ]);
    final agent = make(c);
    final r1 = await agent.send('想练腿');
    expect(r1.kind, 'ask');
    expect(r1.askStep, QaAskStep.place);
    expect(r1.text, 'Q-place');
    expect(r1.question!.multiple, isFalse);
    final r2 = await agent.send('随便');
    expect(_rejection(c.requests[2]), contains('上一轮刚问过 place'));
    expect(r2.kind, 'recommend', reason: '${r2.issues}');
    expect(r2.toolTrace, ['ask_user', 'search_actions', 'show_actions']);
  });

  test('2. home with unknown equipment → ask equipment; asking equipment at the gym is sent back', () async {
    final c = _Stub([
      _do('set_conditions', {'place': 'home'}),
      _do('ask_user', {'step': 'equipment', 'question': 'Q-eq', 'options': ['1', '2', '3', '4', '5', '6'], 'multi': true}),
    ]);
    final r = await make(c).send('在家练腿');
    expect(r.askStep, QaAskStep.equipment);
    expect(r.question!.multiple, isTrue);
    expect(r.question!.options, hasLength(6));

    final g = _Stub([
      _do('set_conditions', {'place': 'gym'}),
      _do('ask_user', {'step': 'equipment', 'question': 'Q-eq', 'options': ['1', '2']}),
      _fn((r) => ('show_actions', _items(_pre(r).take(3).toList()))),
    ]);
    final rg = await make(g).send('健身房练腿');
    expect(_rejection(g.requests[2]), contains('不能问器械'));
    expect(rg.kind, 'recommend');
  });

  test('3. place known from memory → asking place is sent back', () async {
    final c = _Stub([
      _do('ask_user', {'step': 'place', 'question': 'Q', 'options': ['A', 'B', 'C', 'D']}),
      _fn((r) => ('show_actions', _items(_pre(r).take(3).toList()))),
    ]);
    final agent = make(c, memory: const CoachQaMemory(scene: 'home', equipment: {'band'}));
    final r = await agent.send('练腿');
    expect(_rejection(c.requests[1]), contains('地点已知'));
    expect(r.kind, 'recommend');
    expect(r.conditions['placeSource'], 'memory');
    for (final card in r.cards) {
      expect(agent.index[card.id]!.requiredEquipment.difference({'band', ...homeAlwaysAvailable}), isEmpty, reason: card.id);
    }
  });

  test('4. a skipped question falls back to default conditions with placeSource=skipped', () async {
    final c = _Stub([
      _do('ask_user', {'step': 'place', 'question': 'Q', 'options': ['A', 'B', 'C', 'D']}),
      _do('search_actions', {'muscles': ['abs', 'obliques'], 'limit': 12}),
      _fn((r) => ('show_actions', {..._items(_found(r).take(3).toList()), 'assumption': 'as'})),
    ]);
    final agent = make(c);
    await agent.send('练腹');
    final r = await agent.send('直接推荐');
    expect(r.conditions['placeSource'], 'skipped', reason: '${r.issues}');
    expect(r.conditions['place'], 'home');
    expect(r.conditions['equipment'], isEmpty);
    expect(r.conditionsAssumed, isTrue);
    expect(r.assumption, 'as');
    for (final card in r.cards) {
      expect(agent.index[card.id]!.requiredEquipment.difference(homeAlwaysAvailable), isEmpty, reason: card.id);
    }
  });

  test('5. office: a floor move in show_actions is sent back', () async {
    late CoachQaAgent agent;
    late String floor;
    late final _Stub c;
    c = _Stub([
      _do('set_conditions', {'place': 'office', 'place_word': '公司'}),
      _do('search_actions', {'stretch_muscles': ['hamstrings', 'hip-flexors'], 'types': ['static-stretch']}),
      _fn((r) => ('show_actions', _items([floor, ..._found(r).take(2)]))),
      _fn((r) => ('show_actions', _items(_found(c.requests[2]).take(3).toList()))),
    ]);
    agent = make(c);
    floor = agent.index.all.firstWhere((a) => a.floorRequired).id;
    final r = await agent.send('办公室拉伸');
    expect(_rejection(c.requests[3]), allOf(contains(floor), contains('不符合用户当前条件')));
    expect(r.kind, 'recommend');
    for (final card in r.cards) {
      expect(agent.index[card.id]!.floorRequired, isFalse, reason: card.id);
    }
  });

  test('6. "seated ones too" → search_actions position=seated returns only seated moves', () async {
    late CoachQaAgent agent;
    final c = _Stub([
      _do('set_conditions', {'place': 'office'}),
      _do('search_actions', {'position': ['seated'], 'limit': 12}),
      _fn((r) {
        final ids = _found(r);
        expect(ids, isNotEmpty);
        for (final id in ids) {
          expect(agent.index[id]!.drill.position, 'seated', reason: id);
        }
        return ('show_actions', _items(ids.take(3).toList()));
      }),
    ]);
    agent = make(c);
    final r = await agent.send('还有坐椅子的吗');
    expect(r.kind, 'recommend');
    expect(r.cards.every((x) => agent.index[x.id]!.drill.position == 'seated'), isTrue);
  });

  test('7. 15 minutes with only 2 moves → duration deviation sent back; model adds moves; code never pads', () async {
    var tries = 0;
    late List<String> last;
    late final _Stub c;
    c = _Stub([
      _do('set_conditions', {'place': 'gym'}),
      _do('search_actions', {'muscles': ['chest'], 'limit': 12}),
      for (var k = 0; k < 6; k++)
        _fn((r) {
          tries++;
          last = _found(c.requests[2]).take(2 * tries).toList();
          return ('build_plan', {'mode': 'new', 'title': 't', 'text': 'x', 'minutes': 15, 'main_ids': last, 'chips': <String>[]});
        }),
    ]);
    final r = await make(c).send('练胸 15 分钟');
    expect(r.kind, 'plan');
    expect(tries, greaterThan(1));
    expect(_rejection(c.requests[3]), allOf(contains('偏差'), contains('建议再加')));
    expect(r.planOrderedIds, last, reason: 'exactly the moves the model gave, nothing padded');
    expect((r.planSeconds! / 900 - 1).abs(), lessThanOrEqualTo(0.12));
  });

  test('8. first half seated, second half standing → two segments kept in order', () async {
    final (agent, _, r) = await gymPlan(
      pick: (f) => f.take(4).toList(),
      extra: const {},
    );
    final ids = r.planMainIds;
    final c = _Stub([
      _do('build_plan', {
        'mode': 'retime', 'title': 't', 'text': 'x', 'minutes': r.plan!.targetMinutes, 'chips': <String>[],
        'segments': [
          {'name': 'A', 'ids': ids.take(2).toList()},
          {'name': 'B', 'ids': ids.skip(2).toList()},
        ],
      }),
    ]);
    final next = make(c)
      ..state.place = 'gym'
      ..state.placeSource = 'user'
      ..state.lastPlan = agent.state.lastPlan;
    final r2 = await next.send('前半坐着后半站着');
    expect(r2.kind, 'plan');
    expect(r2.plan!.blocks.map((b) => b.name).toList(), ['A', 'B']);
    expect(r2.planMainIds, ids);
  });

  test('9. "the order is wrong" → resubmitted order takes effect', () async {
    final (agent, _, r1) = await gymPlan();
    final c = _Stub([
      _do('build_plan', {'mode': 'retime', 'title': 't', 'text': 'x', 'minutes': r1.plan!.targetMinutes, 'main_ids': r1.planMainIds.reversed.toList(), 'chips': <String>[]}),
    ]);
    final next = make(c)
      ..state.place = 'gym'
      ..state.placeSource = 'user'
      ..state.lastPlan = agent.state.lastPlan;
    final r2 = await next.send('顺序不对，倒过来');
    expect(r2.planMainIds, r1.planMainIds.reversed.toList());
  });

  test('10. swap the Nth (warm-up position) → only that position changes', () async {
    late CoachQaAgent agent;
    final scope = QaQuery(scene: 'gym', equipment: const {}, strict: true);
    late String warm;
    late String replacement;
    final c = _Stub([
      _do('set_conditions', {'place': 'gym'}),
      _do('search_actions', {'roles': ['warmup'], 'limit': 12}),
      _fn((r) {
        for (final id in _found(r)) {
          final a = agent.index[id]!;
          final alt = agent.finder.swapCandidates(a, scope, role: 'warmup').where((b) => QaFinder.sameArea(a, b)).firstOrNull;
          if (alt != null) {
            warm = id;
            replacement = alt.id;
            break;
          }
        }
        return ('search_actions', {'muscles': ['quadriceps'], 'limit': 12, 'exclude': [warm, replacement]});
      }),
      _fn((r) {
        final mains = _found(r).take(4).toList();
        return ('build_plan', {'mode': 'new', 'title': 't', 'text': 'x', 'minutes': fitMinutes(agent, mains, warm: [warm]), 'main_ids': mains, 'warmup_ids': [warm], 'chips': <String>[]});
      }),
      _fn((_) => ('swap', {'mode': 'swap', 'text': 'x', 'changes': [{'position': 1, 'new_id': replacement, 'why': 'w'}], 'chips': <String>[]})),
    ]);
    agent = make(c);
    final r1 = await agent.send('练腿一套');
    expect(r1.plan!.blocks.first.type, BlockType.warmup);
    final before = r1.planOrderedIds;
    final r2 = await agent.send('换第 1 个');
    expect(r2.kind, 'replace');
    final after = r2.planOrderedIds;
    expect(after.length, before.length);
    expect([for (var k = 0; k < after.length; k++) if (after[k] != before[k]) k], [0]);
    expect(after.first, replacement);
  });

  test('11. no qualifying replacement → reply, the card stays', () async {
    final c = _Stub([
      _do('set_conditions', {'place': 'gym'}),
      _fn((r) => ('show_actions', _items(_pre(r).take(3).toList()))),
      _do('swap', {'mode': 'swap', 'text': 'x', 'changes': <Object>[], 'chips': <String>[]}),
      _do('reply', {'text': 'only N', 'chips': <String>[]}),
    ]);
    final agent = make(c);
    final r1 = await agent.send('练胸');
    final r2 = await agent.send('换第 2 个');
    expect(_rejection(c.requests[3]), contains('reply'));
    expect(r2.kind, 'answer');
    expect(r2.text, 'only N');
    expect(agent.state.lastShown, r1.cards.map((x) => x.id).toList());
  });

  test('12. easier with a harder move is sent back', () async {
    late CoachQaAgent agent;
    final c = _Stub([]);
    agent = make(c);
    final scope = QaQuery(scene: 'gym', equipment: const {}, strict: true);
    final inScope = agent.finder.inScope(scope);
    final card = inScope.firstWhere((a) =>
        agent.finder.swapCandidates(a, scope, mode: QaSwapMode.easier).isNotEmpty &&
        inScope.any((b) => b.difficulty > a.difficulty && QaFinder.sameArea(a, b)));
    final harder = inScope.firstWhere((b) => b.difficulty > card.difficulty && QaFinder.sameArea(card, b) && b.id != card.id);
    final easier = agent.finder.swapCandidates(card, scope, mode: QaSwapMode.easier).first;
    c._script.addAll([
      _do('swap', {'mode': 'easier', 'text': 'x', 'changes': [{'position': 1, 'new_id': harder.id, 'why': 'w'}], 'chips': <String>[]}),
      _do('swap', {'mode': 'easier', 'text': 'x', 'changes': [{'position': 1, 'new_id': easier.id, 'why': 'w'}], 'chips': <String>[]}),
    ]);
    agent.state
      ..place = 'gym'
      ..placeSource = 'user'
      ..lastShown = [card.id];
    final r = await agent.send('太难了');
    expect(_rejection(c.requests[1]), contains('要更简单'));
    expect(r.kind, 'easier');
    expect(r.cards.single.id, easier.id);
  });

  test('13. retime that changes the moves is sent back', () async {
    final (agent, _, r1) = await gymPlan();
    final mains = r1.planMainIds;
    final other = agent.state.seen.firstWhere((id) => !mains.contains(id));
    final c = _Stub([
      _do('build_plan', {'mode': 'retime', 'title': 't', 'text': 'x', 'minutes': r1.plan!.targetMinutes, 'main_ids': [other, ...mains.skip(1)], 'chips': <String>[]}),
      _do('build_plan', {'mode': 'retime', 'title': 't', 'text': 'x', 'minutes': r1.plan!.targetMinutes, 'main_ids': mains, 'chips': <String>[]}),
    ]);
    final next = make(c)
      ..state.place = 'gym'
      ..state.placeSource = 'user'
      ..state.lastPlan = agent.state.lastPlan;
    final r2 = await next.send('改成别的时长');
    expect(_rejection(c.requests[1]), allOf(contains('retime 不换动作'), contains(other)));
    expect(r2.planMainIds, mains);
  });

  test('14. "another one" repeating the previous set is sent back', () async {
    final (agent, _, r1) = await gymPlan();
    final mains = r1.planMainIds;
    final c = _Stub([
      _do('build_plan', {'mode': 'another', 'title': 't', 'text': 'x', 'minutes': r1.plan!.targetMinutes, 'main_ids': mains, 'chips': <String>[]}),
      _do('search_actions', {'muscles': ['quadriceps', 'glute-max'], 'exclude': mains, 'limit': 12}),
      _fn((r) {
        final ids = _found(r).take(4).toList();
        return ('build_plan', {'mode': 'another', 'title': 't', 'text': 'x', 'minutes': fitMinutes(agent, ids), 'main_ids': ids, 'chips': <String>[]});
      }),
    ]);
    final next = make(c)
      ..state.place = 'gym'
      ..state.placeSource = 'user'
      ..state.lastPlan = agent.state.lastPlan;
    final r2 = await next.send('再来一套');
    expect(_rejection(c.requests[1]), contains('不能和上一套重复'));
    expect(r2.planMainIds.toSet().intersection(mains.toSet()), isEmpty);
  });

  test('15. knowledge question → reply', () async {
    final c = _Stub([_do('reply', {'text': '一般 30–60 秒，保持身体成一条直线。', 'chips': ['怎么进阶']})]);
    final r = await make(c).send('平板支撑多久合适');
    expect(r.kind, 'answer');
    expect(r.cards, isEmpty);
    expect(r.llmCalls, 1);
  });

  test('16. confirmed shoulder red flag → reply with items is sent back', () async {
    final c = _Stub([
      _do('set_conditions', {'avoid_joints': ['shoulder'], 'red_flag': true}),
      _fn((r) => ('reply', {..._items(_pre(r).take(1).toList()), 'text': '先停训。'})),
      _do('reply', {'text': '先停止会引起刺痛的训练，安排专业评估。', 'chips': <String>[]}),
    ]);
    final agent = make(c);
    final r = await agent.send('肩一发力就刺痛还卡住');
    expect(_rejection(c.requests[2]), contains('items 必须为空'));
    expect(r.kind, 'answer');
    expect(r.cards, isEmpty);
    expect(agent.state.redFlag, isTrue);
    expect(agent.state.avoidJoints, contains('shoulder'));
  });

  test('17. text naming an off-card move is sent back, then delivered as written', () async {
    late CoachQaAgent agent;
    late String offName;
    late final _Stub c;
    c = _Stub([
      _do('set_conditions', {'place': 'gym'}),
      _do('search_actions', {'muscles': ['glute-max']}),
      _fn((r) {
        final ids = _found(r).take(3).toList();
        offName = agent.index.all
            .firstWhere((a) => !ids.contains(a.id) && (a.drill.name.values['zh'] ?? '').runes.length >= 5 && agent.offCardMentions(a.drill.name.values['zh']!, ids.toSet()).isNotEmpty)
            .drill
            .name
            .values['zh']!;
        return ('show_actions', {..._items(ids), 'text': '也可以试试$offName'});
      }),
      _fn((r) => ('show_actions', {..._items(_found(c.requests[2]).take(3).toList()), 'text': 'clean'})),
    ]);
    agent = make(c);
    final r = await agent.send('练臀');
    expect(_rejection(c.requests[3]), contains('正文提到了卡片外的动作'));
    expect(r.text, 'clean');
  });

  test('18. repeated rejections then a correct delivery; every reason reaches the following requests', () async {
    final c = _Stub([
      _do('set_conditions', {'place': 'gym'}),
      _fn((_) => 'I think these are good.'),
      _fn((r) => ('show_actions', _items(_pre(r).take(2).toList()))),
      _do('show_actions', {'text': 'ok', 'items': [{'id': 'not-a-move', 'why': 'w'}, {'id': 'x2', 'why': 'w'}, {'id': 'x3', 'why': 'w'}], 'chips': <String>[]}),
      _fn((r) => ('show_actions', _items(_pre(r).take(3).toList()))),
    ]);
    final r = await make(c).send('练胸');
    expect(r.kind, 'recommend');
    expect(r.cards, hasLength(3));
    expect(r.llmCalls, 5);
    final last = c.requests.last.messages.map((m) => m.content).join('\n');
    expect(last, contains('请调用工具交结果。'));
    expect(last, contains('items 要 3–5 个，现在 2 个'));
    expect(last, contains('这些 id 不存在：not-a-move'));
    expect(r.issues.where((i) => i.startsWith('show_actions rejected')), hasLength(2));
  });

  test('19. persistence: qa_state.dart roundtrip keeps the state, incl. a segmented plan', () async {
    late CoachQaAgent agent;
    final c = _Stub([
      _do('set_conditions', {'place': 'gym', 'avoid_joints': ['knee'], 'red_flag': false}),
      _do('search_actions', {'muscles': ['chest', 'lats'], 'limit': 12}),
      _fn((r) {
        final ids = _found(r).take(4).toList();
        return ('build_plan', {
          'mode': 'new', 'title': 't', 'text': 'x', 'minutes': fitMinutes(agent, ids), 'chips': <String>[],
          'segments': [
            {'name': 'A', 'ids': ids.take(2).toList()},
            {'name': 'B', 'ids': ids.skip(2).toList()},
          ],
        });
      }),
    ]);
    agent = make(c);
    final r = await agent.send('上下分段');
    expect(r.plan!.blocks.map((b) => b.name).toList(), ['A', 'B']);
    final json = jsonDecode(jsonEncode(encodeQaState(agent.state))) as Map<String, Object?>;
    final restored = make(_Stub([]));
    restoreQaState(restored.state, json, allowedIds: {for (final a in agent.index.all) a.id});
    expect(encodeQaState(restored.state), encodeQaState(agent.state));
    expect(restored.state.lastPlan!.plan.blocks.map((b) => b.name).toList(), ['A', 'B']);
    expect(restored.state.lastPlan!.orderedIds, r.planOrderedIds);
    expect(restored.state.avoidJoints, {'knee'});
  });

  // ------------------------------------------------------------------ 标签与范围

  test('swap candidates follow tags: same area, easier is easier, all in scope', () {
    final index = QaActionIndex(catalog, aiTags: tags);
    final finder = QaFinder(index, profile: profile);
    final q = QaQuery(scene: 'home', equipment: const {'dumbbell'}, strict: true);
    for (final a in index.all.where((a) => a.sessionRole.contains('main') && finder.passes(a, q)).take(20)) {
      for (final b in finder.swapCandidates(a, q, mode: QaSwapMode.easier)) {
        expect(b.difficulty, lessThan(a.difficulty));
        expect(QaFinder.sameArea(a, b), isTrue);
        expect(finder.passes(b, q), isTrue);
      }
    }
  });

  test('office scope: chair + bodyweight only, never floor', () {
    final index = QaActionIndex(catalog, aiTags: tags);
    final finder = QaFinder(index, profile: profile);
    final q = QaQuery(scene: 'office', equipment: const {}, strict: true);
    for (final a in finder.inScope(q)) {
      expect(a.floorRequired, isFalse);
      expect(a.requiredEquipment.difference(officeEquipment), isEmpty);
    }
  });
}
