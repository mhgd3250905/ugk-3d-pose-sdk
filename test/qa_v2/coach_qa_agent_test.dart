import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_coach/ugk_coach_qa_v2.dart';

/// 按候选回 respond / build_plan 的桩模型：只验证 v2 的代码路径，不评估模型质量。
class _StubClient implements LlmClient {
  int calls = 0;
  @override
  String get model => 'stub';
  @override
  Pricing? get pricing => null;
  @override
  Future<LlmResponse> complete(LlmRequest r, {CancelToken? cancel}) async {
    calls++;
    final last = r.messages.last.content;
    final ids = [
      for (final l in const LineSplitter().convert(last))
        if (RegExp(r'^[\w-]+ \| ').hasMatch(l)) l.split(' | ').first,
    ];
    final wantsPlan = RegExp(r'一套|分钟').hasMatch(last.split('\n').first);
    final call = wantsPlan
        ? LlmToolCall(id: 'c1', name: 'build_plan', arguments: jsonEncode({'title': '测试计划', 'text': '思路', 'minutes': 15, 'main_ids': ids.take(3).toList()}))
        : LlmToolCall(
            id: 'c1',
            name: 'respond',
            arguments: jsonEncode({
              'text': '回答。',
              'items': [for (final id in ids.take(4)) {'id': id, 'why': '理由'}],
            }),
          );
    return LlmResponse(content: '', toolCalls: [call]);
  }
}

