// 离线快速上手：假模型 + 回落，不花钱。
// dart run example/quickstart.dart
import 'dart:convert';
import 'dart:io';

import 'package:ugk_coach/ugk_coach.dart';

Future<void> main() async {
  // 1) 目录：内置一份，可选远端热更新（见 README「动作目录」）。
  final repo = CatalogRepository(
    bundled: BundledCatalogSource(() => File('test/fixtures/pose-hub-catalog.json').readAsString()),
  );
  await repo.load();

  // 2) 本 App 的 profile。
  final profile = CoachProfile.fromJson(jsonDecode(File('profiles/hiplab.json').readAsStringSync()));

  // 3) 模型客户端：这里用脚本化的假模型——第一次故意输出错的计划，第二次输出正确的。
  final bad = {
    'kind': 'plan',
    'text': '睡前 10 分钟开胯',
    'plan': {
      'schemaVersion': 1, 'title': '睡前开胯', 'summary': '放松髋部', 'goal': 'relax', 'scene': 'home',
      'equipment': ['mat'], 'level': 1, 'targetMinutes': 10,
      'blocks': [
        {'id': 'b1', 'name': '拉伸', 'type': 'main', 'items': [
          {'exerciseId': 's-figure4', 'mode': 'time', 'sets': 2, 'workSeconds': 40, 'perSide': false, 'restSeconds': 10},
          {'exerciseId': 'burpee', 'mode': 'reps', 'sets': 1, 'reps': 10, 'perSide': false, 'restSeconds': 10},
        ]},
      ],
    },
  };
  final good = jsonDecode(jsonEncode(bad)) as Map<String, Object?>;
  final items = (((good['plan']! as Map)['blocks']! as List).first as Map)['items']! as List;
  (items.first as Map)['perSide'] = true;
  items[1] = {'exerciseId': 's-butterfly', 'mode': 'time', 'sets': 2, 'workSeconds': 40, 'perSide': false, 'restSeconds': 15};
  final client = FakeLlmClient([bad, good], pricing: const Pricing(inputPerMillion: 1, cachedInputPerMillion: 0.1, outputPerMillion: 4));

  final usage = MemoryUsageSink();
  final assistant = CoachAssistant(
    client: client,
    catalog: () => repo.current,
    profile: profile,
    usage: usage,
    fallback: FallbackFn((r) => CoachReply.text('（离线）先给你一套固定的放松流程。原因：${r.reason.name}')),
  );

  final conversation = CoachConversation();
  final result = await assistant.ask('睡前想开开胯，10 分钟', context: const CoachContext(scene: 'home'), conversation: conversation);

  stdout
    ..writeln('走向：${result.outcome.name}')
    ..writeln('回复：${result.reply?.text}')
    ..writeln('动作：${result.reply?.plan?.items.map((i) => i.exerciseId).join(', ')}');
  for (final r in result.records) {
    stdout.writeln('调用#${r.attempt} ${r.outcome.name} 问题=${r.issueCodes} tokens=${r.usage.totalTokens} 花费≈${r.cost?.toStringAsFixed(6)} ${r.currency}');
  }
  final cover = assistant.resolve('s-figure4');
  stdout.writeln('s-figure4 素材：封面 ${cover?.cover?.uri}，视频 ${cover?.video?.uri}，缺 ${cover?.missing.map((m) => m.name)}');
}
