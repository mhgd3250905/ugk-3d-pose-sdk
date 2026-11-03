// 本地真实模型用户模拟：同一套场景跑 CoachAgent（v1，默认）或 CoachQaAgent（v2）。
// dart run tool/sim_user.dart scenarios.json out.jsonl [profile]
// 环境变量：UGK_API_KEY（必填）、SIM_AGENT=v2、AI_TAGS_DIR（Pose-Hub catalog/ai-tags/actions）、
//           SIM_BASE / SIM_MODEL / SIM_THINK=off、ONLY=S01-腰酸,S02-腹肌
//           SIM_STUB=1：v2 用桩模型跑流程和自动检查（不花钱，不评估模型质量）
// 输出是原始 JSONL，不提交。
import 'dart:convert';
import 'dart:io';

import 'package:http/io_client.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_coach/ugk_coach_qa_v2.dart';

import 'qa_checks.dart';

class LoggingClient implements LlmClient {
  LoggingClient(this.inner);
  final LlmClient inner;
  final calls = <Map<String, Object?>>[];
  @override
  String get model => inner.model;
  @override
  Pricing? get pricing => inner.pricing;
  @override
  Future<LlmResponse> complete(LlmRequest r, {CancelToken? cancel}) async {
    final sw = Stopwatch()..start();
    final reqBytes = utf8.encode(jsonEncode([for (final m in r.messages) m.toJson()])).length;
    try {
      final res = await inner.complete(r, cancel: cancel);
      calls.add({
        'ms': sw.elapsedMilliseconds,
        'reqKB': (reqBytes / 1024).round(),
        'tools': [
          for (final c in res.toolCalls)
            '${c.name}(${c.arguments.length > 160 ? '${c.arguments.substring(0, 160)}…' : c.arguments})'
        ],
        'text': res.content.length > 200 ? '${res.content.substring(0, 200)}…' : res.content,
        'in': res.usage.promptTokens,
        'out': res.usage.completionTokens,
        'hit': res.usage.cachedTokens,
      });
      return res;
    } catch (e) {
      calls.add({'ms': sw.elapsedMilliseconds, 'error': '$e'.substring(0, ('$e').length.clamp(0, 200))});
      rethrow;
    }
  }
}

