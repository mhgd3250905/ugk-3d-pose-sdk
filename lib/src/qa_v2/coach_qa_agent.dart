/// AI 问答推荐 Agent v2（原型，可选启用；与 [CoachAgent] 并存）。
///
/// - 条件收集由代码里的小状态机控制（不交给模型决定）：先问地点，再问器械，一次一个问题；
///   原话/本会话/注入记忆里已有的跳过，同一个问题不连问两次，没答或「直接推荐」就按在家徒手出结果。
///   问句和选项都是代码固定模板，不调模型。居家徒手默认可用墙，椅子要选了才算。
/// - 「第 N 个」按卡片上显示的编号：计划是全部动作连续编号（含热身、收操，从 1 起），动作卡按展示顺序。
/// - 代码先按原话预检索候选（同义词典 + 打分），模型多数情况下一次调用就能作答。
/// - 工具 4 个：find_actions / respond / build_plan / ask_user（模型只能用它问安全问题）。
/// - 「换第 N 个」「太难了」「就用这几个」「换成 N 分钟」「再来一套」由代码处理，不调模型。
library;

import 'dart:convert';

import '../catalog/catalog.dart';
import '../llm/llm_client.dart';
import '../llm/llm_types.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';
import '../tools/ask_user.dart';
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

/// 条件收集的步骤。
enum QaAskStep { place, equipment, safety }

/// 一轮的交付：回答 + 动作卡 + chips（+ 计划 / 条件问题 / 安全追问）。
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
    this.askStep,
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

  /// 例如「按上次：在家徒手」「按在家徒手」。null = 条件来自用户这轮的原话或刚答的问题。
  final String? assumption;
  final TrainingPlan? plan;
  final int? planSeconds;

  /// kind == ask 时的问题：现有 [AskUserQuestion]，choice 模式（器械为多选）。
  /// App 把用户点的选项文字（多选用「、」连接）原样 send 回来即可。
  final AskUserQuestion? question;
  final QaAskStep? askStep;
  final int llmCalls;
  final Duration elapsed;
  final TokenUsage usage;
  final List<String> issues;
  final List<String> toolTrace;

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
    'cards': [for (final c in cards) c.toJson()],
    'chips': chips,
    if (assumption != null) 'assumption': assumption,
    if (plan != null) 'plan': plan!.toJson(),
    if (planSeconds != null) 'planSeconds': planSeconds,
    if (question != null) 'question': question!.toJson(),
    if (askStep != null) 'askStep': askStep!.name,
    'llmCalls': llmCalls,
    'ms': elapsed.inMilliseconds,
    if (issues.isNotEmpty) 'issues': issues,
  };
}

/// 跨会话可选注入的记忆（App 持久化）。有 [scene] 时视为地点和器械都已知，不再问。
final class CoachQaMemory {
  const CoachQaMemory({this.scene, this.equipment = const {}});
  final String? scene;
  final Set<String> equipment;
}

/// 等用户回答的条件问题。
final class QaPending {
  QaPending(this.step, this.text, this.intent);
  final QaAskStep step;

  /// 原请求（「想练背」）。
  final String text;

  /// 原请求的意图，回答里顺带的要求（难度、伤痛……）会并进来。
  final QaIntent intent;
}

/// 本会话状态：上次展示的动作、计划、场景条件、条件收集进度。
final class CoachQaState {
  String? scene;

  /// user（原话）/ answered（答了问题）/ memory / skipped（没答或直接推荐，按默认）/ default（没问过）。
  String sceneSource = 'default';
  int sceneTurn = -1;
  Set<String> equipment = {};

  /// 器械对哪个场景已知（null = 未知）。
  String? equipmentFor;
  String equipmentSource = 'default';
  int equipmentTurn = -1;
  Set<String> avoidJoints = {};
  bool noFloor = false;
  bool smallSpace = false;
  String? maxImpact;
  QaIntent? lastIntent;
  String? lastRequest;
  List<String> lastShown = [];
  Map<String, String> lastWhy = {};
  QaPlanResult? lastPlan;
  QaPending? pending;

  /// 上一轮问的是哪一步（用来保证同一个问题不连问两次）。
  QaAskStep? lastAsk;
  int turn = 0;
  final List<(String, String)> history = [];

  bool get sceneKnown => sceneSource != 'default';
}

const _sceneZh = {'home': '在家', 'office': '办公室', 'gym': '健身房', 'hotel': '酒店房间', 'outdoor': '户外'};
const _sceneEn = {'home': 'home', 'office': 'office', 'gym': 'gym', 'hotel': 'hotel room', 'outdoor': 'outdoors'};
const _equipNameZh = {'dumbbell': '哑铃', 'band': '弹力带', 'mat': '瑜伽垫', 'chair': '椅子', 'kettlebell': '壶铃', 'pullup-bar': '单杠', 'barbell': '杠铃', 'foam-roller': '泡沫轴'};
const _equipNameEn = {'dumbbell': 'dumbbells', 'band': 'bands', 'mat': 'yoga mat', 'chair': 'chair', 'kettlebell': 'kettlebell', 'pullup-bar': 'pull-up bar', 'barbell': 'barbell', 'foam-roller': 'foam roller'};

const _placeOptionsZh = ['居家', '健身房', '办公室', '直接推荐'];
const _placeOptionsEn = ['Home', 'Gym', 'Office', 'Just recommend'];
const _equipOptionsZh = ['哑铃', '瑜伽垫', '椅子', '弹力带', '都没有（徒手）', '直接推荐'];
const _equipOptionsEn = ['Dumbbells', 'Yoga mat', 'Chair', 'Bands', 'None (bodyweight)', 'Just recommend'];

final _skipWords = RegExp(r'直接推荐|直接出|你定|都行|无所谓|随便吧|不知道|just recommend|whatever|you pick|any', caseSensitive: false);

