/// AI 问答推荐 Agent v2（原型，可选启用；与 [CoachAgent] 并存）。
///
/// - 场景：用户原话 → 本次会话记忆 → App 默认；不反问，回传 [CoachQaReply.assumption] 和切换 chips。
/// - 代码先按原话预检索候选（同义词典 + 打分），模型多数情况下一次调用就能作答。
/// - 工具 4 个：find_actions / respond / build_plan / ask_user（只用于安全问题）。
/// - 「换第 N 个」「太难了」「就用这几个」由代码按替代/退阶关系处理，不调模型。
library;

import 'dart:convert';

import '../catalog/catalog.dart';
import '../llm/llm_client.dart';
import '../llm/llm_types.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';
import '../util/json.dart';
import 'qa_action.dart';
import 'qa_finder.dart';
import 'qa_lexicon.dart';
import 'qa_plan_builder.dart';

final class CoachQaCard {
  const CoachQaCard({required this.id, required this.name, required this.why});
  final String id;
  final String name;
  final String why;
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'why': why};
}

final class CoachQaQuestion {
  const CoachQaQuestion(this.text, this.options);
  final String text;
  final List<String> options;
  Map<String, Object?> toJson() => {'text': text, 'options': options};
}

/// 一轮的交付：回答 + 动作卡 + chips（+ 计划 / 安全追问）。
final class CoachQaReply {
  CoachQaReply({
    required this.kind,
    required this.text,
    this.cards = const [],
    this.chips = const [],
    this.assumption,
    this.plan,
    this.planSeconds,
    this.question,
    this.llmCalls = 0,
    this.elapsed = Duration.zero,
    this.usage = TokenUsage.zero,
    this.issues = const [],
    this.toolTrace = const [],
  });

  /// answer / recommend / plan / ask / replace / easier / harder / error。
  final String kind;
  final String text;
  final List<CoachQaCard> cards;
  final List<String> chips;

  /// 例如「按居家徒手」。null = 场景来自用户原话。
  final String? assumption;
  final TrainingPlan? plan;
  final int? planSeconds;
  final CoachQaQuestion? question;
  final int llmCalls;
  final Duration elapsed;
  final TokenUsage usage;
  final List<String> issues;
  final List<String> toolTrace;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'text': text,
    'cards': [for (final c in cards) c.toJson()],
    'chips': chips,
    if (assumption != null) 'assumption': assumption,
    if (plan != null) 'plan': plan!.toJson(),
    if (planSeconds != null) 'planSeconds': planSeconds,
    if (question != null) 'question': question!.toJson(),
    'llmCalls': llmCalls,
    'ms': elapsed.inMilliseconds,
    if (issues.isNotEmpty) 'issues': issues,
  };
}

/// 跨会话可选注入的记忆（App 持久化）。
final class CoachQaMemory {
  const CoachQaMemory({this.scene, this.equipment = const {}});
  final String? scene;
  final Set<String> equipment;
}

/// 本会话状态：上次展示的动作、计划、场景条件。
final class CoachQaState {
  String? scene;
  String sceneSource = 'default';
  Set<String> equipment = {};
  Set<String> avoidJoints = {};
  bool noFloor = false;
  String? maxImpact;
  QaIntent? lastIntent;
  List<String> lastShown = [];
  Map<String, String> lastWhy = {};
  QaPlanResult? lastPlan;
  final List<(String, String)> history = [];
}

const _sceneZh = {'home': '居家', 'office': '办公室', 'gym': '健身房', 'hotel': '酒店房间', 'outdoor': '户外'};
const _sceneEn = {'home': 'home', 'office': 'office', 'gym': 'gym', 'hotel': 'hotel room', 'outdoor': 'outdoors'};