Future<void> main(List<String> args) async {
  final scenarios = (jsonDecode(File(args[0]).readAsStringSync()) as List).cast<Map<String, dynamic>>();
  final out = File(args[1]).openWrite(mode: FileMode.append);
  final profileName = args.length > 2 ? args[2] : 'smartfit';
  final only = Platform.environment['ONLY']?.split(',').toSet();
  final metaFile = File('packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json');
  final meta = PoseHubAppTestCatalog.fromBytes(metaFile.readAsBytesSync());
  final sem = File('${metaFile.parent.path}/${meta.semanticCatalogFile.path}').readAsBytesSync();
  final catalog = PoseHubAppTestCatalog.fromBytes(metaFile.readAsBytesSync(), semanticCatalogBytes: sem).toAiCatalog();
  final profile = CoachProfile.fromJson(jsonDecode(File('profiles/$profileName.json').readAsStringSync()));
  final config = LlmConfig(
    baseUrl: Platform.environment['SIM_BASE'] ?? 'https://ai.uuugk.win/v1',
    model: Platform.environment['SIM_MODEL'] ?? 'deepseek-flash',
    maxTokens: 6000,
    timeout: const Duration(seconds: 120),
    maxRetries: 0,
    extraBody: Platform.environment['SIM_THINK'] == 'off'
        ? {'thinking': {'type': 'disabled'}}
        : {'thinking': {'type': 'enabled'}},
  );
  if (Platform.environment['SIM_AGENT'] == 'v2') {
    await _runV2(scenarios, out, only, catalog, profile, config);
    await out.close();
    return;
  }
  for (final s in scenarios) {
    if (only != null && !only.contains(s['id'])) continue;
    final client = LoggingClient(OpenAiCompatibleClient(config: config, httpClient: _http(), auth: ApiKeyAuth(Platform.environment['UGK_API_KEY'] ?? 'x')));
    final agent = CoachAgent(client: client, catalog: () => catalog, profile: profile);
    final controller = CoachConversationController(agent: agent);
    var turn = 0;
    for (final text in (s['turns'] as List).cast<String>()) {
      turn++;
      final before = client.calls.length;
      final sw = Stopwatch()..start();
      Map<String, Object?> rec;
      try {
        final r = await controller.send(text, context: CoachContext(language: (s['locale'] as String?) ?? 'zh'));
        final plan = r?.plan?.plan;
        rec = {
          'status': r?.status.name,
          'text': r?.text,
          'question': r?.question?.toJson(),
          'actions': [for (final a in r?.actions?.items ?? <ValidatedAction>[]) a.drill.name.values['zh'] ?? a.drill.id],
          'actionNote': (r?.actions?.items.isNotEmpty ?? false) ? r!.actions!.items.first.note : null,
          if (plan != null)
            'plan': {
              'title': plan.title,
              'summary': plan.summary,
              'scene': plan.scene,
              'equipment': plan.equipment,
              'blocks': [
                for (final b in plan.blocks)
                  [for (final i in b.items) catalog[i.exerciseId]?.name.values['zh'] ?? i.exerciseId]
              ],
              'raw': plan.toJson(),
            },
          'issues': [for (final i in r?.issues ?? <PlanIssue>[]) '$i'],
          'fallback': r?.fallbackReason?.name,
          'error': r?.error == null ? null : '${r!.error}',
        };
      } catch (e) {
        rec = {'exception': '$e'};
      }
      final calls = client.calls.sublist(before);
      out.writeln(jsonEncode({
        'id': s['id'],
        'turn': turn,
        'user': text,
        'ms': sw.elapsedMilliseconds,
        'http': calls.length,
        'calls': calls,
        ...rec,
      }));
      await out.flush();
      stdout.writeln('${s['id']}#$turn ${sw.elapsedMilliseconds}ms http=${calls.length} ${rec['status'] ?? rec['exception']}');
    }
  }
  await out.close();
}

Map<String, Map<String, Object?>> _loadAiTags() {
  final dir = Directory(Platform.environment['AI_TAGS_DIR'] ?? '../../pose-hub/catalog/ai-tags/actions');
  if (!dir.existsSync()) return const {};
  return {
    for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')))
      for (final j in [jsonDecode(f.readAsStringSync()) as Map<String, Object?>]) j['id'] as String: j,
  };
}

