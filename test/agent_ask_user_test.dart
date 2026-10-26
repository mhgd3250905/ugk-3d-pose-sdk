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

LlmResponse _tools(List<LlmToolCall> calls, {String? reasoning}) => LlmResponse(
  content: '',
  toolCalls: calls,
  reasoning: reasoning,
  finishReason: 'tool_calls',
  model: 'fake',
);

Map<String, Object?> _textQuestion([String question = '准备花多久？']) => {
  'question': question,
  'mode': 'text',
};

Map<String, Object?> _choiceQuestion({bool? multiple}) => {
  'question': '哪里最紧？',
  'mode': 'choice',
  'options': ['肩颈', '髋屈肌', '大腿后侧'],
  'multiple': ?multiple,
};

LlmResponse _ask(Object args, {String? reasoning}) =>
    _tools([_call(AgentTools.askUser, args)], reasoning: reasoning);

Map<String, Object?> _plan() => planOf(okEnvelope())..remove('source');

LlmResponse _showPlan() => _tools([_call(AgentTools.showPlan, _plan())]);

LlmResponse _showActions() => _tools([
  _call(AgentTools.showActions, {
    'items': [
      {'actionId': 's-figure4'},
    ],
  }),
]);

/// Every assistant tool batch must have exactly one acknowledgement per call.
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

  group('ask_user delivery', () {
    test(
      'text question ends this send immediately and publishes ask before done',
      () async {
        final client = FakeLlmClient([
          _ask(_textQuestion()),
          'This must wait for another send.',
        ]);
        final coach = agent(client);
        final events = <AgentEvent>[];
        coach.events.listen(events.add);

        final result = await coach.send('请澄清这个动作');

        expect(result.status, TurnStatus.ok);
        expect(result.text, '准备花多久？');
        expect(result.question, isA<AskUserQuestion>());
        expect(result.question!.question, result.text);
        expect(result.question!.mode, AskUserMode.text);
        expect(result.question!.options, isEmpty);
        expect(result.question!.multiple, isFalse);
        expect(result.plan, isNull);
        expect(result.actions, isNull);
        expect(result.reads, isEmpty);
        expect(result.steps, 1);
        expect(client.requests, hasLength(1));
        expect(client.remaining, 1);
        expect(coach.isBusy, isFalse);
        expect(coach.questionsAsked, 1);
        expect(events.map((event) => event.kind), [
          AgentEventKind.thinking,
          AgentEventKind.askUser,
          AgentEventKind.done,
        ]);
        final ask = events.singleWhere(
          (event) => event.kind == AgentEventKind.askUser,
        );
        expect(ask.turnId, result.turnId);
        expect(ask.question, same(result.question));
        expect(events.last.status, TurnStatus.ok);
      },
    );

    for (final multiple in [null, false, true]) {
      test(
        'choice exposes options and multiple=$multiple to the App',
        () async {
          final coach = agent(
            FakeLlmClient([_ask(_choiceQuestion(multiple: multiple))]),
          );

          final result = await coach.send('练习前想放松');

          expect(result.status, TurnStatus.ok);
          expect(result.question!.mode, AskUserMode.choice);
          expect(result.question!.options, ['肩颈', '髋屈肌', '大腿后侧']);
          expect(result.question!.multiple, multiple ?? false);
          expect(coach.questionsAsked, 1);
        },
      );
    }

    for (final answer in ['肩颈、髋屈肌', '我想重点放松手腕，别按选项来']) {
      test(
        'answer "$answer" resumes the same conversation as user text',
        () async {
          final client = FakeLlmClient([
            _ask(
              _choiceQuestion(multiple: true),
              reasoning: 'Need the tight areas first.',
            ),
            _showPlan(),
          ]);
          final coach = agent(client);

          await coach.send('练习前想放松');
          final result = await coach.send(answer);

          expect(result.status, TurnStatus.ok);
          expect(result.plan, isNotNull);
          expect(result.question, isNull);
          expect(client.requests, hasLength(2));
          final messages = client.requests.last.messages;
          expect(messages.last.role, LlmRole.user);
          expect(messages.last.content, answer);
          final priorAsk = messages.singleWhere(
            (message) => message.toolCalls.any(
              (call) => call.name == AgentTools.askUser,
            ),
          );
          expect(priorAsk.reasoning, 'Need the tight areas first.');
          final ack = messages.singleWhere(
            (message) =>
                message.role == LlmRole.tool &&
                message.toolCallId == priorAsk.toolCalls.single.id,
          );
          expect(ack.content, isNotEmpty);
          _expectToolProtocol(messages);
          expect(coach.questionsAsked, 0);
        },
      );
    }

    test(
      'the one question and combined answer survive until final plan',
      () async {
        final client = FakeLlmClient([
          _ask(_textQuestion('还有什么特别要求？')),
          _showPlan(),
        ]);
        final coach = agent(client);

        await coach.send('我明天练托马斯，先了解动作');
        final result = await coach.send('在家，有瑜伽垫，10 分钟，肩颈、髋屈肌');

        expect(result.status, TurnStatus.ok);
        expect(result.plan, isNotNull);
        expect(
          client.requests.last.messages
              .where((message) => message.role == LlmRole.user)
              .map((message) => message.content.split('\n').last),
          ['我明天练托马斯，先了解动作', '在家，有瑜伽垫，10 分钟，肩颈、髋屈肌'],
        );
        expect(
          client.requests.last.messages
              .expand((message) => message.toolCalls)
              .where((call) => call.name == AgentTools.askUser),
          hasLength(1),
        );
        _expectToolProtocol(client.requests.last.messages);
        expect(coach.questionsAsked, 0);
      },
    );
  });

  group('ask_user validation and repair', () {
    final badArguments = <String, Object>{
      'malformed JSON': '{',
      'non-object JSON': '[]',
      'missing question': {'mode': 'text'},
      'empty question': {'question': '  ', 'mode': 'text'},
      'non-string question': {'question': 3, 'mode': 'text'},
      'missing mode': {'question': '多久？'},
      'unknown mode': {'question': '多久？', 'mode': 'other'},
      'non-string mode': {'question': '多久？', 'mode': true},
      'extra field': {..._textQuestion(), 'extra': true},
      'text options': {..._textQuestion(), 'options': <String>[]},
      'text multiple': {..._textQuestion(), 'multiple': false},
      'missing choice options': {'question': '哪里紧？', 'mode': 'choice'},
      'non-list options': {..._choiceQuestion(), 'options': '肩颈、髋屈肌'},
      'one option': {
        ..._choiceQuestion(),
        'options': ['肩颈'],
      },
      'seven options': {
        ..._choiceQuestion(),
        'options': ['一', '二', '三', '四', '五', '六', '七'],
      },
      'non-string option': {
        ..._choiceQuestion(),
        'options': ['肩颈', 3],
      },
      'empty option': {
        ..._choiceQuestion(),
        'options': ['肩颈', '  '],
      },
      'duplicate options': {
        ..._choiceQuestion(),
        'options': ['肩颈', '肩颈'],
      },
      '13-character option': {
        ..._choiceQuestion(),
        'options': ['肩颈', '一' * 13],
      },
      'non-bool multiple': {..._choiceQuestion(), 'multiple': 'true'},
      'null multiple': {..._choiceQuestion(), 'multiple': null},
    };

    for (final entry in badArguments.entries) {
      test(
        '${entry.key} is returned to the model, then a repaired question passes',
        () async {
          final client = FakeLlmClient([
            _ask(entry.value),
            _ask(_textQuestion()),
          ]);
          final coach = agent(client);
          final events = <AgentEvent>[];
          coach.events.listen(events.add);

          final result = await coach.send('请澄清这个动作');

          expect(result.status, TurnStatus.ok);
          expect(result.question!.question, '准备花多久？');
          expect(client.requests, hasLength(2));
          expect(result.records.first.outcome, CallOutcome.rejected);
          final feedback = client.requests.last.messages.last;
          expect(feedback.role, LlmRole.tool);
          expect((jsonDecode(feedback.content) as Map)['ok'], false);
          expect(coach.questionsAsked, 1);
          expect(
            events.where((event) => event.kind == AgentEventKind.askUser),
            hasLength(1),
          );
          _expectToolProtocol(client.requests.last.messages);
        },
      );
    }

    for (final length in [2, 6]) {
      test(
        'choice accepts $length options and 12 Unicode code points',
        () async {
          final coach = agent(
            FakeLlmClient([
              _ask({
                'question': '选哪个？',
                'mode': 'choice',
                'options': ['😀' * 12, for (var i = 1; i < length; i++) '选项$i'],
              }),
            ]),
          );

          final result = await coach.send('请澄清这个动作');

          expect(result.status, TurnStatus.ok);
          expect(result.question!.options, hasLength(length));
          expect(result.question!.options.first.runes, hasLength(12));
        },
      );
    }

    test(
      'rejected question never emits an event or consumes the task budget',
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

        final result = await coach.send('请澄清这个动作');

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

    for (final show in [AgentTools.showPlan, AgentTools.showActions]) {
      for (final askFirst in [true, false]) {
        test(
          'ask and $show in one response are rejected (askFirst=$askFirst)',
          () async {
            final question = _call(AgentTools.askUser, _textQuestion());
            final delivery = show == AgentTools.showPlan
                ? _call(show, _plan())
                : _call(show, {
                    'items': [
                      {'actionId': 's-figure4'},
                    ],
                  });
            final client = FakeLlmClient([
              _tools(askFirst ? [question, delivery] : [delivery, question]),
              _ask(_textQuestion()),
            ]);
            final coach = agent(client);
            final events = <AgentEvent>[];
            coach.events.listen(events.add);

            final result = await coach.send('请澄清这个动作');

            expect(result.status, TurnStatus.ok);
            expect(result.plan, isNull);
            expect(result.actions, isNull);
            expect(result.question, isNotNull);
            expect(result.records.first.outcome, CallOutcome.rejected);
            expect(client.requests, hasLength(2));
            expect(coach.questionsAsked, 1);
            expect(
              events.where((event) => event.kind == AgentEventKind.askUser),
              hasLength(1),
            );
            _expectToolProtocol(client.requests.last.messages);
          },
        );
      }
    }

    test(
      'two questions in one response are both rejected before a corrected single ask',
      () async {
        final client = FakeLlmClient([
          _tools([
            _call(AgentTools.askUser, _textQuestion()),
            _call(AgentTools.askUser, _choiceQuestion()),
          ]),
          _ask(_textQuestion()),
        ]);
        final coach = agent(client);
        final events = <AgentEvent>[];
        coach.events.listen(events.add);

        final result = await coach.send('请澄清这个动作');

        expect(result.status, TurnStatus.ok);
        expect(result.records.first.outcome, CallOutcome.rejected);
        expect(coach.questionsAsked, 1);
        expect(
          events.where((event) => event.kind == AgentEventKind.askUser),
          hasLength(1),
        );
        _expectToolProtocol(client.requests.last.messages);
      },
    );

    test('invalid show can be repaired to a single question', () async {
      final client = FakeLlmClient([
        _tools([_call(AgentTools.showPlan, <String, Object?>{})]),
        _ask(_textQuestion()),
      ]);
      final coach = agent(client);

      final result = await coach.send('请澄清这个动作');

      expect(result.status, TurnStatus.ok);
      expect(result.question, isNotNull);
      expect(client.requests, hasLength(2));
      expect(coach.questionsAsked, 1);
    });

    for (final sideTool in [AgentTools.read, AgentTools.remember]) {
      test(
        'ask combined with $sideTool is rejected before reads or memory writes',
        () async {
          final store = InMemoryUserMemoryStore();
          final side = sideTool == AgentTools.read
              ? _call(sideTool, {'path': 'action-library/SKILL.md'})
              : _call(sideTool, {'kind': 'goal', 'text': '想劈叉'});
          final client = FakeLlmClient([
            _tools([side, _call(AgentTools.askUser, _textQuestion())]),
            _ask(_textQuestion()),
          ]);
          final coach = agent(client, memory: true, store: store);
          final events = <AgentEvent>[];
          coach.events.listen(events.add);

          final result = await coach.send('请澄清这个动作');

          expect(result.status, TurnStatus.ok);
          expect(result.records.first.outcome, CallOutcome.rejected);
          expect(result.reads, isEmpty);
          expect(store.entries, isEmpty);
          expect(
            events.where(
              (event) =>
                  event.kind == AgentEventKind.reading ||
                  event.kind == AgentEventKind.memory,
            ),
            isEmpty,
          );
          expect(coach.questionsAsked, 1);
          _expectToolProtocol(client.requests.last.messages);
        },
      );
    }
  });

  group('ask_user task budget', () {
    test(
      'one question is allowed; second is repaired to plan and starts a new task',
      () async {
        final client = FakeLlmClient([
          for (var i = 0; i < 2; i++) _ask(_textQuestion('问题$i？')),
          _showPlan(),
          _ask(_textQuestion('新任务多久？')),
        ]);
        final coach = agent(client);
        expect(CoachAgent.maxQuestionsPerTask, 1);

        for (var i = 0; i < 1; i++) {
          expect((await coach.send('回答$i')).question, isNotNull);
          expect(coach.questionsAsked, i + 1);
        }
        final result = await coach.send('最后一个回答');

        expect(result.status, TurnStatus.ok);
        expect(result.plan, isNotNull);
        expect(result.question, isNull);
        expect(result.records.first.outcome, CallOutcome.rejected);
        final feedback = client.requests[2].messages.last.content;
        expect((jsonDecode(feedback) as Map)['ok'], false);
        expect(feedback, contains('show_plan'));
        expect(coach.questionsAsked, 0);
        expect((await coach.send('下一个动作问题')).question!.question, '新任务多久？');
        expect(coach.questionsAsked, 1);
      },
    );

    test('successful actions delivery clears the task budget', () async {
      final coach = agent(
        FakeLlmClient([_ask(_textQuestion()), _showActions()]),
      );

      await coach.send('请澄清这个动作');
      expect(coach.questionsAsked, 1);
      final result = await coach.send('改为看看动作');

      expect(result.actions, isNotNull);
      expect(coach.questionsAsked, 0);
    });

    test('validated fallback plan clears the task budget', () async {
      final fallbackPlan = const PlanCodec().decode(_plan());
      final coach = agent(
        FakeLlmClient([
          _ask(_textQuestion()),
          const LlmException(LlmErrorKind.auth, 'bad key'),
        ]),
        fallback: (_) =>
            SessionFallbackReply('按默认 10 分钟安排。', plan: fallbackPlan),
      );

      await coach.send('请澄清这个动作');
      final result = await coach.send('10 分钟');

      expect(result.status, TurnStatus.fallback);
      expect(result.plan, isNotNull);
      expect(coach.questionsAsked, 0);
    });

    test(
      'plain text does not silently reset an unfinished task budget',
      () async {
        final coach = agent(
          FakeLlmClient([
            _ask(_textQuestion()),
            '收到。',
            _ask(_textQuestion()),
            _showPlan(),
          ]),
        );

        await coach.send('请澄清这个动作');
        await coach.send('我先想想');
        expect(coach.questionsAsked, 1);
        await coach.send('继续');
        expect(coach.questionsAsked, 0);
      },
    );

    test(
      'reset clears question count, history, and permits a fresh task',
      () async {
        final coach = agent(
          FakeLlmClient([_ask(_textQuestion()), '收到', _ask(_textQuestion())]),
        );

        await coach.send('请澄清这个动作');
        await coach.send('10 分钟');
        expect(coach.questionsAsked, 1);
        coach.reset();

        expect(coach.questionsAsked, 0);
        expect(coach.history, isEmpty);
        expect(coach.turnCount, 0);
        expect((await coach.send('新任务')).question, isNotNull);
        expect(coach.questionsAsked, 1);
      },
    );
  });

  group('ask_user cancellation boundaries', () {
    for (final how in ['cancel', 'reset']) {
      test(
        '$how during accounting suppresses question delivery and state changes',
        () async {
          final inSink = Completer<void>();
          final release = Completer<void>();
          final token = CancelToken();
          final coach = agent(
            FakeLlmClient([_ask(_textQuestion())]),
            usage: CallbackUsageSink((_) {
              inSink.complete();
              return release.future;
            }),
          );
          final events = <AgentEvent>[];
          coach.events.listen(events.add);
          final pending = coach.send('请澄清这个动作', cancel: token);
          await inSink.future;
          expect(coach.questionsAsked, 0);
          expect(coach.history, isEmpty);
          expect(
            events.where((event) => event.kind == AgentEventKind.askUser),
            isEmpty,
          );

          how == 'cancel' ? token.cancel() : coach.reset();
          release.complete();
          final result = await pending;

          expect(result.status, TurnStatus.cancelled);
          expect(result.question, isNull);
          expect(result.text, isEmpty);
          expect(coach.questionsAsked, 0);
          expect(coach.history, isEmpty);
          expect(coach.turnCount, 0);
          expect(
            events.where(
              (event) =>
                  event.kind == AgentEventKind.askUser ||
                  event.kind == AgentEventKind.done,
            ),
            isEmpty,
          );
        },
      );

      test(
        '$how in the synchronous ask listener cannot commit a stale question',
        () async {
          final token = CancelToken();
          final coach = agent(FakeLlmClient([_ask(_textQuestion())]));
          final events = <AgentEvent>[];
          coach.events.listen((event) {
            events.add(event);
            if (event.kind == AgentEventKind.askUser) {
              how == 'cancel' ? token.cancel() : coach.reset();
            }
          });

          final result = await coach.send('请澄清这个动作', cancel: token);

          expect(result.status, TurnStatus.cancelled);
          expect(result.question, isNull);
          expect(coach.questionsAsked, 0);
          expect(coach.history, isEmpty);
          expect(coach.turnCount, 0);
          expect(
            events.where((event) => event.kind == AgentEventKind.done),
            isEmpty,
          );
        },
      );
    }

    test(
      'cancel while the next model response is in flight preserves the prior question budget',
      () async {
        final entered = Completer<void>();
        final release = Completer<Object>();
        final token = CancelToken();
        final client = FakeLlmClient([
          _ask(_textQuestion()),
          (_) {
            entered.complete();
            return release.future;
          },
        ]);
        final coach = agent(client);
        await coach.send('请澄清这个动作');
        final historyBefore = List<LlmMessage>.of(coach.history);
        final pending = coach.send('10 分钟', cancel: token);
        await entered.future;

        token.cancel();
        final result = await pending.timeout(const Duration(seconds: 1));
        release.complete(_ask(_textQuestion('在哪里练？')));

        expect(result.status, TurnStatus.cancelled);
        expect(coach.questionsAsked, 1);
        expect(coach.history, historyBefore);
        expect(coach.turnCount, 1);
      },
    );
  });
}