final class CoachQaAgent {
  CoachQaAgent({
    required this.client,
    required Catalog catalog,
    required this.profile,
    Map<String, Map<String, Object?>> aiTags = const {},
    this.memory = const CoachQaMemory(),
    this.maxCalls = 4,
    this.maxTokens = 1600,
  }) : index = QaActionIndex(catalog, aiTags: aiTags) {
    finder = QaFinder(index);
    builder = QaPlanBuilder(
      finder,
      warmupFromMinutes: profile.planRules.warmupFromMinutes,
      cooldownFromMinutes: profile.planRules.cooldownFromMinutes,
    );
  }

  final LlmClient client;
  final CoachProfile profile;
  final CoachQaMemory memory;
  final int maxCalls;
  final int maxTokens;
  final QaActionIndex index;
  late final QaFinder finder;
  late final QaPlanBuilder builder;
  final CoachQaState state = CoachQaState();

  /// 标签覆盖率（ai-tags 命中数 / 动作总数）。
  String get tagCoverage => '${index.taggedCount}/${index.length}';

  Future<CoachQaReply> send(String text, {String language = 'zh'}) async {
    final sw = Stopwatch()..start();
    final intent = parseIntent(text);
    _resolveScene(intent);
    final follow = detectFollowUp(text);
    CoachQaReply? reply;
    if (follow.kind != QaFollowUp.none) reply = _followUp(follow, intent, language, sw);
    reply ??= await _llmTurn(text, intent, language, sw);
    state.history.add((text, _historyLine(reply, language)));
    if (state.history.length > 6) state.history.removeAt(0);
    return reply;
  }

  // ---------------------------------------------------------------- 场景
  void _resolveScene(QaIntent i) {
    if (i.scene != null) {
      state.scene = i.scene;
      state.sceneSource = 'user';
      if (!i.equipment.any((e) => e != 'mat' && e != 'chair')) state.equipment = {};
    } else if (state.scene == null) {
      if (memory.scene != null) {
        state.scene = memory.scene;
        state.sceneSource = 'memory';
        state.equipment = {...memory.equipment};
      } else {
        state.scene = profile.defaultScene;
        state.sceneSource = 'default';
      }
    }
    if (i.equipment.isNotEmpty) {
      state.equipment = i.onlyEquipment ? {...i.equipment} : {...state.equipment, ...i.equipment};
    }
    if (i.bodyweightOnly) state.equipment = {};
    state.avoidJoints.addAll(i.avoidJoints);
    if (i.noFloor) state.noFloor = true;
    if (i.maxImpact != null) state.maxImpact = i.maxImpact;
  }

  String? _assumption(String lang) {
    if (state.sceneSource == 'user') return null;
    final s = state.scene ?? 'home';
    final eq = state.equipment.isEmpty ? (lang == 'en' ? 'bodyweight' : '徒手') : state.equipment.join('、');
    final prefix = state.sceneSource == 'memory' ? (lang == 'en' ? 'Same as last time: ' : '沿用上次：') : (lang == 'en' ? 'Assuming ' : '按');
    return lang == 'en' ? '$prefix${_sceneEn[s]}, $eq' : '$prefix${_sceneZh[s]}$eq';
  }

  QaQuery _query(QaIntent i, {Set<String> exclude = const {}, int limit = 8}) {
    final merged = QaIntent()
      ..muscles.addAll(i.muscles)
      ..stretchMuscles.addAll(i.stretchMuscles)
      ..types.addAll(i.types)
      ..goals.addAll(i.goals)
      ..roles.addAll(i.roles)
      ..keywords.addAll(i.keywords)
      ..avoidJoints.addAll({...i.avoidJoints, ...state.avoidJoints})
      ..equipment.addAll(i.equipment)
      ..noFloor = i.noFloor || state.noFloor
      ..maxImpact = i.maxImpact ?? state.maxImpact
      ..easy = i.easy
      ..lowIntensity = i.lowIntensity
      ..maxDifficulty = i.maxDifficulty;
    return queryFromIntent(merged, scene: state.scene ?? 'home', equipment: state.equipment, exclude: exclude, limit: limit);
  }

  List<String> _chips(String lang, {bool plan = false}) => lang == 'en'
      ? [plan ? 'Make it 10 min' : 'Make it a 10-min session', 'Easier', 'Change place']
      : [plan ? '缩短到10分钟' : '排成10分钟', '换简单点', '换场地'];

