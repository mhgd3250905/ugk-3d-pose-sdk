/// 中文口语 → 结构化检索条件（代码里的同义词典）。
/// 只做确定的映射：场景、器械、避开的部位/冲击/躺地、目标肌群和目的。
library;

/// 一次检索需要的条件。字段全可空：空 = 不限制。
final class QaIntent {
  QaIntent();

  String? scene;
  final Set<String> equipment = {};
  bool onlyEquipment = false;
  bool bodyweightOnly = false;
  final Set<String> muscles = {};
  final Set<String> stretchMuscles = {};
  final Set<String> types = {};
  final Set<String> goals = {};
  final Set<String> roles = {};
  final List<String> keywords = [];
  final Set<String> avoidJoints = {};
  bool noFloor = false;
  String? maxImpact;
  bool easy = false;
  bool lowIntensity = false;
  int? maxDifficulty;
  int? minutes;
  bool wantsPlan = false;
  bool safetyFlag = false;
  bool knowledge = false;

  /// 用户这句是否点了具体练什么（部位/目的/关键词）。
  bool get hasFocus => muscles.isNotEmpty || stretchMuscles.isNotEmpty || types.isNotEmpty || keywords.isNotEmpty;

  Map<String, Object?> toJson() => {
    if (scene != null) 'scene': scene,
    if (equipment.isNotEmpty) 'equipment': equipment.toList(),
    if (muscles.isNotEmpty) 'muscles': muscles.toList(),
    if (stretchMuscles.isNotEmpty) 'stretchMuscles': stretchMuscles.toList(),
    if (types.isNotEmpty) 'types': types.toList(),
    if (goals.isNotEmpty) 'goals': goals.toList(),
    if (roles.isNotEmpty) 'roles': roles.toList(),
    if (keywords.isNotEmpty) 'keywords': keywords,
    if (avoidJoints.isNotEmpty) 'avoidJoints': avoidJoints.toList(),
    if (noFloor) 'noFloor': true,
    if (maxImpact != null) 'maxImpact': maxImpact,
    if (easy) 'easy': true,
    if (minutes != null) 'minutes': minutes,
    if (wantsPlan) 'wantsPlan': true,
    if (safetyFlag) 'safety': true,
  };
}

const _stretch = {'static-stretch', 'dynamic-stretch', 'mobility'};

class _Rule {
  const _Rule(
    this.triggers, {
    this.muscles = const {},
    this.stretch = const {},
    this.types = const {},
    this.goals = const {},
    this.roles = const {},
    this.keywords = const [],
    this.avoid = const {},
    this.noFloor = false,
    this.quiet = false,
    this.easy = false,
    this.lowIntensity = false,
    this.knowledge = false,
  });
  final List<String> triggers;
  final Set<String> muscles;
  final Set<String> stretch;
  final Set<String> types;
  final Set<String> goals;
  final Set<String> roles;
  final List<String> keywords;
  final Set<String> avoid;
  final bool noFloor;
  final bool quiet;
  final bool easy;
  final bool lowIntensity;
  final bool knowledge;
}

