// 真实模型冒烟（花钱！只在需要时跑一次）：HipLab profile + Pose-Hub 目录，一轮对话。
//
//   dart run example/smoke.dart                       # 不带 Authorization（上游代理注入 key）
//   UGK_API_KEY=sk-... dart run example/smoke.dart    # 自带 key
//   UGK_BASE_URL / UGK_MODEL 覆盖地址与模型；UGK_PRICE_IN / UGK_PRICE_CACHED / UGK_PRICE_OUT（每百万 token）估算花费
//
// 调用记录追加到 example/smoke-usage.jsonl。
import 'dart:convert';
import 'dart:io';

import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_coach/ugk_coach_io.dart';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  double? price(String k) => double.tryParse(env[k] ?? '');
  final pin = price('UGK_PRICE_IN'), pout = price('UGK_PRICE_OUT');
  final config = LlmConfig.deepSeekOpenCsg.copyWith(
    baseUrl: env['UGK_BASE_URL'],
    model: env['UGK_MODEL'],
    temperature: 0.3,
    maxRetries: 1,
    pricing: pin != null && pout != null
        ? Pricing(inputPerMillion: pin, outputPerMillion: pout, cachedInputPerMillion: price('UGK_PRICE_CACHED'))
        : null,
  );
  final key = env['UGK_API_KEY'];
  final client = OpenAiCompatibleClient(config: config, auth: key == null || key.isEmpty ? const NoAuth() : ApiKeyAuth(key));

  final repo = CatalogRepository(bundled: BundledCatalogSource(() => File('test/fixtures/pose-hub-catalog.json').readAsString()));
  await repo.load();
  final profile = CoachProfile.fromJson(jsonDecode(File('profiles/hiplab.json').readAsStringSync()));
  final sink = MultiUsageSink([JsonlUsageSink(File('example/smoke-usage.jsonl')), MemoryUsageSink()]);

  final assistant = CoachAssistant(
    client: client,
    catalog: () => repo.current,
    profile: profile,
    usage: sink,
    fallback: FallbackFn((r) => CoachReply.text('（回落）${r.reason.name}：${r.error ?? r.issues.map((i) => i.feedbackLine).join('；')}')),
  );

  final text = args.isNotEmpty ? args.join(' ') : '晚上睡前想在床边垫子上开开胯，10 分钟左右，膝盖有点不舒服';
  stdout.writeln('用户：$text');
  final sw = Stopwatch()..start();
  final r = await assistant.ask(text, context: const CoachContext(scene: 'home', avoid: {'膝'}));
  sw.stop();

  stdout
    ..writeln('走向：${r.outcome.name}${r.fallbackReason == null ? '' : '（${r.fallbackReason!.name}）'}，总耗时 ${sw.elapsedMilliseconds} ms')
    ..writeln('回复（${r.reply?.kind.name}）：${r.reply?.text}');
  final plan = r.reply?.plan;
  if (plan != null) {
    stdout.writeln('计划：${plan.title}（${plan.targetMinutes} 分钟，估算 ${(const PlanDuration().estimateSeconds(plan, repo.current) / 60).toStringAsFixed(1)} 分钟）');
    for (final b in plan.blocks) {
      stdout.writeln('  [${b.type.name}] ${b.name}');
      for (final i in b.items) {
        final d = repo.current[i.exerciseId];
        final dose = i.mode == DoseMode.reps ? '${i.reps} 次' : '${i.workSeconds} 秒';
        stdout.writeln('    ${i.exerciseId} ${d?.name.of()} ${i.sets}×$dose${i.perSide ? ' 每侧' : ''} 休${i.restSeconds}');
      }
    }
  }
  for (final w in r.issues) {
    stdout.writeln('  ${w.isError ? '错误' : '警告'} ${w.feedbackLine}');
  }
  for (final c in r.records) {
    stdout.writeln('调用#${c.attempt} ${c.outcome.name} model=${c.model} prompt=${c.usage.promptTokens}'
        '（缓存 ${c.usage.cachedTokens}）completion=${c.usage.completionTokens}（推理 ${c.usage.reasoningTokens}）'
        ' ${c.latency.inMilliseconds}ms http×${c.httpAttempts} ${c.errorKind ?? ''} ${c.issueCodes.join(',')}'
        '${c.cost == null ? '' : ' ≈${c.cost!.toStringAsFixed(5)} ${c.currency}'}');
  }
  stdout.writeln('promptVersion=${r.records.firstOrNull?.promptVersion} catalog=${repo.current.version}');
  client.close();
}
