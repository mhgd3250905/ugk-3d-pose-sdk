import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach/ugk_coach_qa_v2.dart' as qa;

/// Only conversation facts are stored here; catalogues, tags and clients belong
/// to the host configuration and are never copied into chat history.
Map<String, Object?> encodeQaState(qa.CoachQaState state) => {
  'version': 1,
  'place': state.place,
  'placeWord': state.placeWord,
  'placeSource': state.placeSource,
  'placeTurn': state.placeTurn,
  'equipmentKnown': state.equipmentKnown,
  'equipment': state.equipment.toList(),
  'equipmentSource': state.equipmentSource,
  'equipmentTurn': state.equipmentTurn,
  'avoidJoints': state.avoidJoints.toList(),
  'noFloor': state.noFloor,
  'quiet': state.quiet,
  'easy': state.easy,
  'smallSpace': state.smallSpace,
  'language': state.language,
  'focus': _focus(state.focus),
  'pendingFocus': _focus(state.pendingFocus),
  'pendingText': state.pendingText,
  'lastShown': [...state.lastShown],
  'lastWhy': {...state.lastWhy},
  'lastPlan': state.lastPlan?.plan.toJson(),
  'lastPlanSeconds': state.lastPlan?.seconds,
  'lastAsk': state.lastAsk?.name,
  'turn': state.turn,
  'history': [
    for (final (user, assistant) in state.history) [user, assistant],
  ],
  // v3 追加：用户已确认的安全危险信号（旧存档没有时为 false）。
  'redFlag': state.redFlag,
};

Map<String, Object?>? _focus(qa.QaFocus? focus) => focus == null
    ? null
    : {
        'muscles': focus.muscles.toList(),
        'stretch_muscles': focus.stretchMuscles.toList(),
        'types': focus.types.toList(),
        'goals': focus.goals.toList(),
        'roles': focus.roles.toList(),
        'patterns': focus.patterns.toList(),
        'minutes': focus.minutes,
        'intent': focus.intent,
      };

void restoreQaState(
  qa.CoachQaState state,
  Map<String, Object?> json, {
  required Set<String> allowedIds,
}) {
  if (json['version'] != 1) throw const FormatException('Unknown QA state');
  final shown = _strings(json['lastShown']).toList();
  coach.TrainingPlan? plan;
  if (json['lastPlan'] != null) {
    final decoded = const coach.PlanCodec().decodeStrict(json['lastPlan']);
    if (!decoded.ok) throw const FormatException('Invalid QA plan');
    plan = decoded.plan;
  }
  if (!allowedIds.containsAll(shown) ||
      (plan != null && !allowedIds.containsAll(plan.exerciseIds))) {
    throw const FormatException('QA history is outside the action scope');
  }
  state
    ..place = json['place'] as String?
    ..placeWord = json['placeWord'] as String?
    ..placeSource = json['placeSource'] as String? ?? 'none'
    ..placeTurn = (json['placeTurn'] as num?)?.toInt() ?? -1
    ..equipmentKnown = json['equipmentKnown'] == true
    ..equipment = _strings(json['equipment'])
    ..equipmentSource = json['equipmentSource'] as String? ?? 'none'
    ..equipmentTurn = (json['equipmentTurn'] as num?)?.toInt() ?? -1
    ..avoidJoints = _strings(json['avoidJoints'])
    ..noFloor = json['noFloor'] == true
    ..quiet = json['quiet'] == true
    ..easy = json['easy'] == true
    ..smallSpace = json['smallSpace'] == true
    ..language = json['language'] as String? ?? 'zh'
    ..focus = _readFocus(json['focus'])
    ..pendingFocus = _readFocus(json['pendingFocus'])
    ..pendingText = json['pendingText'] as String?
    ..lastShown = shown
    ..lastWhy = {
      for (final entry in (json['lastWhy'] as Map? ?? const {}).entries)
        entry.key as String: entry.value as String,
    }
    ..lastPlan = plan == null
        ? null
        : qa.QaPlanResult(
            plan,
            (json['lastPlanSeconds'] as num?)?.toInt() ?? 0,
            const [],
          )
    ..lastAsk = json['lastAsk'] == null
        ? null
        : qa.QaAskStep.values.byName(json['lastAsk']! as String)
    ..turn = (json['turn'] as num?)?.toInt() ?? 0
    ..redFlag = json['redFlag'] == true;
  state.history
    ..clear()
    ..addAll([
      for (final row in (json['history'] as List? ?? const []))
        ((row as List)[0] as String, row[1] as String),
    ]);
}

Set<String> _strings(Object? value) =>
    (value as List? ?? const []).cast<String>().toSet();

qa.QaFocus? _readFocus(Object? value) => value is Map
    ? qa.QaFocus.of(qa.QaForm(Map<String, Object?>.from(value)))
    : null;