/// 口语同义词典。先匹配的长词不影响后面的规则：所有命中的规则叠加。
const List<_Rule> _rules = [
  // 目的
  _Rule(['瘦肚子', '小肚子', '肚腩', '减肚子', '游泳圈', 'belly fat'], types: {'cardio'}, muscles: {'abs', 'obliques'}, goals: {'fat-loss'}),
  _Rule(['燃脂', '减脂', '减肥', '瘦身', '出汗', '有氧', 'fat', 'cardio', 'burn'], types: {'cardio'}, goals: {'fat-loss'}),
  _Rule(['腹肌', '腹部', '马甲线', '练腹', 'abs'], muscles: {'abs', 'obliques'}, types: {'strength', 'stability-control'}),
  _Rule(['核心', 'core'], muscles: {'abs', 'obliques', 'erectors'}, types: {'strength', 'stability-control'}),
  _Rule(['侧腰', '腹斜'], muscles: {'obliques'}),
  _Rule(['翘臀', '臀部', '屁股', '蜜桃臀', '练臀', '臀', 'glute'], muscles: {'glute-max', 'hip-abductors'}, types: {'strength'}),
  _Rule(['大腿内侧', '内收'], muscles: {'adductors'}),
  _Rule(['大腿后侧', '腘绳'], muscles: {'hamstrings'}),
  _Rule(['大腿前侧', '股四头'], muscles: {'quadriceps'}),
  _Rule(['小腿'], muscles: {'calves'}),
  _Rule(['练腿', '腿部', '下肢', '大腿', 'legs', 'leg day'], muscles: {'quadriceps', 'hamstrings', 'glute-max'}, types: {'strength'}),
  _Rule(['练背', '背部', '后背', '背肌', 'back'], muscles: {'lats', 'scapular', 'erectors'}, types: {'strength'}),
  _Rule(['练胸', '胸肌', '胸部', 'chest'], muscles: {'chest'}, types: {'strength'}),
  _Rule(['练肩', '肩部', '三角肌', 'shoulders'], muscles: {'deltoids'}),
  _Rule(['手臂', '胳膊', '麒麟臂', '拜拜肉', 'arms'], muscles: {'biceps', 'triceps'}, types: {'strength'}),
  _Rule(['二头'], muscles: {'biceps'}),
  _Rule(['三头'], muscles: {'triceps'}),
  _Rule(['全身', 'full body'], goals: {'strength'}, types: {'strength'}),
  _Rule(['体态', '圆肩', '驼背', '含胸', '富贵包'], goals: {'posture'}, muscles: {'scapular'}, stretch: {'chest'}),
  // 放松 / 拉伸
  _Rule(['拉伸', '放松', '舒展', '松一松', '伸展', 'stretch', 'relax'], types: _stretch),
  _Rule(['腰酸', '腰好酸', '腰背酸', '下背酸', '腰僵'], types: _stretch, stretch: {'erectors', 'hip-flexors', 'glute-max'}, goals: {'desk-relief'}),
  _Rule(['坐了一天', '久坐', '坐太久', '一直坐'], goals: {'desk-relief'}, stretch: {'hip-flexors', 'erectors'}),
  _Rule(['肩颈', '脖子'], types: _stretch, stretch: {'upper-traps', 'neck'}),
  _Rule(['睡前', '助眠', '睡不着', '睡得好', '失眠'], types: {'static-stretch', 'breathing'}, stretch: {'erectors', 'glute-max', 'hamstrings', 'hip-flexors', 'upper-traps'}, goals: {'recovery'}, roles: {'cooldown'}, lowIntensity: true),
  _Rule(['跑完', '跑后', '跑步后', '刚跑'], types: {'static-stretch'}, stretch: {'quadriceps', 'hamstrings', 'calves', 'glute-max', 'hip-flexors'}, roles: {'cooldown'}, goals: {'recovery'}),
  _Rule(['晨', '早上', '起床', 'morning'], types: {'mobility', 'dynamic-stretch'}, stretch: {'erectors', 'hip-flexors', 'scapular', 'hamstrings', 'chest'}, roles: {'warmup'}),
  _Rule(['热身', 'warm up', 'warmup'], roles: {'warmup'}, types: {'mobility', 'dynamic-stretch'}),
  // 具体动作词（关键词检索 + 目标肌群）
  _Rule(['俯卧撑', 'push-up', 'pushup'], keywords: ['俯卧撑'], muscles: {'chest', 'triceps'}),
  _Rule(['平板', 'plank'], keywords: ['平板'], muscles: {'abs'}, knowledge: true),
  _Rule(['深蹲', 'squat'], keywords: ['深蹲'], muscles: {'quadriceps', 'glute-max'}),
  _Rule(['臀桥', '臀推'], keywords: ['臀桥'], muscles: {'glute-max'}),
  _Rule(['弓步'], keywords: ['弓步'], muscles: {'quadriceps', 'glute-max'}),
  _Rule(['划船'], keywords: ['划船'], muscles: {'lats', 'scapular'}),
  // 疼痛 / 避开
  _Rule(['膝盖疼', '膝盖痛', '膝盖不好', '膝盖不舒服', '膝痛', '护膝', 'knee pain'], avoid: {'knee'}, knowledge: true),
  _Rule(['肩膀痛', '肩膀疼', '肩痛', '肩疼', '肩膀前面有点痛', '肩前', '肩膀不舒服', 'shoulder pain'], avoid: {'shoulder'}, knowledge: true),
  _Rule(['腰疼', '腰痛', '腰伤', '腰椎', '腰间盘'], avoid: {'lumbar'}, knowledge: true),
  _Rule(['手腕疼', '手腕痛', '腕痛'], avoid: {'wrist'}),
  _Rule(['不躺', '不用躺', '不想躺', '不能躺', '不趴', '西裤', '穿裙子', '穿着裙子', '正装'], noFloor: true),
  _Rule(['不能吵', '楼下', '安静', '不跳', '静音', '别太吵', '邻居', 'quiet'], quiet: true),
  // 难度
  _Rule(['新手', '入门', '零基础', '小白', '做不起', '做不了', '简单', '太难', '初学', 'beginner', 'easy'], easy: true),
  // 知识题信号
  _Rule(['多久', '多少', '正常吗', '为什么', '怎么办', '还能', '能不能', '可以吗', '合适', '怎么安排'], knowledge: true),
];

