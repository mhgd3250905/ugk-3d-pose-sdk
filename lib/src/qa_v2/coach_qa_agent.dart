/// AI 问答推荐 Agent v2（原型，可选启用；与 [CoachAgent] 并存）。
///
/// 凡是要理解用户语言的地方都交给模型，模型照着 SOP（`coach_qa_sop.md`，整份放进系统提示词）一步步填空：
/// - 第 1 步「理解」（1 次调用，`fill_form`）：判断类型、更新条件（地点 / 器械 / 限制）、练什么（结构化 id）、
///   卡片编号、下一步是问还是答。
/// - 第 2 步（1 次调用，失败或不合规时同一步内重试）：要问 → `ask_user`，问句和选项由模型用用户语言生成；
///   要答 → `respond` / `build_plan` / `swap`。
/// - 第 3 步「改写」（只在不一致时，1 次调用，`rewrite`）：正文提到卡片外的动作，或有动作因越界被去掉。
///
/// 代码只做和语言无关的部分：按结构化标签硬过滤圈定范围、按标签排序、换动作的合格候选、
/// 排计划的时长和组数、校验模型的选择都在范围和候选里、按条件来源结构化判断「不连问 / 已知不再问」。
library;

import 'dart:convert';

import '../catalog/catalog.dart';
import '../llm/llm_client.dart';
import '../llm/llm_types.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';
import '../tools/ask_user.dart';
import '../util/json.dart';
import 'coach_qa_sop.g.dart';
import 'qa_action.dart';
import 'qa_finder.dart';
import 'qa_plan_builder.dart';

export 'coach_qa_sop.g.dart' show coachQaSop;

final class CoachQaCard {
  const CoachQaCard({required this.id, required this.name, required this.why});
  final String id;
  final String name;
  final String why;
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'why': why};
}

/// 条件收集的步骤。
enum QaAskStep { place, equipment, safety }

/// 一次模型调用的记录。
final class QaStepLog {
  const QaStepLog(this.step, this.ms, {this.ok = true});
  final String step;
  final int ms;
  final bool ok;
  Map<String, Object?> toJson() => {'step': step, 'ms': ms, if (!ok) 'ok': false};
}

/// 一轮的交付。
final class CoachQaReply {
  CoachQaReply({
    required this.kind,
    required this.text,
    this.cards = const [],
    this.chips = const [],
    this.assumption,
    this.conditions = const {},
    this.plan,
    this.planSeconds,
    this.question,
    this.askStep,
    this.llmCalls = 0,
    this.elapsed = Duration.zero,
    this.usage = TokenUsage.zero,
    this.issues = const [],
    this.toolTrace = const [],
    this.steps = const [],
    this.form = const {},
    this.language = 'zh',
  });

  /// answer / recommend / plan / ask / replace / easier / harder / error。
  final String kind;
  final String text;
  final List<CoachQaCard> cards;
  final List<String> chips;

  /// 模型按用户语言写的条件说明（条件不是这轮刚给的时才有）。
  final String? assumption;

  /// 结构化条件：place / placeWord / equipment / placeSource / equipmentSource / assumed。
  final Map<String, Object?> conditions;
  final TrainingPlan? plan;
  final int? planSeconds;

  /// kind == ask 时的问题。App 把用户点的选项文字原样 send 回来即可（多选用顿号或逗号连接都行，由模型理解）。
  final AskUserQuestion? question;
  final QaAskStep? askStep;
  final int llmCalls;
  final Duration elapsed;
  final TokenUsage usage;
  final List<String> issues;
  final List<String> toolTrace;

  /// 每次模型调用：步骤名和耗时。
  final List<QaStepLog> steps;

  /// 第 1 步模型填的表（调试用）。
  final Map<String, Object?> form;

  /// 模型判断的用户语言。
  final String language;

  /// 条件是不是假设的（来自记忆、上次、默认或用户跳过）。
  bool get conditionsAssumed => conditions['assumed'] == true;

  /// 计划卡片上的动作顺序（全部动作连续编号，含热身、收操）：第 N 个 = 这里的 [N-1]。
  List<String> get planOrderedIds => [for (final b in plan?.blocks ?? const <PlanBlock>[]) for (final i in b.items) i.exerciseId];

  /// 计划里主训练的动作 id（不含热身、收操）。
  List<String> get planMainIds => [
    for (final b in plan?.blocks ?? const <PlanBlock>[])
      if (b.type == BlockType.main || b.type == BlockType.circuit) for (final i in b.items) i.exerciseId,
  ];

  Map<String, Object?> toJson() => {
    'kind': kind,
    'text': text,
    'language': language,
    'cards': [for (final c in cards) c.toJson()],
    'chips': chips,
    if (assumption != null) 'assumption': assumption,
    'conditions': conditions,
    if (plan != null) 'plan': plan!.toJson(),
    if (planSeconds != null) 'planSeconds': planSeconds,
    if (question != null) 'question': question!.toJson(),
    if (askStep != null) 'askStep': askStep!.name,
    'llmCalls': llmCalls,
    'ms': elapsed.inMilliseconds,
    'steps': [for (final s in steps) s.toJson()],
    if (issues.isNotEmpty) 'issues': issues,
  };
}

/// 跨会话可选注入的记忆（App 持久化）。有 [scene] 时地点已知；居家时 [equipment] 也视为已知。
final class CoachQaMemory {
  const CoachQaMemory({this.scene, this.equipment = const {}, this.placeWord});
  final String? scene;
  final Set<String> equipment;
  final String? placeWord;
}

/// 第 1 步模型填的表（全部结构化）。
final class QaForm {
  QaForm(this.raw);
  final Map<String, Object?> raw;

  String get language => asString(raw['language']) ?? 'zh';
  String get intent => asString(raw['intent']) ?? 'actions';
  String? get place {
    final p = asString(raw['place']);
    return const {'home', 'gym', 'office'}.contains(p) ? p : null;
  }

  String? get placeWord => _nonEmpty(asString(raw['place_word']));
  bool get equipmentKnown => asBool(raw['equipment_known']) ?? false;
  Set<String> get equipment => asStringList(raw['equipment']).toSet();
  String get answerStatus => asString(raw['answer_status']) ?? 'none';
  Set<String> get muscles => asStringList(raw['muscles']).toSet();
  Set<String> get stretchMuscles => asStringList(raw['stretch_muscles']).toSet();
  Set<String> get types => asStringList(raw['types']).toSet();
  Set<String> get goals => asStringList(raw['goals']).toSet();
  Set<String> get roles => asStringList(raw['roles']).toSet();
  Set<String> get patterns => asStringList(raw['patterns']).toSet();
  Set<String> get avoidJoints => asStringList(raw['avoid_joints']).toSet();
  bool get noFloor => asBool(raw['no_floor']) ?? false;
  bool get quiet => asBool(raw['quiet']) ?? false;
  bool get easy => asBool(raw['easy']) ?? false;
  bool get smallSpace => asBool(raw['small_space']) ?? false;
  int? get minutes => asInt(raw['minutes']);
  List<int> get positions => [for (final p in asList(raw['positions'])) if (asInt(p) != null) asInt(p)!];
  String get next => asString(raw['next']) ?? 'answer';

