/// 用户记忆：只存用户主动提供的训练相关信息。存储由 App 实现 [UserMemoryStore]（本地文件 / 偏好设置 / 服务端），
/// SDK 负责去重、每类条数与总长度上限、生成进系统提示词的摘要。
library;

import '../util/json.dart';

enum MemoryKind { injury, goal, level, equipment, scene, schedule, body, preference, other }

class MemoryEntry {
  const MemoryEntry(this.kind, this.text, {required this.at});
  final MemoryKind kind;
  final String text;
  final DateTime at;

  static MemoryEntry? tryParse(Object? raw) {
    final j = asMap(raw);
    final kind = MemoryKind.values.where((k) => k.name == j['kind']).firstOrNull;
    final text = asString(j['text']);
    if (kind == null || text == null || text.trim().isEmpty) return null;
    return MemoryEntry(kind, text.trim(), at: DateTime.tryParse(asString(j['at']) ?? '') ?? DateTime.utc(1970));
  }

  Map<String, Object?> toJson() => {'kind': kind.name, 'text': text, 'at': at.toUtc().toIso8601String()};
}

/// App 实现：读 / 写一个用户的全部记忆（整表覆盖）。
abstract interface class UserMemoryStore {
  Future<List<MemoryEntry>> load();
  Future<void> save(List<MemoryEntry> entries);
}

class InMemoryUserMemoryStore implements UserMemoryStore {
  InMemoryUserMemoryStore([List<MemoryEntry> initial = const []]) : _entries = List.of(initial);
  List<MemoryEntry> _entries;
  List<MemoryEntry> get entries => List.unmodifiable(_entries);

  @override
  Future<List<MemoryEntry>> load() async => List.of(_entries);

  @override
  Future<void> save(List<MemoryEntry> entries) async => _entries = List.of(entries);
}

/// 记忆上限。
class MemoryLimits {
  const MemoryLimits({this.perKind = 5, this.maxTotalChars = 800, this.maxEntryChars = 60});
  final int perKind;
  final int maxTotalChars;
  final int maxEntryChars;
}

/// 纯函数式的记忆整理：去重、截断、限额。
abstract final class UserMemoryOps {
  static String _norm(String s) => s.replaceAll(RegExp(r'[\s，。,.!！？?、；;：:]'), '').toLowerCase();

  /// 记一条：同类里与已有条目相同或互相包含的视为同一件事，用新说法替换；超出每类条数丢最旧的；超出总长丢全表最旧的。
  static List<MemoryEntry> remember(List<MemoryEntry> list, MemoryEntry e, MemoryLimits lim) {
    var text = e.text.trim();
    if (text.isEmpty) return list;
    if (text.length > lim.maxEntryChars) text = text.substring(0, lim.maxEntryChars);
    final n = _norm(text);
    final out = [
      for (final x in list)
        if (!(x.kind == e.kind && (_norm(x.text) == n || _norm(x.text).contains(n) || n.contains(_norm(x.text))))) x,
      MemoryEntry(e.kind, text, at: e.at),
    ];
    final ofKind = [
      for (final x in out)
        if (x.kind == e.kind) x,
    ];
    while (ofKind.length > lim.perKind) {
      out.remove(ofKind.removeAt(0));
    }
    while (out.length > 1 && out.fold(0, (s, x) => s + x.text.length) > lim.maxTotalChars) {
      out.removeAt(0);
    }
    return out;
  }

  /// 忘掉：给 [text] 时删同类（或任意类，[kind] 为 null）里与它相同或互相包含的条目；只给 [kind] 删整类。
  static List<MemoryEntry> forget(List<MemoryEntry> list, {MemoryKind? kind, String? text}) {
    final t = text == null || text.trim().isEmpty ? null : _norm(text);
    if (t == null && kind == null) return list;
    return [
      for (final x in list)
        if (!((kind == null || x.kind == kind) &&
            (t == null || _norm(x.text) == t || _norm(x.text).contains(t) || t.contains(_norm(x.text)))))
          x,
    ];
  }

  /// 进系统提示词的摘要：按类一行。
  static String summary(List<MemoryEntry> list) {
    final byKind = <MemoryKind, List<String>>{};
    for (final x in list) {
      (byKind[x.kind] ??= []).add(x.text);
    }
    return [
      for (final k in MemoryKind.values)
        if (byKind[k] != null) '- ${k.name}：${byKind[k]!.join('；')}',
    ].join('\n');
  }
}