const _sceneWords = <String, List<String>>{
  'office': ['办公室', '公司', '工位', '上班', '单位', 'office', 'desk'],
  'hotel': ['酒店', '宾馆', '民宿', 'hotel'],
  'gym': ['健身房', 'gym'],
  'outdoor': ['户外', '公园', '操场', '小区', 'outdoor', 'park'],
  'home': ['在家', '家里', '居家', '客厅', '卧室', '床上', '床边', 'at home'],
};

const _equipWords = <String, List<String>>{
  'dumbbell': ['哑铃', 'dumbbell'],
  'band': ['弹力带', '弹力绳', '阻力带', 'band'],
  'kettlebell': ['壶铃', 'kettlebell'],
  'pullup-bar': ['单杠', '引体向上杆', 'pull-up bar'],
  'mat': ['垫子', '瑜伽垫', 'mat'],
  'chair': ['椅子', '凳子', 'chair'],
  'foam-roller': ['泡沫轴'],
  'barbell': ['杠铃'],
  'bench': ['卧推凳', '训练凳'],
};

const _safetyWords = ['剧痛', '刺痛', '肿', '麻木', '发麻', '放射', '扭伤', '受伤', '手术', '怀孕', '孕期', '产后', '骨折', '胸闷', '头晕'];

/// 解析一句话。只认确定的词，认不出的交给模型。
QaIntent parseIntent(String text) {
  final t = text.toLowerCase();
  final i = QaIntent();
  for (final r in _rules) {
    if (!r.triggers.any(t.contains)) continue;
    i.muscles.addAll(r.muscles);
    i.stretchMuscles.addAll(r.stretch);
    i.types.addAll(r.types);
    i.goals.addAll(r.goals);
    i.roles.addAll(r.roles);
    for (final k in r.keywords) {
      if (!i.keywords.contains(k)) i.keywords.add(k);
    }
    i.avoidJoints.addAll(r.avoid);
    if (r.noFloor) i.noFloor = true;
    if (r.quiet) i.maxImpact = 'low';
    if (r.easy) i.easy = true;
    if (r.lowIntensity) i.lowIntensity = true;
    if (r.knowledge) i.knowledge = true;
  }
  // 「腰酸」是放松诉求，不当伤病避开；「腰疼」才避开腰。
  const joints = {'膝': 'knee', '肩': 'shoulder', '腰': 'lumbar', '腕': 'wrist', '颈': 'neck', '脖子': 'neck', '踝': 'ankle', '髋': 'hip'};
  for (final e in joints.entries) {
    if (RegExp('${e.key}[^，。,.？?！!]{0,6}(疼|痛|伤|不舒服)').hasMatch(t)) {
      i.avoidJoints.add(e.value);
      i.knowledge = true;
    }
  }
  for (final e in _sceneWords.entries) {
    if (e.value.any(t.contains)) {
      i.scene = e.key;
      break;
    }
  }
  if (i.scene == null && (t.contains('家') && !t.contains('大家'))) i.scene = 'home';
  for (final e in _equipWords.entries) {
    if (e.value.any(t.contains)) i.equipment.add(e.key);
  }
  if (i.equipment.isNotEmpty && RegExp(r'只有|只带|就一|仅有|only').hasMatch(t)) i.onlyEquipment = true;
  if (RegExp(r'徒手|没器械|没有器械|不用器械|bodyweight').hasMatch(t)) i.bodyweightOnly = true;
  final m = RegExp(r'(\d+)\s*(分钟|min)').firstMatch(t);
  if (m != null) i.minutes = int.tryParse(m.group(1)!);
  if (RegExp(r'一套|安排|计划|排成|排一|来一组|课表|一节|routine|session|workout').hasMatch(t) || i.minutes != null) {
    i.wantsPlan = true;
  }
  if (_safetyWords.any(t.contains)) i.safetyFlag = true;
  // 办公室里要拉伸：默认针对久坐紧的部位。
  if (i.scene == 'office' && i.types.contains('static-stretch') && i.stretchMuscles.isEmpty) {
    i.stretchMuscles.addAll(const {'hip-flexors', 'chest', 'upper-traps', 'erectors', 'hamstrings'});
    i.goals.add('desk-relief');
  }
  // 「瘦肚子」不是腹肌力量专项：有氧优先，核心为辅。
  return i;
}

