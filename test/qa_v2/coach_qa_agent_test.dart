import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_coach/ugk_coach_qa_v2.dart';

/// 桩模型：按工具名交给脚本函数回参数；记下每个请求。只验证代码路径，不评估模型质量。
class _Scripted implements LlmClient {
  _Scripted(this.handler);
  final Map<String, Object?> Function(String tool, String context, int nth) handler;
  final requests = <LlmRequest>[];
  final _count = <String, int>{};
  @override
  String get model => 'stub';
  @override
  Pricing? get pricing => null;
  @override
  Future<LlmResponse> complete(LlmRequest r, {CancelToken? cancel}) async {
    requests.add(r);
    final tool = r.tools.first.name;
    final n = _count[tool] = (_count[tool] ?? 0) + 1;
    final ctx = r.messages.where((m) => m.role == LlmRole.user).last.content;
    return LlmResponse(content: '', toolCalls: [LlmToolCall(id: 'c$n', name: tool, arguments: jsonEncode(handler(tool, ctx, n)))]);
  }

  int calls(String tool) => _count[tool] ?? 0;
}

/// 上下文里的候选 id（`id | …` 行，或 `  候选：id | …`）。
List<String> _candidates(String ctx) => [
  for (final l in const LineSplitter().convert(ctx))
    if (RegExp(r'^(\s*候选：)?[\w-]+ \| ').hasMatch(l)) l.replaceFirst(RegExp(r'^\s*候选：'), '').split(' | ').first,
];

