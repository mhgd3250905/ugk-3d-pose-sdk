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
    expect(detectFollowUp('太难了，换简单点的').kind, QaFollowUp.easier);
    expect(detectFollowUp('就用这几个，帮我排成10分钟的训练').minutes, 10);
  });

  test('recommend without asking place, then use these as a plan without model', () async {
    final client = _StubClient();
    final agent = CoachQaAgent(client: client, catalog: catalog, profile: profile);
    final r1 = await agent.send('推荐几个练腿的动作');
    expect(r1.kind, 'recommend');
    expect(r1.cards.length, greaterThanOrEqualTo(3));
    expect(r1.assumption, isNotNull);
    expect(client.calls, 1);
    final r2 = await agent.send('就用这几个，帮我排成10分钟的训练');
    expect(r2.kind, 'plan');
    expect(client.calls, 1);
    expect(r2.planSeconds! / 60, inInclusiveRange(8, 12));
  });

  test('office never returns floor actions; replace keeps plan length', () async {
    final client = _StubClient();
    final agent = CoachQaAgent(client: client, catalog: catalog, profile: profile);
    final r = await agent.send('我在办公室，给我来一套15分钟的');
    expect(r.kind, 'plan');
    for (final id in r.plan!.blocks.expand((b) => b.items).map((i) => i.exerciseId)) {
      expect(agent.index[id]!.floorRequired, isFalse, reason: id);
    }
    final n = r.plan!.blocks.expand((b) => b.items).length;
    final r2 = await agent.send('第二个换掉');
    expect(r2.kind, 'replace');
    expect(r2.plan!.blocks.expand((b) => b.items).length, n);
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
    final r = await agent.send('想练背，来一套15分钟的');
    final before = r.plan!;
    final r2 = await agent.send('太难了，换简单点的');
    expect(r2.kind, 'easier');
    expect(r2.planSeconds! / 60, inInclusiveRange(12, 17.5));
    final oldMain = before.blocks.firstWhere((b) => b.type == BlockType.main).items.map((i) => agent.index[i.exerciseId]!);
    final newMain = r2.plan!.blocks.firstWhere((b) => b.type == BlockType.main).items.map((i) => agent.index[i.exerciseId]!);
    final oldAreas = {for (final a in oldMain) ...a.primaryMuscles, for (final a in oldMain) ...a.stretchedMuscles};
    for (final a in newMain) {
      expect([...a.primaryMuscles, ...a.stretchedMuscles].any(oldAreas.contains), isTrue, reason: a.id);
    }
  });
}