/// 只有居家（酒店算居家）才问器械；健身房不限器械，办公室只到椅子 + 徒手。
bool _equipmentScene(String? s) => s == 'home' || s == 'hotel';
String _equipGroup(String? s) => s == 'hotel' ? 'home' : (s ?? 'home');

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
    if (memory.scene != null) {
      state.scene = memory.scene;
      state.sceneSource = 'memory';
      state.equipment = {...memory.equipment};
      state.equipmentFor = _equipGroup(memory.scene);
      state.equipmentSource = 'memory';
    }
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
    state.turn++;
    final askedLast = state.lastAsk;
    state.lastAsk = null;
    CoachQaReply reply;
    final pending = state.pending;
    if (pending != null) {
      state.pending = null;
      reply = await _onAnswer(pending, text, language, sw);
    } else {
      reply = await _onMessage(text, language, sw, askedLast: askedLast);
    }
    if (reply.kind == 'ask' && reply.askStep != null) state.lastAsk = reply.askStep;
    state.history.add((text, _historyLine(reply, language)));
    if (state.history.length > 6) state.history.removeAt(0);
    return reply;
  }

  Future<CoachQaReply> _onMessage(String text, String lang, Stopwatch sw, {QaAskStep? askedLast, bool noAsk = false}) async {
    final intent = parseIntent(text);
    final follow = detectFollowUp(text);
    if (follow.kind == QaFollowUp.changePlace) {
      final req = state.lastRequest;
      if (req != null && askedLast != QaAskStep.place) {
        // 用户主动要换场地：问一次地点，答完按原请求重出。
        state.sceneSource = 'default';
        return _ask(QaAskStep.place, req, state.lastIntent ?? parseIntent(req), lang, sw);
      }
    }
    _applyWords(intent);
    if (follow.kind != QaFollowUp.none && follow.kind != QaFollowUp.changePlace) {
      final r = _followUp(follow, intent, lang, sw);
      if (r != null) return r;
    }
    return _request(text, intent, lang, sw, askedLast: askedLast, noAsk: noAsk);
  }

  /// 新请求：先看条件够不够（状态机），够了再调模型。
  Future<CoachQaReply> _request(String text, QaIntent intent, String lang, Stopwatch sw, {QaAskStep? askedLast, bool noAsk = false, String? modelText, QaIntent? rawIntent}) async {
    final eff = _effectiveIntent(intent);
    if (!noAsk) {
      final step = nextStep(eff, raw: rawIntent ?? intent);
      if (step != null && step != askedLast) return _ask(step, text, eff, lang, sw);
    }
    state.lastRequest = text;
    return _llmTurn(modelText ?? text, intent, lang, sw);
  }

  /// 跟进句（「那来一套15分钟的」「我现在在办公室」）没有新焦点时沿用上次意图。
  QaIntent _effectiveIntent(QaIntent intent) {
    if (intent.hasFocus || state.lastIntent == null) return intent;
    final last = state.lastIntent!;
    final e = _copyIntent(last);
    if (intent.minutes != null) e.minutes = intent.minutes;
    if (intent.wantsPlan) e.wantsPlan = true;
    if (intent.easy) e.easy = true;
    e.avoidJoints.addAll(intent.avoidJoints);
    return e;
  }

  // ---------------------------------------------------------------- 条件收集（状态机）

  /// 这句话里地点会不会明显改变答案。拉伸放松、纯知识题、安全题、周计划都不问。
  bool placeSensitive(QaIntent i, {QaIntent? raw}) {
    final r = raw ?? i;
    if (r.safetyFlag || r.avoidJoints.isNotEmpty || state.avoidJoints.isNotEmpty && !r.wantsPlan) return false;
    if (r.weekly) return false;
    if (r.onlyEquipment || r.bodyweightOnly) return false; // 「只有弹力带」「徒手」：器械已定，按在家
    if (_pureKnowledge(r)) return false;
    const stretchy = {'static-stretch', 'dynamic-stretch', 'mobility', 'breathing'};
    final stretchOnly = i.types.isNotEmpty && i.types.every(stretchy.contains) && i.muscles.isEmpty;
    if (stretchOnly || (i.stretchMuscles.isNotEmpty && i.muscles.isEmpty && !i.types.contains('cardio'))) return false;
    if (i.roles.isNotEmpty && i.roles.every((x) => x == 'warmup' || x == 'cooldown') && i.muscles.isEmpty) return false;
    if (i.wantsPlan || i.muscles.isNotEmpty || i.types.contains('cardio') || i.types.contains('strength')) return true;
    if (i.keywords.isNotEmpty) return false; // 点名某个动作（俯卧撑、深蹲）：讲这个动作，不问场地
    return _trainingWords.hasMatch(r.raw);
  }

  static final _trainingWords = RegExp(r'练|训练|动一动|运动|锻炼|健身|workout|exercise|train');

  static bool _pureKnowledge(QaIntent i) =>
      RegExp(r'多久|多少|正常吗|为什么|怎么办|是什么|有用吗|有没有用|区别|还能|能不能练|可以练吗|how long|how many|why|normal|is it ok').hasMatch(i.raw) &&
      !i.wantsPlan &&
      !RegExp(r'推荐|来几个|给我|有什么动作|哪些动作|recommend|give me').hasMatch(i.raw);

  /// 下一步要问什么（null = 条件够了）。
  QaAskStep? nextStep(QaIntent i, {QaIntent? raw}) {
    if (!placeSensitive(i, raw: raw)) return null;
    if (!state.sceneKnown) return QaAskStep.place;
    final s = state.scene;
    if (_equipmentScene(s) && state.equipmentFor != _equipGroup(s)) return QaAskStep.equipment;
    return null;
  }

  /// 原话里的场景、器械、限制写进状态。
  void _applyWords(QaIntent i) {
    if (i.scene != null) {
      if (_equipGroup(i.scene) != _equipGroup(state.scene)) {
        state.equipmentFor = null;
        state.equipment = {};
      }
      state.scene = i.scene;
      state.sceneSource = 'user';
      state.sceneTurn = state.turn;
    }
    if (i.bodyweightOnly || i.equipment.isNotEmpty) {
      state.equipment = i.bodyweightOnly ? {} : (i.onlyEquipment ? {...i.equipment} : {...state.equipment, ...i.equipment});
      if (!state.sceneKnown && (i.onlyEquipment || i.bodyweightOnly)) {
        state.scene = profile.defaultScene;
        state.sceneSource = 'user';
        state.sceneTurn = state.turn;
      }
      state.equipmentFor = _equipGroup(state.scene ?? profile.defaultScene);
      state.equipmentSource = 'user';
      state.equipmentTurn = state.turn;
    }
    state.avoidJoints.addAll(i.avoidJoints);
    if (i.noFloor) state.noFloor = true;
    if (i.smallSpace) state.smallSpace = true;
    if (i.maxImpact != null) state.maxImpact = i.maxImpact;
  }

  /// 条件问题：问句和选项都是代码里的固定模板（只按用户原话填部位），不调模型，几毫秒出。
  CoachQaReply _ask(QaAskStep step, String text, QaIntent intent, String lang, Stopwatch sw) {
    final en = lang == 'en';
    state.pending = QaPending(step, text, intent);
    final options = step == QaAskStep.place ? (en ? _placeOptionsEn : _placeOptionsZh) : (en ? _equipOptionsEn : _equipOptionsZh);
    final question = fixedQuestion(step, intent, text, lang);
    final gate = AskUserGate.check(
      jsonEncode({'question': question, 'mode': 'choice', 'options': options, 'multiple': step == QaAskStep.equipment}),
      language: lang,
    );
    return CoachQaReply(
      kind: 'ask',
      text: question,
      question: gate.question,
      askStep: step,
      elapsed: sw.elapsed,
      issues: gate.notes,
    );
  }

  /// 固定问句：地点「练背的话，你在哪练？」；器械「在家练背，手边有哪些器械？可以多选。」。
  static String fixedQuestion(QaAskStep step, QaIntent intent, String text, String lang) {
    final en = lang == 'en';
    final topic = _topic(intent, text, lang);
    if (step == QaAskStep.place) {
      return en ? (topic.isEmpty ? 'Where will you train?' : 'For $topic, where will you train?') : '${topic.isEmpty ? '' : '$topic的话，'}你在哪练？';
    }
    return en ? 'What equipment do you have at home? Pick all that apply.' : '在家${topic.isEmpty ? '' : '$topic，'}手边有哪些器械？可以多选。';
  }

  static String _topic(QaIntent i, String text, String lang) {
    final en = lang == 'en';
    final m = i.muscles;
    if (m.contains('lats')) return en ? 'back training' : '练背';
    if (m.contains('quadriceps')) return en ? 'a leg workout' : '练腿';
    if (m.contains('glute-max')) return en ? 'glutes' : '练臀';
    if (m.contains('chest')) return en ? 'chest' : '练胸';
    if (m.contains('biceps') || m.contains('triceps')) return en ? 'arms' : '练手臂';
    if (m.contains('deltoids')) return en ? 'shoulders' : '练肩';
    if (i.types.contains('cardio')) return en ? 'burning fat' : (m.contains('abs') ? '想瘦肚子' : '燃脂');
    if (m.contains('abs')) return en ? 'abs' : '练腹肌';
    if (i.minutes != null) return en ? 'a ${i.minutes}-min session' : '这套${i.minutes}分钟的训练';
    if (i.wantsPlan) return en ? 'this session' : '这套训练';
    return en ? '' : '想动一动';
  }

  String? _matchPlace(String text) {
    final t = text.toLowerCase().trim();
    const map = {'居家': 'home', '在家': 'home', 'home': 'home', '健身房': 'gym', 'gym': 'gym', '办公室': 'office', 'office': 'office'};
    if (map.containsKey(t)) return map[t];
    return parseIntent(text).scene;
  }

  /// 器械回答：null = 没答到器械；空集合 = 徒手。
  Set<String>? _matchEquipment(String text) {
    final t = text.toLowerCase();
    final eq = <String>{};
    if (RegExp(r'哑铃|dumbbell').hasMatch(t)) eq.add('dumbbell');
    if (RegExp(r'弹力带|弹力绳|阻力带|band').hasMatch(t)) eq.add('band');
    if (RegExp(r'瑜伽垫|垫子|\bmat\b').hasMatch(t)) eq.add('mat');
    if (RegExp(r'椅子|凳子|chair').hasMatch(t)) eq.add('chair');
    eq.addAll(parseIntent(text).equipment);
    if (eq.isEmpty && RegExp(r'徒手|都没有|没有器械|没器械|啥也没有|什么都没有|bodyweight|nothing|none').hasMatch(t)) return {};
    return eq.isEmpty ? null : eq;
  }

  Future<CoachQaReply> _onAnswer(QaPending p, String text, String lang, Stopwatch sw) async {
    final ans = parseIntent(text);
    final skip = _skipWords.hasMatch(text);
    final merged = _mergeExtras(p.intent, ans);
    final modelText = '${p.text}（补充：$text）';
    if (p.step == QaAskStep.place) {
      final scene = skip ? null : _matchPlace(text);
      if (scene != null) {
        if (_equipGroup(scene) != _equipGroup(state.scene) || state.sceneSource == 'default') {
          state.equipmentFor = null;
          state.equipment = {};
        }
        state.scene = scene;
        state.sceneSource = 'answered';
        state.sceneTurn = state.turn;
        final eq = _matchEquipment(text);
        if (eq != null) _setEquipment(eq, 'answered');
        _applyLimits(ans);
        return _request(p.text, merged, lang, sw, askedLast: QaAskStep.place, modelText: modelText, rawIntent: parseIntent(p.text));
      }
      // 直接推荐 / 没回答 / 说了别的：按在家徒手（或已知条件），不再问地点。
      _skipConditions();
      _applyLimits(ans);
      if (!skip && _isNewRequest(ans, text)) return _onMessage(text, lang, sw, askedLast: QaAskStep.place, noAsk: true);
      return _request(p.text, merged, lang, sw, askedLast: QaAskStep.place, noAsk: true, modelText: skip ? p.text : modelText);
    }
    // 器械
    final eq = skip ? null : _matchEquipment(text);
    if (eq != null) {
      _setEquipment(eq, 'answered');
    } else {
      _setEquipment({}, 'skipped');
    }
    _applyLimits(ans);
    if (eq == null && !skip && _isNewRequest(ans, text)) return _onMessage(text, lang, sw, askedLast: QaAskStep.equipment, noAsk: true);
    return _request(p.text, merged, lang, sw, askedLast: QaAskStep.equipment, noAsk: true, modelText: skip || eq != null ? p.text : modelText);
  }

  bool _isNewRequest(QaIntent ans, String text) =>
      ans.hasFocus && ans.muscles.isNotEmpty || ans.wantsPlan && ans.minutes == null && !ans.easy || detectFollowUp(text).kind == QaFollowUp.changePlace;

  void _setEquipment(Set<String> eq, String source) {
    state.equipment = eq;
    state.equipmentFor = _equipGroup(state.scene ?? profile.defaultScene);
    state.equipmentSource = source;
    state.equipmentTurn = state.turn;
  }

  void _skipConditions() {
    if (!state.sceneKnown) {
      state.scene = profile.defaultScene;
      state.sceneSource = 'skipped';
      state.sceneTurn = state.turn;
    }
    if (_equipmentScene(state.scene) && state.equipmentFor != _equipGroup(state.scene)) _setEquipment({}, 'skipped');
  }

  void _applyLimits(QaIntent i) {
    state.avoidJoints.addAll(i.avoidJoints);
    if (i.noFloor) state.noFloor = true;
    if (i.smallSpace) state.smallSpace = true;
    if (i.maxImpact != null) state.maxImpact = i.maxImpact;
  }

  /// 回答里顺带的要求（难度、时长、伤痛）并进原请求。
  QaIntent _mergeExtras(QaIntent base, QaIntent ans) {
    final e = _copyIntent(base);
    if (ans.easy) e.easy = true;
    if (ans.minutes != null) {
      e.minutes = ans.minutes;
      e.wantsPlan = true;
    }
    e.avoidJoints.addAll(ans.avoidJoints);
    if (ans.noFloor) e.noFloor = true;
    if (ans.maxImpact != null) e.maxImpact = ans.maxImpact;
    if (ans.smallSpace) e.smallSpace = true;
    if (ans.lowIntensity) e.lowIntensity = true;
    return e;
  }

  static QaIntent _copyIntent(QaIntent s) => QaIntent()
    ..raw = s.raw
    ..scene = s.scene
    ..muscles.addAll(s.muscles)
    ..stretchMuscles.addAll(s.stretchMuscles)
    ..types.addAll(s.types)
    ..goals.addAll(s.goals)
    ..roles.addAll(s.roles)
    ..keywords.addAll(s.keywords)
    ..avoidJoints.addAll(s.avoidJoints)
    ..equipment.addAll(s.equipment)
    ..noFloor = s.noFloor
    ..smallSpace = s.smallSpace
    ..maxImpact = s.maxImpact
    ..easy = s.easy
    ..lowIntensity = s.lowIntensity
    ..maxDifficulty = s.maxDifficulty
    ..minutes = s.minutes
    ..wantsPlan = s.wantsPlan
    ..safetyFlag = s.safetyFlag
    ..knowledge = s.knowledge
    ..weekly = s.weekly;

  // ---------------------------------------------------------------- 场景说明

  String _equipLabel(String lang) {
    final en = lang == 'en';
    final s = state.scene ?? 'home';
    if (s == 'gym') return en ? 'full equipment' : '器械齐全';
    if (s == 'office') return en ? 'chair + bodyweight' : '椅子+徒手';
    if (state.equipment.isEmpty) return en ? 'bodyweight' : '徒手';
    return state.equipment.map((e) => en ? (_equipNameEn[e] ?? e) : (_equipNameZh[e] ?? e)).join(en ? ' + ' : '、');
  }

  /// 条件来自哪：这轮原话/刚答的 → null；之前答过或记忆 → 「按上次：…」；没答/直接推荐/默认 → 「按…」。
  String? _assumption(String lang) {
    final en = lang == 'en';
    final s = state.scene ?? 'home';
    // 这轮刚收齐（地点、器械分两轮答完也算）→ 不写假设。
    const given = {'user', 'answered'};
    final eqGiven = !_equipmentScene(s) || given.contains(state.equipmentSource);
    final latest = _equipmentScene(s) && state.equipmentTurn > state.sceneTurn ? state.equipmentTurn : state.sceneTurn;
    final fresh = given.contains(state.sceneSource) && latest == state.turn;
    final eqFresh = eqGiven;
    if (fresh && eqFresh) return null;
    final label = en ? '${_sceneEn[s]}, ${_equipLabel(lang)}' : '${_sceneZh[s]}${_equipLabel(lang)}';
    final reused = state.sceneSource == 'memory' || ((state.sceneSource == 'user' || state.sceneSource == 'answered') && !fresh) ||
        (fresh && !eqFresh && (state.equipmentSource == 'answered' || state.equipmentSource == 'user' || state.equipmentSource == 'memory'));
    if (reused) return en ? 'Same as last time: $label' : '按上次：$label';
    return en ? 'Assuming $label' : '按$label';
  }

  QaQuery _query(QaIntent i, {Set<String> exclude = const {}, int limit = 8}) {
    final merged = _copyIntent(i)
      ..avoidJoints.addAll(state.avoidJoints)
      ..noFloor = i.noFloor || state.noFloor
      ..smallSpace = i.smallSpace || state.smallSpace
      ..maxImpact = i.maxImpact ?? state.maxImpact;
    return queryFromIntent(merged, scene: state.scene ?? profile.defaultScene, equipment: state.equipment, exclude: exclude, limit: limit, strict: _strict);
  }

  /// 范围已圈定（地点已知；居家还要器械已知）→ 严格只用圈定的器械，不越界。
  bool get _strict {
    if (!state.sceneKnown) return false;
    final s = state.scene;
    if (_equipmentScene(s)) return state.equipmentFor == _equipGroup(s);
    return s == 'gym' || s == 'office';
  }

  List<String> _chips(String lang, {bool plan = false}) => lang == 'en'
      ? [plan ? 'Make it 10 min' : 'Make it a 10-min session', 'Easier', 'Change place']
      : [plan ? '换成10分钟' : '排成10分钟', '换简单点', '换场地'];

  // ---------------------------------------------------------------- 代码跟进
  CoachQaReply? _followUp(QaFollowUpMatch f, QaIntent intent, String lang, Stopwatch sw) {
    final en = lang == 'en';
    final planIds = state.lastPlan?.orderedIds ?? const <String>[];
    final shown = state.lastShown;
    switch (f.kind) {
      case QaFollowUp.useThese:
        if (shown.isEmpty && planIds.isEmpty) return null;
        if (shown.isEmpty) return _retime(f.minutes ?? intent.minutes ?? 10, lang, sw);
        final minutes = f.minutes ?? intent.minutes ?? 10;
        final ids = shown;
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
      case QaFollowUp.retime:
        if (state.lastPlan == null && shown.isNotEmpty) {
          return _followUp(QaFollowUpMatch(QaFollowUp.useThese, minutes: f.minutes), intent, lang, sw);
        }
        if (state.lastPlan == null || f.minutes == null) return null;
        return _retime(f.minutes!, lang, sw);
      case QaFollowUp.another:
        return _another(f.minutes, intent, lang, sw);
      case QaFollowUp.changePlace:
        return null;
      case QaFollowUp.replace:
        // 「第 N 个」严格按卡片上显示的编号：计划卡片把全部动作连续编号（含热身、收操，从 1 起），
        // 动作卡按展示顺序编号。
        final inPlan = state.lastPlan != null && shown.isEmpty;
        final list = inPlan ? planIds : shown;
        if (list.isEmpty) return null;
        final i = f.index ?? 0;
        if (i < 0 || i >= list.length) {
          return CoachQaReply(
            kind: 'answer',
            text: en
                ? 'The ${inPlan ? 'plan' : 'list'} above has ${list.length} moves (#1–#${list.length}). Which number should I swap?'
                : '上面的${inPlan ? '计划' : '卡片'}一共${list.length}个动作（第1–${list.length}个），要换第几个？',
            plan: inPlan ? state.lastPlan!.plan : null,
            planSeconds: inPlan ? state.lastPlan!.seconds : null,
            cards: inPlan ? const [] : _cardsFor(shown, lang, state.lastWhy),
            chips: _chips(lang, plan: inPlan),
            elapsed: sw.elapsed,
          );
        }
        final old = index[list[i]];
        if (old == null) return null;
        // 计划里其他动作（含热身/收操）也排除，免得换上来的和别处重复。
        final base = _query(state.lastIntent ?? intent, exclude: {...list, ...planIds});
        final hit = finder.replacementFor(old, base, lang: lang, focus: base.muscles) ?? (inPlan ? _sessionPartReplacement(i, base, lang) : null);
        if (hit == null) {
          return CoachQaReply(
            kind: 'answer',
            text: en
                ? 'Within your setup (${_equipLabel(lang)}) there is no other move that does the same job as #${i + 1} ${old.name(lang)}, so I kept it.'
                : '在你圈定的范围（${_sceneZh[state.scene] ?? '在家'}${_equipLabel(lang)}）里，没有和第${i + 1}个「${old.name(lang)}」练同一处的其他动作，先保留它。',
            plan: inPlan ? state.lastPlan!.plan : null,
            planSeconds: inPlan ? state.lastPlan!.seconds : null,
            cards: inPlan ? const [] : _cardsFor(shown, lang, state.lastWhy),
            chips: _chips(lang, plan: inPlan),
            assumption: _assumption(lang),
            elapsed: sw.elapsed,
          );
        }
        if (inPlan) {
          final r = _swapInPlan(state.lastPlan!, i, hit.action.id);
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
        final newIds = [...list]..[i] = hit.action.id;
        state.lastShown = newIds;
        return CoachQaReply(
          kind: 'replace',
          text: en ? 'Swapped #${i + 1} for ${hit.action.name(lang)}: ${hit.reason}.' : '第${i + 1}个换成了「${hit.action.name(lang)}」：${hit.reason}。',
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
        final base = _query(state.lastIntent ?? intent, exclude: {...list, if (shown.isEmpty) ...planIds});
        final out = <String>[];
        final why = <String, String>{};
        var changed = 0;
        for (final id in list) {
          final a = index[id];
          if (a == null) continue;
          final h = easier ? finder.easierThan(a, base.withExclude(out.toSet()), lang: lang, focus: base.muscles) : finder.harderThan(a, base.withExclude(out.toSet()), lang: lang);
          if (h != null) {
            out.add(h.action.id);
            why[h.action.id] = h.reason;
            changed++;
          } else {
            out.add(id);
          }
        }
        if (changed == 0) {
          if (!easier) return null;
          // 圈定范围里没有更简单的同部位动作：如实说，不越界、不换成别的部位。
          final keepPlan = state.lastPlan != null && shown.isEmpty;
          return CoachQaReply(
            kind: 'easier',
            text: en
                ? 'Within your setup (${_equipLabel(lang)}) there is no easier move for the same muscles. Halve the reps and slow down for now; adding a yoga mat or a band unlocks easier versions.'
                : '在你圈定的范围（${_sceneZh[state.scene] ?? '在家'}${_equipLabel(lang)}）里，没有比这几个更简单、又练同一处的动作。先把次数减半、动作放慢做稳；加一张瑜伽垫或一根弹力带，就能换更简单的版本。',
            cards: keepPlan ? const [] : _cardsFor(list, lang, state.lastWhy),
            plan: keepPlan ? state.lastPlan!.plan : null,
            planSeconds: keepPlan ? state.lastPlan!.seconds : null,
            chips: _chips(lang, plan: keepPlan),
            assumption: _assumption(lang),
            elapsed: sw.elapsed,
          );
        }
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

  CoachQaReply _retime(int minutes, String lang, Stopwatch sw) {
    final old = state.lastPlan!;
    final base = _query(state.lastIntent ?? QaIntent());
    final r = builder.build(mainIds: old.mainIds, minutes: minutes, base: base, title: old.plan.title, lang: lang);
    _rememberPlan(r);
    final en = lang == 'en';
    return CoachQaReply(
      kind: 'plan',
      text: en
          ? 'Same moves and conditions, re-fitted to about ${(r.seconds / 60).round()} min.'
          : '动作和条件不变，按$minutes分钟重新排了组数，总共约${(r.seconds / 60).round()}分钟。',
      plan: r.plan,
      planSeconds: r.seconds,
      chips: _chips(lang, plan: true),
      assumption: _assumption(lang),
      elapsed: sw.elapsed,
      issues: r.notes,
    );
  }

  /// 再来一套：同样的条件和时长，换一批主训练。
  CoachQaReply? _another(int? minutes, QaIntent intent, String lang, Stopwatch sw) {
    final en = lang == 'en';
    final base = state.lastIntent ?? intent;
    if (state.lastPlan != null) {
      final old = state.lastPlan!;
      final n = old.mainIds.length.clamp(3, 5);
      final hits = finder.find(_query(base, exclude: {...old.orderedIds}, limit: n), lang: lang);
      if (hits.length < 2) return null;
      final r = builder.build(
        mainIds: [for (final h in hits) h.action.id],
        minutes: minutes ?? old.plan.targetMinutes,
        base: _query(base, exclude: {...old.mainIds}),
        title: old.plan.title,
        lang: lang,
      );
      _rememberPlan(r);
      return CoachQaReply(
        kind: 'plan',
        text: en
            ? 'A fresh set of main moves with the same conditions, about ${(r.seconds / 60).round()} min.'
            : '条件不变，换了一批主训练动作，总共约${(r.seconds / 60).round()}分钟。',
        plan: r.plan,
        planSeconds: r.seconds,
        chips: _chips(lang, plan: true),
        assumption: _assumption(lang),
        elapsed: sw.elapsed,
        issues: r.notes,
      );
    }
    if (state.lastShown.isEmpty) return null;
    final hits = finder.find(_query(base, exclude: {...state.lastShown}, limit: state.lastShown.length.clamp(3, 5)), lang: lang);
    if (hits.isEmpty) return null;
    final ids = [for (final h in hits) h.action.id];
    state.lastShown = ids;
    state.lastWhy = {for (final h in hits) h.action.id: h.reason};
    return CoachQaReply(
      kind: 'recommend',
      text: en ? 'Another set of moves for the same goal and conditions.' : '同样的目标和条件，换了一批动作。',
      cards: _cardsFor(ids, lang, state.lastWhy),
      chips: _chips(lang),
      assumption: _assumption(lang),
      elapsed: sw.elapsed,
    );
  }

  /// 热身/收操没有练同一处的替代时：换成同一环节、照顾本次主训练部位的另一个动作（和排计划同一套条件）。
  QaHit? _sessionPartReplacement(int pos, QaQuery base, String lang) {
    final plan = state.lastPlan!.plan;
    var k = -1;
    BlockType? type;
    for (final b in plan.blocks) {
      for (final _ in b.items) {
        if (++k == pos) type = b.type;
      }
    }
    if (type != BlockType.warmup && type != BlockType.cooldown) return null;
    final warm = type == BlockType.warmup;
    final region = {for (final id in state.lastPlan!.mainIds) ...?index[id]?.primaryMuscles};
    QaQuery q(Set<String> area) => QaQuery(
      scene: base.scene,
      equipment: base.equipment,
      strict: base.strict,
      muscles: warm ? area : const {},
      stretchMuscles: warm ? const {} : area,
      types: warm ? const {'mobility', 'dynamic-stretch'} : const {'static-stretch'},
      roles: {warm ? 'warmup' : 'cooldown'},
      avoidJoints: base.avoidJoints,
      noFloor: base.noFloor,
      maxImpact: base.maxImpact,
      exclude: base.exclude,
      limit: 4,
    );
    // 必须照顾到本次主训练的部位（主动肌/辅助肌/被拉伸肌有交集），不拿不相干的动作凑数。
    bool fits(QaAction a) => a.sessionRole.contains(warm ? 'warmup' : 'cooldown') && [...a.primaryMuscles, ...a.secondaryMuscles, ...a.stretchedMuscles].any(region.contains);
    final h = finder.find(q(region).withLimit(12), lang: lang).where((h) => fits(h.action)).firstOrNull;
    if (h == null) return null;
    return QaHit(h.action, 0, [lang == 'en' ? (warm ? 'another warm-up for this session' : 'another cool-down for this session') : (warm ? '同样是这套的热身' : '同样是这套的放松')]);
  }

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
1. 场地和器械由 App 代码负责确认，你不要再问场地、器械、时长、水平：直接用状态里的条件作答（标「默认」的 App 会显示假设和切换按钮）。没说水平按新手。只有安全问题缺关键信息时才 ask_user。
2. 每次只调用一个工具。优先直接用「候选动作」作答：
   - 问答/推荐/知识题/安全题 → respond。text 2–4 句，针对这个人的原话回答（原因、做法、最该注意的一点）。禁止通用套话（如「不憋气、不弹震、有牵扯感即可」「注意安全」），不列组数次数。items 选 3–5 个最贴切的候选；知识题、安全题有合适动作也附上（如平板的变式、膝盖友好的下肢动作、肩痛时能练的）。why 写这个动作为什么适合这个人，不要复述动作名。
   - 要一套训练 / N 分钟 / 计划 → build_plan，main_ids 给 3–6 个主训练动作。没说时长按 15 分钟。热身、收操、组数时长由代码排，别写进 text。
   - 候选明显不对题时才 find_actions 换条件查一次。
3. 只能用候选或 find_actions 返回的 id。库里没有的动作（跑步、波比跳等）说一句没有，再用最接近的代替。状态里有「器械缺口」时，text 要如实说库里没有，并说最接近的做法或加什么器械能做。
4b. text 不能和卡片矛盾：说「不跳」「不用躺」「不用器械」就不能选跳跃、躺地、要器械的动作。
4. 疼痛：先给判断标准（什么情况可以继续、什么情况停下就医），再给能练的动作。
5. 周计划类：text 给出一周怎么排（哪几天、每次多久、练什么），items 附一次课可用的动作。
6. 用 ${lang == 'en' ? 'English' : '简体中文'} 回答。''';

  String _stateBlock(QaIntent i, List<QaHit> hits, String lang, {String? gap}) {
    final b = StringBuffer();
    final s = state.scene ?? 'home';
    b.writeln('[状态]');
    const src = {'user': '用户说的', 'answered': '用户刚答的', 'memory': '沿用上次', 'skipped': '用户没选，默认', 'default': '默认'};
    b.writeln('场景：${_sceneZh[s]}（${src[state.sceneSource]}）');
    b.writeln(_strict
        ? '器械：${_equipLabel('zh')}${_equipmentScene(s) ? '（墙默认可用）' : ''}（用户圈定的范围，候选已严格过滤，只能用这些，${s == 'gym' ? '不限器械' : '不能超出'}）'
        : '器械：${_equipLabel('zh')}${state.equipment.isEmpty && s != 'gym' ? '（可用场景里的椅子/墙/垫子）' : ''}');
    final lim = [
      if (state.avoidJoints.isNotEmpty) '避开${state.avoidJoints.map((j) => jointZh[j] ?? j).join('、')}受力',
      if (state.noFloor || s == 'office') '不躺地',
      if (state.maxImpact != null) '无跳跃、不扰邻',
      if (state.smallSpace || i.smallSpace) '场地小，原地完成',
      if (i.easy) '要简单的',
    ];
    if (lim.isNotEmpty) b.writeln('限制：${lim.join('；')}');
    if (i.safetyFlag) b.writeln('安全信号：原话里有需要警惕的描述，先给判断标准；必要时 ask_user。');
    if (state.lastShown.isNotEmpty) {
      b.writeln('上次展示：${[for (var k = 0; k < state.lastShown.length; k++) '${k + 1}.${index[state.lastShown[k]]?.name('zh')}(${state.lastShown[k]})'].join(' ')}');
    }
    if (state.lastPlan != null) {
      final ids = state.lastPlan!.orderedIds;
      // 编号和计划卡片上显示的一致（全部动作连续编号，含热身/收操）。
      b.writeln('上次计划：${state.lastPlan!.plan.title}，${[for (var k = 0; k < ids.length; k++) '${k + 1}.${index[ids[k]]?.name('zh')}'].join(' ')}（编号=卡片上的编号）');
    }
    if (gap != null) b.writeln('器械缺口：$gap');
    b.writeln('[候选动作]（代码按原话检索，已过滤场景/器械/限制，按相关度排序）');
    if (hits.isEmpty) b.writeln('（无）');
    for (final h in hits) {
      final a = h.action;
      final marks = [
        if (a.impact != 'none') '有轻微冲击',
        if (a.floorRequired) '要躺/趴地',
        if (a.requiredEquipment.isNotEmpty) '要${a.requiredEquipment.join('/')}',
      ].join('，');
      b.writeln('${a.id} | ${a.name(lang)} | 难度${a.difficulty} | ${a.sessionRole.join('/')} | ${h.reason}${marks.isEmpty ? '' : ' | $marks'} | ${lang == 'en' && a.summaryEn.isNotEmpty ? a.summaryEn : a.summaryZh}');
    }
    return b.toString();
  }

  Future<CoachQaReply> _llmTurn(String text, QaIntent intent, String lang, Stopwatch sw) async {
    // 跟进句（如「那来一套15分钟的」）没有新焦点时沿用上次意图。
    final eff = _effectiveIntent(intent);
    if (intent.hasFocus) state.lastIntent = intent;
    state.lastIntent ??= intent;
    var hits = finder.find(_query(eff), lang: lang);
    final gap = _gap(eff, lang);
    // 有续接的上次展示，排在候选前面。
    final hitMap = {for (final h in hits) h.action.id: h};
    final messages = <LlmMessage>[LlmMessage.system(_system(lang))];
    for (final (u, a) in state.history) {
      messages
        ..add(LlmMessage.user(u))
        ..add(LlmMessage.assistant(a));
    }
    messages.add(LlmMessage.user('$text\n\n${_stateBlock(eff, hits, lang, gap: gap)}'));
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
        return _finishRespond(t, const [], hitMap, lang, sw, calls, usage, trace, issues, range: _query(eff), hits: hits, wantCards: eff.hasFocus && !_pureKnowledge(intent));
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
          return _finishRespond(_withGap(asString(args['text']) ?? '', gap), items, hitMap, lang, sw, calls, usage, trace, issues, range: _query(eff), hits: hits, wantCards: eff.hasFocus && !_pureKnowledge(intent));
        case 'build_plan':
          // 正文说「不跳」就按零冲击排，免得文字和计划打架。
          final noJump = RegExp(r'不跳|无跳跃|不用跳|没有跳|no jump').hasMatch(asString(args['text']) ?? '');
          final planIntent = noJump ? (_copyIntent(eff)..maxImpact = 'none') : eff;
          final ids = asStringList(args['main_ids'])
              .where((id) => index[id] != null && !(noJump && RegExp(r'跳|jump|jack', caseSensitive: false).hasMatch(index[id]!.name('zh'))))
              .toList();
          final minutes = asInt(args['minutes']) ?? eff.minutes ?? 15;
          final r = builder.build(
            mainIds: ids,
            minutes: minutes,
            base: _query(planIntent),
            title: asString(args['title']) ?? _planTitle(eff, lang),
            lang: lang,
          );
          _rememberPlan(r);
          return CoachQaReply(
            kind: 'plan',
            text: _withDropped(_withGap(_clean(asString(args['text']) ?? ''), gap), r.notes, lang),
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
          final q = asString(args['question']) ?? '';
          final safety = eff.safetyFlag || eff.avoidJoints.isNotEmpty || state.avoidJoints.isNotEmpty;
          final aboutConditions = RegExp(r'在哪|场地|地点|器械|哑铃|弹力带|多久|几分钟|时长|水平|where|equipment|how long', caseSensitive: false).hasMatch(q);
          if (!safety || aboutConditions || state.lastAsk == QaAskStep.safety) {
            // 场地/器械由代码问；模型自己追问一律打回，让它直接作答。
            issues.add('拦下模型追问：$q');
            messages
              ..add(LlmMessage.assistant(res.content, toolCalls: [call], reasoning: res.reasoning))
              ..add(LlmMessage.tool(call.id, '不要追问。条件已在状态里，直接 respond 或 build_plan。'));
            continue;
          }
          final opts = asStringList(args['options']);
          final gate = AskUserGate.check(
            jsonEncode({'question': q, if (opts.length >= 2) ...{'mode': 'choice', 'options': opts.take(6).toList()} else 'mode': 'text'}),
            language: lang,
          );
          return CoachQaReply(
            kind: 'ask',
            text: q,
            question: gate.question,
            askStep: QaAskStep.safety,
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

  /// 器械不够：用户点名的部位在当前器械下一个主练动作都没有时，如实说，并给最接近的做法或该加什么器械。
  String? _gap(QaIntent eff, String lang) {
    final s = state.scene ?? profile.defaultScene;
    if (s == 'gym' || eff.muscles.isEmpty) return null;
    final en = lang == 'en';
    final q = _query(eff);
    final names = en ? muscleEn : muscleZh;
    final have = en ? _equipLabel('en') : _equipLabel('zh');
    final out = <String>[];
    for (final m in eff.muscles) {
      if (index.all.any((a) => a.primaryMuscles.contains(m) && finder.passes(a, q))) continue;
      final closest = index.all.where((a) => a.secondaryMuscles.contains(m) && finder.passes(a, q)).firstOrNull;
      String? unlock;
      QaAction? unlockAction;
      if (s == 'office') return null;
      for (final e in const ['dumbbell', 'band', 'mat', 'chair']) {
        if (state.equipment.contains(e)) continue;
        final q2 = queryFromIntent(_copyIntent(eff)..avoidJoints.addAll(state.avoidJoints), scene: s, equipment: {...state.equipment, e}, strict: _strict);
        final a = index.all.where((a) => a.primaryMuscles.contains(m) && finder.passes(a, q2)).firstOrNull;
        if (a != null) {
          unlock = e;
          unlockAction = a;
          break;
        }
      }
      final mz = names[m] ?? m;
      if (en) {
        out.add('No move in the library trains $mz with $have.'
            '${closest != null ? ' Closest: ${closest.name(lang)} (works $mz as a helper).' : ''}'
            '${unlock != null ? ' Add ${_equipNameEn[unlock]} and you can do ${unlockAction!.name(lang)}.' : ''}');
      } else {
        out.add('动作库里没有用$have主练$mz的动作。'
            '${closest != null ? '最接近的是「${closest.name(lang)}」（$mz辅助发力）。' : ''}'
            '${unlock != null ? '加${const {'dumbbell': '一对', 'band': '一根', 'mat': '一张', 'chair': '一把'}[unlock] ?? ''}${_equipNameZh[unlock]}就能做「${unlockAction!.name(lang)}」。' : ''}');
      }
    }
    return out.isEmpty ? null : out.join(en ? ' ' : '');
  }

  /// 计划里去掉了越界动作时，正文补一句，免得文字还在说它。
  static String _withDropped(String text, List<String> notes, String lang) {
    final names = [for (final n in notes) if (n.endsWith('超出当前范围/限制，已去掉')) n.replaceAll(' 超出当前范围/限制，已去掉', '')];
    if (names.isEmpty) return text;
    return lang == 'en'
        ? '$text (Removed ${names.join(', ')}: outside your setup.)'
        : '$text（${names.map((n) => '「$n」').join('、')}超出你选的范围，已从计划里去掉。）';
  }

  static String _withGap(String text, String? gap) {
    if (gap == null) return text;
    final hasIt = RegExp(r'没有|没法|不能|无法|缺|no move|not in the library|missing', caseSensitive: false).hasMatch(text);
    return hasIt ? text : '$text${text.isEmpty ? '' : (RegExp(r'[。.!！?？]$').hasMatch(text) ? '' : '。')}$gap';
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
    List<String> issues, {
    QaQuery? range,
    List<QaHit> hits = const [],
    bool wantCards = false,
  }) {
    final ids = <String>[];
    final why = <String, String>{};
    final noJumpClaim = RegExp(r'不跳|无跳跃|不用跳|没有跳|no jump').hasMatch(text);
    for (final (id, w) in items) {
      final a = index[id];
      if (a == null) {
        issues.add('丢弃未知动作 $id');
        continue;
      }
      // 圈定的范围和禁忌是硬边界：模型从历史里拿来的越界动作也去掉。
      if (range != null && !finder.passes(a, range.withExclude(const {}))) {
        issues.add('去掉越界动作 $id');
        continue;
      }
      if (noJumpClaim && RegExp(r'跳|jump|jack', caseSensitive: false).hasMatch(a.name('zh'))) {
        issues.add('去掉和「不跳」矛盾的 $id');
        continue;
      }
      if (ids.contains(id) || ids.length >= 5) continue;
      ids.add(id);
      if (w.trim().isNotEmpty) why[id] = w.trim();
    }
    // 推荐类却没给卡：按正文里点到的动作名补卡，没有就补前 3 个候选。
    if (ids.isEmpty && wantCards && hits.isNotEmpty) {
      final named = [for (final h in hits) if (text.contains(h.action.name(lang))) h.action.id];
      ids.addAll((named.isNotEmpty ? named : [for (final h in hits.take(3)) h.action.id]).take(5));
      issues.add('模型没给动作卡，代码按正文补卡');
    }
    if (ids.isNotEmpty) {
      state.lastPlan = null;
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
    var s = t.trim().replaceAll(RegExp(r'\s*\[(动作卡|展示动作|计划)[：:][^\]]*\]'), '');
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
    if (r.cards.isNotEmpty) b.write('\n[展示动作] ${[for (var k = 0; k < r.cards.length; k++) '${k + 1}.${r.cards[k].name}'].join(' ')}');
    if (r.plan != null) {
      final ids = [for (final bl in r.plan!.blocks) for (final i in bl.items) i.exerciseId];
      b.write('\n[计划] ${r.plan!.title}：${[for (var k = 0; k < ids.length; k++) '${k + 1}.${index[ids[k]]?.name(lang) ?? ids[k]}'].join(' ')}');
    }
    return b.toString();
  }
}