  bool get hasFocus => muscles.isNotEmpty || stretchMuscles.isNotEmpty || types.isNotEmpty || patterns.isNotEmpty || roles.isNotEmpty;

  static String? _nonEmpty(String? s) => s == null || s.trim().isEmpty ? null : s.trim();
}

/// 「练什么」：从表里抽出的焦点，跨轮沿用。
final class QaFocus {
  const QaFocus({
    this.muscles = const {},
    this.stretchMuscles = const {},
    this.types = const {},
    this.goals = const {},
    this.roles = const {},
    this.patterns = const {},
    this.minutes,
    this.intent = 'actions',
  });
  factory QaFocus.of(QaForm f, {String? intent}) => QaFocus(
    muscles: f.muscles,
    stretchMuscles: f.stretchMuscles,
    types: f.types,
    goals: f.goals,
    roles: f.roles,
    patterns: f.patterns,
    minutes: f.minutes,
    intent: intent ?? f.intent,
  );
  final Set<String> muscles;
  final Set<String> stretchMuscles;
  final Set<String> types;
  final Set<String> goals;
  final Set<String> roles;
  final Set<String> patterns;
  final int? minutes;
  final String intent;
}

/// 本会话状态（全部结构化）。
final class CoachQaState {
  String? place;
  String? placeWord;

  /// none / user（用户说的）/ answered（答了问题）/ memory / skipped（用户跳过，按默认）。
  String placeSource = 'none';
  int placeTurn = -1;
  bool equipmentKnown = false;
  Set<String> equipment = {};
  String equipmentSource = 'none';
  int equipmentTurn = -1;
  Set<String> avoidJoints = {};
  bool noFloor = false;
  bool quiet = false;
  bool easy = false;
  bool smallSpace = false;
  String language = 'zh';
  QaFocus? focus;
  List<String> lastShown = [];
  Map<String, String> lastWhy = {};
  QaPlanResult? lastPlan;

  /// 上一轮问的是哪一步（保证同一个问题不连问两次）；null = 上一轮没问。
  QaAskStep? lastAsk;

  /// 等回答时的原请求（焦点 + 原话）。
  QaFocus? pendingFocus;
  String? pendingText;
  int turn = 0;
  final List<(String, String)> history = [];

  bool get placeKnown => place != null;
}

const _thinkingMax = <String, Object?>{
  'thinking': {'type': 'enabled'},
  'reasoning_effort': 'max',
};

final class CoachQaAgent {
  CoachQaAgent({
    required this.client,
    required Catalog catalog,
    required this.profile,
    Map<String, Map<String, Object?>> aiTags = const {},
    this.memory = const CoachQaMemory(),
    this.sop = coachQaSop,
    this.thinking = _thinkingMax,
    this.maxTokens = 24000,
    this.maxRetriesPerStep = 2,
  }) : index = QaActionIndex(catalog, aiTags: aiTags) {
    finder = QaFinder(index, profile: profile);
    builder = QaPlanBuilder(
      finder,
      warmupFromMinutes: profile.planRules.warmupFromMinutes,
      cooldownFromMinutes: profile.planRules.cooldownFromMinutes,
    );
    if (memory.scene != null) {
      state.place = memory.scene == 'hotel' ? 'home' : memory.scene;
      state.placeWord = memory.placeWord;
      state.placeSource = 'memory';
      if (state.place == 'home') {
        state.equipmentKnown = true;
        state.equipment = {...memory.equipment};
        state.equipmentSource = 'memory';
      }
    }
  }

  final LlmClient client;
  final CoachProfile profile;
  final CoachQaMemory memory;

  /// 给模型的 SOP（默认是 `coach_qa_sop.md` 的内容）；App 可以换成自己的版本。
  final String sop;

  /// 每次请求附带的思考参数。默认 DeepSeek 思考开到最大档：`thinking.enabled` + `reasoning_effort: max`。
  final Map<String, Object?> thinking;
  final int maxTokens;
  final int maxRetriesPerStep;

  final QaActionIndex index;
  late final QaFinder finder;
  late final QaPlanBuilder builder;
  final CoachQaState state = CoachQaState();

  String get tagCoverage => '${index.taggedCount}/${index.length}';

  Future<CoachQaReply> send(String text, {String language = 'zh'}) async {
    final run = _Run(Stopwatch()..start());
    state.turn++;
    if (state.turn == 1) state.language = language;
    final askedLast = state.lastAsk;
    state.lastAsk = null;
    CoachQaReply reply;
    try {
      reply = await _turn(text, askedLast, run);
    } on _StepFailed catch (e) {
      reply = run.reply(kind: 'error', text: '', issues: ['step failed: ${e.step}: ${e.why}'], language: state.language);
    }
    if (reply.kind == 'ask' && reply.askStep != null) state.lastAsk = reply.askStep;
    state.history.add((text, _historyLine(reply)));
    if (state.history.length > 8) state.history.removeAt(0);
    return reply;
  }

  // ---------------------------------------------------------------- 第 1 步：理解

  Future<CoachQaReply> _turn(String text, QaAskStep? askedLast, _Run run) async {
    final form = await _understand(text, askedLast, run);
    run.form = form.raw;
    state.language = form.language;
    final intent = _applyForm(form, askedLast, text);

    // 下一步：模型判断；代码只按结构化状态拦「已知还问」「连问同一个」。
    var next = form.next;
    if (next == 'ask_place' && askedLast == QaAskStep.place) next = 'answer';
    if (next == 'ask_equipment' && askedLast == QaAskStep.equipment) next = 'answer';
    if (next == 'ask_safety' && askedLast == QaAskStep.safety) next = 'answer';
    if (next == 'ask_place' && state.placeKnown && intent != 'change_place') {
      run.issues.add('guard: place already known');
      next = state.place == 'home' && !state.equipmentKnown && askedLast != QaAskStep.equipment ? 'ask_equipment' : 'answer';
    }
    if (next == 'ask_equipment' && (state.place != 'home' || state.equipmentKnown)) {
      run.issues.add('guard: equipment not needed');
      next = 'answer';
    }
    if (next == 'answer' && askedLast != null && (askedLast == QaAskStep.place || askedLast == QaAskStep.equipment)) {
      // 问过却没得到答案（或模型想再问）：按默认补齐，不再问。
      _fillSkipped();
    }
    if (intent == 'change_place' && next != 'ask_place') next = askedLast == QaAskStep.place ? 'answer' : 'ask_place';

    switch (next) {
      case 'ask_place':
        return _ask(QaAskStep.place, text, run);
      case 'ask_equipment':
        return _ask(QaAskStep.equipment, text, run);
      case 'ask_safety':
        return _ask(QaAskStep.safety, text, run);
    }
    final answerIntent = intent == 'change_place' || intent == 'answer_pending' ? (state.focus?.intent ?? 'actions') : intent;
    return _answer(answerIntent, text, run);
  }