void main() {
  final meta = File('packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json');
  if (!meta.existsSync()) return;
  final m = PoseHubAppTestCatalog.fromBytes(meta.readAsBytesSync());
  final sem = File('${meta.parent.path}/${m.semanticCatalogFile.path}').readAsBytesSync();
  final catalog = PoseHubAppTestCatalog.fromBytes(meta.readAsBytesSync(), semanticCatalogBytes: sem).toAiCatalog();
  final profile = CoachProfile.fromJson(jsonDecode(File('profiles/smartfit.json').readAsStringSync()));

  test('lexicon maps colloquial words and scene', () {
    final i = parseIntent('我在办公室，穿着西裤，想练核心');
    expect(i.scene, 'office');
    expect(i.noFloor, isTrue);
    expect(i.muscles, contains('abs'));
    expect(parseIntent('深蹲的时候膝盖有点疼').avoidJoints, contains('knee'));
    expect(detectFollowUp('第二个动作换掉').index, 1);
    expect(detectFollowUp('换第12个').index, 11);
    expect(detectFollowUp('第十个换掉').index, 9);
    expect(detectFollowUp('第十二个不喜欢').index, 11);
    expect(detectFollowUp('太难了，换简单点的').kind, QaFollowUp.easier);
    expect(detectFollowUp('就用这几个，帮我排成10分钟的训练').minutes, 10);
  });

  test('asks place, then equipment (multi), one step each; answers then recommends', () async {
    final client = _StubClient();
    final agent = CoachQaAgent(client: client, catalog: catalog, profile: profile);
    final r1 = await agent.send('推荐几个练腿的动作');
    expect(r1.kind, 'ask');
    // 问句是代码固定模板，不调模型。
    expect(client.calls, 0);
    expect(r1.llmCalls, 0);
    expect(r1.text, '练腿的话，你在哪练？');
    expect(r1.askStep, QaAskStep.place);
    expect(r1.question!.mode, AskUserMode.choice);
    expect(r1.question!.options, ['居家', '健身房', '办公室', '直接推荐']);
    expect(r1.text, contains('练腿'));
    final r2 = await agent.send('居家');
    expect(r2.askStep, QaAskStep.equipment);
    expect(client.calls, 0);
    expect(r2.text, '在家练腿，手边有哪些器械？可以多选。');
    expect(r2.question!.options, ['哑铃', '瑜伽垫', '椅子', '弹力带', '都没有（徒手）', '直接推荐']);
    expect(r2.question!.multiple, isTrue);
    expect(r2.question!.options, contains('都没有（徒手）'));
    final r3 = await agent.send('哑铃、椅子');
    expect(r3.kind, 'recommend');
    expect(r3.assumption, isNull);
    for (final c in r3.cards) {
      expect(agent.index[c.id]!.requiredEquipment.difference({'dumbbell', 'chair'}), isEmpty, reason: c.id);
    }
    // 之后的新请求沿用条件，不再问。
    final r4 = await agent.send('那练背呢');
    expect(r4.kind, isNot('ask'));
    expect(r4.assumption, startsWith('按上次'));
    final calls = client.calls;
    final r5 = await agent.send('就用这几个，帮我排成10分钟的训练');
    expect(r5.kind, 'plan');
    expect(client.calls, calls);
    expect(r5.planSeconds! / 60, inInclusiveRange(8, 12));
  });

  test('never asks the same question twice; skip or other talk falls back to home bodyweight', () async {
    final agent = CoachQaAgent(client: _StubClient(), catalog: catalog, profile: profile);
    expect((await agent.send('想练腹肌')).askStep, QaAskStep.place);
    final r = await agent.send('太难的不要');
    expect(r.kind, isNot('ask'));
    expect(r.assumption, '按在家徒手');
    expect(r.chips, contains('换场地'));
    for (final c in r.cards) {
      expect(agent.index[c.id]!.requiredEquipment, isEmpty, reason: c.id);
      expect(agent.index[c.id]!.difficulty, lessThanOrEqualTo(2), reason: c.id);
    }
    final agent2 = CoachQaAgent(client: _StubClient(), catalog: catalog, profile: profile);
    await agent2.send('推荐几个练腿的动作');
    expect((await agent2.send('直接推荐')).kind, isNot('ask'));
  });

  test('no questions for stretching, knowledge, injuries, stated or remembered conditions', () async {
    for (final t in ['睡前做点什么拉伸能睡得好一点', '平板支撑一般坚持多久合适', '手腕疼，还想练胸，怎么办', '我只有弹力带，想练手臂']) {
      final agent = CoachQaAgent(client: _StubClient(), catalog: catalog, profile: profile);
      expect((await agent.send(t)).kind, isNot('ask'), reason: t);
    }
    final mem = CoachQaAgent(client: _StubClient(), catalog: catalog, profile: profile, memory: const CoachQaMemory(scene: 'home', equipment: {'band'}));
    final r = await mem.send('想练背');
    expect(r.kind, isNot('ask'));
    expect(r.assumption, '按上次：在家弹力带');
    final gym = CoachQaAgent(client: _StubClient(), catalog: catalog, profile: profile);
    await gym.send('想练胸');
    expect((await gym.send('健身房')).kind, isNot('ask'));
  });

  test('office: chair + bodyweight only, never floor; "Nth" follows the card numbering (warm-up and cool-down included)', () async {
    final client = _StubClient();
    final agent = CoachQaAgent(client: client, catalog: catalog, profile: profile);
    final r = await agent.send('我在办公室，给我来一套15分钟的');
    expect(r.kind, 'plan');
    for (final id in r.plan!.blocks.expand((b) => b.items).map((i) => i.exerciseId)) {
      expect(agent.index[id]!.floorRequired, isFalse, reason: id);
      expect(agent.index[id]!.requiredEquipment.difference({'chair'}), isEmpty, reason: id);
    }
    final before = r.planOrderedIds;
    // 卡片编号 = 全部动作连续编号，热身在前：15 分钟计划第 1 个是热身。
    expect(r.plan!.blocks.first.type, BlockType.warmup);
    var swapped = 0;
    for (final n in [1, 2, before.length]) {
      final prev = agent.state.lastPlan!.orderedIds;
      final r2 = await agent.send('换第$n个');
      expect(r2.kind, anyOf('replace', 'answer'), reason: '第$n个');
      if (r2.kind != 'replace') continue;
      final now = r2.planOrderedIds;
      expect(now.length, prev.length);
      final changed = [
        for (var k = 0; k < now.length; k++)
          if (now[k] != prev[k]) k + 1,
      ];
      expect(changed, [n], reason: '只换卡片第$n个');
      expect(r2.text, startsWith('第$n个'));
      swapped++;
    }
    expect(swapped, greaterThanOrEqualTo(2));
    final out = await agent.send('换第${before.length + 1}个');
    expect(out.kind, 'answer');
    expect(out.text, contains('一共${before.length}个动作'));
    expect(out.plan, isNotNull);
  });

  test('recommend cards: "Nth" is the card position', () async {
    final agent = CoachQaAgent(
      client: _StubClient(),
      catalog: catalog,
      profile: profile,
      memory: const CoachQaMemory(scene: 'gym'),
    );
    final r = await agent.send('推荐几个练腿的动作');
    expect(r.kind, 'recommend');
    final r2 = await agent.send('第三个换掉');
    expect(r2.kind, 'replace');
    expect(r2.cards.length, r.cards.length);
    expect(
      [
        for (var k = 0; k < r.cards.length; k++)
          if (r.cards[k].id != r2.cards[k].id) k + 1,
      ],
      [3],
    );
  });

  test('home "none (bodyweight)": wall counts, chair only when picked', () {
    final finder = QaFinder(QaActionIndex(catalog));
    final bodyweight = QaQuery(scene: 'home', equipment: const {}, strict: true);
    final wallOnly = [
      for (final a in finder.index.all)
        if (a.scenes.contains('home') && a.requiredEquipment.isNotEmpty && a.requiredEquipment.every({'wall'}.contains)) a,
    ];
    expect(wallOnly, isNotEmpty);
    for (final a in wallOnly) {
      expect(finder.passes(a, bodyweight), isTrue, reason: a.id);
    }
    final chairOnly = [
      for (final a in finder.index.all)
        if (a.scenes.contains('home') && a.requiredEquipment.contains('chair') && a.requiredEquipment.every({'chair', 'wall'}.contains)) a,
    ];
    expect(chairOnly, isNotEmpty);
    for (final a in chairOnly) {
      expect(finder.passes(a, bodyweight), isFalse, reason: a.id);
      expect(
        finder.passes(a, QaQuery(scene: 'home', equipment: const {'chair'}, strict: true)),
        isTrue,
        reason: a.id,
      );
    }
  });

  // 需要 Pose-Hub ai-tags（退阶关系）；设 AI_TAGS_DIR 指向 catalog/ai-tags/actions。
  final tagsDir = Directory(Platform.environment['AI_TAGS_DIR'] ?? '../pose-hub/catalog/ai-tags/actions');
  test('easier on a plan swaps only main moves, same area, keeps time', skip: tagsDir.existsSync() ? false : 'no ai-tags', () async {
    final tags = {
      for (final f in tagsDir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')))
        for (final j in [jsonDecode(f.readAsStringSync()) as Map<String, Object?>]) j['id'] as String: j,
    };
    final client = _StubClient();
    final agent = CoachQaAgent(client: client, catalog: catalog, profile: profile, aiTags: tags);
    await agent.send('想练背，来一套15分钟的');
    await agent.send('居家');
    final r = await agent.send('哑铃、瑜伽垫、椅子、弹力带');
    final before = r.plan!;
    final r2 = await agent.send('太难了，换简单点的');
    expect(r2.kind, 'easier');
    expect(r2.planSeconds! / 60, inInclusiveRange(12, 17.5));
    for (final i in r2.plan!.blocks.expand((b) => b.items)) {
      expect(agent.index[i.exerciseId]!.requiredEquipment.difference({'dumbbell', 'mat', 'chair', 'band'}), isEmpty, reason: i.exerciseId);
    }
    final oldMain = before.blocks.firstWhere((b) => b.type == BlockType.main).items.map((i) => agent.index[i.exerciseId]!);
    final newMain = r2.plan!.blocks.firstWhere((b) => b.type == BlockType.main).items.map((i) => agent.index[i.exerciseId]!);
    final oldAreas = {for (final a in oldMain) ...a.primaryMuscles, for (final a in oldMain) ...a.stretchedMuscles};
    for (final a in newMain) {
      expect([...a.primaryMuscles, ...a.stretchedMuscles].any(oldAreas.contains), isTrue, reason: a.id);
    }
  });
}
