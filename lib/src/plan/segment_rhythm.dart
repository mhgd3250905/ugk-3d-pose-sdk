/// Structural checks shared by the codec and validator. Keep this pure Dart:
/// rhythm execution belongs to ugk_trainer.
Map<String, String> segmentRhythmErrors(Map<String, dynamic> rhythm) {
  final errors = <String, String>{};
  const kinds = {'rep_updown', 'rep_cycle', 'rep_alternate', 'rep_hold', 'rep_breath', 'hold'};
  if (!kinds.contains(rhythm['kind'])) {
    errors['.kind'] = rhythm['kind'] == 'self_paced'
        ? 'self_paced 只能由动作目录显式标记，计划分段不得启用'
        : '未知 rhythm kind';
  }
  bool finiteNonnegative(Object? n) => n is num && n.isFinite && n >= 0;
  for (final key in ['leadSeconds', 'holdSeconds', 'reps']) {
    if (!rhythm.containsKey(key)) continue;
    final n = rhythm[key];
    if (!finiteNonnegative(n) || (key != 'leadSeconds' && (n == 0 || (n as num) != n.roundToDouble()))) {
      errors['.$key'] = '$key 必须是有效${key == 'leadSeconds' ? '非负秒数' : '正整数'}';
    }
  }
  final phases = rhythm['phases'];
  if (phases != null && phases is! List) errors['.phases'] = 'phases 必须是数组';
  if (phases is List) {
    final ids = <String>{};
    for (var i = 0; i < phases.length; i++) {
      final p = phases[i];
      final path = '.phases[$i]';
      if (p is! Map) {
        errors[path] = '节奏阶段必须是对象';
        continue;
      }
      final id = p['id'];
      if (id is! String || id.trim().isEmpty || !ids.add(id)) {
        errors['$path.id'] = '阶段 id 必须非空且唯一';
      }
      final seconds = p['seconds'];
      if (!finiteNonnegative(seconds) || seconds == 0) {
        errors['$path.seconds'] = '阶段 seconds 必须是有限正数';
      }
      if (p.containsKey('cueAt') &&
          (!finiteNonnegative(p['cueAt']) || (seconds is num && p['cueAt'] is num && (p['cueAt'] as num) > seconds))) {
        errors['$path.cueAt'] = 'cueAt 必须位于本阶段内';
      }
      final cue = p['cue'];
      if (cue != null && cue is! String && !(cue is List && cue.every((x) => x is String))) {
        errors['$path.cue'] = 'cue 必须是字符串或字符串数组';
      }
    }
  }
  return errors;
}
