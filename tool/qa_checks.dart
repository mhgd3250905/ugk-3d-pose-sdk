// v2 问答推荐的代码自动检查（tool/sim_user.dart 每轮调用）。
// 场景文件里每个场景可写 `expect`（场景级，各轮都查）和 `turns_expect`（逐轮）：
//   ask: none | place | equipment | safety | "none|safety"
//   muscles: [...]       点名部位（主动肌/辅助肌/被拉伸肌命中任一即可）；cardioOk: true 允许有氧动作
//   scene / equipment    场地与器械（严格按圈定范围：居家=选的器械，办公室=椅子+徒手，健身房不限）
//   avoid: [...] / noFloor / quiet / easy
//   modify: replace:N（N=卡片上显示的编号；计划含热身/收操连续编号）| easier | harder | retime:M | another
//   minutes: M           计划时长 ±15%
//   assumption: true     条件是假设的，要写假设说明并给 chips
//   lang: ja             模型判断的语言
//   gap: true            要如实说器械不够
//   mustSay: "正则"
//   noneOk: true         replace / easier 时范围里确实没有合格候选，可以如实说不换（核对：同一处 + 过准入的候选为空）
//   segments: [seated, standing]  分段计划：主训练各段按顺序，每段动作的姿势（drill.position）都要对
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_coach/ugk_coach_qa_v2.dart';

List<String> allIds(CoachQaReply r) => [
  for (final c in r.cards) c.id,
  for (final b in r.plan?.blocks ?? const <PlanBlock>[]) for (final i in b.items) i.exerciseId,
];

List<String> mainIds(CoachQaReply r) => r.plan != null ? r.planMainIds : [for (final c in r.cards) c.id];

const _heavy = {'dumbbell', 'band', 'kettlebell', 'barbell', 'pullup-bar', 'cable', 'dip-bars', 'rings', 'parallettes', 'mini-band'};