  Future<QaForm> _understand(String text, QaAskStep? askedLast, _Run run) async {
    final ctx = StringBuffer()
      ..writeln('[当前步骤] 第 1 步：理解。按 SOP 第 1 步填表，调用 fill_form。')
      ..writeln(_conditionsBlock())
      ..writeln('[上一轮问过] ${askedLast?.name ?? '无'}')
      ..writeln(state.pendingText == null || askedLast == null ? '' : '[等回答的原请求] ${state.pendingText}')
      ..writeln(_cardsBlock())
      ..writeln('[用户这句话]')
      ..writeln(text);
    final args = await _call(step: 'understand', tool: _fillFormTool, context: ctx.toString(), run: run);
    return QaForm(args);
  }

  /// 把表写进状态（结构化合并），返回这轮的意图。
  String _applyForm(QaForm f, QaAskStep? askedLast, String text) {
    var intent = f.intent;
    final answering = askedLast != null && f.answerStatus != 'none';
    // 只有地点/器械问题才有「跳过就按默认」；安全追问没回答不影响条件收集。
    final conditionAsk = askedLast == QaAskStep.place || askedLast == QaAskStep.equipment;
    if (intent == 'change_place') {
      state.place = null;
      state.placeWord = null;
      state.placeSource = 'none';
      state.equipmentKnown = false;
      state.equipment = {};
      state.equipmentSource = 'none';
    } else if (answering && conditionAsk && f.answerStatus == 'skipped') {
      // 用户跳过了地点/器械问题：不采用模型替用户填的条件，下面按默认补齐（来源记为 skipped）。
    } else {
      final p = f.place;
      if (p != null && (p != state.place || (f.placeWord != null && f.placeWord != state.placeWord) || !state.placeKnown)) {
        final samePlace = p == state.place;
        if (!samePlace) {
          state.equipmentKnown = false;
          state.equipment = {};
          state.equipmentSource = 'none';
        }
        state.place = p;
        state.placeWord = f.placeWord ?? (samePlace ? state.placeWord : null);
        state.placeSource = askedLast == QaAskStep.place ? 'answered' : 'user';
        state.placeTurn = state.turn;
      }
      if (state.place == 'home' && f.equipmentKnown) {
        final eq = f.equipment;
        if (!state.equipmentKnown || eq.length != state.equipment.length || !eq.containsAll(state.equipment)) {
          state.equipment = eq;
          state.equipmentKnown = true;
          state.equipmentSource = askedLast == QaAskStep.equipment ? 'answered' : 'user';
          state.equipmentTurn = state.turn;
        }
      }
    }
    state.avoidJoints.addAll(f.avoidJoints);
    if (f.noFloor) state.noFloor = true;
    if (f.quiet) state.quiet = true;
    if (f.easy) state.easy = true;
    if (f.smallSpace) state.smallSpace = true;

    if (answering && conditionAsk && f.answerStatus == 'skipped') _fillSkipped();
    // 焦点：这轮有就用这轮的；在回答问题时沿用原请求；跟进句沿用上次。
    if (f.hasFocus) {
      state.focus = QaFocus.of(f, intent: intent == 'answer_pending' ? (state.pendingFocus?.intent ?? 'actions') : intent);
    } else if (answering && state.pendingFocus != null) {
      final p = state.pendingFocus!;
      state.focus = QaFocus(
        muscles: p.muscles,
        stretchMuscles: p.stretchMuscles,
        types: p.types,
        goals: p.goals,
        roles: p.roles,
        patterns: p.patterns,
        minutes: f.minutes ?? p.minutes,
        intent: p.intent,
      );
      if (intent == 'answer_pending') intent = p.intent;
    } else if (state.focus != null && f.minutes != null) {
      final p = state.focus!;
      state.focus = QaFocus(muscles: p.muscles, stretchMuscles: p.stretchMuscles, types: p.types, goals: p.goals, roles: p.roles, patterns: p.patterns, minutes: f.minutes, intent: p.intent);
    }
    state.focus ??= QaFocus.of(f);
    if (!answering) {
      state.pendingFocus = state.focus;
      state.pendingText = text;
    }
    return intent;
  }

  void _fillSkipped() {
    if (!state.placeKnown) {
      state.place = profile.defaultScene == 'hotel' ? 'home' : profile.defaultScene;
      state.placeSource = 'skipped';
      state.placeTurn = state.turn;
    }
    if (state.place == 'home' && !state.equipmentKnown) {
      state.equipmentKnown = true;
      state.equipment = {};
      state.equipmentSource = 'skipped';
      state.equipmentTurn = state.turn;
    }
  }

  // ---------------------------------------------------------------- 第 2 步 A：问

