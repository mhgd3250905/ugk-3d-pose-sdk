/// 读 JSON 的小工具：类型宽容（num→int、缺省值），不抛 TypeError。
library;

typedef JsonMap = Map<String, Object?>;

JsonMap asMap(Object? v) =>
    v is Map ? v.map((k, val) => MapEntry('$k', val)) : <String, Object?>{};

List<Object?> asList(Object? v) => v is List ? List<Object?>.from(v) : const [];

String? asString(Object? v) => v is String ? v : null;

int? asInt(Object? v) => v is num && v == v.roundToDouble() ? v.toInt() : null;

double? asDouble(Object? v) => v is num ? v.toDouble() : null;

bool? asBool(Object? v) => v is bool ? v : null;

List<String> asStringList(Object? v) => [
  for (final e in asList(v))
    if (e is String) e,
];

/// 多语言文本：`{"zh": "…", "en": "…"}`，也接受单个字符串（当作 zh）。
class LocalizedText {
  const LocalizedText(this.values);
  final Map<String, String> values;

  factory LocalizedText.fromJson(Object? v) {
    if (v is String) return LocalizedText({'zh': v});
    return LocalizedText({
      for (final e in asMap(v).entries)
        if (e.value is String) e.key: e.value! as String,
    });
  }

  /// 指定语言，没有就退到 zh，再退到任意一个。
  String of([String lang = 'zh']) =>
      values[lang] ?? values['zh'] ?? (values.isEmpty ? '' : values.values.first);

  Object toJson() => values;

  @override
  String toString() => of();
}