/// 每轮的检查：返回不通过的项（空 = 全通过）。
List<String> checkTurn({
  required CoachQaAgent agent,
  required Map<String, dynamic> expect,
  required CoachQaReply r,
  CoachQaReply? prev,
  String lang = 'zh',
}) {
  final fails = <String>[];
  final idx = agent.index;
  String nm(String id) => idx[id]?.name('zh') ?? id;

  // 1) 反问：该问的问了、不该问的没问、不连问。
  final wantAsk = (expect['ask'] as String?) ?? 'none';
  final allowed = wantAsk.split('|').toSet();
  final got = r.kind == 'ask' ? (r.askStep?.name ?? 'safety') : 'none';
  if (!allowed.contains(got)) {
    fails.add(got == 'none' ? '反问：该问「${_stepZh(wantAsk)}」没问' : '反问：多问了「${_stepZh(got)}」');
  }
  if (r.kind == 'ask' && prev != null && prev.kind == 'ask' && prev.askStep == r.askStep) {
    fails.add('反问：连着两次问同一个问题（${_stepZh(got)}）');
  }
  if (r.kind == 'ask') return fails;

  final main = mainIds(r);
  final all = allIds(r);
  if (main.isEmpty && expect['muscles'] != null) fails.add('部位：没给动作');

  // 2) 点名部位
  final muscles = ((expect['muscles'] as List?) ?? const []).cast<String>().toSet();
  if (muscles.isNotEmpty) {
    for (final id in main) {
      final a = idx[id];
      if (a == null) continue;
      final hit = [...a.primaryMuscles, ...a.secondaryMuscles, ...a.stretchedMuscles].any(muscles.contains);
      final cardio = expect['cardioOk'] == true && a.trainingType.contains('cardio');
      if (!hit && !cardio) fails.add('部位：「${nm(id)}」没练到点名部位');
    }
  }

  // 3) 场地/器械、4) 伤痛禁忌、躺地、冲击
  final scene = expect['scene'] as String?;
  final eq = expect['equipment'] == null ? null : (expect['equipment'] as List).cast<String>().toSet();
  final avoid = ((expect['avoid'] as List?) ?? const []).cast<String>();
  for (final id in all) {
    final a = idx[id];
    if (a == null) continue;
    if (scene != null && scene != 'gym') {
      // 和 Agent 同一套「圈定范围」：居家只用选的器械，办公室只到椅子 + 徒手。
      final q = QaQuery(scene: scene, equipment: eq ?? const {}, strict: eq != null || scene == 'office');
      if (!a.scenes.contains(scene == 'hotel' ? 'home' : scene)) {
        fails.add('场地：「${nm(id)}」不适合$scene');
      } else if (eq != null && !agent.finder.passes(a, q)) {
        final need = a.requiredEquipment.where(_heavy.contains).toList();
        fails.add('器械：「${nm(id)}」要${need.isEmpty ? a.requiredEquipment.join('/') : need.join('/')}');
      }
    }
    if ((expect['noFloor'] == true || scene == 'office') && a.floorRequired) fails.add('躺地：「${nm(id)}」要躺/趴地');
    if (expect['quiet'] == true && a.impact != 'none') fails.add('冲击：「${nm(id)}」有冲击/跳');
    for (final j in avoid) {
      if (stressLevel(a.jointStress[j]) >= 2) fails.add('禁忌：「${nm(id)}」$j负担中等以上');
    }
  }
  if (expect['easy'] == true) {
    for (final id in main) {
      if ((idx[id]?.difficulty ?? 1) > 2) fails.add('难度：「${nm(id)}」难度${idx[id]!.difficulty}');
    }
  }

  // 5) 文字和卡片矛盾
  final t = r.text.toLowerCase();
  for (final id in all) {
    final a = idx[id];
    if (a == null) continue;
    final n = a.name('zh');
    if (RegExp(r'不跳|无跳跃|没有跳|不用跳|零冲击|no jump').hasMatch(t) && (a.impact != 'none' || RegExp(r'跳|jump|jack').hasMatch(n))) {
      fails.add('矛盾：说不跳却有「$n」');
    }
    if (RegExp(r'不用躺|不躺|不趴|全程站|no floor').hasMatch(t) && a.floorRequired) fails.add('矛盾：说不用躺却有「$n」');
    if (RegExp(r'不用器械|不需要器械|徒手就能|no equipment').hasMatch(t) && a.requiredEquipment.any(_heavy.contains)) {
      fails.add('矛盾：说不用器械却有「$n」');
    }
    for (final (word, j) in const [('膝', 'knee'), ('腰', 'lumbar'), ('手腕', 'wrist'), ('肩', 'shoulder')]) {
      if (RegExp('$word[^，。]{0,4}(不受力|零压力|不承重|完全不)').hasMatch(t) && stressLevel(a.jointStress[j]) >= 2) {
        fails.add('矛盾：说$word不受力却有「$n」');
      }
    }
  }

  // 6) 修改类跟进：只动该动的、部位不变、时长不变
  final mod = expect['modify'] as String?;
  if (mod != null && prev != null) {
    final pm = mainIds(prev);
    if (mod.startsWith('replace:')) {
      // 第 N 个 = 卡片上显示的编号：计划按全部动作连续编号（含热身/收操），动作卡按展示顺序。
      final n = int.parse(mod.split(':')[1]) - 1;
      final po = prev.plan != null ? prev.planOrderedIds : pm;
      // 没带卡片的回复 = 卡片原样不动。
      final no = r.plan != null ? r.planOrderedIds : (main.isEmpty && r.cards.isEmpty ? po : main);
      if (po.length != no.length) fails.add('修改：动作数量变了 ${po.length}→${no.length}');
      final changed = [for (var k = 0; k < po.length && k < no.length; k++) if (po[k] != no[k]) k];
      if (changed.length != 1 || changed.first != n) fails.add('修改：应只换卡片第${n + 1}个，实际换了${changed.map((k) => k + 1).toList()}');
      if (n < po.length && n < no.length) {
        final a = idx[po[n]], b = idx[no[n]];
        // 热身/收操位置：可以换成照顾本次主训练部位的同环节动作。
        final part = prev.plan == null ? null : [for (final bl in prev.plan!.blocks) for (final _ in bl.items) bl.type][n];
        final region = {for (final id in pm) ...?idx[id]?.primaryMuscles};
        final sameArea = a != null && b != null && [...a.primaryMuscles, ...a.stretchedMuscles].any([...b.primaryMuscles, ...b.stretchedMuscles].contains);
        final sessionFit = (part == BlockType.warmup || part == BlockType.cooldown) && b != null &&
            [...b.primaryMuscles, ...b.secondaryMuscles, ...b.stretchedMuscles].any(region.contains);
        if (a != null && b != null && !sameArea && !sessionFit) {
          fails.add('修改：替换动作「${nm(no[n])}」和原动作练的不是一处');
        }
      }
      final unchanged = po.length == no.length && [for (var k = 0; k < po.length; k++) po[k] == no[k]].every((v) => v);
      if (unchanged && expect['noneOk'] == true && n < po.length && idx[po[n]] != null) {
        // 没换：只有范围里确实没有同一处的合格动作时才算对，且正文要如实说。
        fails.removeWhere((f) => f.startsWith('修改：应只换卡片第'));
        final a = idx[po[n]]!;
        final others = po.toSet();
        final can = [
          for (final b in agent.finder.inScope(scopeOf(agent)))
            if (!others.contains(b.id) && QaFinder.sameArea(a, b)) b.id,
        ];
        if (can.isNotEmpty) fails.add('修改：范围里有可换的（${can.take(3).map(nm).join('、')}）却没换');
        if (!_honest.hasMatch(r.text)) fails.add('修改：没换也没如实说没有合适的');
      }
      final ord = RegExp(r'第\s*(\d+)\s*个').firstMatch(r.text);
      if (r.kind == 'replace' && ord != null && int.parse(ord.group(1)!) != n + 1) fails.add('修改：回复里说的是第${ord.group(1)}个，用户要第${n + 1}个');
    }
    if (mod == 'easier' || mod == 'harder') {
      for (var k = 0; k < pm.length && k < main.length; k++) {
        final a = idx[pm[k]], b = idx[main[k]];
        if (a == null || b == null || a.id == b.id) continue;
        if (![...a.primaryMuscles, ...a.stretchedMuscles].any([...b.primaryMuscles, ...b.stretchedMuscles].contains)) {
          fails.add('修改：「${nm(b.id)}」和原来的「${nm(a.id)}」部位不同');
        }
        if (mod == 'easier' && b.difficulty > a.difficulty) fails.add('修改：「${nm(b.id)}」反而更难');
      }
      final same = pm.length == main.length && [for (var k = 0; k < pm.length; k++) pm[k] == main[k]].every((v) => v);
      if (same && expect['noneOk'] == true) {
        final easier = mod == 'easier';
        final can = <String>{
          for (final id in pm)
            if (idx[id] case final a?)
              for (final b in agent.finder.inScope(scopeOf(agent)))
                if (!pm.contains(b.id) && QaFinder.sameArea(a, b) && (easier ? b.difficulty < a.difficulty : b.difficulty > a.difficulty)) b.id,
        };
        if (can.isNotEmpty) fails.add('修改：范围里有${easier ? '更简单' : '更难'}的（${can.take(3).map(nm).join('、')}）却没换');
        if (!_honest.hasMatch(r.text)) fails.add('修改：没换也没如实说没有合适的');
      }
    }
    final keepMinutes = mod == 'easier' || mod == 'harder' || mod.startsWith('replace:') || mod == 'another';
    if (keepMinutes && prev.planSeconds != null && r.planSeconds != null) {
      final ratio = r.planSeconds! / prev.planSeconds!;
      if (ratio < 0.85 || ratio > 1.15) fails.add('修改：时长从${(prev.planSeconds! / 60).round()}分钟变成${(r.planSeconds! / 60).round()}分钟');
    }
    if (mod.startsWith('retime:') && r.planSeconds != null) {
      final m = int.parse(mod.split(':')[1]);
      if ((r.planSeconds! / 60 - m).abs() > m * 0.15) fails.add('修改：要$m分钟，实际${(r.planSeconds! / 60).round()}分钟');
      if (!main.toSet().containsAll(pm.take(2))) fails.add('修改：改时长时换了动作');
    }
    if (mod == 'another' && main.toSet().intersection(pm.toSet()).length > 1) fails.add('修改：再来一套和上一套重复太多');
  }
  final segs = (expect['segments'] as List?)?.cast<String>();
  if (segs != null) {
    final mains = [for (final b in r.plan?.blocks ?? const <PlanBlock>[]) if (b.type == BlockType.main) b];
    if (mains.length != segs.length) {
      fails.add('分段：要${segs.length}段（${segs.join('→')}），实际主训练${mains.length}段');
    } else {
      for (var k = 0; k < segs.length; k++) {
        for (final i in mains[k].items) {
          final pos = idx[i.exerciseId]?.drill.position;
          if (pos != segs[k]) fails.add('分段：第${k + 1}段应为${segs[k]}，「${nm(i.exerciseId)}」是$pos');
        }
      }
    }
  }
  final minutes = expect['minutes'] as int?;
  if (minutes != null) {
    if (r.planSeconds == null) {
      fails.add('时长：要$minutes分钟的计划，没给计划');
    } else if ((r.planSeconds! / 60 - minutes).abs() > minutes * 0.15) {
      fails.add('时长：要$minutes分钟，实际${(r.planSeconds! / 60).round()}分钟');
    }
  }
  if (expect['assumption'] == true) {
    if (!r.conditionsAssumed) fails.add('假设：条件应是假设的');
    if (r.assumption == null) fails.add('假设：没写按什么条件出的');
    if (r.chips.isEmpty) fails.add('假设：没给 chips');
  }
  final lang = expect['lang'] as String?;
  if (lang != null && !r.language.startsWith(lang)) fails.add('语言：应为$lang，模型判断为${r.language}');
  final off = agent.offCardMentions(r.text, {...all, ...?prev?.cards.map((c) => c.id), ...?prev?.planOrderedIds});
  if (off.isNotEmpty) fails.add('一致：正文提到卡片外的动作 ${off.map(nm).join('、')}');
  if (expect['gap'] == true && !RegExp(r'没有|没法|无法|no move', caseSensitive: false).hasMatch(r.text)) fails.add('器械缺口：没如实说库里没有');
  final must = expect['mustSay'] as String?;
  if (must != null && !RegExp(must, caseSensitive: false).hasMatch(r.text)) fails.add('内容：没提到「$must」');
  return fails;
}

final _honest = RegExp(r'没有|找不到|无法|没法|不换|暂时只有|no (other|easier|suitable)|ない|ありません|no hay|no tengo', caseSensitive: false);

/// 当前已知条件下的范围（和 Agent 的准入同一套 [QaFinder.passes]）。
QaQuery scopeOf(CoachQaAgent agent) {
  final st = agent.state;
  return QaQuery(
    scene: st.place ?? agent.profile.defaultScene,
    equipment: {...st.equipment},
    strict: st.placeKnown && (st.place != 'home' || st.equipmentKnown),
    avoidJoints: {...st.avoidJoints},
    noFloor: st.noFloor,
    smallSpace: st.smallSpace,
    maxImpact: st.quiet ? 'none' : null,
    maxDifficulty: st.easy ? 2 : null,
  );
}

String _stepZh(String s) => const {'place': '在哪练', 'equipment': '器械', 'safety': '安全追问', 'none': '不问'}[s] ?? s;
