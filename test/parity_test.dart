// 与 ai-coach-eval `tools/validate.py --selftest` 的 24 个用例逐条对照：
// 同一份输出，SDK 与评测脚本给出相同的错误分类（E_*），保证评测通过率 = 线上通过率。
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  final profiles = {for (final p in ['flarelab', 'hiplab', 'smartfit']) p: loadProfile(p)};

  Map<String, Object?> mut(void Function(Map<String, Object?> env) f) {
    final e = deepCopy(okEnvelope());
    f(e);
    return e;
  }

  final quadC = {'exerciseId': 'quadriceps-C', 'mode': 'reps', 'sets': 3, 'reps': 10, 'perSide': false, 'restSeconds': 45};
  final cases = <(String, String, Object, CoachContext, Set<String>)>[
    ('合法计划', 'hiplab', okEnvelope(), const CoachContext(), {}),
    ('代码块包裹也能解析', 'hiplab', '```json\n${jsonEncode(okEnvelope())}\n```', const CoachContext(), {}),
    ('ask', 'hiplab', {'kind': 'ask', 'text': '在家还是办公室？', 'options': ['在家', '办公室']}, const CoachContext(), {}),
    ('reply', 'hiplab', {'kind': 'reply', 'text': '建议先就医。'}, const CoachContext(), {}),
    ('不是 JSON', 'hiplab', '好的，给你排一个计划', const CoachContext(), {'E_JSON'}),
    ('kind 错', 'hiplab', {'kind': 'chat', 'text': 'x'}, const CoachContext(), {'E_JSON'}),
    ('编造 id', 'hiplab', mut((e) => addItem(e, 1, {'exerciseId': 'burpee', 'mode': 'reps', 'sets': 1, 'reps': 10, 'perSide': false, 'restSeconds': 10})), const CoachContext(), {'E_UNKNOWN'}),
    ('越界：开胯 App 用胸部动作', 'hiplab', mut((e) => addItem(e, 1, {'exerciseId': 'h-incline-pushup', 'mode': 'reps', 'sets': 2, 'reps': 10, 'perSide': false, 'restSeconds': 30})), const CoachContext(), {'E_SCOPE'}),
    ('perSide 错', 'hiplab', mut((e) => itemOf(e, 1, 0)['perSide'] = false), const CoachContext(), {'E_SIDE'}),
    ('单腿臀桥 perSide=true 合法', 'hiplab', mut((e) => addItem(e, 1, {'exerciseId': 'glute-max-A', 'mode': 'reps', 'sets': 2, 'reps': 8, 'perSide': true, 'restSeconds': 20})), const CoachContext(), {}),
    ('次数超限', 'hiplab', mut((e) => itemOf(e, 1, 3)['reps'] = 40), const CoachContext(), {'E_DOSE'}),
    ('时长超限', 'hiplab', mut((e) => itemOf(e, 1, 0)['workSeconds'] = 150), const CoachContext(), {'E_DOSE'}),
    ('mode 不一致', 'hiplab', mut((e) => itemOf(e, 1, 0)..['mode'] = 'reps'..['reps'] = 10), const CoachContext(), {'E_DOSE'}),
    ('组数 0', 'hiplab', mut((e) => itemOf(e, 1, 1)['sets'] = 0), const CoachContext(), {'E_DOSE'}),
    ('热身在放松后', 'hiplab', mut((e) => blocksOf(e).add(deepCopy((blocksOf(e)[0]! as Map).cast<String, Object?>()))), const CoachContext(), {'E_ORDER'}),
    ('膝要保护却选了含膝动作', 'hiplab', mut((e) => planOf(e)['avoid'] = ['膝']), const CoachContext(), {'E_AVOID'}),
    ('请求侧 avoid 也生效', 'hiplab', okEnvelope(), const CoachContext(avoid: {'膝'}), {'E_AVOID'}),
    ('办公室着地动作', 'hiplab', mut((e) => planOf(e)['scene'] = 'office'), const CoachContext(scene: 'office'), {'E_SCENE'}),
    ('缺器械：居家没有哑铃', 'smartfit', mut((e) => addItem(e, 1, {'exerciseId': 'h-db-curl', 'mode': 'reps', 'sets': 2, 'reps': 10, 'perSide': false, 'restSeconds': 30})), const CoachContext(equipment: {}), {'E_EQUIP'}),
    ('健身房可用器械与居家动作', 'smartfit', mut((e) {
      planOf(e)['scene'] = 'gym';
      addItem(e, 1, quadC);
    }), const CoachContext(), {}),
    ('居家用健身房器械', 'smartfit', mut((e) => addItem(e, 1, quadC)), const CoachContext(), {'E_EQUIP', 'E_SCENE'}),
    ('托马斯 App 不支持办公室', 'flarelab', {
      'kind': 'plan',
      'text': 'x',
      'plan': {
        ...planOf(okEnvelope()),
        'scene': 'office',
        'blocks': [
          {'id': 'b', 'name': '主', 'type': 'main', 'rounds': 1, 'restBetweenRoundsSeconds': 0, 'items': [
            {'exerciseId': 'hamstrings-A', 'mode': 'reps', 'sets': 2, 'reps': 8, 'perSide': true, 'restSeconds': 30},
          ]},
        ],
      },
    }, const CoachContext(), {'E_SCENE'}),
    ('缺 title / 错 goal', 'hiplab', mut((e) => planOf(e)..remove('title')..['goal'] = 'fun'), const CoachContext(), {'E_SCHEMA'}),
    ('targetMinutes 超出 profile', 'hiplab', mut((e) => planOf(e)['targetMinutes'] = 90), const CoachContext(), {'E_DOSE'}),
  ];

  test('用例数与评测一致', () => expect(cases, hasLength(24)));

  for (final (name, prof, reply, ctx, expected) in cases) {
    test(name, () {
      final r = check(reply, profiles[prof]!, catalog, ctx);
      if (expected.isEmpty) {
        expect(r.errors, isEmpty, reason: r.issues.where((i) => i.isError).join('\n'));
      } else {
        // 与 validate.py 相同的判定：期望的都出现，额外的只允许是场所/器械连带错误。
        expect(r.errors.containsAll(expected), isTrue, reason: '得到 ${r.errors}：${r.issues.where((i) => i.isError).join('\n')}');
        expect(r.errors.difference(expected).difference({'E_SCENE', 'E_EQUIP'}), isEmpty, reason: '多出 ${r.errors}');
      }
    });
  }

  test('合法计划估算时长与评测一致（validate.py 输出 10.7 分钟）', () {
    final plan = const EnvelopeParser().parse(jsonEncode(okEnvelope())).reply!.plan!;
    final est = const PlanDuration().estimateSeconds(plan, catalog) / 60;
    expect(est, closeTo(10.7, 0.05));
  });
}