  Future<CoachQaReply> _ask(QaAskStep step, String text, _Run run) async {
    final ctx = StringBuffer()
      ..writeln('[当前步骤] 第 2 步 A：问一个问题。要问的是：${switch (step) {
        QaAskStep.place => 'ask_place（地点，单选）',
        QaAskStep.equipment => 'ask_equipment（器械，多选）',
        QaAskStep.safety => 'ask_safety（安全）',
      }}。用户语言：${state.language}。调用 ask_user。')
      ..writeln(_conditionsBlock())
      ..writeln('[原请求] ${state.pendingText ?? text}')
      ..writeln('[用户这句话] $text');
    final args = await _call(step: 'ask', tool: _askTool, context: ctx.toString(), run: run, validate: (a) {
      final q = asString(a['question'])?.trim() ?? '';
      if (q.isEmpty) return 'question 不能为空';
      final n = asStringList(a['options']).where((o) => o.trim().isNotEmpty).length;
      if (step != QaAskStep.safety && (n < 2 || n > 6)) return 'options 需要 2–6 个';
      return null;
    });
    final question = AskUserQuestion.direct(
      asString(args['question']) ?? '',
      options: asStringList(args['options']),
      multiple: step == QaAskStep.equipment,
      language: state.language,
    );
    return run.reply(kind: 'ask', text: question.question, question: question, askStep: step, language: state.language, conditions: _conditions());
  }

  // ---------------------------------------------------------------- 第 2 步 B：答

  bool get _strict {
    if (!state.placeKnown) return false;
    return state.place == 'home' ? state.equipmentKnown : true;
  }

  QaQuery _query({Set<String> exclude = const {}, int limit = 12}) {
    final f = state.focus ?? const QaFocus();
    return QaQuery(
      scene: state.place ?? profile.defaultScene,
      equipment: state.equipment,
      strict: _strict,
      muscles: f.muscles,
      stretchMuscles: f.stretchMuscles,
      types: f.types,
      goals: f.goals,
      roles: f.roles,
      patterns: f.patterns,
      avoidJoints: state.avoidJoints,
      noFloor: state.noFloor,
      smallSpace: state.smallSpace,
      maxImpact: state.quiet ? 'none' : null,
      maxDifficulty: state.easy ? 2 : null,
      targetDifficulty: state.easy ? 1 : 2,
      preferEquipment: state.equipment.difference(const {'mat', 'chair'}),
      exclude: exclude,
      limit: limit,
    );
  }

  bool get _assumed {
    if (!state.placeKnown) return true;
    const given = {'user', 'answered'};
    final eqOk = state.place != 'home' || given.contains(state.equipmentSource);
    final latest = state.place == 'home' && state.equipmentTurn > state.placeTurn ? state.equipmentTurn : state.placeTurn;
    return !(given.contains(state.placeSource) && eqOk && latest == state.turn);
  }

  Map<String, Object?> _conditions() => {
    'place': state.place,
    if (state.placeWord != null) 'placeWord': state.placeWord,
    'placeSource': state.placeSource,
    if (state.place == 'home') 'equipment': state.equipmentKnown ? state.equipment.toList() : null,
    if (state.place == 'home') 'equipmentSource': state.equipmentSource,
    'assumed': _assumed,
  };

  Future<CoachQaReply> _answer(String intent, String text, _Run run) async {
    final planIds = state.lastPlan?.orderedIds ?? const <String>[];
    final shown = state.lastShown;
    final hasCards = shown.isNotEmpty || planIds.isNotEmpty;
    if (const {'swap', 'easier', 'harder'}.contains(intent) && hasCards) return _swap(intent, text, run);
    if (const {'retime', 'use_these'}.contains(intent) && !hasCards) intent = 'plan';
    if (intent == 'retime' && state.lastPlan == null) intent = 'use_these';
    if (intent == 'another' && !hasCards) intent = 'actions';
    final isPlan = const {'plan', 'another', 'use_these', 'retime'}.contains(intent);

    final exclude = intent == 'another' ? {...planIds, ...shown} : <String>{};
    final base = _query(exclude: exclude);
    final List<QaAction> candidates = switch (intent) {
      'use_these' => [for (final id in shown.isNotEmpty ? shown : state.lastPlan!.mainIds) if (index[id] != null && finder.passes(index[id]!, base.scopeOnly)) index[id]!],
      'retime' => [for (final id in state.lastPlan!.mainIds) if (index[id] != null) index[id]!],
      _ => [for (final h in finder.find(base)) h.action],
    };
    final gap = isPlan || intent == 'actions' ? _gap(base) : const <String>[];
    final ctx = StringBuffer()
      ..writeln('[当前步骤] 第 2 步 B：给结果。intent = $intent。用户语言：${state.language}。调用 ${isPlan ? 'build_plan' : 'respond'}。')
      ..writeln(_conditionsBlock())
      ..writeln(_scopeBlock(base))
      ..writeln(gap.isEmpty ? '[范围缺口] 无' : '[范围缺口]\n${gap.join('\n')}')
      ..writeln(_cardsBlock())
      ..writeln(intent == 'retime' || intent == 'use_these' ? '[候选动作]（就是要沿用的主训练，main_ids 用它们，不换）' : '[候选动作]（都在范围内，按相关度排序）')
      ..writeln(candidates.isEmpty ? '（无）' : candidates.map(_actionLine).join('\n'))
      ..writeln('[用户这句话] $text');
    final allowed = {for (final a in candidates) a.id};
    if (isPlan) {
      // 模型掌舵：代码只验收 build_plan 的交付，不合格就把原因退回给模型改，不替它改顺序。
      final keep = intent == 'retime' || intent == 'use_these' ? {for (final a in candidates) a.id} : const <String>{};
      int minutesFor(Map<String, Object?> a) => intent == 'retime' || intent == 'another' || intent == 'use_these'
          ? (state.focus?.minutes ?? asInt(a['minutes']) ?? state.lastPlan?.plan.targetMinutes ?? 15)
          : (asInt(a['minutes']) ?? state.focus?.minutes ?? 15);
      QaPlanResult? built;
      var warnedFit = false;
      var warnedScope = false;
      QaPlanResult buildFrom(Map<String, Object?> a) {
        final (mains, names, segOf) = _planMains(a);
        return builder.build(
          mainIds: mains,
          minutes: minutesFor(a),
          base: base.copyWith(exclude: const {}),
          title: asString(a['title']),
          blockNames: {for (final e in asMap(a['block_names']).entries) e.key: '${e.value}'},
          warmIds: intent == 'retime' ? _blockIds(BlockType.warmup) : null,
          coolIds: intent == 'retime' ? _blockIds(BlockType.cooldown) : null,
          segmentNames: names,
          segmentOf: segOf,
          autoWarmup: a['warmup'] != false,
          autoCooldown: a['cooldown'] != false,
        );
      }
      final args = await _call(step: 'answer', tool: _planTool, context: ctx.toString(), run: run, validate: (a) {
        final (ids, names, _) = _planMains(a);
        if (ids.isEmpty && candidates.isNotEmpty) return 'main_ids 不能为空';
        if (ids.toSet().length != ids.length) return 'main_ids 有重复的 id';
        final bad = ids.where((id) => !allowed.contains(id)).toList();
        if (bad.isNotEmpty && candidates.isNotEmpty) return 'main_ids 只能用候选里的 id，这些不在候选里：${bad.join(', ')}';
        if (intent == 'retime' && !ids.toSet().containsAll(keep)) {
          return 'retime 不换动作，main_ids 要包含当前主训练全部动作（顺序可按用户要求调整）：${keep.join(', ')}';
        }
        final segs = asList(a['segments']);
        if (segs.isNotEmpty && names.length != segs.length) return 'segments 每段都要有 name 和非空 ids';
        final r = buildFrom(a);
        final out = [for (final n in r.notes) if (n.startsWith('out_of_scope:')) n.substring(13)];
        if (out.isNotEmpty && !warnedScope) {
          warnedScope = true;
          return '这些动作不符合用户当前条件，不能用：${out.join(', ')}。请从候选里换掉后重交';
        }
        final padded = [for (final n in r.notes) if (n.startsWith('padded:')) n.substring(7)];
        final trimmed = [for (final n in r.notes) if (n.startsWith('trimmed:')) n.substring(8)];
        if ((padded.isNotEmpty || trimmed.isNotEmpty) && !warnedFit) {
          warnedFit = true;
          final m = minutesFor(a);
          return '你给的主训练和 $m 分钟对不上：代码要${padded.isNotEmpty ? '补上 ${padded.join(', ')}' : ''}${trimmed.isNotEmpty ? '去掉 ${trimmed.join(', ')}' : ''}。'
              '请自己调整 main_ids（或按用户原话调整 minutes）后重交；坚持原样就原样重交，代码会照上面补/去，正文要如实说明。';
        }
        built = r;
        return null;
      });
      final r = built ?? buildFrom(args);
      state.lastPlan = r;
      state.lastShown = [];
      final dropped = [for (final n in r.notes) if (n.startsWith('out_of_scope:')) n.substring(13)];
      final finalText = await _consistent(asString(args['text']) ?? '', r.orderedIds, dropped: dropped, run: run);
      return run.reply(
        kind: 'plan',
        text: finalText,
        plan: r.plan,
        planSeconds: r.seconds,
        chips: asStringList(args['chips']),
        assumption: _assumed ? _nonEmpty(asString(args['assumption'])) : null,
        conditions: _conditions(),
        language: state.language,
        extraIssues: r.notes,
      );
    }
    final args = await _call(step: 'answer', tool: _respondTool, context: ctx.toString(), run: run, validate: (a) {
      final items = [for (final it in asList(a['items'])) asString(asMap(it)['id']) ?? ''];
      final bad = items.where((id) => !allowed.contains(id)).toList();
      if (bad.isNotEmpty) return 'items 只能用候选里的 id，这些不在候选里：${bad.join(', ')}';
      if (intent == 'actions' && items.isEmpty && candidates.isNotEmpty) return '用户要动作，items 不能为空（从候选里选 3–5 个）';
      return null;
    });
    final ids = <String>[];
    final why = <String, String>{};
    final dropped = <String>[];
    for (final it in asList(args['items'])) {
      final m = asMap(it);
      final id = asString(m['id']) ?? '';
      final a = index[id];
      if (a == null || !allowed.contains(id) || !finder.passes(a, base.scopeOnly)) {
        if (a != null) dropped.add(id);
        continue;
      }
      if (ids.contains(id) || ids.length >= 5) continue;
      ids.add(id);
      final w = asString(m['why'])?.trim() ?? '';
      if (w.isNotEmpty) why[id] = w;
    }
    if (ids.isNotEmpty) {
      state.lastPlan = null;
      state.lastShown = ids;
      state.lastWhy = {for (final id in ids) id: why[id] ?? _summary(index[id]!)};
    }
    final finalText = await _consistent(asString(args['text']) ?? '', ids, dropped: dropped, run: run);
    return run.reply(
      kind: ids.isEmpty ? 'answer' : 'recommend',
      text: finalText,
      cards: _cardsFor(ids, why),
      chips: asStringList(args['chips']),
      assumption: ids.isNotEmpty && _assumed ? _nonEmpty(asString(args['assumption'])) : null,
      conditions: _conditions(),
      language: state.language,
    );
  }

  /// 换动作 / 退阶 / 进阶：代码按标签给每个编号列出合格候选，模型挑一个并写理由。
  Future<CoachQaReply> _swap(String intent, String text, _Run run) async {
    final inPlan = state.lastShown.isEmpty && state.lastPlan != null;
    final list = inPlan ? state.lastPlan!.orderedIds : state.lastShown;
    final roles = inPlan
        ? [for (final b in state.lastPlan!.plan.blocks) for (final _ in b.items) switch (b.type) { BlockType.warmup => 'warmup', BlockType.cooldown => 'cooldown', _ => 'main' }]
        : List.filled(list.length, 'main');
    var positions = QaForm(run.form).positions;
    if (positions.isEmpty) {
      positions = [for (var k = 0; k < list.length; k++) if (intent == 'swap' ? k == 0 : roles[k] == 'main') k + 1];
      if (intent == 'swap') run.issues.add('swap without positions');
    }
    final mode = switch (intent) { 'easier' => QaSwapMode.easier, 'harder' => QaSwapMode.harder, _ => QaSwapMode.any };
    final base = _query(exclude: {...list});
    final region = {for (var k = 0; k < list.length; k++) if (roles[k] == 'main') ...?index[list[k]]?.primaryMuscles};
    final options = <int, List<QaAction>>{};
    final out = <int>[];
    final b = StringBuffer();
    for (final p in positions.toSet()) {
      if (p < 1 || p > list.length) {
        out.add(p);
        continue;
      }
      final a = index[list[p - 1]];
      if (a == null) continue;
      final c = finder.swapCandidates(a, base, mode: mode, focus: (state.focus?.muscles ?? const {}), sessionRegion: region, role: inPlan ? roles[p - 1] : null)
          .where((x) => x.id != a.id)
          .toList();
      options[p] = c;
      b
        ..writeln('第 $p 个（${roles[p - 1]}）原动作：${_actionLine(a)}')
        ..writeln(c.isEmpty ? '  候选：（无，没有合格的替换）' : c.map((x) => '  候选：${_actionLine(x)}').join('\n'));
    }
    final ctx = StringBuffer()
      ..writeln('[当前步骤] 第 2 步 B：给结果。intent = $intent。用户语言：${state.language}。调用 swap。')
      ..writeln(_conditionsBlock())
      ..writeln(_cardsBlock())
      ..writeln('[可替换]')
      ..write(b)
      ..writeln(out.isEmpty ? '' : '[超出范围的编号] ${out.join(', ')}（卡片一共 ${list.length} 个）')
      ..writeln('[用户这句话] $text');
    final args = await _call(step: 'answer', tool: _swapTool, context: ctx.toString(), run: run, validate: (a) {
      for (final ch in asList(a['changes'])) {
        final m = asMap(ch);
        final p = asInt(m['position']);
        final id = asString(m['new_id']);
        if (p == null || !options.containsKey(p)) return 'position $p 不在要换的编号里（${options.keys.join(', ')}）';
        if (!options[p]!.any((x) => x.id == id)) return '第 $p 个只能从它的候选里选，$id 不是它的候选';
      }
      return null;
    });
    final changes = <int, (String, String)>{};
    final used = <String>{};
    for (final ch in asList(args['changes'])) {
      final m = asMap(ch);
      final p = asInt(m['position'])!;
      final id = asString(m['new_id'])!;
      if (changes.containsKey(p) || used.contains(id)) continue;
      changes[p] = (id, asString(m['why'])?.trim() ?? '');
      used.add(id);
    }
    final kind = changes.isEmpty ? 'answer' : (intent == 'swap' ? 'replace' : intent);
    final replacedOld = [for (final p in changes.keys) list[p - 1]];
    if (inPlan) {
      var r = state.lastPlan!;
      for (final e in changes.entries) {
        r = _swapInPlan(r, e.key - 1, e.value.$1);
      }
      state.lastPlan = r;
      final finalText = await _consistent(asString(args['text']) ?? '', r.orderedIds, also: replacedOld, run: run);
      return run.reply(
        kind: kind,
        text: finalText,
        plan: r.plan,
        planSeconds: r.seconds,
        chips: asStringList(args['chips']),
        assumption: null,
        conditions: _conditions(),
        language: state.language,
      );
    }
    final ids = [...list];
    final why = {...state.lastWhy};
    for (final e in changes.entries) {
      ids[e.key - 1] = e.value.$1;
      why[e.value.$1] = e.value.$2.isEmpty ? _summary(index[e.value.$1]!) : e.value.$2;
    }
    state.lastShown = ids;
    state.lastWhy = why;
    final finalText = await _consistent(asString(args['text']) ?? '', ids, also: replacedOld, run: run);
    return run.reply(
      kind: kind,
      text: finalText,
      cards: _cardsFor(ids, why),
      chips: asStringList(args['chips']),
      conditions: _conditions(),
      language: state.language,
    );
  }

  List<String> _blockIds(BlockType t) => [
    for (final b in state.lastPlan?.plan.blocks ?? const <PlanBlock>[])
      if (b.type == t) for (final i in b.items) i.exerciseId,
  ];

  /// 范围缺口：点名的部位在当前范围里一个主练动作都没有时，结构化地告诉模型（最接近的范围内动作 + 加什么器械就有）。
  List<String> _gap(QaQuery q) {
    final s = state.place ?? profile.defaultScene;
    if (s == 'gym' || q.muscles.isEmpty) return const [];
    final scope = finder.inScope(q);
    final out = <String>[];
    for (final m in q.muscles) {
      if (scope.any((a) => a.primaryMuscles.contains(m))) continue;
      final closest = scope.where((a) => a.secondaryMuscles.contains(m)).take(2).map((a) => a.id).toList();
      String? unlock;
      if (s == 'home' && _strict) {
        for (final e in const ['dumbbell', 'band', 'mat', 'chair']) {
          if (state.equipment.contains(e)) continue;
          final q2 = QaQuery(scene: 'home', equipment: {...state.equipment, e}, strict: true, avoidJoints: q.avoidJoints, noFloor: q.noFloor, maxImpact: q.maxImpact);
          if (index.all.any((a) => a.primaryMuscles.contains(m) && finder.passes(a, q2))) {
            unlock = e;
            break;
          }
        }
      }
      out.add('muscle=$m：范围内主练它的动作 0 个；辅助练到它的范围内动作：${closest.isEmpty ? '无' : closest.join(', ')}；'
          '${unlock == null ? '加常见家用器械也没有' : '加 $unlock 就有主练它的动作（只说器械，不说范围外的动作名）'}');
    }
    return out;
  }

  // ---------------------------------------------------------------- 第 3 步：一致性

  /// 正文提到卡片外的动作名，或有动作因越界被去掉 → 带着最终清单让模型重写一次。
  Future<String> _consistent(String text, List<String> finalIds, {List<String> dropped = const [], List<String> also = const [], required _Run run}) async {
    final off = offCardMentions(text, {...finalIds, ...also});
    if (off.isEmpty && dropped.isEmpty) return text.trim();
    run.issues.add('rewrite: off-card ${off.join(',')} dropped ${dropped.join(',')}');
    final ctx = StringBuffer()
      ..writeln('[当前步骤] 第 3 步：改写正文。用户语言：${state.language}。调用 rewrite。')
      ..writeln('[原正文] $text')
      ..writeln('[最终卡片]')
      ..writeln([for (var k = 0; k < finalIds.length; k++) '${k + 1}. ${_names(index[finalIds[k]])}'].join('\n'))
      ..writeln(also.isEmpty ? '' : '[本轮被换掉的原动作，可以提] ${also.map((id) => _names(index[id])).join('；')}')
      ..writeln(off.isEmpty ? '' : '[正文提到但不在卡片上的动作] ${off.map((id) => _names(index[id])).join('；')}')
      ..writeln(dropped.isEmpty ? '' : '[因超出用户条件被去掉的动作] ${dropped.map((id) => _names(index[id])).join('；')}');
    final args = await _call(step: 'rewrite', tool: _rewriteTool, context: ctx.toString(), run: run, validate: (a) {
      final t = asString(a['text'])?.trim() ?? '';
      if (t.isEmpty) return 'text 不能为空';
      final still = offCardMentions(t, {...finalIds, ...also, ...dropped});
      if (still.isNotEmpty) return '正文仍提到卡片外的动作：${still.map((id) => _names(index[id])).join('；')}';
      return null;
    });
    return (asString(args['text']) ?? text).trim();
  }

  /// 正文里出现的、不在 [allowed] 里的动作（按目录里各语言的名字字面匹配，与语言无关）。
  List<String> offCardMentions(String text, Set<String> allowed) {
    final t = text.toLowerCase();
    final allowedNames = [for (final id in allowed) ...?index[id]?.allNames.map((n) => n.toLowerCase())];
    final out = <String>[];
    for (final a in index.all) {
      if (allowed.contains(a.id)) continue;
      for (final raw in a.allNames) {
        final n = raw.toLowerCase().trim();
        final ascii = n.codeUnits.every((c) => c < 128);
        if (n.runes.length < (ascii ? 8 : 3)) continue;
        if (!t.contains(n)) continue;
        if (allowedNames.any((x) => x.contains(n))) continue;
        out.add(a.id);
        break;
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- 模型调用

  Future<Map<String, Object?>> _call({
    required String step,
    required LlmTool tool,
    required String context,
    required _Run run,
    String? Function(Map<String, Object?>)? validate,
  }) async {
    final messages = <LlmMessage>[
      LlmMessage.system('$sop\n\n---\n应用：${profile.appName}。\n${profile.focus}'),
      for (final (u, a) in state.history) ...[LlmMessage.user(u), LlmMessage.assistant(a)],
      LlmMessage.user(context),
    ];
    for (var attempt = 0; attempt <= maxRetriesPerStep; attempt++) {
      final sw = Stopwatch()..start();
      final LlmResponse res;
      try {
        res = await client.complete(LlmRequest(
          messages: messages,
          tools: [tool],
          toolChoice: 'auto',
          maxTokens: maxTokens,
          extraBody: thinking,
        ));
      } catch (e) {
        run.steps.add(QaStepLog(step, sw.elapsedMilliseconds, ok: false));
        run.calls++;
        run.issues.add('$step: $e');
        continue;
      }
      run.calls++;
      run.usage = run.usage + res.usage;
      final call = res.toolCalls.where((c) => c.name == tool.name).firstOrNull;
      if (call == null) {
        run.steps.add(QaStepLog(step, sw.elapsedMilliseconds, ok: false));
        messages
          ..add(LlmMessage.assistant(res.content, reasoning: res.reasoning))
          ..add(LlmMessage.user('请调用 ${tool.name} 工具交结果。'));
        continue;
      }
      run.trace.add(tool.name);
      Map<String, Object?> args;
      try {
        args = asMap(jsonDecode(call.arguments));
      } catch (_) {
        args = const {};
      }
      final problem = validate?.call(args);
      run.steps.add(QaStepLog(step, sw.elapsedMilliseconds, ok: problem == null));
      if (problem == null) return args;
      run.issues.add('$step retry: $problem');
      messages
        ..add(LlmMessage.assistant(res.content, toolCalls: [call], reasoning: res.reasoning))
        ..add(LlmMessage.tool(call.id, '不合规：$problem。请改好后重新调用 ${tool.name}。'));
    }
    throw _StepFailed(step, 'no valid ${tool.name} after ${maxRetriesPerStep + 1} tries');
  }

  // ---------------------------------------------------------------- 给模型看的结构化块

  String _conditionsBlock() {
    final b = StringBuffer('[已知条件]');
    b.write(' place=${state.place ?? 'unknown'}');
    if (state.placeWord != null) b.write(' place_word=${state.placeWord}');
    b.write('（来源 ${state.placeSource}）');
    if (state.place == 'home') {
      b.write(' equipment=${state.equipmentKnown ? '[${state.equipment.join(', ')}]${state.equipment.isEmpty ? '（徒手，墙可用）' : '（另外墙可用）'}' : 'unknown'}（来源 ${state.equipmentSource}）');
    }
    if (state.place == 'gym') b.write(' equipment=全库');
    if (state.place == 'office') b.write(' equipment=椅子+徒手，不躺地');
    final lim = [
      if (state.avoidJoints.isNotEmpty) 'avoid_joints=${state.avoidJoints.join(',')}',
      if (state.noFloor) 'no_floor',
      if (state.quiet) 'quiet',
      if (state.easy) 'easy',
      if (state.smallSpace) 'small_space',
    ];
    if (lim.isNotEmpty) b.write(' 限制：${lim.join(' ')}');
    final f = state.focus;
    if (f != null) {
      b.write('\n[上次的焦点] intent=${f.intent} muscles=${f.muscles.join(',')} stretch=${f.stretchMuscles.join(',')} types=${f.types.join(',')}${f.minutes == null ? '' : ' minutes=${f.minutes}'}');
    }
    b.write('\n[条件是否假设] ${_assumed ? '是（不是用户这轮刚给的：写 assumption）' : '否（用户刚给的：assumption 留空）'}');
    return b.toString();
  }

  String _scopeBlock(QaQuery q) => '[范围] ${jsonEncode(q.scopeOnly.toJson())}；范围内动作共 ${finder.inScope(q).length} 个';

  String _cardsBlock() {
    final plan = state.lastPlan;
    if (state.lastShown.isNotEmpty) {
      return '[卡片]（动作卡，按展示顺序编号）\n${[for (var k = 0; k < state.lastShown.length; k++) '${k + 1}. ${_actionLine(index[state.lastShown[k]]!)}'].join('\n')}';
    }
    if (plan != null) {
      final rows = <String>[];
      var k = 0;
      for (final bl in plan.plan.blocks) {
        for (final it in bl.items) {
          k++;
          final a = index[it.exerciseId];
          rows.add('$k. [${bl.type.name}] ${a == null ? it.exerciseId : _actionLine(a)}');
        }
      }
      return '[卡片]（计划，全部动作连续编号，含热身和收操；目标 ${plan.plan.targetMinutes} 分钟）\n${rows.join('\n')}';
    }
    return '[卡片] 无';
  }

  static String _names(QaAction? a) => a == null ? '?' : '${a.id}（${a.drill.name.values.values.toSet().join(' / ')}）';

  /// build_plan 的主训练：有 segments 用 segments（顺序即各段先后），否则用 main_ids。
  (List<String>, List<String>, Map<String, int>) _planMains(Map<String, Object?> a) {
    final segs = asList(a['segments']);
    if (segs.isEmpty) return (asStringList(a['main_ids']), const <String>[], const <String, int>{});
    final ids = <String>[];
    final names = <String>[];
    final of = <String, int>{};
    for (final raw in segs) {
      final m = asMap(raw);
      final name = (asString(m['name']) ?? '').trim();
      final seg = asStringList(m['ids']);
      if (name.isEmpty || seg.isEmpty) continue;
      for (final id in seg) {
        ids.add(id);
        of.putIfAbsent(id, () => names.length);
      }
      names.add(name);
    }
    return (ids, names, of);
  }

  String _actionLine(QaAction a) => [
    a.id,
    a.drill.name.values.values.toSet().join(' / '),
    '主:${a.primaryMuscles.join(',')}',
    '辅:${a.secondaryMuscles.join(',')}',
    '拉:${a.stretchedMuscles.join(',')}',
    '型:${a.trainingType.join(',')}',
    '环节:${a.sessionRole.join(',')}',
    '难度${a.difficulty}',
    '器械:${a.requiredEquipment.isEmpty ? '无' : a.requiredEquipment.join(',')}',
    a.floorRequired ? '躺地' : '不躺地',
    '姿势:${a.drill.position}',
    '冲击:${a.impact}',
    '关节:${[for (final e in a.jointStress.entries) if (e.value != 'none') '${e.key}=${e.value}'].join(',')}',
    _summary(a),
  ].join(' | ');

  String _summary(QaAction a) => state.language.startsWith('zh') || a.summaryEn.isEmpty ? a.summaryZh : a.summaryEn;

  List<CoachQaCard> _cardsFor(List<String> ids, Map<String, String> why) => [
    for (final id in ids)
      if (index[id] != null) CoachQaCard(id: id, name: index[id]!.name(state.language), why: why[id] ?? _summary(index[id]!)),
  ];

  /// 把计划里卡片编号为 [pos] + 1 的那一个动作（全部动作连续编号，含热身/收操）换成 [to]。
  QaPlanResult _swapInPlan(QaPlanResult r, int pos, String to) {
    final a = index[to]!;
    var k = -1;
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
              if (++k != pos)
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
                  replacedFrom: it.exerciseId,
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
      equipment: builder.equipmentFor([
        for (final block in blocks)
          for (final item in block.items) item.exerciseId,
      ]),
      level: p.level,
      targetMinutes: p.targetMinutes,
      blocks: blocks,
      avoid: p.avoid,
    );
    return QaPlanResult(plan, const PlanDuration().estimateSeconds(plan, index.catalog).round(), r.notes);
  }

  String _historyLine(CoachQaReply r) {
    final b = StringBuffer(r.text);
    if (r.cards.isNotEmpty) b.write('\n[cards] ${[for (var k = 0; k < r.cards.length; k++) '${k + 1}.${r.cards[k].id}'].join(' ')}');
    if (r.plan != null) {
      final ids = r.planOrderedIds;
      b.write('\n[plan] ${[for (var k = 0; k < ids.length; k++) '${k + 1}.${ids[k]}'].join(' ')}');
    }
    if (r.question != null) b.write('\n[options] ${r.question!.options.join(' / ')}');
    return b.toString();
  }

  static String? _nonEmpty(String? s) => s == null || s.trim().isEmpty ? null : s.trim();

  // ---------------------------------------------------------------- 工具

  static const _muscleIds = [
    'abs', 'obliques', 'erectors', 'glute-max', 'hip-abductors', 'adductors', 'quadriceps', 'hamstrings', 'calves', 'tibialis',
    'chest', 'triceps', 'biceps', 'deltoids', 'lats', 'scapular', 'rotator-cuff', 'serratus', 'forearms', 'upper-traps',
    'hip-flexors', 'hip-rotators', 'peroneals', 'neck',
  ];

  static final _fillFormTool = LlmTool(
    name: 'fill_form',
    description: 'SOP 第 1 步：把对用户这句话的理解填成结构化表。',
    parameters: {
      'type': 'object',
      'properties': {
        'language': {'type': 'string', 'description': '用户语言，BCP-47（zh/en/ja/es…）'},
        'intent': {
          'type': 'string',
          'enum': ['actions', 'plan', 'knowledge', 'safety', 'swap', 'easier', 'harder', 'retime', 'another', 'use_these', 'change_place', 'answer_pending', 'chat'],
        },
        'answer_status': {'type': 'string', 'enum': ['none', 'answered', 'skipped']},
        'place': {'type': 'string', 'enum': ['home', 'gym', 'office', 'unknown']},
        'place_word': {'type': 'string', 'description': '用户对地点的原话说法（如 酒店 / 宿舍 / hotel）'},
        'equipment_known': {'type': 'boolean'},
        'equipment': {
          'type': 'array',
          'items': {'type': 'string', 'enum': ['dumbbell', 'mat', 'chair', 'band', 'kettlebell', 'pullup-bar', 'foam-roller']},
        },
        'muscles': {'type': 'array', 'items': {'type': 'string', 'enum': _muscleIds}},
        'stretch_muscles': {'type': 'array', 'items': {'type': 'string', 'enum': _muscleIds}},
        'types': {
          'type': 'array',
          'items': {'type': 'string', 'enum': ['strength', 'cardio', 'stability-control', 'balance', 'mobility', 'dynamic-stretch', 'static-stretch', 'breathing']},
        },
        'goals': {
          'type': 'array',
          'items': {'type': 'string', 'enum': ['strength', 'hypertrophy', 'fat-loss', 'mobility', 'posture', 'recovery', 'desk-relief', 'performance']},
        },
        'roles': {'type': 'array', 'items': {'type': 'string', 'enum': ['warmup', 'main', 'cooldown']}},
        'patterns': {
          'type': 'array',
          'items': {
            'type': 'string',
            'enum': ['squat', 'lunge', 'hinge', 'push-horizontal', 'push-vertical', 'pull-horizontal', 'pull-vertical', 'anti-extension', 'anti-rotation', 'anti-lateral-flexion', 'rotation', 'carry', 'gait', 'isolation'],
          },
        },
        'avoid_joints': {'type': 'array', 'items': {'type': 'string', 'enum': ['knee', 'shoulder', 'lumbar', 'wrist', 'neck', 'ankle', 'hip']}},
        'no_floor': {'type': 'boolean'},
        'quiet': {'type': 'boolean'},
        'easy': {'type': 'boolean'},
        'small_space': {'type': 'boolean'},
        'minutes': {'type': 'integer'},
        'positions': {'type': 'array', 'items': {'type': 'integer'}, 'description': '卡片编号（从 1 起，计划含热身收操）'},
        'next': {'type': 'string', 'enum': ['ask_place', 'ask_equipment', 'ask_safety', 'answer']},
        'note': {'type': 'string'},
      },
      'required': ['language', 'intent', 'answer_status', 'place', 'equipment_known', 'next'],
    },
  );

  static const _askTool = LlmTool(
    name: 'ask_user',
    description: 'SOP 第 2 步 A：问用户一个问题（用户语言）。',
    parameters: {
      'type': 'object',
      'properties': {
        'question': {'type': 'string'},
        'options': {'type': 'array', 'items': {'type': 'string'}},
      },
      'required': ['question', 'options'],
    },
  );

  static const _respondTool = LlmTool(
    name: 'respond',
    description: 'SOP 第 2 步 B：回答并附动作卡（actions / knowledge / safety / chat）。',
    parameters: {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
        'items': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {'id': {'type': 'string'}, 'why': {'type': 'string'}},
            'required': ['id', 'why'],
          },
        },
        'assumption': {'type': 'string'},
        'chips': {'type': 'array', 'items': {'type': 'string'}},
      },
      'required': ['text', 'items', 'chips'],
    },
  );

  static const _planTool = LlmTool(
    name: 'build_plan',
    description: 'SOP 第 2 步 B：排一套训练（plan / another / use_these / retime）。主训练顺序以你给的为准；代码只验收并配组数时长，不合格会退回原因。',
    parameters: {
      'type': 'object',
      'properties': {
        'title': {'type': 'string'},
        'text': {'type': 'string'},
        'minutes': {'type': 'integer'},
        'main_ids': {'type': 'array', 'items': {'type': 'string'}},
        'segments': {
          'type': 'array',
          'description': '可选：用户要求主训练分段（如先坐着做、再站着做）时按顺序给出各段；给了就以它为准。',
          'items': {
            'type': 'object',
            'properties': {'name': {'type': 'string'}, 'ids': {'type': 'array', 'items': {'type': 'string'}}},
            'required': ['name', 'ids'],
          },
        },
        'warmup': {'type': 'boolean', 'description': '是否让代码加热身，默认 true；用户指定了完整顺序或不要热身时填 false。'},
        'cooldown': {'type': 'boolean', 'description': '是否让代码加收操，默认 true；用户指定了完整顺序或不要收操时填 false。'},
        'block_names': {
          'type': 'object',
          'properties': {'warmup': {'type': 'string'}, 'main': {'type': 'string'}, 'cooldown': {'type': 'string'}},
        },
        'assumption': {'type': 'string'},
        'chips': {'type': 'array', 'items': {'type': 'string'}},
      },
      'required': ['title', 'text', 'minutes', 'main_ids', 'chips'],
    },
  );

  static const _swapTool = LlmTool(
    name: 'swap',
    description: 'SOP 第 2 步 B：换动作 / 退阶 / 进阶。每个编号只能从它的候选里选。',
    parameters: {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
        'changes': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {'position': {'type': 'integer'}, 'new_id': {'type': 'string'}, 'why': {'type': 'string'}},
            'required': ['position', 'new_id', 'why'],
          },
        },
        'chips': {'type': 'array', 'items': {'type': 'string'}},
      },
      'required': ['text', 'changes', 'chips'],
    },
  );

  static const _rewriteTool = LlmTool(
    name: 'rewrite',
    description: 'SOP 第 3 步：按最终卡片改写正文。',
    parameters: {
      'type': 'object',
      'properties': {'text': {'type': 'string'}},
      'required': ['text'],
    },
  );
}

