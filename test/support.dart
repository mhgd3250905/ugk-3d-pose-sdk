import 'dart:convert';
import 'dart:io';

import 'package:ugk_coach/ugk_coach.dart';

final _catalogText = File('test/fixtures/pose-hub-catalog.json').readAsStringSync();

/// Pose-Hub 统一目录快照（ai-coach-eval / 3D-Pose-Hub feat/ai-coach-catalog，0.1.0）。
Catalog loadCatalog() => Catalog.fromJson(jsonDecode(_catalogText));
String catalogText() => _catalogText;

CoachProfile loadProfile(String id) =>
    CoachProfile.fromJson(jsonDecode(File('profiles/$id.json').readAsStringSync()));

Map<String, Object?> deepCopy(Map<String, Object?> m) => (jsonDecode(jsonEncode(m)) as Map).cast<String, Object?>();

/// 评测自测里的合法 HipLab 计划（ai-coach-eval tools/validate.py ok_plan）。
Map<String, Object?> okEnvelope() => deepCopy(_okEnvelope);

final Map<String, Object?> _okEnvelope = {
  'kind': 'plan',
  'text': '给你排了 10 分钟开胯。',
  'plan': {
    'schemaVersion': 1, 'source': 'ai', 'title': '睡前开胯', 'summary': '放松髋部', 'goal': 'relax', 'scene': 'home',
    'equipment': ['mat'], 'level': 1, 'targetMinutes': 10, 'avoid': <String>[], 'notes': <String>[], 'safetyNotes': <String>[],
    'blocks': [
      {'id': 'b1', 'name': '热身', 'type': 'warmup', 'rounds': 1, 'restBetweenRoundsSeconds': 0, 'items': [
        {'exerciseId': 'n-windshield', 'mode': 'reps', 'sets': 1, 'reps': 8, 'perSide': false, 'restSeconds': 10},
      ]},
      {'id': 'b2', 'name': '拉伸', 'type': 'main', 'rounds': 1, 'restBetweenRoundsSeconds': 0, 'items': [
        {'exerciseId': 's-figure4', 'mode': 'time', 'sets': 1, 'workSeconds': 40, 'perSide': true, 'restSeconds': 10},
        {'exerciseId': 's-butterfly', 'mode': 'time', 'sets': 2, 'workSeconds': 40, 'perSide': false, 'restSeconds': 15},
        {'exerciseId': 's-kneel-hipflex', 'mode': 'time', 'sets': 1, 'workSeconds': 40, 'perSide': true, 'restSeconds': 10},
        {'exerciseId': 'h-reverse-clam', 'mode': 'reps', 'sets': 2, 'reps': 12, 'perSide': true, 'restSeconds': 20},
      ]},
      {'id': 'b3', 'name': '放松', 'type': 'cooldown', 'rounds': 1, 'restBetweenRoundsSeconds': 0, 'items': [
        {'exerciseId': 'h-knee-hug', 'mode': 'time', 'sets': 1, 'workSeconds': 45, 'perSide': false, 'restSeconds': 0},
      ]},
    ],
  },
};

Map<String, Object?> planOf(Map<String, Object?> env) => (env['plan']! as Map).cast<String, Object?>();
List<Object?> blocksOf(Map<String, Object?> env) => planOf(env)['blocks']! as List<Object?>;
Map<String, Object?> itemOf(Map<String, Object?> env, int b, int i) =>
    (((blocksOf(env)[b]! as Map)['items']! as List)[i]! as Map).cast<String, Object?>();
void addItem(Map<String, Object?> env, int b, Map<String, Object?> item) =>
    ((blocksOf(env)[b]! as Map)['items']! as List).add(item);

/// 校验一条模型输出（信封 → 计划 → 规则），返回错误分类集合（与 validate.py 的 E_* 对照）。
({Set<String> errors, List<PlanIssue> issues}) check(Object reply, CoachProfile profile, Catalog catalog,
    [CoachContext context = const CoachContext()]) {
  final content = reply is String ? reply : jsonEncode(reply);
  final parsed = const EnvelopeParser().parse(content);
  final issues = [...parsed.issues];
  if (parsed.reply?.plan != null) {
    issues.addAll(PlanValidator(catalog: catalog, profile: profile).validate(parsed.reply!.plan!, context).issues);
  }
  return (errors: {for (final i in issues) if (i.isError) i.category}, issues: issues);
}
