/// 可注入的时钟与 id 生成，测试里换成固定值。
typedef Clock = DateTime Function();

DateTime systemClock() => DateTime.now();

/// 单调递增的短 id：`<prefix>-<毫秒>-<序号>`。
class IdGenerator {
  IdGenerator({this.clock = systemClock});
  final Clock clock;
  int _seq = 0;
  String next(String prefix) =>
      '$prefix-${clock().millisecondsSinceEpoch}-${(_seq++).toRadixString(36)}';
}