  // ---------------------------------------------------------------- 代码跟进
  CoachQaReply? _followUp(QaFollowUpMatch f, QaIntent intent, String lang, Stopwatch sw) {
    final en = lang == 'en';
    final planIds = state.lastPlan?.orderedIds ?? const <String>[];
    final shown = state.lastShown;
    switch (f.kind) {
      case QaFollowUp.useThese:
        if (shown.isEmpty && planIds.isEmpty) return null;
        final minutes = f.minutes ?? intent.minutes ?? 10;
        final ids = shown.isNotEmpty ? shown : planIds;
        final base = _query(state.lastIntent ?? intent);
        final r = builder.build(mainIds: ids, minutes: minutes, base: base, title: _planTitle(state.lastIntent ?? intent, lang), lang: lang);
        _rememberPlan(r);
        final kept = ids.where((id) => r.orderedIds.contains(id)).length;
        final text = en
            ? 'Built around the $kept moves above, with warm-up and cool-down added by time; total about ${(r.seconds / 60).round()} min.'
            : '就用上面这$kept个做主训练${r.plan.blocks.length > 1 ? '，前后补了热身和放松' : ''}，按时长排好组数，总共约${(r.seconds / 60).round()}分钟。';
        return CoachQaReply(
          kind: 'plan',
          text: text,
          plan: r.plan,
          planSeconds: r.seconds,
          chips: _chips(lang, plan: true),
          assumption: _assumption(lang),
          elapsed: sw.elapsed,
          issues: r.notes,
        );
      case QaFollowUp.replace:
        final list = planIds.isNotEmpty ? planIds : shown;
        final i = f.index ?? 0;
        if (i < 0 || i >= list.length) return null;
        final old = index[list[i]];
        if (old == null) return null;
        final base = _query(state.lastIntent ?? intent, exclude: {...list});
        final hit = finder.replacementFor(old, base, lang: lang);
        if (hit == null) return null;
        final newIds = [...list]..[i] = hit.action.id;
        if (state.lastPlan != null && planIds.isNotEmpty) {
          final r = _swapInPlan(state.lastPlan!, old.id, hit.action.id);
          _rememberPlan(r);
          return CoachQaReply(
            kind: 'replace',
            text: en
                ? 'Swapped #${i + 1} ${old.name(lang)} for ${hit.action.name(lang)}: ${hit.reason}. Everything else stays.'
                : '第${i + 1}个「${old.name(lang)}」换成了「${hit.action.name(lang)}」：${hit.reason}。其余不变，总时长约${(r.seconds / 60).round()}分钟。',
            plan: r.plan,
            planSeconds: r.seconds,
            chips: _chips(lang, plan: true),
            assumption: _assumption(lang),
            elapsed: sw.elapsed,
          );
        }
        state.lastShown = newIds;
        return CoachQaReply(
          kind: 'replace',
          text: en
              ? 'Swapped #${i + 1} for ${hit.action.name(lang)}: ${hit.reason}.'
              : '第${i + 1}个换成了「${hit.action.name(lang)}」：${hit.reason}。',
          cards: _cardsFor(newIds, lang, {...state.lastWhy, hit.action.id: hit.reason}),
          chips: _chips(lang),
          assumption: _assumption(lang),
          elapsed: sw.elapsed,
        );
      case QaFollowUp.easier:
      case QaFollowUp.harder:
        final list = shown.isNotEmpty ? shown : (state.lastPlan?.mainIds ?? const <String>[]);
        if (list.isEmpty) return null;
        final easier = f.kind == QaFollowUp.easier;
        final base = _query(state.lastIntent ?? intent, exclude: {...list});
        final out = <String>[];
        final why = <String, String>{};
        var changed = 0;
        for (final id in list) {
          final a = index[id];
          if (a == null) continue;
          final h = easier ? finder.easierThan(a, base.withExclude(out.toSet()), lang: lang) : finder.harderThan(a, base.withExclude(out.toSet()), lang: lang);
          if (h != null) {
            out.add(h.action.id);
            why[h.action.id] = h.reason;
            changed++;
          } else {
            out.add(id);
          }
        }
        if (changed == 0) return null;
        if (state.lastPlan != null && shown.isEmpty) {
          // 只换主训练，热身/收操和组数按原时长重排。
          final old = state.lastPlan!;
          final r = builder.build(
            mainIds: out,
            minutes: old.plan.targetMinutes,
            base: _query(state.lastIntent ?? intent, exclude: {...list}.difference(out.toSet())),
            title: old.plan.title,
            lang: lang,
          );
          _rememberPlan(r);
          return CoachQaReply(
            kind: easier ? 'easier' : 'harder',
            text: en
                ? 'Swapped $changed main moves for ${easier ? 'easier' : 'harder'} versions; time stays about ${(r.seconds / 60).round()} min.'
                : '主训练里$changed个动作换成了${easier ? '更简单' : '更难'}的版本，练的部位不变，总时长约${(r.seconds / 60).round()}分钟。',
            plan: r.plan,
            planSeconds: r.seconds,
            chips: _chips(lang, plan: true),
            assumption: _assumption(lang),
            elapsed: sw.elapsed,
          );
        }
        state.lastShown = out;
        return CoachQaReply(
          kind: easier ? 'easier' : 'harder',
          text: en
              ? 'Here are ${easier ? 'easier' : 'harder'} versions of the same moves — same muscles, ${easier ? 'less' : 'more'} demanding.'
              : '换成了${easier ? '更简单' : '更难'}的版本：练的还是同样的部位，${easier ? '对力量和控制的要求更低，先把动作做稳' : '负荷和控制要求更高'}。',
          cards: _cardsFor(out, lang, why),
          chips: _chips(lang),
          assumption: _assumption(lang),
          elapsed: sw.elapsed,
        );
      case QaFollowUp.none:
        return null;
    }
  }