final class _StepFailed implements Exception {
  _StepFailed(this.step, this.why);
  final String step;
  final String why;
}

/// 一轮里的累计：调用次数、用量、每步耗时、问题。
final class _Run {
  _Run(this.sw);
  final Stopwatch sw;
  int calls = 0;
  TokenUsage usage = TokenUsage.zero;
  final List<QaStepLog> steps = [];
  final List<String> issues = [];
  final List<String> trace = [];
  Map<String, Object?> form = const {};

  CoachQaReply reply({
    required String kind,
    required String text,
    List<CoachQaCard> cards = const [],
    List<String> chips = const [],
    String? assumption,
    Map<String, Object?> conditions = const {},
    TrainingPlan? plan,
    int? planSeconds,
    AskUserQuestion? question,
    QaAskStep? askStep,
    String language = 'zh',
    List<String> issues = const [],
    List<String> extraIssues = const [],
  }) => CoachQaReply(
    kind: kind,
    text: text,
    cards: cards,
    chips: chips,
    assumption: assumption,
    conditions: conditions,
    plan: plan,
    planSeconds: planSeconds,
    question: question,
    askStep: askStep,
    llmCalls: calls,
    elapsed: sw.elapsed,
    usage: usage,
    issues: [...this.issues, ...issues, ...extraIssues],
    toolTrace: trace,
    steps: steps,
    form: form,
    language: language,
  );
}
