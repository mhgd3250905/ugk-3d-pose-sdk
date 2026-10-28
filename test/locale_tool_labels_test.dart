import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

Map<String, Object?> _form({
  String label = 'What equipment is available to you',
  List<String> options = const ['A chair and a wall', 'No extra equipment'],
}) => {
  'question': 'Which equipment can you use?',
  'mode': 'form',
  'fields': [
    {'key': 'equipment', 'label': label, 'options': options, 'multiple': true},
  ],
};

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');

  test(
    'localized dimension labels resolve source hyphens and encoded aliases',
    () {
      final tags = ActionTags(profile, catalog);
      expect(tags.localizedLabel('body.hip_flexors', 'zh'), '髋屈肌');
      expect(tags.localizedLabel('body.inner_thigh', 'zh'), '内收肌群');
      expect(tags.localizedLabel('equip.chair', 'zh'), '椅子/凳子');
    },
  );

  test('requested catalogue translation wins, including regional locale', () {
    final data = deepCopy(catalog.raw);
    final taxonomy = data['taxonomy'] as Map;
    (taxonomy['muscleGroups'] as Map)['hip-flexors'] = {
      'zh': '髋屈肌',
      'en': 'Hip flexors',
    };
    (taxonomy['equipment'] as Map)['chair'] = {'zh': '椅子', 'en': 'Chair'};
    final tags = ActionTags(profile, Catalog.fromJson(data));
    expect(tags.localizedLabel('body.hip_flexors', 'en'), 'Hip flexors');
    expect(tags.localizedLabel('body.hip_flexors', 'en-US'), 'Hip flexors');
    expect(tags.localizedLabel('equip.chair', 'en'), 'Chair');
  });

  test(
    'missing English translation uses readable words, never a tool code',
    () {
      final tags = ActionTags(profile, catalog);
      expect(tags.localizedLabel('body.hip_flexors', 'en'), 'hip flexors');
      expect(tags.localizedLabel('equip.chair', 'en'), 'chair');
      expect(
        tags.localizedLabel('body.missing_translation', 'en'),
        'missing translation',
      );
      for (final code in [
        'body.hip_flexors',
        'equip.chair',
        'body.missing_translation',
      ]) {
        final label = tags.localizedLabel(code, 'en');
        expect(label, isNot(contains('.')));
        expect(label, isNot(contains('_')));
      }
    },
  );

  test('English form label allows six words, even when over 20 characters', () {
    final raw = jsonEncode(_form());
    final result = AskUserGate.check(raw, language: 'en');
    expect(result.ok, isTrue);
    expect(
      result.question!.fields.single.label,
      'What equipment is available to you',
    );
    expect(result.question!.skipLabel, 'Show suggestions');
    expect(result.question!.toJson()['skipLabel'], 'Show suggestions');
    expect(AskUserGate.check(raw).ok, isFalse);
    expect(
      AskUserGate.check(
        jsonEncode(_form(label: 'What equipment is available to you today')),
        language: 'en',
      ).ok,
      isFalse,
    );
  });

  test(
    'English choice and form options count words instead of code points',
    () {
      final choice = {
        'question': 'Which option?',
        'mode': 'choice',
        'options': [List.filled(12, 'word').join(' '), 'Something else'],
      };
      expect(
        AskUserGate.check(jsonEncode(choice), language: 'en-GB').ok,
        isTrue,
      );
      expect(
        AskUserGate.check(
          jsonEncode({
            ...choice,
            'options': [List.filled(13, 'word').join(' '), 'Other'],
          }),
          language: 'en',
        ).ok,
        isFalse,
      );
      final form = _form(options: [List.filled(24, 'word').join(' '), 'Other']);
      expect(AskUserGate.check(jsonEncode(form), language: 'en').ok, isTrue);
      expect(
        AskUserGate.check(
          jsonEncode(
            _form(options: [List.filled(25, 'word').join(' '), 'Other']),
          ),
          language: 'en',
        ).ok,
        isFalse,
      );
    },
  );

  test('Chinese label and option boundaries remain unchanged', () {
    final form = _form(label: '字' * 20, options: ['字' * 24, '另一个']);
    expect(AskUserGate.check(jsonEncode(form)).ok, isTrue);
    expect(
      AskUserGate.check(
        jsonEncode(_form(label: '字' * 21, options: ['一', '二'])),
      ).ok,
      isFalse,
    );
    expect(
      AskUserGate.check(
        jsonEncode(_form(label: '器械', options: ['字' * 25, '二'])),
      ).ok,
      isFalse,
    );
    final choice = {
      'question': '选哪个？',
      'mode': 'choice',
      'options': ['字' * 12, '另一个'],
    };
    expect(AskUserGate.check(jsonEncode(choice)).ok, isTrue);
    expect(
      AskUserGate.check(
        jsonEncode({
          ...choice,
          'options': ['字' * 13, '二'],
        }),
      ).ok,
      isFalse,
    );
  });

  test(
    'the real agent passes host locale through to the clarification gate',
    () async {
      final client = FakeLlmClient([
        LlmResponse(
          content: '',
          toolCalls: [
            LlmToolCall(
              id: 'english-ask',
              name: AgentTools.askUser,
              arguments: jsonEncode(_form()),
            ),
          ],
        ),
      ]);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
      );
      addTearDown(agent.dispose);
      final result = await agent.send(
        'Help me stretch',
        context: const CoachContext(language: 'en'),
      );
      expect(result.status, TurnStatus.ok);
      expect(
        result.question?.fields.single.label,
        'What equipment is available to you',
      );
      expect(result.question?.skipLabel, 'Show suggestions');
      expect(client.requests, hasLength(1));
    },
  );
}