Future<void> _runV2(
  List<Map<String, dynamic>> scenarios,
  IOSink out,
  Set<String>? only,
  Catalog catalog,
  CoachProfile profile,
  LlmConfig config,
) async {
  final tags = _loadAiTags();
  var printed = false;
  for (final s in scenarios) {
    if (only != null && !only.contains(s['id'])) continue;
    final LlmClient inner = Platform.environment['SIM_STUB'] == '1'
        ? StubClient()
        : OpenAiCompatibleClient(config: config, httpClient: _http(), auth: ApiKeyAuth(Platform.environment['UGK_API_KEY'] ?? 'x'));
    final client = LoggingClient(inner);
    final mem = (s['memory'] as Map?)?.cast<String, dynamic>();
    final agent = CoachQaAgent(
      client: client,
      catalog: catalog,
      profile: profile,
      aiTags: tags,
      memory: mem == null ? const CoachQaMemory() : CoachQaMemory(scene: mem['scene'] as String?, equipment: ((mem['equipment'] as List?) ?? const []).cast<String>().toSet()),
    );
    final base = ((s['expect'] as Map?) ?? const {}).cast<String, dynamic>();
    final perTurn = ((s['turns_expect'] as List?) ?? const []);
    CoachQaReply? prev;
    if (!printed) {
      stdout.writeln('ai-tags 覆盖 ${agent.tagCoverage}；未命中 ${agent.index.untaggedIds}');
      printed = true;
    }
    final lang = (s['locale'] as String?) ?? 'zh';
    var turn = 0;
    for (final text in (s['turns'] as List).cast<String>()) {
      turn++;
      final before = client.calls.length;
      final sw = Stopwatch()..start();
      Map<String, Object?> rec;
      try {
        final r = await agent.send(text, language: lang);
        final plan = r.plan;
        final exp = {...base, if (turn - 1 < perTurn.length && perTurn[turn - 1] != null) ...(perTurn[turn - 1] as Map).cast<String, dynamic>()};
        final fails = checkTurn(agent: agent, expect: exp, r: r, prev: prev, lang: lang);
        prev = r;
        rec = {
          'status': r.kind,
          'text': r.text,
          'checks': fails,
          'ids': allIds(r),
          'main': mainIds(r),
          'askStep': r.askStep?.name,
          'question': r.question?.toJson(),
          'assumption': r.assumption,
          'actions': [for (final c in r.cards) c.name],
          'why': [for (final c in r.cards) c.why],
          'chips': r.chips,
          if (plan != null)
            'plan': {
              'title': plan.title,
              'seconds': r.planSeconds,
              'target': plan.targetMinutes,
              'blocks': [
                for (final b in plan.blocks)
                  [for (final i in b.items) '${catalog[i.exerciseId]?.name.values[lang] ?? i.exerciseId} ${i.sets}x${i.reps ?? '${i.workSeconds}s'}']
              ],
            },
          'issues': r.issues,
          'trace': r.toolTrace,
        };
      } catch (e, st) {
        rec = {'exception': '$e', 'stack': '$st'.split('\n').take(5).join(' | ')};
      }
      final calls = client.calls.sublist(before);
      out.writeln(jsonEncode({'id': s['id'], 'turn': turn, 'user': text, 'ms': sw.elapsedMilliseconds, 'http': calls.length, 'calls': calls, ...rec}));
      await out.flush();
      stdout.writeln('${s['id']}#$turn ${sw.elapsedMilliseconds}ms http=${calls.length} ${rec['status'] ?? rec['exception']} ${rec['askStep'] ?? ''} ${(rec['checks'] as List?)?.join('; ') ?? ''}');
    }
  }
}

/// 桩模型：措辞调用回一句问题；工具调用按候选回 respond / build_plan。
class StubClient implements LlmClient {
  @override
  String get model => 'stub';
  @override
  Pricing? get pricing => null;
  @override
  Future<LlmResponse> complete(LlmRequest r, {CancelToken? cancel}) async {
    final last = r.messages.last.content;
    if (r.tools.isEmpty) return LlmResponse(content: last.contains('只问器械') ? '手边有哪些器械？' : '你在哪练？');
    final ids = [
      for (final l in const LineSplitter().convert(last))
        if (RegExp(r'^[\w-]+ \| ').hasMatch(l)) l.split(' | ').first,
    ];
    final first = last.split('\n').first;
    final wantsPlan = RegExp(r'一套|分钟|minute|session|workout').hasMatch(first);
    final m = RegExp(r'(\d+)\s*(分钟|minute)').firstMatch(first);
    final call = wantsPlan
        ? LlmToolCall(id: 'c1', name: 'build_plan', arguments: jsonEncode({'title': '测试', 'text': '思路', 'minutes': int.tryParse(m?.group(1) ?? '') ?? 15, 'main_ids': ids.take(4).toList()}))
        : LlmToolCall(id: 'c1', name: 'respond', arguments: jsonEncode({'text': '回答。', 'items': [for (final id in ids.take(4)) {'id': id, 'why': '理由'}]}));
    return LlmResponse(content: '', toolCalls: [call]);
  }
}

IOClient _http() {
  final ctx = SecurityContext(withTrustedRoots: true);
  final f = Platform.environment['SSL_CERT_FILE'];
  if (f != null) ctx.setTrustedCertificates(f);
  return IOClient(HttpClient(context: ctx)..idleTimeout = const Duration(seconds: 5));
}
