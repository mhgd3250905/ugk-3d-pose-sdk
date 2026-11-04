/// AI 问答推荐 Agent v3（可选启用；与 [CoachAgent] 并存）。规格：docs/coach-qa-agent-v3.md。
///
/// 常规 agent 循环：每一轮把全部工具一次给模型（toolChoice auto），由模型照 SOP（`coach_qa_sop.md`）
/// 自己决定先查动作库、先问还是直接交结果，不设调用次数上限。
/// - 信息类工具：`set_conditions`（记条件）、`search_actions`（按结构化标签查动作库）→ 返回结果，继续。
/// - 交付类工具：`ask_user`、`show_actions`、`build_plan`、`swap`、`reply` → 脚本验收；
///   不合格把原因作为 tool result 退回模型重交，合格本轮结束。代码绝不静默修改、补、删、重排交付内容。
///
/// 代码只做和语言无关的部分：验收器、安全与场景准入（[QaAdmission] / [QaFinder.passes]）、
/// 组数与时长配置（[QaPlanBuilder]）、条件状态记录。
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

  /// 模型本轮最后一次 `set_conditions` 的参数（调试用）。
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

/// v2 的结构化表。v3 不再有理解步；保留类型只为持久化兼容（`QaFocus.of` 从存档的焦点读回）。
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

/// 「练什么」：模型最近一次 `search_actions` 的焦点，跨轮沿用（用于下一轮预选候选）。
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

  // ---- v3 追加（旧存档没有这些字段时取默认值）

  /// 用户已确认安全危险信号（模型经 `set_conditions.red_flag` 记录）：此时 `reply` 不能附动作。
  bool redFlag = false;

  /// 本轮已见候选：预选候选 + 本轮 `search_actions` 结果 + 当前卡片。每轮开始重置，不持久化。
  Set<String> seen = {};

  bool get placeKnown => place != null;
}

const _thinkingMax = <String, Object?>{
  'thinking': {'type': 'enabled'},
  'reasoning_effort': 'max',
};

