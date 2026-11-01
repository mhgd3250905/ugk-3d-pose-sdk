// Ported from HipLab@99fcc83 lib/hip/domain/action_kit.dart
// (ActionKind, KitPhase, RepPlan; unchanged semantics). Pure Dart.

/// How an action is paced (action-kit v1 `training.kind`).
enum ActionKind {
  /// 计数·双相起落: count + "go" word, "back" word at the return.
  repUpdown('rep_updown'),

  /// 计数·正反循环: one count = one loop in both directions.
  repCycle('rep_cycle'),

  /// 计数·左右交替: each count is one side; the go word rotates.
  repAlternate('rep_alternate'),

  /// 计数·带停留: a rep with a timed hold at the top.
  repHold('rep_hold'),

  /// 呼吸配合: exhale / inhale phases.
  repBreath('rep_breath'),

  /// 保持计时.
  hold('hold');

  const ActionKind(this.id);
  final String id;
  bool get counted => this != hold;
  static ActionKind byId(String id) =>
      values.firstWhere((k) => k.id == id, orElse: () => hold);
  static ActionKind? tryId(Object? id) =>
      values.where((k) => k.id == id).firstOrNull;
}

/// One phase of a rep: go / hold / back / rest.
class KitPhase {
  const KitPhase(this.id, this.seconds, this.cues, {this.cueAt = 0});
  final String id;
  final double seconds;

  /// How far into the phase its word is said (a hold word waits a beat so
  /// the count before it has room).
  final double cueAt;

  /// Word clip(s) said when the phase starts; several rotate with the count
  /// (右/左, 开门/关门). Empty: silent phase. Keys of the app's voice source.
  final List<String> cues;

  String? cueFor(int count) =>
      cues.isEmpty ? null : cues[(count - 1) % cues.length];

  KitPhase withSeconds(double s) => KitPhase(id, s, cues, cueAt: cueAt);

  factory KitPhase.fromJson(Map<String, dynamic> j) {
    final c = j['cue'];
    return KitPhase(
      j['id'] as String,
      (j['seconds'] as num).toDouble(),
      c == null
          ? const []
          : c is List
          ? [for (final x in c) x as String]
          : [c as String],
      cueAt: (j['cueAt'] as num? ?? 0).toDouble(),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'seconds': seconds,
    if (cues.length == 1) 'cue': cues.single,
    if (cues.length > 1) 'cue': cues,
    if (cueAt != 0) 'cueAt': cueAt,
  };
}

/// When each rep of one set starts and each of its phases begins.
class RepPlan {
  const RepPlan({
    required this.lead,
    required this.reps,
    required this.sets,
    required this.phases,
  });

  /// Seconds before the first count of each set ("开始" / "再来一组").
  final double lead;
  final int reps;
  final int sets;
  final List<KitPhase> phases;

  double get cycle => phases.fold(0.0, (s, p) => s + p.seconds);
  double get setSeconds => lead + reps * cycle;
  double get seconds => sets * setSeconds;

  /// Start of rep [k] (1-based) of set [set] (0-based).
  double repStart(int set, int k) => set * setSeconds + lead + (k - 1) * cycle;
}