  QaPlanResult _swapInPlan(QaPlanResult r, String from, String to) {
    final a = index[to]!;
    final blocks = [
      for (final b in r.plan.blocks)
        PlanBlock(
          id: b.id,
          name: b.name,
          type: b.type,
          rounds: b.rounds,
          restBetweenRoundsSeconds: b.restBetweenRoundsSeconds,
          items: [
            for (final it in b.items)
              if (it.exerciseId != from)
                it
              else
                PlanItem(
                  exerciseId: to,
                  mode: a.drill.defaultDose.mode,
                  sets: it.sets,
                  reps: a.drill.defaultDose.mode == DoseMode.reps ? (a.drill.defaultDose.reps ?? 10) : null,
                  workSeconds: a.drill.defaultDose.mode == DoseMode.time ? (a.drill.defaultDose.seconds ?? 30) : null,
                  perSide: a.drill.unilateral,
                  restSeconds: it.restSeconds,
                  replacedFrom: from,
                ),
          ],
        ),
    ];
    final p = r.plan;
    final plan = TrainingPlan(
      id: p.id,
      source: p.source,
      title: p.title,
      summary: p.summary,
      goal: p.goal,
      scene: p.scene,
      equipment: p.equipment,
      level: p.level,
      targetMinutes: p.targetMinutes,
      blocks: blocks,
      avoid: p.avoid,
    );
    return QaPlanResult(plan, const PlanDuration().estimateSeconds(plan, index.catalog).round(), r.notes);
  }

  void _rememberPlan(QaPlanResult r) {
    state.lastPlan = r;
    state.lastShown = [];
  }

  List<CoachQaCard> _cardsFor(List<String> ids, String lang, Map<String, String> why, {Map<String, QaHit>? hits}) => [
    for (final id in ids)
      if (index[id] != null)
        CoachQaCard(
          id: id,
          name: index[id]!.name(lang),
          why: why[id] ?? hits?[id]?.reason ?? (lang == 'en' ? index[id]!.summaryEn : index[id]!.summaryZh),
        ),
  ];