/// 模型直接输出文字、没调用工具时的提示。
const _nudge = '请调用工具交结果。';

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

  /// 模型调用连续抛错（网络、服务端）的重试次数；超过就本轮报错。不限制工具调用次数。
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

  // ---------------------------------------------------------------- 循环

  Future<CoachQaReply> _turn(String text, QaAskStep? askedLast, _Run run) async {
    final pre = [for (final h in finder.find(_query(focus: state.focus, limit: 12))) h.action];
    state.seen = {for (final a in pre) a.id, ..._cardIds()};
    final ctx = StringBuffer()
      ..writeln(_conditionsBlock())
      ..writeln('[上一轮问过] ${askedLast?.name ?? '无'}')
      ..writeln(askedLast == null || state.pendingText == null ? '' : '[等回答的原请求] ${state.pendingText}')
      ..writeln(_cardsBlock())
      ..writeln('[预选候选]（按已知条件和上次焦点预取，都在当前范围内；不对题或不够就 search_actions）')
      ..writeln(pre.isEmpty ? '（无）' : pre.map(_actionLine).join('\n'))
      ..writeln('[用户这句话]')
      ..writeln(text);
    final messages = <LlmMessage>[
      LlmMessage.system('$sop\n\n---\n应用：${profile.appName}。\n${profile.focus}'),
      for (final (u, a) in state.history) ...[LlmMessage.user(u), LlmMessage.assistant(a)],
      LlmMessage.user(ctx.toString()),
    ];
    var failures = 0;
    while (true) {
      final sw = Stopwatch()..start();
      final LlmResponse res;
      try {
        res = await client.complete(LlmRequest(
          messages: List.unmodifiable(messages),
          tools: _tools,
          toolChoice: 'auto',
          maxTokens: maxTokens,
          extraBody: thinking,
        ));
      } catch (e) {
        run.steps.add(QaStepLog('model', sw.elapsedMilliseconds, ok: false));
        run.calls++;
        run.issues.add('model: $e');
        if (++failures > maxRetriesPerStep) throw _StepFailed('model', '$e');
        continue;
      }
      failures = 0;
      run.calls++;
      run.usage = run.usage + res.usage;
      if (res.toolCalls.isEmpty) {
        run.steps.add(QaStepLog('text', sw.elapsedMilliseconds, ok: false));
        run.issues.add('no tool call');
        messages
          ..add(LlmMessage.assistant(res.content, reasoning: res.reasoning))
          ..add(LlmMessage.user(_nudge));
        continue;
      }
      messages.add(LlmMessage.assistant(res.content, toolCalls: res.toolCalls, reasoning: res.reasoning));
      var ok = true;
      for (final call in res.toolCalls) {
        run.trace.add(call.name);
        Map<String, Object?>? args;
        try {
          args = asMap(jsonDecode(call.arguments.isEmpty ? '{}' : call.arguments));
        } catch (_) {
          args = null;
        }
        final out = args == null ? _reject(call.name, '参数不是合法的 JSON', run) : _handle(call.name, args, text, askedLast, run);
        if (out.reply != null) {
          run.steps.add(QaStepLog(call.name, sw.elapsedMilliseconds));
          return out.reply!;
        }
        if (out.rejected) ok = false;
        messages.add(LlmMessage.tool(call.id, out.result));
      }
      run.steps.add(QaStepLog(res.toolCalls.map((c) => c.name).join('+'), sw.elapsedMilliseconds, ok: ok));
    }
  }

  _Outcome _handle(String tool, Map<String, Object?> a, String text, QaAskStep? askedLast, _Run run) => switch (tool) {
    'set_conditions' => _setConditions(a, askedLast, run),
    'search_actions' => _search(a, askedLast, run),
    'ask_user' => _askUser(a, text, askedLast, run),
    'show_actions' => _showActions(a, askedLast, run),
    'build_plan' => _buildPlan(a, askedLast, run),
    'swap' => _swap(a, run),
    'reply' => _reply(a, askedLast, run),
    _ => _reject(tool, '没有这个工具，可用：${_tools.map((t) => t.name).join(', ')}', run, retry: '正确的工具'),
  };

  _Outcome _reject(String tool, String why, _Run run, {String? retry}) {
    run.issues.add('$tool rejected: $why');
    return _Outcome.rejected('不合规：$why。请改好后重新调用 ${retry ?? tool}。');
  }

  // ---------------------------------------------------------------- 信息类工具

  _Outcome _setConditions(Map<String, Object?> a, QaAskStep? askedLast, _Run run) {
    final bad = <String>[];
    final place = asString(a['place']);
    final placeOk = place == null || const {'home', 'gym', 'office', 'unknown'}.contains(place);
    if (!placeOk) bad.add('place=$place 不是合法场景（home / gym / office / unknown）');
    final eq = asStringList(a['equipment']);
    final badEq = [for (final e in eq) if (!_equipmentIds.contains(e)) e];
    if (badEq.isNotEmpty) bad.add('equipment 里这些不是合法器械 id：${badEq.join(', ')}');
    final joints = asStringList(a['avoid_joints']);
    final badJ = [for (final j in joints) if (!_jointIds.contains(j)) j];
    if (badJ.isNotEmpty) bad.add('avoid_joints 里这些不是合法关节 id：${badJ.join(', ')}');
    final minutes = asInt(a['minutes']);
    if (a['minutes'] != null && (minutes == null || minutes < 1)) bad.add('minutes 要是正整数');
    if (bad.isNotEmpty) return _reject('set_conditions', bad.join('；'), run);
    run.form = a;

    final word = _nonEmpty(asString(a['place_word']));
    if (place == 'unknown') {
      state
        ..place = null
        ..placeWord = null
        ..placeSource = 'none'
        ..equipmentKnown = false
        ..equipment = {}
        ..equipmentSource = 'none';
    } else if (place != null && (place != state.place || (word != null && word != state.placeWord))) {
      final same = place == state.place;
      if (!same) {
        state
          ..equipmentKnown = false
          ..equipment = {}
          ..equipmentSource = 'none';
      }
      state
        ..place = place
        ..placeWord = word ?? (same ? state.placeWord : null)
        ..placeSource = askedLast == QaAskStep.place ? 'answered' : 'user'
        ..placeTurn = state.turn;
    }
    if (asBool(a['equipment_known']) == true) {
      final next = eq.toSet();
      if (!state.equipmentKnown || next.length != state.equipment.length || !next.containsAll(state.equipment)) {
        state
          ..equipment = next
          ..equipmentKnown = true
          ..equipmentSource = askedLast == QaAskStep.equipment ? 'answered' : 'user'
          ..equipmentTurn = state.turn;
      }
    }
    state.avoidJoints.addAll(joints);
    if (asBool(a['no_floor']) == true) state.noFloor = true;
    if (asBool(a['quiet']) == true) state.quiet = true;
    if (asBool(a['easy']) == true) state.easy = true;
    if (asBool(a['small_space']) == true) state.smallSpace = true;
    if (asBool(a['red_flag']) case final f?) state.redFlag = f;
    final lang = _nonEmpty(asString(a['language']));
    if (lang != null) state.language = lang;
    if (minutes != null) state.focus = _focusWith(minutes: minutes);
    return _Outcome.info('已记录。\n${_conditionsBlock()}');
  }

  _Outcome _search(Map<String, Object?> a, QaAskStep? askedLast, _Run run) {
    final bad = <String>[];
    Set<String> ids(String key, Set<String> allowed) {
      final v = asStringList(a[key]).toSet();
      final wrong = [for (final x in v) if (!allowed.contains(x)) x];
      if (wrong.isNotEmpty) bad.add('$key 里这些不是合法 id：${wrong.join(', ')}');
      return v;
    }

    final muscles = ids('muscles', _muscleIds.toSet());
    final stretch = ids('stretch_muscles', _muscleIds.toSet());
    final types = ids('types', _typeIds.toSet());
    final roles = ids('roles', _roleIds.toSet());
    final goals = ids('goals', _goalIds.toSet());
    final patterns = ids('patterns', _patternIds.toSet());
    final positions = {...asStringList(a['position']), ?asString(a['position'])};
    final badPos = [for (final p in positions) if (!_positionIds.contains(p)) p];
    if (badPos.isNotEmpty) bad.add('position 里这些不是合法姿势 id：${badPos.join(', ')}（可用：${_positionIds.join(', ')}）');
    final exclude = asStringList(a['exclude']).toSet();
    final unknown = [for (final id in exclude) if (index[id] == null) id];
    if (unknown.isNotEmpty) bad.add('exclude 里这些 id 不存在：${unknown.join(', ')}');
    final limit = asInt(a['limit']) ?? 8;
    if (limit < 1 || limit > 12) bad.add('limit 要在 1–12 之间');
    if (bad.isNotEmpty) return _reject('search_actions', bad.join('；'), run);
    _fillSkipped(askedLast);
    final focus = QaFocus(
      muscles: muscles,
      stretchMuscles: stretch,
      types: types,
      goals: goals,
      roles: roles,
      patterns: patterns,
      minutes: state.focus?.minutes,
      intent: state.focus?.intent ?? 'actions',
    );
    final sideOnly = roles.isNotEmpty && !roles.contains('main');
    if (!sideOnly && (muscles.isNotEmpty || stretch.isNotEmpty || types.isNotEmpty || patterns.isNotEmpty)) state.focus = focus;
    // 姿势筛选：把其他姿势的动作排除掉（结构化标签，与语言无关）。
    final otherPosition = positions.isEmpty ? const <String>{} : {for (final x in index.all) if (!positions.contains(x.drill.position)) x.id};
    final q = _query(focus: focus, exclude: {...exclude, ...otherPosition}, limit: limit);
    final hits = [for (final h in finder.find(q)) h.action];
    state.seen.addAll(hits.map((x) => x.id));
    final scope = jsonEncode(q.scopeOnly.toJson());
    if (hits.isEmpty) return _Outcome.info('[搜索结果] 0 个：在当前范围 $scope 里没有符合这些条件的动作。');
    return _Outcome.info('[搜索结果] ${hits.length} 个（都在当前范围 $scope 内，按相关度排序）\n${hits.map(_actionLine).join('\n')}');
  }

  /// 上一轮问了地点/器械、这轮没得到答案就要动作：按默认补齐，来源记为 skipped（结构化判断，不读用户的话）。
  void _fillSkipped(QaAskStep? askedLast) {
    if (askedLast == QaAskStep.place && !state.placeKnown) {
      state
        ..place = profile.defaultScene == 'hotel' ? 'home' : profile.defaultScene
        ..placeSource = 'skipped'
        ..placeTurn = state.turn;
    }
    final eqAsked = askedLast == QaAskStep.equipment || (askedLast == QaAskStep.place && state.placeSource == 'skipped');
    if (eqAsked && state.place == 'home' && !state.equipmentKnown) {
      state
        ..equipmentKnown = true
        ..equipment = {}
        ..equipmentSource = 'skipped'
        ..equipmentTurn = state.turn;
    }
  }

  // ---------------------------------------------------------------- 交付类工具

  _Outcome _askUser(Map<String, Object?> a, String text, QaAskStep? askedLast, _Run run) {
    final stepName = asString(a['step']);
    final step = QaAskStep.values.where((s) => s.name == stepName).firstOrNull;
    if (step == null) return _reject('ask_user', 'step 要是 place / equipment / safety', run);
    final q = asString(a['question'])?.trim() ?? '';
    final options = [for (final o in asStringList(a['options'])) if (o.trim().isNotEmpty) o.trim()];
    final multi = asBool(a['multi']);
    final bad = <String>[];
    if (q.isEmpty) bad.add('question 不能为空');
    if (step == askedLast) bad.add('上一轮刚问过 ${step.name}，不能连问；按已知条件或默认条件交结果');
    if (step == QaAskStep.place && state.placeKnown) {
      bad.add('地点已知（${state.place}，来源 ${state.placeSource}），不能再问 place；用户要换场地时先 set_conditions place=unknown');
    }
    if (step == QaAskStep.equipment && state.place != 'home') bad.add('当前地点不是居家（${state.place ?? 'unknown'}），不能问器械');
    if (step == QaAskStep.equipment && state.place == 'home' && state.equipmentKnown) {
      bad.add('器械已知（${state.equipment.join(', ')}，来源 ${state.equipmentSource}），不能再问 equipment');
    }
    if (step == QaAskStep.place && options.length != 4) bad.add('place 的 options 要 4 个，现在 ${options.length} 个');
    if (step == QaAskStep.place && multi == true) bad.add('place 是单选，multi 要为 false');
    if (step == QaAskStep.equipment && (options.length < 2 || options.length > 6)) bad.add('equipment 的 options 要 2–6 个，现在 ${options.length} 个');
    if (bad.isNotEmpty) return _reject('ask_user', bad.join('；'), run);
    if (askedLast == null) {
      state
        ..pendingText = text
        ..pendingFocus = state.focus;
    }
    final question = AskUserQuestion.direct(q, options: options, multiple: multi ?? step == QaAskStep.equipment, language: state.language);
    return _Outcome.done(run.reply(kind: 'ask', text: q, question: question, askStep: step, language: state.language, conditions: _conditions()));
  }

  /// items 的公共验收：存在、在已见候选里、过准入、不重复、个数。返回问题列表。
  (List<String>, Map<String, String>, List<String>) _items(Object? raw, {required int min, required int max}) {
    final ids = <String>[];
    final why = <String, String>{};
    final bad = <String>[];
    for (final it in asList(raw)) {
      final m = asMap(it);
      final id = asString(m['id']) ?? '';
      ids.add(id);
      final w = asString(m['why'])?.trim() ?? '';
      if (w.isNotEmpty) why[id] = w;
    }
    if (ids.length < min || ids.length > max) bad.add('items 要 ${min == max ? '$min' : '$min–$max'} 个，现在 ${ids.length} 个');
    bad.addAll(_idProblems(ids));
    return (ids, why, bad);
  }

  /// 一组动作 id 的验收：存在、不重复、在已见候选里、过准入。
  List<String> _idProblems(List<String> ids, {bool needSeen = true}) {
    final bad = <String>[];
    final dup = <String>{};
    final seenOnce = <String>{};
    for (final id in ids) {
      if (!seenOnce.add(id)) dup.add(id);
    }
    if (dup.isNotEmpty) bad.add('有重复的动作：${dup.join(', ')}');
    final unknown = [for (final id in ids.toSet()) if (index[id] == null) id];
    if (unknown.isNotEmpty) bad.add('这些 id 不存在：${unknown.join(', ')}');
    if (needSeen) {
      final notSeen = [for (final id in ids.toSet()) if (index[id] != null && !state.seen.contains(id)) id];
      if (notSeen.isNotEmpty) bad.add('这些 id 不在本轮搜索结果、预选候选或当前卡片里：${notSeen.join(', ')}（先 search_actions 查到再用）');
    }
    final scope = _scope();
    final out = [for (final id in ids.toSet()) if (index[id] != null && !finder.passes(index[id]!, scope)) id];
    if (out.isNotEmpty) bad.add('这些动作不符合用户当前条件（场景、器械、限制或安全准入），不能用：${out.map((id) => _names(index[id])).join('；')}');
    return bad;
  }

  /// 正文只能提 [allowed] 里的动作。
  String? _textProblem(String text, Set<String> allowed) {
    if (text.isEmpty) return 'text 不能为空';
    final off = offCardMentions(text, allowed);
    if (off.isEmpty) return null;
    return '正文提到了卡片外的动作：${off.map((id) => _names(index[id])).join('；')}。正文只能提卡片上的动作';
  }

  _Outcome _showActions(Map<String, Object?> a, QaAskStep? askedLast, _Run run) {
    _fillSkipped(askedLast);
    final text = asString(a['text'])?.trim() ?? '';
    final (ids, why, bad) = _items(a['items'], min: 3, max: 5);
    if (bad.isEmpty) {
      final t = _textProblem(text, ids.toSet());
      if (t != null) bad.add(t);
    }
    if (bad.isNotEmpty) return _reject('show_actions', bad.join('；'), run);
    return _Outcome.done(_deliverCards('recommend', text, ids, why, a, intent: 'actions', run: run));
  }

  CoachQaReply _deliverCards(String kind, String text, List<String> ids, Map<String, String> why, Map<String, Object?> a, {required String intent, required _Run run}) {
    state
      ..lastPlan = null
      ..lastShown = ids
      ..lastWhy = {for (final id in ids) id: why[id] ?? _summary(index[id]!)}
      ..pendingText = null
      ..pendingFocus = null;
    state.focus = _focusWith(intent: intent);
    return run.reply(
      kind: kind,
      text: text,
      cards: _cardsFor(ids, why),
      chips: asStringList(a['chips']),
      assumption: _assumed ? _nonEmpty(asString(a['assumption'])) : null,
      conditions: _conditions(),
      language: state.language,
    );
  }

  _Outcome _reply(Map<String, Object?> a, QaAskStep? askedLast, _Run run) {
    final text = asString(a['text'])?.trim() ?? '';
    final hasItems = asList(a['items']).isNotEmpty;
    final bad = <String>[];
    var ids = <String>[];
    var why = <String, String>{};
    if (hasItems) {
      if (state.redFlag) {
        bad.add('用户已确认安全危险信号，reply 的 items 必须为空：先建议停止诱发症状的训练并寻求专业评估');
      } else {
        _fillSkipped(askedLast);
        final (i, w, b) = _items(a['items'], min: 1, max: 5);
        ids = i;
        why = w;
        bad.addAll(b);
      }
    }
    if (bad.isEmpty) {
      final t = _textProblem(text, {...ids, ..._cardIds()});
      if (t != null) bad.add(t);
    }
    if (bad.isNotEmpty) return _reject('reply', bad.join('；'), run);
    if (ids.isNotEmpty) return _Outcome.done(_deliverCards('recommend', text, ids, why, a, intent: 'answer', run: run));
    state
      ..pendingText = null
      ..pendingFocus = null;
    return _Outcome.done(run.reply(kind: 'answer', text: text, chips: asStringList(a['chips']), conditions: _conditions(), language: state.language));
  }

  _Outcome _buildPlan(Map<String, Object?> a, QaAskStep? askedLast, _Run run) {
    _fillSkipped(askedLast);
    final text = asString(a['text'])?.trim() ?? '';
    final mode = asString(a['mode']) ?? 'new';
    final bad = <String>[];
    final modeOk = const {'new', 'another', 'retime'}.contains(mode);
    if (!modeOk) bad.add('mode 要是 new / another / retime');
    final (mains, names, segOf, segBad) = _planMains(a);
    bad.addAll(segBad);
    final warm = asStringList(a['warmup_ids']);
    final cool = asStringList(a['cooldown_ids']);
    if (mains.isEmpty) bad.add('主训练不能为空：给 main_ids 或 segments');
    final minutes = asInt(a['minutes']);
    if (minutes == null || minutes < 3 || minutes > 60) bad.add('minutes 要是 3–60 的整数');
    final all = [...warm, ...mains, ...cool];
    bad.addAll(_idProblems(all));
    final prev = state.lastPlan;
    if (mode == 'retime') {
      if (prev == null) {
        bad.add('当前没有计划，不能 retime；用 mode=new');
      } else {
        final want = prev.mainIds.toSet();
        final got = mains.toSet();
        if (got.length != want.length || !got.containsAll(want)) {
          final missing = want.difference(got);
          final added = got.difference(want);
          bad.add('retime 不换动作，主训练集合必须等于当前计划的主训练（${want.join(', ')}）'
              '${missing.isEmpty ? '' : '；少了 ${missing.join(', ')}'}${added.isEmpty ? '' : '；多了 ${added.join(', ')}'}');
        }
      }
    }
    if (mode == 'another') {
      final before = (prev?.mainIds ?? state.lastShown).toSet();
      final repeated = [for (final id in mains) if (before.contains(id)) id];
      if (repeated.isNotEmpty) bad.add('再来一套不能和上一套重复：${repeated.join(', ')} 上一套已经有了（search_actions 用 exclude 排除上一套）');
    }
    if (bad.isNotEmpty) return _reject('build_plan', bad.join('；'), run);
    final r = builder.build(
      mainIds: mains,
      minutes: minutes!,
      base: _query(),
      title: asString(a['title']),
      blockNames: {for (final e in asMap(a['block_names']).entries) e.key: '${e.value}'},
      warmIds: warm,
      coolIds: cool,
      segmentNames: names,
      segmentOf: segOf,
    );
    final dev = QaPlanBuilder.deviation(r);
    if (dev.abs() > 0.12) {
      final target = minutes * 60;
      final per = r.seconds / (r.orderedIds.isEmpty ? 1 : r.orderedIds.length);
      final k = ((r.seconds - target).abs() / (per <= 0 ? 60 : per)).ceil().clamp(1, 10);
      final pct = (dev * 100).round();
      bad.add('配好组数后约 ${(r.seconds / 60).toStringAsFixed(1)} 分钟，目标 $minutes 分钟，偏差 ${pct > 0 ? '+' : ''}$pct%（允许 ±12%），组数已调到${dev < 0 ? '上限' : '下限'}。'
          '${dev < 0 ? '建议再加约 $k 个主训练动作（或热身、收操）' : '建议减约 $k 个动作（或去掉热身、收操）'}，或按用户原话调整 minutes');
    }
    if (bad.isEmpty) {
      final t = _textProblem(text, r.orderedIds.toSet());
      if (t != null) bad.add(t);
    }
    if (bad.isNotEmpty) return _reject('build_plan', bad.join('；'), run);
    state
      ..lastPlan = r
      ..lastShown = []
      ..lastWhy = {}
      ..pendingText = null
      ..pendingFocus = null;
    state.focus = _focusWith(minutes: minutes, intent: 'plan');
    return _Outcome.done(run.reply(
      kind: 'plan',
      text: text,
      plan: r.plan,
      planSeconds: r.seconds,
      chips: asStringList(a['chips']),
      assumption: _assumed ? _nonEmpty(asString(a['assumption'])) : null,
      conditions: _conditions(),
      language: state.language,
      extraIssues: r.notes,
    ));
  }

  _Outcome _swap(Map<String, Object?> a, _Run run) {
    final text = asString(a['text'])?.trim() ?? '';
    final mode = asString(a['mode']) ?? 'swap';
    final inPlan = state.lastShown.isEmpty && state.lastPlan != null;
    final list = inPlan ? state.lastPlan!.orderedIds : state.lastShown;
    final bad = <String>[];
    final modeOk = const {'swap', 'easier', 'harder'}.contains(mode);
    if (!modeOk) bad.add('mode 要是 swap / easier / harder');
    if (list.isEmpty) return _reject('swap', '当前没有卡片，不能换动作；改用 reply 或 show_actions', run, retry: 'reply');
    final changes = asList(a['changes']);
    if (changes.isEmpty) bad.add('changes 不能为空；没有合格的替换就改用 reply 如实说明，卡片保持不变');
    final applied = <int, (String, String)>{};
    for (final raw in changes) {
      final m = asMap(raw);
      final p = asInt(m['position']);
      final id = asString(m['new_id']) ?? '';
      if (p == null || p < 1 || p > list.length) {
        bad.add('position $p 超出卡片范围（卡片一共 ${list.length} 个）');
        continue;
      }
      if (applied.containsKey(p)) {
        bad.add('第 $p 个重复出现');
        continue;
      }
      final old = index[list[p - 1]];
      final b = index[id];
      if (b == null) {
        bad.add('第 $p 个的 new_id $id 不存在');
        continue;
      }
      if (list.contains(id) || applied.values.any((v) => v.$1 == id)) {
        bad.add('第 $p 个的 new_id $id 已经在卡片上');
        continue;
      }
      if (!finder.passes(b, _scope())) bad.add('第 $p 个的 new_id ${_names(b)} 不符合用户当前条件（场景、器械、限制或安全准入）');
      if (old != null) {
        if (mode == 'easier' && b.difficulty >= old.difficulty) bad.add('第 $p 个要更简单：${_names(b)} 难度 ${b.difficulty}，原动作难度 ${old.difficulty}');
        if (mode == 'harder' && b.difficulty <= old.difficulty) bad.add('第 $p 个要更难：${_names(b)} 难度 ${b.difficulty}，原动作难度 ${old.difficulty}');
        if (!QaFinder.sameArea(old, b)) bad.add('第 $p 个要练同一处：${_names(b)} 和原动作 ${_names(old)} 的主动肌、拉伸肌没有交集');
      }
      applied[p] = (id, asString(m['why'])?.trim() ?? '');
    }
    if (bad.isEmpty) {
      final next = [...list];
      for (final e in applied.entries) {
        next[e.key - 1] = e.value.$1;
      }
      final t = _textProblem(text, {...next, for (final p in applied.keys) list[p - 1]});
      if (t != null) bad.add(t);
    }
    if (bad.isNotEmpty) return _reject('swap', bad.join('；'), run);
    final kind = mode == 'swap' ? 'replace' : mode;
    state
      ..pendingText = null
      ..pendingFocus = null;
    if (inPlan) {
      var r = state.lastPlan!;
      for (final e in applied.entries) {
        r = _swapInPlan(r, e.key - 1, e.value.$1);
      }
      state.lastPlan = r;
      return _Outcome.done(run.reply(
        kind: kind,
        text: text,
        plan: r.plan,
        planSeconds: r.seconds,
        chips: asStringList(a['chips']),
        conditions: _conditions(),
        language: state.language,
      ));
    }
    final ids = [...list];
    final why = {...state.lastWhy};
    for (final e in applied.entries) {
      ids[e.key - 1] = e.value.$1;
      why[e.value.$1] = e.value.$2.isEmpty ? _summary(index[e.value.$1]!) : e.value.$2;
    }
    state
      ..lastShown = ids
      ..lastWhy = why;
    return _Outcome.done(run.reply(
      kind: kind,
      text: text,
      cards: _cardsFor(ids, why),
      chips: asStringList(a['chips']),
      conditions: _conditions(),
      language: state.language,
    ));
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

  // ---------------------------------------------------------------- 状态与范围

  bool get _strict {
    if (!state.placeKnown) return false;
    return state.place == 'home' ? state.equipmentKnown : true;
  }

  QaFocus _focusWith({int? minutes, String? intent}) {
    final f = state.focus ?? const QaFocus();
    return QaFocus(
      muscles: f.muscles,
      stretchMuscles: f.stretchMuscles,
      types: f.types,
      goals: f.goals,
      roles: f.roles,
      patterns: f.patterns,
      minutes: minutes ?? f.minutes,
      intent: intent ?? f.intent,
    );
  }

  QaQuery _query({QaFocus? focus, Set<String> exclude = const {}, int limit = 12}) {
    final f = focus ?? const QaFocus();
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

  QaQuery _scope() => _query().scopeOnly;

  List<String> _cardIds() => [...state.lastShown, ...?state.lastPlan?.orderedIds];

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
    if (!state.placeKnown) b.write('（地点未知时搜索按 ${profile.defaultScene} 的宽松范围）');
    final lim = [
      if (state.avoidJoints.isNotEmpty) 'avoid_joints=${state.avoidJoints.join(',')}',
      if (state.noFloor) 'no_floor',
      if (state.quiet) 'quiet',
      if (state.easy) 'easy',
      if (state.smallSpace) 'small_space',
    ];
    if (lim.isNotEmpty) b.write(' 限制：${lim.join(' ')}');
    if (state.redFlag) b.write('\n[安全] 用户已确认危险信号 red_flag=true（reply 不能附动作）');
    final f = state.focus;
    if (f != null) {
      b.write('\n[上次的焦点] muscles=${f.muscles.join(',')} stretch=${f.stretchMuscles.join(',')} types=${f.types.join(',')}${f.minutes == null ? '' : ' minutes=${f.minutes}'}');
    }
    b.write('\n[条件是否假设] ${_assumed ? '是（不是用户这轮刚给的：交付时写 assumption）' : '否（用户刚给的：assumption 留空）'}');
    return b.toString();
  }

  String _cardsBlock() {
    final plan = state.lastPlan;
    if (state.lastShown.isNotEmpty) {
      return '[当前卡片]（动作卡，按展示顺序编号）\n${[for (var k = 0; k < state.lastShown.length; k++) '${k + 1}. ${_actionLine(index[state.lastShown[k]]!)}'].join('\n')}';
    }
    if (plan != null) {
      final rows = <String>[];
      var k = 0;
      for (final bl in plan.plan.blocks) {
        for (final it in bl.items) {
          k++;
          final a = index[it.exerciseId];
          rows.add('$k. [${bl.type.name}${bl.type == BlockType.main ? ':${bl.name}' : ''}] ${a == null ? it.exerciseId : _actionLine(a)}');
        }
      }
      return '[当前卡片]（计划，全部动作连续编号，含热身和收操；目标 ${plan.plan.targetMinutes} 分钟，当前约 ${(plan.seconds / 60).toStringAsFixed(1)} 分钟）\n${rows.join('\n')}';
    }
    return '[当前卡片] 无';
  }

  static String _names(QaAction? a) => a == null ? '?' : '${a.id}（${a.drill.name.values.values.toSet().join(' / ')}）';

  /// build_plan 的主训练：有 segments 用 segments（顺序即各段先后），否则用 main_ids。
  (List<String>, List<String>, Map<String, int>, List<String>) _planMains(Map<String, Object?> a) {
    final segs = asList(a['segments']);
    if (segs.isEmpty) return (asStringList(a['main_ids']), const <String>[], const <String, int>{}, const <String>[]);
    final ids = <String>[];
    final names = <String>[];
    final of = <String, int>{};
    final bad = <String>[];
    for (final (k, raw) in segs.indexed) {
      final m = asMap(raw);
      final name = (asString(m['name']) ?? '').trim();
      final seg = asStringList(m['ids']);
      if (name.isEmpty || seg.isEmpty) {
        bad.add('segments 第 ${k + 1} 段要有 name 和非空 ids');
        continue;
      }
      for (final id in seg) {
        ids.add(id);
        of.putIfAbsent(id, () => names.length);
      }
      names.add(name);
    }
    return (ids, names, of, bad);
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
  static const _typeIds = ['strength', 'cardio', 'stability-control', 'balance', 'mobility', 'dynamic-stretch', 'static-stretch', 'breathing'];
  static const _goalIds = ['strength', 'hypertrophy', 'fat-loss', 'mobility', 'posture', 'recovery', 'desk-relief', 'performance'];
  static const _roleIds = ['warmup', 'main', 'cooldown'];
  static const _patternIds = [
    'squat', 'lunge', 'hinge', 'push-horizontal', 'push-vertical', 'pull-horizontal', 'pull-vertical', 'anti-extension', 'anti-rotation',
    'anti-lateral-flexion', 'rotation', 'carry', 'gait', 'isolation',
  ];
  static const _jointIds = ['knee', 'shoulder', 'lumbar', 'wrist', 'neck', 'ankle', 'hip'];
  static const _homeEquipment = ['dumbbell', 'mat', 'chair', 'band', 'kettlebell', 'pullup-bar', 'foam-roller'];

  /// 合法器械 id：常见家用器械 + 目录 taxonomy 里的器械。
  late final Set<String> _equipmentIds = {..._homeEquipment, ...index.equipmentCatalog().taxonomy.equipment.keys};

  /// 合法姿势 id：目录 taxonomy 里的姿势 + 动作实际用到的姿势。
  late final List<String> _positionIds = {...index.catalog.taxonomy.positions.keys, for (final a in index.all) a.drill.position}.toList();

  static const _itemSchema = {
    'type': 'array',
    'items': {
      'type': 'object',
      'properties': {'id': {'type': 'string'}, 'why': {'type': 'string'}},
      'required': ['id', 'why'],
    },
  };

  late final List<LlmTool> _tools = [
    const LlmTool(
      name: 'set_conditions',
      description: '记录用户的条件（地点、器械、限制、时长、语言、安全危险信号）。只填这轮有变化的字段；返回更新后的 [已知条件]。',
      parameters: {
        'type': 'object',
        'properties': {
          'place': {'type': 'string', 'enum': ['home', 'gym', 'office', 'unknown'], 'description': 'unknown = 清空地点（用户要换场地）'},
          'place_word': {'type': 'string', 'description': '用户对地点的原话说法（如 酒店 / 宿舍 / hotel）'},
          'equipment_known': {'type': 'boolean'},
          'equipment': {'type': 'array', 'items': {'type': 'string'}, 'description': '器械 id：dumbbell / mat / chair / band / kettlebell / pullup-bar / foam-roller'},
          'avoid_joints': {'type': 'array', 'items': {'type': 'string', 'enum': _jointIds}},
          'no_floor': {'type': 'boolean'},
          'quiet': {'type': 'boolean'},
          'easy': {'type': 'boolean'},
          'small_space': {'type': 'boolean'},
          'minutes': {'type': 'integer'},
          'language': {'type': 'string', 'description': '用户语言，BCP-47（zh/en/ja/es…）'},
          'red_flag': {'type': 'boolean', 'description': '用户已确认安全危险信号（发力刺痛、卡住、麻木等）'},
        },
      },
    ),
    const LlmTool(
      name: 'search_actions',
      description: '查动作库：按结构化标签返回当前条件范围内的动作行（带姿势、躺地、器械、关节负担标签），范围外的不返回。',
      parameters: {
        'type': 'object',
        'properties': {
          'muscles': {'type': 'array', 'items': {'type': 'string', 'enum': _muscleIds}},
          'stretch_muscles': {'type': 'array', 'items': {'type': 'string', 'enum': _muscleIds}},
          'types': {'type': 'array', 'items': {'type': 'string', 'enum': _typeIds}},
          'roles': {'type': 'array', 'items': {'type': 'string', 'enum': _roleIds}},
          'goals': {'type': 'array', 'items': {'type': 'string', 'enum': _goalIds}},
          'patterns': {'type': 'array', 'items': {'type': 'string', 'enum': _patternIds}},
          'position': {'type': 'array', 'items': {'type': 'string'}, 'description': '姿势 id：standing / seated / supine / prone / quadruped / kneeling / side_lying / support / hanging'},
          'exclude': {'type': 'array', 'items': {'type': 'string'}},
          'limit': {'type': 'integer', 'description': '1–12，默认 8'},
        },
      },
    ),
    const LlmTool(
      name: 'ask_user',
      description: '交付：问用户一个问题（用户语言）。',
      parameters: {
        'type': 'object',
        'properties': {
          'step': {'type': 'string', 'enum': ['place', 'equipment', 'safety']},
          'question': {'type': 'string'},
          'options': {'type': 'array', 'items': {'type': 'string'}},
          'multi': {'type': 'boolean'},
        },
        'required': ['step', 'question', 'options'],
      },
    ),
    const LlmTool(
      name: 'show_actions',
      description: '交付：推荐 3–5 个动作卡。',
      parameters: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
          'items': _itemSchema,
          'assumption': {'type': 'string'},
          'chips': {'type': 'array', 'items': {'type': 'string'}},
        },
        'required': ['text', 'items', 'chips'],
      },
    ),
    const LlmTool(
      name: 'build_plan',
      description: '交付：排一套训练。动作、顺序、分段、热身、收操都以你给的为准；代码只配组数时长并验收，不合格退回原因。',
      parameters: {
        'type': 'object',
        'properties': {
          'mode': {'type': 'string', 'enum': ['new', 'another', 'retime'], 'description': 'new 新排；another 再来一套（不和上一套重复）；retime 动作不变（改时长、顺序、分段）'},
          'title': {'type': 'string'},
          'text': {'type': 'string'},
          'minutes': {'type': 'integer'},
          'main_ids': {'type': 'array', 'items': {'type': 'string'}},
          'segments': {
            'type': 'array',
            'description': '可选：主训练分段，按顺序；给了就以它为准，不用 main_ids。',
            'items': {
              'type': 'object',
              'properties': {'name': {'type': 'string'}, 'ids': {'type': 'array', 'items': {'type': 'string'}}},
              'required': ['name', 'ids'],
            },
          },
          'warmup_ids': {'type': 'array', 'items': {'type': 'string'}, 'description': '热身动作（从 roles=warmup 的搜索结果里选）；不给就没有热身'},
          'cooldown_ids': {'type': 'array', 'items': {'type': 'string'}, 'description': '收操动作（从 roles=cooldown 的搜索结果里选）；不给就没有收操'},
          'block_names': {
            'type': 'object',
            'properties': {'warmup': {'type': 'string'}, 'main': {'type': 'string'}, 'cooldown': {'type': 'string'}},
          },
          'assumption': {'type': 'string'},
          'chips': {'type': 'array', 'items': {'type': 'string'}},
        },
        'required': ['mode', 'title', 'text', 'minutes', 'chips'],
      },
    ),
    const LlmTool(
      name: 'swap',
      description: '交付：换卡片上第 N 个动作 / 退阶 / 进阶。编号按 [当前卡片]；其他编号不变。',
      parameters: {
        'type': 'object',
        'properties': {
          'mode': {'type': 'string', 'enum': ['swap', 'easier', 'harder']},
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
        'required': ['mode', 'text', 'changes', 'chips'],
      },
    ),
    const LlmTool(
      name: 'reply',
      description: '交付：文字回答（知识、安全、闲聊、没有合格替换时）。items 可空。',
      parameters: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
          'items': _itemSchema,
          'chips': {'type': 'array', 'items': {'type': 'string'}},
        },
        'required': ['text', 'chips'],
      },
    ),
  ];
}

final class _StepFailed implements Exception {
  _StepFailed(this.step, this.why);
  final String step;
  final String why;
}

/// 一次工具调用的结果：信息（继续）、退回（继续）或交付（本轮结束）。
final class _Outcome {
  const _Outcome.info(this.result) : reply = null, rejected = false;
  const _Outcome.rejected(this.result) : reply = null, rejected = true;
  const _Outcome.done(CoachQaReply this.reply) : result = '', rejected = false;
  final String result;
  final CoachQaReply? reply;
  final bool rejected;
}

/// 一轮里的累计：调用次数、用量、每次调用耗时、问题。
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