Map<String, Object?> _form({
  String intent = 'actions',
  String place = 'unknown',
  bool eqKnown = false,
  List<String> eq = const [],
  String status = 'none',
  List<String> muscles = const [],
  String next = 'answer',
  int? minutes,
  List<int> positions = const [],
  String lang = 'zh',
}) => {
  'language': lang,
  'intent': intent,
  'answer_status': status,
  'place': place,
  'equipment_known': eqKnown,
  'equipment': eq,
  'muscles': muscles,
  'next': next,
  'minutes': ?minutes,
  if (positions.isNotEmpty) 'positions': positions,
};

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

  test('every request asks for max thinking; OpenAI body merges request extraBody last', () async {
    final c = _Scripted((tool, ctx, n) => tool == 'fill_form' ? _form(intent: 'knowledge') : {'text': 'ok', 'items': [], 'chips': []});
    final agent = CoachQaAgent(client: c, catalog: catalog, profile: profile, aiTags: tags);
    await agent.send('平板支撑多久合适');
    expect(c.requests, hasLength(2));
    for (final r in c.requests) {
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

  test('place, then equipment, questions written by the model; answer is strictly scoped', () async {
    final c = _Scripted((tool, ctx, n) {
      switch (tool) {
        case 'fill_form':
          return switch (n) {
            1 => _form(muscles: ['lats', 'scapular'], next: 'ask_place'),
            2 => _form(muscles: const [], place: 'home', status: 'answered', next: 'ask_equipment', intent: 'answer_pending'),
            _ => _form(muscles: const [], place: 'home', eqKnown: true, status: 'answered', intent: 'answer_pending'),
          };
        case 'ask_user':
          return n == 1
              ? {'question': 'Q-place', 'options': ['A', 'B', 'C', 'D']}
              : {'question': 'Q-eq', 'options': ['1', '2', '3', '4', '5', '6']};
        default:
          return {'text': 'ok', 'items': [for (final id in _candidates(ctx).take(4)) {'id': id, 'why': 'w'}], 'chips': ['c']};
      }
    });
    final agent = CoachQaAgent(client: c, catalog: catalog, profile: profile, aiTags: tags);
    final r1 = await agent.send('想练背');
    expect(r1.kind, 'ask');
    expect(r1.askStep, QaAskStep.place);
    expect(r1.text, 'Q-place');
    expect(r1.question!.mode, AskUserMode.choice);
    expect(r1.question!.multiple, isFalse);
    expect(r1.steps.map((s) => s.step), ['understand', 'ask']);
    final r2 = await agent.send('居家');
    expect(r2.askStep, QaAskStep.equipment);
    expect(r2.question!.multiple, isTrue);
    expect(r2.question!.options, hasLength(6));
    final r3 = await agent.send('都没有');
    expect(r3.kind, 'recommend');
    expect(r3.conditionsAssumed, isFalse);
    expect(r3.cards, isNotEmpty);
    for (final card in r3.cards) {
      expect(agent.index[card.id]!.requiredEquipment.difference(homeAlwaysAvailable), isEmpty, reason: card.id);
      // 焦点沿用原请求（练背）。
      final a = agent.index[card.id]!;
      expect([...a.primaryMuscles, ...a.secondaryMuscles, ...a.stretchedMuscles].any({'lats', 'scapular'}.contains), isTrue, reason: card.id);
    }
  });

  test('never asks the same step twice; a skipped answer falls back to home bodyweight', () async {
    final c = _Scripted((tool, ctx, n) {
      if (tool == 'fill_form') return _form(muscles: ['abs'], next: 'ask_place', status: n == 1 ? 'none' : 'skipped');
      if (tool == 'ask_user') return {'question': 'Q', 'options': ['A', 'B', 'C', 'D']};
      return {'text': 'ok', 'items': [for (final id in _candidates(ctx).take(3)) {'id': id, 'why': 'w'}], 'assumption': 'as', 'chips': ['change']};
    });
    final agent = CoachQaAgent(client: c, catalog: catalog, profile: profile, aiTags: tags);
    expect((await agent.send('x')).askStep, QaAskStep.place);
    final r = await agent.send('y');
    expect(r.kind, 'recommend');
    expect(r.conditions['place'], 'home');
    expect(r.conditions['equipment'], isEmpty);
    expect(r.conditionsAssumed, isTrue);
    expect(r.assumption, 'as');
    for (final card in r.cards) {
      expect(agent.index[card.id]!.requiredEquipment.difference(homeAlwaysAvailable), isEmpty, reason: card.id);
    }
  });

  test('skipped equipment question stays a default even if the model fills equipment', () async {
    final c = _Scripted((tool, ctx, n) {
      if (tool == 'fill_form') {
        return n == 1
            ? _form(muscles: ['quadriceps'], place: 'home', next: 'ask_equipment')
            : _form(muscles: ['quadriceps'], place: 'home', eqKnown: true, eq: ['dumbbell'], status: 'skipped');
      }
      if (tool == 'ask_user') return {'question': 'Q', 'options': ['1', '2', '3', '4', '5', '6']};
      return {'text': 'ok', 'items': [for (final id in _candidates(ctx).take(3)) {'id': id, 'why': 'w'}], 'assumption': 'as', 'chips': ['c']};
    });
    final agent = CoachQaAgent(client: c, catalog: catalog, profile: profile, aiTags: tags);
    expect((await agent.send('x')).askStep, QaAskStep.equipment);
    final r = await agent.send('y');
    expect(r.conditions['equipment'], isEmpty);
    expect(r.conditions['equipmentSource'], 'skipped');
    expect(r.conditionsAssumed, isTrue);
    expect(r.assumption, 'as');
  });

  test('known place (memory) is not asked again even if the model wants to', () async {
    final c = _Scripted((tool, ctx, n) => tool == 'fill_form'
        ? _form(muscles: ['quadriceps'], next: 'ask_place', place: 'home', eqKnown: true, eq: ['band'])
        : {'text': 'ok', 'items': [for (final id in _candidates(ctx).take(3)) {'id': id, 'why': 'w'}], 'chips': []});
    final agent = CoachQaAgent(client: c, catalog: catalog, profile: profile, aiTags: tags, memory: const CoachQaMemory(scene: 'home', equipment: {'band'}));
    final r = await agent.send('x');
    expect(r.kind, isNot('ask'));
    expect(c.calls('ask_user'), 0);
    expect(r.issues.join(), contains('guard'));
  });

  test('out-of-candidate id is sent back to the model and retried', () async {
    final c = _Scripted((tool, ctx, n) {
      if (tool == 'fill_form') return _form(place: 'gym', muscles: ['chest']);
      return n == 1
          ? {'text': 'ok', 'items': [{'id': 'not-a-move', 'why': 'w'}], 'chips': []}
          : {'text': 'ok', 'items': [for (final id in _candidates(ctx).take(3)) {'id': id, 'why': 'w'}], 'chips': []};
    });
    final agent = CoachQaAgent(client: c, catalog: catalog, profile: profile, aiTags: tags);
    final r = await agent.send('x');
    expect(c.calls('respond'), 2);
    expect(r.cards, hasLength(3));
    expect(r.issues.join(), contains('retry'));
  });

  test('text naming an off-card move is rewritten', () async {
    String? offName;
    final c = _Scripted((tool, ctx, n) {
      if (tool == 'fill_form') return _form(place: 'gym', muscles: ['glute-max']);
      if (tool == 'rewrite') return {'text': 'clean'};
      final ids = _candidates(ctx);
      return {'text': 'try $offName', 'items': [for (final id in ids.take(2)) {'id': id, 'why': 'w'}], 'chips': []};
    });
    final agent = CoachQaAgent(client: c, catalog: catalog, profile: profile, aiTags: tags);
    // 选一个名字足够长、且不会出现在卡片里的动作。
    offName = agent.index.all.firstWhere((a) => (a.drill.name.values['zh'] ?? '').runes.length >= 5 && a.primaryMuscles.contains('chest')).drill.name.values['zh'];
    final r = await agent.send('x');
    expect(c.calls('rewrite'), 1);
    expect(r.text, 'clean');
  });

  test('"Nth" follows the plan card numbering incl. warm-up; only that position changes', () async {
    late List<String> ordered;
    final c = _Scripted((tool, ctx, n) {
      switch (tool) {
        case 'fill_form':
          return n == 1 ? _form(intent: 'plan', place: 'gym', muscles: ['quadriceps', 'glute-max'], minutes: 15) : _form(intent: 'swap', place: 'gym', positions: [1]);
        case 'build_plan':
          return {'title': 't', 'text': 'x', 'minutes': 15, 'main_ids': _candidates(ctx).take(4).toList(), 'chips': []};
        default: // swap
          final cand = _candidates(ctx).where((id) => id != ordered.first).toList();
          return {'text': 'x', 'changes': [{'position': 1, 'new_id': cand.first, 'why': 'w'}], 'chips': []};
      }
    });
    final agent = CoachQaAgent(client: c, catalog: catalog, profile: profile, aiTags: tags);
    final r1 = await agent.send('x');
    expect(r1.kind, 'plan');
    expect(r1.plan!.blocks.first.type, BlockType.warmup);
    ordered = r1.planOrderedIds;
    final r2 = await agent.send('y');
    expect(r2.kind, 'replace');
    final after = r2.planOrderedIds;
    expect(after.length, ordered.length);
    expect([for (var k = 0; k < after.length; k++) if (after[k] != ordered[k]) k], [0]);
    expect(agent.index[after.first]!.sessionRole, contains('warmup'));
  });

  test('swap with no qualifying candidate keeps the card and lets the model say so', () async {
    final c = _Scripted((tool, ctx, n) {
      if (tool == 'fill_form') return n == 1 ? _form(place: 'gym', muscles: ['abs']) : _form(intent: 'swap', place: 'gym', positions: [99]);
      if (tool == 'swap') return {'text': 'only N', 'changes': [], 'chips': []};
      return {'text': 'ok', 'items': [for (final id in _candidates(ctx).take(3)) {'id': id, 'why': 'w'}], 'chips': []};
    });
    final agent = CoachQaAgent(client: c, catalog: catalog, profile: profile, aiTags: tags);
    final r1 = await agent.send('x');
    final r2 = await agent.send('y');
    expect(r2.kind, 'answer');
    expect(r2.cards.map((x) => x.id), r1.cards.map((x) => x.id));
    expect(c.requests.last.messages.last.content, contains('99'));
  });

  test('retime keeps the main moves and refits the duration', () async {
    final c = _Scripted((tool, ctx, n) {
      if (tool == 'fill_form') return n == 1 ? _form(intent: 'plan', place: 'gym', muscles: ['chest'], minutes: 20) : _form(intent: 'retime', place: 'gym', minutes: 10);
      return {'title': 't', 'text': 'x', 'minutes': n == 1 ? 20 : 10, 'main_ids': _candidates(ctx).take(4).toList(), 'chips': []};
    });
    final agent = CoachQaAgent(client: c, catalog: catalog, profile: profile, aiTags: tags);
    final r1 = await agent.send('x');
    final r2 = await agent.send('y');
    expect(r2.planMainIds.toSet().containsAll(r1.planMainIds.take(2)), isTrue);
    expect(r2.planSeconds! / 60, inInclusiveRange(8, 12));
  });

  test('swap candidates follow tags: same area, easier is easier, all in scope', () {
    final index = QaActionIndex(catalog, aiTags: tags);
    final finder = QaFinder(index);
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
    final finder = QaFinder(index);
    final q = QaQuery(scene: 'office', equipment: const {}, strict: true);
    for (final a in finder.inScope(q)) {
      expect(a.floorRequired, isFalse);
      expect(a.requiredEquipment.difference(officeEquipment), isEmpty);
    }
  });
}