  String _planTitle(QaIntent i, String lang) {
    final en = lang == 'en';
    final m = i.muscles;
    if (i.types.contains('static-stretch') || i.types.contains('mobility')) return en ? 'Stretch & Release' : '拉伸放松';
    if (m.contains('quadriceps')) return en ? 'Leg Session' : '腿部训练';
    if (m.contains('glute-max')) return en ? 'Glute Session' : '臀部训练';
    if (m.contains('abs')) return en ? 'Core Session' : '核心训练';
    if (m.contains('lats')) return en ? 'Back Session' : '背部训练';
    if (i.types.contains('cardio')) return en ? 'Fat-burn Session' : '燃脂训练';
    return en ? 'Full-body Session' : '全身训练';
  }

  // ---------------------------------------------------------------- 模型轮
  static const _tools = [
    LlmTool(
      name: 'respond',
      description: '回答问题并附动作卡（问答、推荐、知识题、安全题都用它）。',
      parameters: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string', 'description': '2–4 句，直接回答这个人的问题；不写通用套话，不列剂量。'},
          'items': {
            'type': 'array',
            'description': '3–5 个动作（知识题没合适的可为空）。',
            'items': {
              'type': 'object',
              'properties': {
                'id': {'type': 'string'},
                'why': {'type': 'string', 'description': '一句话：为什么适合这个人（≤20字）'},
              },
              'required': ['id', 'why'],
            },
          },
        },
        'required': ['text', 'items'],
      },
    ),
    LlmTool(
      name: 'build_plan',
      description: '用户要一套训练/计划/N 分钟时用。只给主训练动作；热身、收操、组数和时长由代码排。',
      parameters: {
        'type': 'object',
        'properties': {
          'title': {'type': 'string', 'description': '计划名，不含数字'},
          'text': {'type': 'string', 'description': '1–3 句说这套的思路'},
          'minutes': {'type': 'integer'},
          'main_ids': {'type': 'array', 'items': {'type': 'string'}, 'description': '主训练 3–6 个，按顺序'},
        },
        'required': ['title', 'text', 'minutes', 'main_ids'],
      },
    ),
    LlmTool(
      name: 'find_actions',
      description: '候选不对题时换条件再查。只填要改的字段，其余沿用状态。',
      parameters: {
        'type': 'object',
        'properties': {
          'muscles': {'type': 'array', 'items': {'type': 'string'}, 'description': '目标主动肌 id'},
          'stretch_muscles': {'type': 'array', 'items': {'type': 'string'}, 'description': '要拉伸的肌肉 id'},
          'types': {'type': 'array', 'items': {'type': 'string'}, 'description': 'strength/cardio/static-stretch/dynamic-stretch/mobility/stability-control/balance/breathing'},
          'roles': {'type': 'array', 'items': {'type': 'string'}, 'description': 'warmup/main/cooldown'},
          'keywords': {'type': 'array', 'items': {'type': 'string'}, 'description': '动作名关键词，如 俯卧撑'},
          'avoid_joints': {'type': 'array', 'items': {'type': 'string'}, 'description': 'knee/shoulder/lumbar/wrist/neck/ankle/hip'},
          'no_floor': {'type': 'boolean'},
          'max_difficulty': {'type': 'integer'},
        },
      },
    ),
    LlmTool(
      name: 'ask_user',
      description: '只在安全问题（剧痛、麻木、肿胀、受伤/术后、孕期）缺关键信息时用。场地、器械、时长不要问。',
      parameters: {
        'type': 'object',
        'properties': {
          'question': {'type': 'string'},
          'options': {'type': 'array', 'items': {'type': 'string'}},
        },
        'required': ['question'],
      },
    ),
  ];

  String _system(String lang) =>
      '''你是「${profile.appName}」里的 AI 教练，负责健身问答、推荐动作、排训练。
规则：
1. 不要反问场地、器械、时长、水平。用状态里的场景作答；用户没说的按「假设」处理（App 会显示假设和切换按钮）。没说水平按新手。只有安全问题缺关键信息时才 ask_user。
2. 每次只调用一个工具。优先直接用「候选动作」作答：
   - 问答/推荐/知识题/安全题 → respond。text 2–4 句，针对这个人的原话回答（原因、做法、最该注意的一点）。禁止通用套话（如「不憋气、不弹震、有牵扯感即可」「注意安全」），不列组数次数。items 选 3–5 个最贴切的候选；知识题、安全题有合适动作也附上（如平板的变式、膝盖友好的下肢动作、肩痛时能练的）。why 写这个动作为什么适合这个人，不要复述动作名。
   - 要一套训练 / N 分钟 / 计划 → build_plan，main_ids 给 3–6 个主训练动作。没说时长按 15 分钟。热身、收操、组数时长由代码排，别写进 text。
   - 候选明显不对题时才 find_actions 换条件查一次。
3. 只能用候选或 find_actions 返回的 id。库里没有的动作（跑步、波比跳等）说一句没有，再用最接近的代替。
4. 疼痛：先给判断标准（什么情况可以继续、什么情况停下就医），再给能练的动作。
5. 周计划类：text 给出一周怎么排（哪几天、每次多久、练什么），items 附一次课可用的动作。
6. 用 ${lang == 'en' ? 'English' : '简体中文'} 回答。''';

  String _stateBlock(QaIntent i, List<QaHit> hits, String lang) {
    final b = StringBuffer();
    final s = state.scene ?? 'home';
    b.writeln('[状态]');
    b.writeln('场景：${_sceneZh[s]}（${state.sceneSource == 'user' ? '用户说的' : state.sceneSource == 'memory' ? '沿用记忆' : '默认假设，可直接用'}）');
    b.writeln('器械：${state.equipment.isEmpty ? '徒手（可用场景里的椅子/墙${s == 'office' ? '' : '/垫子'}）' : state.equipment.join('、')}');
    final lim = [
      if (state.avoidJoints.isNotEmpty) '避开${state.avoidJoints.map((j) => jointZh[j] ?? j).join('、')}受力',
      if (state.noFloor || s == 'office') '不躺地',
      if (state.maxImpact != null) '无跳跃、不扰邻',
    ];
    if (lim.isNotEmpty) b.writeln('限制：${lim.join('；')}');
    if (i.safetyFlag) b.writeln('安全信号：原话里有需要警惕的描述，先给判断标准；必要时 ask_user。');
    if (state.lastShown.isNotEmpty) {
      b.writeln('上次展示：${[for (var k = 0; k < state.lastShown.length; k++) '${k + 1}.${index[state.lastShown[k]]?.name('zh')}(${state.lastShown[k]})'].join(' ')}');
    }
    if (state.lastPlan != null) {
      b.writeln('上次计划：${state.lastPlan!.plan.title}，${[for (final id in state.lastPlan!.orderedIds) index[id]?.name('zh')].join('、')}');
    }
    b.writeln('[候选动作]（代码按原话检索，已过滤场景/器械/限制，按相关度排序）');
    if (hits.isEmpty) b.writeln('（无）');
    for (final h in hits) {
      final a = h.action;
      b.writeln('${a.id} | ${a.name(lang)} | 难度${a.difficulty} | ${a.sessionRole.join('/')} | ${h.reason} | ${lang == 'en' && a.summaryEn.isNotEmpty ? a.summaryEn : a.summaryZh}');
    }
    return b.toString();
  }

  Future<CoachQaReply> _llmTurn(String text, QaIntent intent, String lang, Stopwatch sw) async {
    // 跟进句（如「那来一套15分钟的」）没有新焦点时沿用上次意图。
    var eff = intent;
    if (!intent.hasFocus && state.lastIntent != null) {
      eff = state.lastIntent!;
      if (intent.minutes != null) eff.minutes = intent.minutes;
    }
    if (intent.hasFocus) state.lastIntent = intent;
    state.lastIntent ??= intent;
    var hits = finder.find(_query(eff), lang: lang);
    // 有续接的上次展示，排在候选前面。
    final hitMap = {for (final h in hits) h.action.id: h};
    final messages = <LlmMessage>[LlmMessage.system(_system(lang))];
    for (final (u, a) in state.history) {
      messages
        ..add(LlmMessage.user(u))
        ..add(LlmMessage.assistant(a));
    }
    messages.add(LlmMessage.user('$text\n\n${_stateBlock(intent, hits, lang)}'));
    var usage = TokenUsage.zero;
    var calls = 0;
    final trace = <String>[];
    final issues = <String>[];
    while (calls < maxCalls) {
      calls++;
      final LlmResponse res;
      try {
        res = await client.complete(
          LlmRequest(messages: messages, tools: _tools, toolChoice: 'auto', maxTokens: maxTokens),
        );
      } catch (e) {
        return _fallback(hits, lang, sw, calls, usage, '模型调用失败：$e');
      }
      usage = usage + res.usage;
      if (res.toolCalls.isEmpty) {
        final t = res.content.trim();
        if (t.isEmpty) continue;
        return _finishRespond(t, const [], hitMap, lang, sw, calls, usage, trace, issues);
      }
      final call = res.toolCalls.first;
      trace.add(call.name);
      Map<String, Object?> args;
      try {
        args = asMap(jsonDecode(call.arguments));
      } catch (_) {
        args = const {};
      }
      switch (call.name) {
        case 'respond':
          final items = [
            for (final it in asList(args['items'])) (asString(asMap(it)['id']) ?? '', asString(asMap(it)['why']) ?? ''),
          ];
          return _finishRespond(asString(args['text']) ?? '', items, hitMap, lang, sw, calls, usage, trace, issues);
        case 'build_plan':
          final ids = asStringList(args['main_ids']).where((id) => index[id] != null).toList();
          final minutes = asInt(args['minutes']) ?? eff.minutes ?? 15;
          final r = builder.build(
            mainIds: ids,
            minutes: minutes,
            base: _query(eff),
            title: asString(args['title']) ?? _planTitle(eff, lang),
            lang: lang,
          );
          _rememberPlan(r);
          return CoachQaReply(
            kind: 'plan',
            text: _clean(asString(args['text']) ?? ''),
            plan: r.plan,
            planSeconds: r.seconds,
            chips: _chips(lang, plan: true),
            assumption: _assumption(lang),
            llmCalls: calls,
            elapsed: sw.elapsed,
            usage: usage,
            issues: [...issues, ...r.notes],
            toolTrace: trace,
          );
        case 'ask_user':
          return CoachQaReply(
            kind: 'ask',
            text: asString(args['question']) ?? '',
            question: CoachQaQuestion(asString(args['question']) ?? '', asStringList(args['options'])),
            llmCalls: calls,
            elapsed: sw.elapsed,
            usage: usage,
            toolTrace: trace,
          );
        case 'find_actions':
          final q = _queryFromArgs(args, eff);
          hits = finder.find(q, lang: lang);
          for (final h in hits) {
            hitMap[h.action.id] = h;
          }
          messages
            ..add(LlmMessage.assistant(res.content, toolCalls: [call], reasoning: res.reasoning))
            ..add(
              LlmMessage.tool(
                call.id,
                hits.isEmpty
                    ? '没有符合条件的动作，放宽条件或直接 respond。'
                    : [
                        for (final h in hits)
                          '${h.action.id} | ${h.action.name(lang)} | 难度${h.action.difficulty} | ${h.reason} | ${h.action.summaryZh}',
                      ].join('\n'),
              ),
            );
        default:
          messages
            ..add(LlmMessage.assistant(res.content, toolCalls: [call], reasoning: res.reasoning))
            ..add(LlmMessage.tool(call.id, '未知工具 ${call.name}，只能用 respond / build_plan / find_actions / ask_user。'));
      }
    }
    return _fallback(hits, lang, sw, calls, usage, '超过调用上限');
  }

  QaQuery _queryFromArgs(Map<String, Object?> a, QaIntent base) {
    final i = QaIntent()
      ..muscles.addAll(a.containsKey('muscles') ? asStringList(a['muscles']) : base.muscles)
      ..stretchMuscles.addAll(a.containsKey('stretch_muscles') ? asStringList(a['stretch_muscles']) : base.stretchMuscles)
      ..types.addAll(a.containsKey('types') ? asStringList(a['types']) : base.types)
      ..roles.addAll(a.containsKey('roles') ? asStringList(a['roles']) : base.roles)
      ..keywords.addAll(a.containsKey('keywords') ? asStringList(a['keywords']) : base.keywords)
      ..avoidJoints.addAll({...asStringList(a['avoid_joints']), ...base.avoidJoints})
      ..equipment.addAll(base.equipment)
      ..noFloor = (asBool(a['no_floor']) ?? false) || base.noFloor
      ..maxImpact = base.maxImpact
      ..easy = base.easy
      ..maxDifficulty = asInt(a['max_difficulty']) ?? base.maxDifficulty;
    return _query(i);
  }

  CoachQaReply _finishRespond(
    String text,
    List<(String, String)> items,
    Map<String, QaHit> hitMap,
    String lang,
    Stopwatch sw,
    int calls,
    TokenUsage usage,
    List<String> trace,
    List<String> issues,
  ) {
    final ids = <String>[];
    final why = <String, String>{};
    for (final (id, w) in items) {
      if (index[id] == null) {
        issues.add('丢弃未知动作 $id');
        continue;
      }
      if (ids.contains(id) || ids.length >= 5) continue;
      ids.add(id);
      if (w.trim().isNotEmpty) why[id] = w.trim();
    }
    if (ids.isNotEmpty) {
      state.lastShown = ids;
      state.lastWhy = {for (final c in _cardsFor(ids, lang, why, hits: hitMap)) c.id: c.why};
    }
    return CoachQaReply(
      kind: ids.isEmpty ? 'answer' : 'recommend',
      text: _clean(text),
      cards: _cardsFor(ids, lang, why, hits: hitMap),
      chips: ids.isEmpty ? const [] : _chips(lang),
      assumption: ids.isEmpty ? null : _assumption(lang),
      llmCalls: calls,
      elapsed: sw.elapsed,
      usage: usage,
      issues: issues,
      toolTrace: trace,
    );
  }

  /// 去掉模型偶尔仍带上的套话尾巴。
  static String _clean(String t) {
    var s = t.trim();
    for (final p in [
      RegExp(r'[，。；]?\s*全程不憋气[^。]*。?'),
      RegExp(r'[，。；]?\s*不憋气、不弹震[^。]*。?'),
    ]) {
      s = s.replaceAll(p, '。');
    }
    return s.replaceAll(RegExp(r'。{2,}'), '。').replaceAll(RegExp(r'^。'), '');
  }

  CoachQaReply _fallback(List<QaHit> hits, String lang, Stopwatch sw, int calls, TokenUsage usage, String why) {
    final ids = [for (final h in hits.take(4)) h.action.id];
    if (ids.isNotEmpty) state.lastShown = ids;
    return CoachQaReply(
      kind: ids.isEmpty ? 'error' : 'recommend',
      text: lang == 'en' ? 'Here are a few moves that fit what you asked.' : '先按你的描述挑了几个合适的动作。',
      cards: _cardsFor(ids, lang, {for (final h in hits) h.action.id: h.reason}),
      chips: ids.isEmpty ? const [] : _chips(lang),
      assumption: _assumption(lang),
      llmCalls: calls,
      elapsed: sw.elapsed,
      usage: usage,
      issues: [why],
    );
  }

  String _historyLine(CoachQaReply r, String lang) {
    final b = StringBuffer(r.text);
    if (r.cards.isNotEmpty) b.write('\n[展示动作] ${r.cards.map((c) => c.name).join('、')}');
    if (r.plan != null) b.write('\n[计划] ${r.plan!.title}');
    return b.toString();
  }
}
