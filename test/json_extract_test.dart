import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

void main() {
  group('extractJsonObject 容错', () {
    test('纯 JSON', () {
      final r = extractJsonObject('{"kind":"reply","text":"好"}');
      expect(r.value, {'kind': 'reply', 'text': '好'});
      expect(r.repairs, isEmpty);
    });
    test('markdown 围栏', () {
      final r = extractJsonObject('好的：\n```json\n{"a":1}\n```\n希望有帮助');
      expect(r.value, {'a': 1});
      expect(r.repairs, contains('fence'));
    });
    test('无语言标记的围栏', () => expect(extractJsonObject('```\n{"a":1}\n```').value, {'a': 1}));
    test('前后说明文字', () {
      final r = extractJsonObject('下面是计划 {"a":{"b":[1,2]}} 祝训练愉快');
      expect(r.value, {'a': {'b': [1, 2]}});
      expect(r.repairs, contains('prose'));
    });
    test('<think> 段', () {
      final r = extractJsonObject('<think>先想想 {不是json}</think>{"a":1}');
      expect(r.value, {'a': 1});
      expect(r.repairs, contains('think'));
    });
    test('BOM', () => expect(extractJsonObject('\uFEFF{"a":1}').repairs, contains('bom')));
    test('字符串里的花括号与转义引号', () {
      final r = extractJsonObject(r'{"text":"他说 \"{别管}\" 然后}","n":2}');
      expect(r.value!['n'], 2);
      expect(r.value!['text'], '他说 "{别管}" 然后}');
    });
    test('末尾多余逗号', () {
      final r = extractJsonObject('{"a":[1,2,],"b":{"c":3,},}');
      expect(r.value, {'a': [1, 2], 'b': {'c': 3}});
      expect(r.repairs, contains('trailing_comma'));
    });
    test('字符串里的「,}」不被改', () {
      final r = extractJsonObject('{"t":"a,}","x":[1,]}');
      expect(r.value!['t'], 'a,}');
    });
    test('被截断', () {
      final r = extractJsonObject('{"kind":"plan","plan":{"blocks":[');
      expect(r.ok, isFalse);
      expect(r.error, contains('截断'));
    });
    test('没有对象', () => expect(extractJsonObject('好的，给你排一个计划').ok, isFalse));
    test('语法错误', () => expect(extractJsonObject('{"a": nope}').ok, isFalse));
  });
}
