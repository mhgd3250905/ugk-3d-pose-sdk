/// 比较版本字符串：按数字段逐段比较（`1.2.10` > `1.2.9`，
/// `2026.10.19-2` > `2026.10.19-1`）。非数字段按字典序。
int compareVersions(String a, String b) {
  final pa = RegExp(r'\d+|[A-Za-z]+').allMatches(a).map((m) => m[0]!).toList();
  final pb = RegExp(r'\d+|[A-Za-z]+').allMatches(b).map((m) => m[0]!).toList();
  for (var i = 0; i < pa.length || i < pb.length; i++) {
    if (i >= pa.length) return -1;
    if (i >= pb.length) return 1;
    final na = int.tryParse(pa[i]), nb = int.tryParse(pb[i]);
    final c = (na != null && nb != null) ? na.compareTo(nb) : pa[i].compareTo(pb[i]);
    if (c != 0) return c.sign;
  }
  return 0;
}