/// 跟进句类型（代码处理，不调模型）。
enum QaFollowUp { none, replace, easier, harder, useThese }

final class QaFollowUpMatch {
  const QaFollowUpMatch(this.kind, {this.index, this.minutes});
  final QaFollowUp kind;

  /// 0 起；replace 用。
  final int? index;
  final int? minutes;
}

const _cnNum = {'一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, '十': 10};

QaFollowUpMatch detectFollowUp(String text) {
  final t = text.toLowerCase();
  final idx = RegExp(r'第\s*([0-9一二两三四五六七八九十])\s*个').firstMatch(t);
  if (idx != null && RegExp(r'换|不喜欢|替|不想|删').hasMatch(t)) {
    final g = idx.group(1)!;
    final n = int.tryParse(g) ?? _cnNum[g] ?? 1;
    return QaFollowUpMatch(QaFollowUp.replace, index: n - 1);
  }
  final m = RegExp(r'(\d+)\s*分钟').firstMatch(t);
  final minutes = m == null ? null : int.tryParse(m.group(1)!);
  if (RegExp(r'就用这|用这几个|就这几个|这几个动作|这些动作|就用上面|排成\d+分钟$|^排成').hasMatch(t)) {
    return QaFollowUpMatch(QaFollowUp.useThese, minutes: minutes);
  }
  if (RegExp(r'太难|难了|简单点|简单一点|容易点|做不动|换简单|easier|too hard').hasMatch(t)) {
    return const QaFollowUpMatch(QaFollowUp.easier);
  }
  if (RegExp(r'太简单|难一点|加点难度|更难|harder|too easy').hasMatch(t)) {
    return const QaFollowUpMatch(QaFollowUp.harder);
  }
  return const QaFollowUpMatch(QaFollowUp.none);
}
