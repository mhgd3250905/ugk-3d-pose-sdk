import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

var _seq = 0;
LlmToolCall _call(String name, Object args) => LlmToolCall(
  id: 'ask${_seq++}',
  name: name,
  arguments: args is String ? args : jsonEncode(args),
);
LlmResponse _tools(List<LlmToolCall> calls) => LlmResponse(
  content: '',
  toolCalls: calls,
  reasoning: 'tool response',
  finishReason: 'tool_calls',
  model: 'fake',
);
LlmResponse _ask(Object args) => _tools([_call(AgentTools.askUser, args)]);
Map<String, Object?> _text([String value = '准备花多久？']) => {
  'question': value,
  'mode': 'text',
};
Map<String, Object?> _choice({bool? multiple}) => {
  'question': '哪里最紧？',
  'mode': 'choice',
  'options': ['肩颈', '髋屈肌', '大腿后侧'],
  'multiple': ?multiple,
};
Map<String, Object?> _plan() => planOf(okEnvelope())..remove('source');
LlmResponse _showPlan() => _tools([_call(AgentTools.showPlan, _plan())]);
LlmResponse _showActions() => _tools([
  _call(AgentTools.showActions, {
    'items': [
      {'actionId': 's-figure4'},
    ],
  }),
]);

/// Every model batch is followed by one acknowledgement per tool call.
void _expectToolProtocol(List<LlmMessage> messages) {
  final pending = <String>{};
  for (final message in messages) {
    if (message.role == LlmRole.assistant) {
      expect(pending, isEmpty, reason: 'Previous tool batch is incomplete');
      pending.addAll(message.toolCalls.map((call) => call.id));
    } else if (message.role == LlmRole.tool) {
      expect(pending.remove(message.toolCallId), isTrue);
    }
  }
  expect(pending, isEmpty);
}

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');
  CoachAgent agent(
    FakeLlmClient client, {
    bool memory = false,
    UserMemoryStore? store,
    UsageSink? usage,
    SessionFallback? fallback,
  }) {
    final value = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: memory,
      memoryStore: store,
      usage: usage,
      fallback: fallback,
      maxRequestRetries: 0,
    );
    addTearDown(value.dispose);
    return value;
  }

  group('AskUserGate validated legacy payloads', () {
    test('text question is valid and does not invent options', () {
      final result = AskUserGate.check(jsonEncode(_text()));
      expect(result.ok, isTrue);
      expect(result.question!.mode, AskUserMode.text);
      expect(result.question!.options, isEmpty);
      expect(result.question!.multiple, isFalse);
    });
    for (final multiple in [null, false, true]) {
      test('choice allows multiple=$multiple', () {
        final result = AskUserGate.check(
          jsonEncode(_choice(multiple: multiple)),
        );
        expect(result.ok, isTrue);
        expect(result.question!.options, ['肩颈', '髋屈肌', '大腿后侧']);
        expect(result.question!.multiple, multiple ?? false);
      });
    }
    for (final length in [2, 6]) {
      test('choice accepts $length options and 12 Unicode code points', () {
        final result = AskUserGate.check(
          jsonEncode({
            'question': '选哪个？',
            'mode': 'choice',
            'options': ['😀' * 12, for (var i = 1; i < length; i++) '选项$i'],
          }),
        );
        expect(result.ok, isTrue);
        expect(result.question!.options, hasLength(length));
        expect(result.question!.options.first.runes, hasLength(12));
      });
    }
  });

  group('unsafe ask_user input and repair', () {
    final badArguments = <String, Object>{
      'malformed JSON': '{',
      'non-object JSON': '[]',
      'missing question': {'mode': 'text'},
      'empty question': {'question': '  ', 'mode': 'text'},
      'non-string question': {'question': 3, 'mode': 'text'},
      'missing mode': {'question': '多久？'},
      'unknown mode': {'question': '多久？', 'mode': 'other'},
      'non-string mode': {'question': '多久？', 'mode': true},
      'extra field': {..._text(), 'extra': true},
      'text options': {..._text(), 'options': <String>[]},
      'text multiple': {..._text(), 'multiple': false},
      'missing choice options': {'question': '哪里紧？', 'mode': 'choice'},
      'non-list options': {..._choice(), 'options': '肩颈、髋屈肌'},
      'one option': {
        ..._choice(),
        'options': ['肩颈'],
      },
      'seven options': {
        ..._choice(),
        'options': ['一', '二', '三', '四', '五', '六', '七'],
      },
      'non-string option': {
        ..._choice(),
        'options': ['肩颈', 3],
      },
      'empty option': {
        ..._choice(),
        'options': ['肩颈', '  '],
      },
      'duplicate options': {
        ..._choice(),
        'options': ['肩颈', '肩颈'],
      },
      '13-character option': {
        ..._choice(),
        'options': ['肩颈', '一' * 13],
      },
      'non-bool multiple': {..._choice(), 'multiple': 'true'},
      'null multiple': {..._choice(), 'multiple': null},
    };
    for (final entry in badArguments.entries) {
      test(
        '${entry.key}: gate rejects and Agent repairs to a safe answer',
        () async {
          final raw = entry.value is String
              ? entry.value as String
              : jsonEncode(entry.value);
          final gate = AskUserGate.check(raw);
          expect(gate.ok, isFalse);
          expect(gate.errors, isNotEmpty);
          final client = FakeLlmClient([_ask(entry.value), '可以慢慢练习。']);
          final coach = agent(client);
          final events = <AgentEvent>[];
          coach.events.listen(events.add);
          final result = await coach.send('请讲解这个动作');
          expect(result.status, TurnStatus.ok);
          expect(result.question, isNull);
          expect(result.plan, isNull);
          expect(result.text, '可以慢慢练习。');
          expect(result.records.first.outcome, CallOutcome.rejected);
          expect(client.requests, hasLength(2));
          final feedback = client.requests.last.messages.last;
          expect(feedback.role, LlmRole.tool);
          expect((jsonDecode(feedback.content) as Map)['ok'], false);
          expect(coach.questionsAsked, 0);
          expect(
            events.where((event) => event.kind == AgentEventKind.askUser),
            isEmpty,
          );
          _expectToolProtocol(client.requests.last.messages);
        },
      );
    }
    test('valid model ask is rejected for a non-planning request', () async {
      final client = FakeLlmClient([_ask(_text()), '这动作注意缓慢呼吸。']);
      final coach = agent(client);
      final result = await coach.send('请讲解这个动作');
      expect(result.status, TurnStatus.ok);
      expect(result.question, isNull);
      expect(result.plan, isNull);
      expect(result.records.first.outcome, CallOutcome.rejected);
      expect(
        client.requests.last.messages.last.content,
        contains('clarification_not_requested'),
      );
      _expectToolProtocol(client.requests.last.messages);
    });
    for (final show in [AgentTools.showPlan, AgentTools.showActions]) {
      for (final askFirst in [true, false]) {
        test(
          'ask and $show in one response are rejected (askFirst=$askFirst)',
          () async {
            final question = _call(AgentTools.askUser, _text());
            final delivery = show == AgentTools.showPlan
                ? _call(show, _plan())
                : _call(show, {
                    'items': [
                      {'actionId': 's-figure4'},
                    ],
                  });
            final client = FakeLlmClient([
              _tools(askFirst ? [question, delivery] : [delivery, question]),
              '可以慢慢练习。',
            ]);
            final coach = agent(client);
            final events = <AgentEvent>[];
            coach.events.listen(events.add);
            final result = await coach.send('请讲解这个动作');
            expect(result.status, TurnStatus.ok);
            expect(result.plan, isNull);
            expect(result.actions, isNull);
            expect(result.question, isNull);
            expect(result.records.first.outcome, CallOutcome.rejected);
            expect(coach.questionsAsked, 0);
            expect(
              events.where((event) => event.kind == AgentEventKind.askUser),
              isEmpty,
            );
            _expectToolProtocol(client.requests.last.messages);
          },
        );
      }
    }
    test('two asks in the same response are both rejected', () async {
      final client = FakeLlmClient([
        _tools([
          _call(AgentTools.askUser, _text()),
          _call(AgentTools.askUser, _choice()),
        ]),
        '可以慢慢练习。',
      ]);
      final coach = agent(client);
      final result = await coach.send('请讲解这个动作');
      expect(result.status, TurnStatus.ok);
      expect(result.question, isNull);
      expect(result.records.first.outcome, CallOutcome.rejected);
      expect(coach.questionsAsked, 0);
      _expectToolProtocol(client.requests.last.messages);
    });
    test('invalid show can be repaired without inventing a question', () async {
      final client = FakeLlmClient([
        _tools([_call(AgentTools.showPlan, <String, Object?>{})]),
        '可以慢慢练习。',
      ]);
      final result = await agent(client).send('请讲解这个动作');
      expect(result.status, TurnStatus.ok);
      expect(result.plan, isNull);
      expect(result.question, isNull);
      expect(result.records.first.outcome, CallOutcome.rejected);
      _expectToolProtocol(client.requests.last.messages);
    });
    for (final sideTool in [AgentTools.read, AgentTools.remember]) {
      test(
        'ask with $sideTool rejects whole batch before side effects',
        () async {
          final store = InMemoryUserMemoryStore();
          final side = sideTool == AgentTools.read
              ? _call(sideTool, {'path': 'action-library/SKILL.md'})
              : _call(sideTool, {'kind': 'goal', 'text': '想劈叉'});
          final client = FakeLlmClient([
            _tools([side, _call(AgentTools.askUser, _text())]),
            '可以慢慢练习。',
          ]);
          final coach = agent(client, memory: true, store: store);
          final events = <AgentEvent>[];
          coach.events.listen(events.add);
          final result = await coach.send('请讲解这个动作');
          expect(result.status, TurnStatus.ok);
          expect(result.question, isNull);
          expect(result.records.first.outcome, CallOutcome.rejected);
          expect(result.reads, isEmpty);
          expect(store.entries, isEmpty);
          expect(
            events.where(
              (e) =>
                  e.kind == AgentEventKind.reading ||
                  e.kind == AgentEventKind.memory,
            ),
            isEmpty,
          );
          expect(coach.questionsAsked, 0);
          _expectToolProtocol(client.requests.last.messages);
        },
      );
    }
    test(
      'malformed ask exhaustion emits no question and preserves budget',
      () async {
        final client = FakeLlmClient([
          for (var i = 0; i < 3; i++) _ask({'mode': 'text'}),
        ]);
        final coach = agent(
          client,
          fallback: (_) => const SessionFallbackReply('请稍后再试'),
        );
        final events = <AgentEvent>[];
        coach.events.listen(events.add);
        final result = await coach.send('请讲解这个动作');
        expect(result.status, TurnStatus.fallback);
        expect(result.question, isNull);
        expect(coach.questionsAsked, 0);
        expect(
          events.where((event) => event.kind == AgentEventKind.askUser),
          isEmpty,
        );
        expect(
          result.records.every(
            (record) => record.outcome == CallOutcome.rejected,
          ),
          isTrue,
        );
      },
    );
  });

  group('real local confirmation and task budget', () {
    const answer = {
      'scene': ['家里'],
      'equipment': ['瑜伽垫'],
      'minutes': ['10 分钟'],
    };
    test(
      'confirmation is local, has three groups, then no second ask is allowed',
      () async {
        final client = FakeLlmClient([_ask(_text()), _showPlan()]);
        final coach = agent(client);
        final events = <AgentEvent>[];
        coach.events.listen(events.add);
        final first = await coach.send('帮我排个髋部训练计划');
        expect(first.status, TurnStatus.ok);
        expect(first.question!.isConfirmation, isTrue);
        expect(first.question!.mode, AskUserMode.form);
        expect(first.question!.fields.map((field) => field.key).toSet(), {
          'scene',
          'equipment',
          'minutes',
        });
        expect(first.plan, isNull);
        expect(first.steps, 0);
        expect(client.requests, isEmpty);
        expect(coach.questionsAsked, 1);
        expect(events.map((event) => event.kind), [
          AgentEventKind.askUser,
          AgentEventKind.done,
        ]);
        expect(events.first.question, same(first.question));
        final result = await coach.send('家里，有瑜伽垫，10 分钟', confirmedForm: answer);
        expect(result.status, TurnStatus.ok);
        expect(result.question, isNull);
        expect(result.plan, isNotNull);
        expect(result.records.first.outcome, CallOutcome.rejected);
        expect(
          client.requests.last.messages.last.content,
          contains('ask_limit'),
        );
        expect(coach.questionsAsked, 0);
        _expectToolProtocol(client.requests.last.messages);
        final next = await coach.send('再做一组肩颈放松');
        expect(next.question?.isConfirmation, isTrue);
        expect(coach.questionsAsked, 1);
      },
    );
    test(
      'known conditions reject model ask and repair to valid plan',
      () async {
        final client = FakeLlmClient([_ask(_choice()), _showPlan()]);
        final coach = agent(client);
        final result = await coach.send('在家有瑜伽垫，10分钟排个训练计划');
        expect(result.status, TurnStatus.ok);
        expect(result.question, isNull);
        expect(result.plan, isNotNull);
        expect(result.records.first.outcome, CallOutcome.rejected);
        expect(
          client.requests.last.messages.last.content,
          contains('ask_not_needed'),
        );
        expect(coach.questionsAsked, 0);
        _expectToolProtocol(client.requests.last.messages);
      },
    );
    test('successful action delivery clears a pending task budget', () async {
      final coach = agent(FakeLlmClient([_showActions()]));
      final first = await coach.send('帮我排个训练组');
      expect(first.question?.isConfirmation, isTrue);
      expect(coach.questionsAsked, 1);
      final result = await coach.send('看看动作');
      expect(result.question, isNull);
      expect(result.actions, isNotNull);
      expect(coach.questionsAsked, 0);
    });
    test('planning failure cannot silently admit a fallback plan', () async {
      var fallbackCalls = 0;
      final coach = agent(
        FakeLlmClient([const LlmException(LlmErrorKind.auth, 'bad key')]),
        fallback: (_) {
          fallbackCalls++;
          return SessionFallbackReply(
            '默认计划',
            plan: const PlanCodec().decode(_plan()),
          );
        },
      );
      final first = await coach.send('帮我排个训练组');
      expect(first.question?.isConfirmation, isTrue);
      final result = await coach.send('家里，有瑜伽垫，10 分钟', confirmedForm: answer);
      expect(result.status, TurnStatus.error);
      expect(result.plan, isNull);
      expect(result.question, isNull);
      expect(fallbackCalls, 0);
    });
    test(
      'reset clears the card and history; a new task can ask once again',
      () async {
        final client = FakeLlmClient([]);
        final coach = agent(client);
        final first = await coach.send('帮我排个训练组');
        expect(first.question, isNotNull);
        expect(coach.questionsAsked, 1);
        coach.reset();
        expect(coach.questionsAsked, 0);
        expect(coach.history, isEmpty);
        expect(coach.turnCount, 0);
        final next = await coach.send('再做一个训练组');
        expect(next.question?.isConfirmation, isTrue);
        expect(coach.questionsAsked, 1);
        expect(client.requests, isEmpty);
      },
    );
  });

  group('local confirmation cancellation boundaries', () {
    for (final how in ['cancel', 'reset']) {
      test(
        '$how in the synchronous confirmation listener cannot commit stale state',
        () async {
          final token = CancelToken();
          final client = FakeLlmClient([]);
          final coach = agent(client);
          final events = <AgentEvent>[];
          coach.events.listen((event) {
            events.add(event);
            if (event.kind == AgentEventKind.askUser) {
              how == 'cancel' ? token.cancel() : coach.reset();
            }
          });
          final result = await coach.send('帮我排个训练组', cancel: token);
          expect(result.status, TurnStatus.cancelled);
          expect(result.question, isNull);
          expect(result.text, isEmpty);
          expect(coach.questionsAsked, 0);
          expect(coach.history, isEmpty);
          expect(coach.turnCount, 0);
          expect(client.requests, isEmpty);
          expect(
            events.where((event) => event.kind == AgentEventKind.done),
            isEmpty,
          );
        },
      );
    }
    test(
      'cancel while the confirmed model response is in flight preserves prior card',
      () async {
        final entered = Completer<void>();
        final release = Completer<Object>();
        final token = CancelToken();
        final client = FakeLlmClient([
          (_) {
            entered.complete();
            return release.future;
          },
        ]);
        final coach = agent(client);
        final first = await coach.send('帮我排个训练组');
        expect(first.question?.isConfirmation, isTrue);
        final historyBefore = List<LlmMessage>.of(coach.history);
        final pending = coach.send(
          '家里，有瑜伽垫，10 分钟',
          cancel: token,
          confirmedForm: const {
            'scene': ['家里'],
            'equipment': ['瑜伽垫'],
            'minutes': ['10 分钟'],
          },
        );
        await entered.future;
        token.cancel();
        final result = await pending.timeout(const Duration(seconds: 1));
        release.complete(_showPlan());
        expect(result.status, TurnStatus.cancelled);
        expect(result.plan, isNull);
        expect(coach.questionsAsked, 1);
        expect(coach.history, historyBefore);
        expect(coach.turnCount, 1);
      },
    );
  });
}
