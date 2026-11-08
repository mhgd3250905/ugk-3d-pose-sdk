import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

Map<String, dynamic> _line(String id, Map<String, String> text) => {
  'id': id,
  'text': text,
  'ms': {for (final l in text.keys) l: 500},
};

DrillPackVoiceSource _source({bool englishNouns = true}) =>
    DrillPackVoiceSource.fromPacks(
      common: {
        'id': '_common',
        'voice': {
          'lines': [
            _line('p.di', {'zh': '第', 'en': 'Number'}),
            _line('n.3', {'zh': '三', 'en': 'three'}),
            _line('u.sets', {'zh': '组', 'en': 'sets'}),
            _line('u.rounds', {'zh': '轮', 'en': 'rounds'}),
            if (englishNouns) ...[
              _line('p.set', {'en': 'Set'}),
              _line('p.round', {'en': 'Round'}),
            ],
          ],
        },
      },
    );

String _say(VoiceSource s, List<String> keys, String lang) =>
    keys.map((k) => s.line(k, lang: lang)).join(' ');

void main() {
  test('Chinese ordinal keeps 第 N 组 / 第 N 轮', () {
    final s = _source();
    expect(s.ordinalSet(3), ['p.di', 'n.3', 'u.sets']);
    expect(_say(s, s.ordinalSet(3, lang: 'zh'), 'zh'), '第 三 组');
    expect(_say(s, s.ordinalRound(3, lang: 'zh'), 'zh'), '第 三 轮');
  });

  test('English ordinal says "Set three", never "Number three sets"', () {
    final s = _source();
    expect(s.ordinalSet(3, lang: 'en'), ['p.set', 'n.3']);
    expect(_say(s, s.ordinalSet(3, lang: 'en'), 'en'), 'Set three');
    expect(_say(s, s.ordinalRound(3, lang: 'en'), 'en'), 'Round three');
    expect(s.ordinalSet(3, lang: 'en'), isNot(contains('p.di')));
    // A total count stays "three sets".
    expect(_say(s, s.setsPhrase(3), 'en'), 'three sets');
  });

  test('English without its Set clip is not whole, so it stays silent', () {
    final s = _source(englishNouns: false);
    final keys = s.ordinalSet(3, lang: 'en');
    expect(keys.every((k) => s.has(k, lang: 'en')), isFalse);
    final script = SessionScript(source: s, lang: 'en');
    expect(script.whole(keys), isFalse);
  });

  test('out-of-range numbers give no phrase', () {
    final s = _source();
    expect(s.ordinalSet(0, lang: 'en'), isEmpty);
    expect(s.ordinalRound(61), isEmpty);
  });
}
