import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  const p = EnvelopeParser();
  test('plan 信封解析为 TrainingPlan', () {
    final r = p.parse(jsonEncode(okEnvelope()), planId: 'plan-x');
    expect(r.ok, isTrue, reason: '${r.issues}');
    expect(r.reply!.kind, ReplyKind.plan);
    expect(r.reply!.plan!.id, 'plan-x');
    expect(r.reply!.plan!.blocks, hasLength(3));
    expect(r.reply!.plan!.items.first.exerciseId, 'n-windshield');
  });
  test('ask 带选项', () {
    final r = p.parse('{"kind":"ask","text":"在家还是办公室？","options":["在家","办公室"]}');
    expect(r.reply!.options, ['在家', '办公室']);
  });
  test('options 超过 4 个', () {
    final r = p.parse('{"kind":"ask","text":"选？","options":["1","2","3","4","5"]}');
    expect(r.ok, isFalse);
    expect(r.issues.single.code, IssueCodes.envelope);
  });
  test('缺 text', () => expect(p.parse('{"kind":"reply"}').ok, isFalse));
  test('kind=plan 但没 plan', () => expect(p.parse('{"kind":"plan","text":"x"}').ok, isFalse));
  test('kind=reply 带 plan 只警告', () {
    final r = p.parse('{"kind":"reply","text":"x","plan":{}}');
    expect(r.ok, isTrue);
    expect(r.issues.single.isError, isFalse);
  });
  test('直接输出计划本体按 plan 包装', () {
    final r = p.parse(jsonEncode(planOf(okEnvelope())));
    expect(r.reply!.kind, ReplyKind.plan);
    expect(r.repairs, contains('bare_plan'));
  });
  test('seconds 规范化为 workSeconds', () {
    final e = okEnvelope();
    itemOf(e, 1, 0)
      ..remove('workSeconds')
      ..['seconds'] = 35;
    final r = p.parse(jsonEncode(e));
    expect(r.ok, isTrue);
    expect(r.reply!.plan!.blocks[1].items[0].workSeconds, 35);
  });
  test('结构错误逐条带路径', () {
    final e = okEnvelope();
    itemOf(e, 0, 0)['mode'] = 'count';
    itemOf(e, 1, 1)['sets'] = '2';
    (blocksOf(e)[2]! as Map)['type'] = 'stretch';
    final r = p.parse(jsonEncode(e));
    expect(r.ok, isFalse);
    final paths = r.issues.map((i) => i.path).toList();
    expect(paths, containsAll(['plan.blocks[0].items[0].mode', 'plan.blocks[1].items[1].sets', 'plan.blocks[2].type']));
    expect(r.issues.every((i) => i.category == 'E_SCHEMA'), isTrue);
  });
  test('计次动作缺 reps', () {
    final e = okEnvelope();
    itemOf(e, 0, 0).remove('reps');
    expect(p.parse(jsonEncode(e)).issues.single.path, 'plan.blocks[0].items[0].reps');
  });
  test('CoachReply JSON 往返', () {
    final r = p.parse(jsonEncode(okEnvelope())).reply!;
    final back = CoachReply.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, Object?>);
    expect(jsonEncode(back.toJson()), jsonEncode(r.toJson()));
  });
}
