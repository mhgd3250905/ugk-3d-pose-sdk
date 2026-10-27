import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

var _calls = 0;

LlmResponse _tool(String name, Object arguments) => LlmResponse(
  content: '',
  toolCalls: [
    LlmToolCall(
      id: 'conversation-${_calls++}',
      name: name,
      arguments: jsonEncode(arguments),
    ),
  ],
  finishReason: 'tool_calls',
);

LlmResponse _textQuestion([String text = '准备花多久？']) =>
    _tool(AgentTools.askUser, {'question': text, 'mode': 'text'});

LlmResponse _choiceQuestion({bool multiple = false}) =>
    _tool(AgentTools.askUser, {
      'question': '今天重点练哪里？',
      'mode': 'choice',
      'options': ['肩颈', '髋部', '腿部'],
      'multiple': multiple,
    });

LlmResponse _plan() =>
    _tool(AgentTools.showPlan, planOf(okEnvelope())..remove('source'));

/// A scripted agent boundary for controller lifecycle tests. This does not
/// test CoachAgent intent policy: question payloads still go through the real
/// AskUserGate and plans through ToolGate before reaching the controller.
/// Real-agent intent behavior is covered separately by the r2 protocol tests.
class _ControllerAgent extends CoachAgent {
  _ControllerAgent(this.fake, Catalog catalog, CoachProfile profile)
    : _catalog = catalog,
      _profile = profile,
      super(
        client: fake,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      );

  final FakeLlmClient fake;
  final Catalog _catalog;
  final CoachProfile _profile;
  final _controllerEvents = StreamController<AgentEvent>.broadcast(sync: true);
  final _controllerHistory = <LlmMessage>[];
  int _controllerTurns = 0;
  int _epoch = 0;
  bool _controllerBusy = false;

  @override
  Stream<AgentEvent> get events => _controllerEvents.stream;
  @override
  List<LlmMessage> get history => List.unmodifiable(_controllerHistory);
  @override
  int get turnCount => _controllerTurns;
  @override
  bool get isBusy => _controllerBusy;

  @override
  void reset() {
    _epoch++;
    _controllerTurns = 0;
    _controllerHistory.clear();
    _controllerBusy = false;
    super.reset();
  }

  @override
  Future<void> dispose() async {
    await _controllerEvents.close();
    await super.dispose();
  }

  @override
  Future<CoachTurnResult> send(
    String userText, {
    CoachContext context = const CoachContext(),
    CancelToken? cancel,
    Map<String, List<String>>? confirmedForm,
  }) async {
    final id = 'controller-${_controllerTurns + 1}';
    if (userText.length > maxInputChars) {
      return CoachTurnResult(turnId: id, status: TurnStatus.inputTooLong);
    }
    if (_controllerBusy) {
      return CoachTurnResult(turnId: id, status: TurnStatus.busy);
    }
    final epoch = _epoch;
    _controllerBusy = true;
    try {
      final request = LlmRequest(
        messages: [..._controllerHistory, LlmMessage.user(userText)],
      );
      final response = await Future.any<LlmResponse?>([
        fake.complete(request, cancel: cancel),
        if (cancel != null) cancel.whenCancelled.then((_) => null),
      ]);
      if (response == null ||
          epoch != _epoch ||
          (cancel?.isCancelled ?? false)) {
        return CoachTurnResult(turnId: id, status: TurnStatus.cancelled);
      }
      AskUserQuestion? question;
      ValidatedPlan? plan;
      if (response.toolCalls.isNotEmpty) {
        final call = response.toolCalls.single;
        if (call.name == AgentTools.askUser) {
          final checked = AskUserGate.check(call.arguments);
          if (!checked.ok) {
            throw StateError('Invalid scripted question: ${checked.errors}');
          }
          question = checked.question!;
          _controllerEvents.add(
            AgentEvent(id, AgentEventKind.askUser, question: question),
          );
        } else if (call.name == AgentTools.showPlan) {
          final checked = ToolGate(
            catalog: _catalog,
            profile: _profile,
          ).check('', [call], context: context);
          if (!checked.ok || checked.plan == null) {
            throw StateError('Invalid scripted plan: ${checked.errors}');
          }
          plan = checked.plan;
        } else {
          throw StateError('Unexpected scripted tool: ${call.name}');
        }
      }
      _controllerTurns++;
      _controllerHistory
        ..add(LlmMessage.user(userText))
        ..add(LlmMessage.assistant(response.content));
      return CoachTurnResult(
        turnId: id,
        status: TurnStatus.ok,
        text: question?.question ?? response.content,
        question: question,
        plan: plan,
      );
    } on LlmException catch (error) {
      return CoachTurnResult(
        turnId: id,
        status: TurnStatus.error,
        error: error,
      );
    } finally {
      if (epoch == _epoch) _controllerBusy = false;
    }
  }
}

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');

  CoachConversationController controller(FakeLlmClient client) {
    final value = CoachConversationController(
      agent: _ControllerAgent(client, catalog, profile),
    );
    addTearDown(value.dispose);
    return value;
  }

  test(
    'one multi-choice clarification reaches a plan on the same agent',
    () async {
      final client = FakeLlmClient([_choiceQuestion(multiple: true), _plan()]);
      final conversation = controller(client);
      final agent = conversation.agent;

      await conversation.send('请澄清这个动作');
      final first = conversation.state.pendingQuestion!;
      expect(first.text, isEmpty, reason: 'The question body is not repeated');
      expect(conversation.canAnswer(first.id), isTrue);
      expect(conversation.state.messages, hasLength(2));

      await conversation.answerChoices(first.id, ['腿部', '肩颈']);
      expect(identical(conversation.agent, agent), isTrue);
      expect(agent.turnCount, 2);
      expect(client.requests, hasLength(2));
      expect(conversation.state.pendingQuestion, isNull);
      expect(conversation.state.admittedPlans, hasLength(1));
      expect(
        conversation.state.messages.last.plan,
        same(conversation.state.admittedPlans.single),
      );
      expect(conversation.state.messages[1].answeredChoices, ['肩颈', '腿部']);
      expect(conversation.state.messages[2].text, '肩颈、腿部');
      expect(
        client.requests.last.messages
            .where((m) => m.role == LlmRole.user)
            .map((m) => m.content),
        containsAllInOrder(['请澄清这个动作', '肩颈、腿部']),
      );
      expect(conversation.state.error, isNull);
    },
  );

  test(
    'single-choice validates answers and sends the selected label',
    () async {
      final client = FakeLlmClient([_choiceQuestion(), '安排好了']);
      final conversation = controller(client);
      await conversation.send('请澄清这个动作');
      final question = conversation.state.pendingQuestion!;
      for (final invalid in <List<String>>[
        [],
        ['肩颈', '腿部'],
        ['肩颈', '肩颈'],
        ['不存在'],
      ]) {
        expect(await conversation.answerChoices(question.id, invalid), isNull);
        expect(conversation.canAnswer(question.id), isTrue);
      }
      await conversation.answerChoices(question.id, ['髋部']);
      expect(client.requests, hasLength(2));
      expect(conversation.state.messages[1].answeredChoices, ['髋部']);
      expect(conversation.state.messages[2].text, '髋部');
    },
  );

  test(
    'choice separator is injectable and raw text remains a same-agent answer',
    () async {
      final client = FakeLlmClient([
        _choiceQuestion(multiple: true),
        '收到',
        '收到',
      ]);
      final agent = _ControllerAgent(client, catalog, profile);
      final conversation = CoachConversationController(
        agent: agent,
        choiceSeparator: ', ',
      );
      addTearDown(conversation.dispose);
      await conversation.send('请澄清这个动作');
      final question = conversation.state.pendingQuestion!;
      expect(conversation.choiceText(question.id, ['腿部', '肩颈']), '肩颈, 腿部');
      await conversation.answerText(question.id, '@settings');
      expect(conversation.state.messages[2].text, '@settings');
      await conversation.send('10分钟');
      expect(agent.turnCount, 3);
      expect(conversation.state.pendingQuestion, isNull);
    },
  );

  test(
    'question becomes answerable only after send returns, never from progress',
    () async {
      final conversation = controller(FakeLlmClient([_textQuestion()]));
      var sawQuestionEvent = false;
      final subscription = conversation.events.listen((event) {
        if (event.kind == AgentEventKind.askUser) {
          sawQuestionEvent = true;
          expect(conversation.state.isWaiting, isTrue);
          expect(conversation.state.pendingQuestion, isNull);
          expect(conversation.state.messages, isEmpty);
        }
      });
      addTearDown(subscription.cancel);
      final pending = conversation.send('请澄清这个动作');
      expect(conversation.state.isWaiting, isTrue);
      await pending;
      expect(sawQuestionEvent, isTrue);
      expect(conversation.state.isWaiting, isFalse);
      expect(
        conversation.canAnswer(conversation.state.pendingQuestion!.id),
        isTrue,
      );
    },
  );

  test(
    'submitting locks the question synchronously and rejects duplicate sends',
    () async {
      final started = Completer<void>();
      final response = Completer<Object>();
      final client = FakeLlmClient([
        _choiceQuestion(),
        (LlmRequest _) {
          started.complete();
          return response.future;
        },
      ]);
      final conversation = controller(client);
      await conversation.send('请澄清这个动作');
      final question = conversation.state.pendingQuestion!;
      final first = conversation.answerChoices(question.id, ['肩颈']);
      expect(conversation.state.isWaiting, isTrue);
      expect(conversation.canAnswer(question.id), isFalse);
      final duplicate = conversation.answerChoices(question.id, ['髋部']);
      expect(await duplicate, isNull);
      expect(await conversation.send('另一条消息'), isNull);
      await started.future;
      response.complete('收到');
      await first;
      expect(client.requests, hasLength(2));
      expect(conversation.state.messages[1].answeredChoices, ['肩颈']);
    },
  );

  test(
    'overlong/empty answers preserve the active question for a valid retry',
    () async {
      final client = FakeLlmClient([_textQuestion(), '收到']);
      final conversation = controller(client);
      await conversation.send('请澄清这个动作');
      final question = conversation.state.pendingQuestion!;
      expect(await conversation.answerText(question.id, '  '), isNull);
      final rejected = await conversation.answerText(question.id, '长' * 501);
      expect(rejected!.status, TurnStatus.inputTooLong);
      expect(conversation.state.lastResult, same(rejected));
      expect(conversation.canAnswer(question.id), isTrue);
      expect(conversation.state.messages, hasLength(2));
      expect(client.requests, hasLength(1));
      await conversation.answerText(question.id, '10分钟');
      expect(conversation.state.messages, hasLength(4));
      expect(conversation.state.pendingQuestion, isNull);
    },
  );

  test(
    'cancel invalidates a completed question and retains the same agent',
    () async {
      final client = FakeLlmClient([_textQuestion(), '新请求收到']);
      final conversation = controller(client);
      final agent = conversation.agent;
      await conversation.send('请澄清这个动作');
      final question = conversation.state.pendingQuestion!;
      conversation.cancel();
      expect(conversation.state.pendingQuestion, isNull);
      expect(conversation.state.messages.last.questionAnswered, isTrue);
      expect(await conversation.answerText(question.id, '旧答案'), isNull);
      await conversation.send('新的请求');
      expect(conversation.agent, same(agent));
      expect(agent.turnCount, 2);
      expect(client.requests, hasLength(2));
    },
  );

  test(
    'cancel discards late results; next send waits only for cancellation',
    () async {
      final started = Completer<void>();
      final late = Completer<Object>();
      final client = FakeLlmClient([
        (LlmRequest _) {
          started.complete();
          return late.future;
        },
        _textQuestion('新的问题？'),
      ]);
      final conversation = controller(client);
      final pending = conversation.send('旧请求');
      await started.future;
      conversation.cancel();
      expect(conversation.state.isWaiting, isFalse);
      final next = conversation.send('新请求');
      await pending;
      await next;
      late.complete(_textQuestion('迟到的问题？'));
      await Future<void>.delayed(Duration.zero);
      expect(conversation.state.messages, hasLength(2));
      expect(conversation.state.pendingQuestion!.question!.question, '新的问题？');
      expect(conversation.state.messages.first.text, '新请求');
    },
  );

  test(
    'new conversation invalidates old questions and resets the same agent',
    () async {
      final client = FakeLlmClient([_textQuestion(), '全新回复']);
      final conversation = controller(client);
      final agent = conversation.agent;
      await conversation.send('请澄清这个动作');
      final question = conversation.state.pendingQuestion!;
      conversation.newConversation();
      expect(conversation.state.messages, isEmpty);
      expect(conversation.state.pendingQuestion, isNull);
      expect(agent.history, isEmpty);
      expect(await conversation.answerText(question.id, '旧答案'), isNull);
      await conversation.send('新对话');
      expect(conversation.agent, same(agent));
      expect(agent.turnCount, 1);
      expect(
        client.requests.last.messages
            .where((m) => m.role == LlmRole.user)
            .map((m) => m.content),
        ['新对话'],
      );
    },
  );

  test(
    'restoring history cannot reactivate a question or tool history',
    () async {
      final conversation = controller(FakeLlmClient([_textQuestion()]));
      await conversation.send('请澄清这个动作');
      final history = conversation.state.messages;
      final question = history.last;
      conversation.restoreHistory(history);
      expect(conversation.state.messages, hasLength(2));
      expect(conversation.state.messages.last.questionAnswered, isTrue);
      expect(conversation.state.pendingQuestion, isNull);
      expect(conversation.agent.history, isEmpty);
      expect(await conversation.answerText(question.id, '历史答案'), isNull);
    },
  );

  test('App-only interactions can invalidate a live question', () async {
    final conversation = controller(FakeLlmClient([_choiceQuestion()]));
    await conversation.send('请澄清这个动作');
    final question = conversation.state.pendingQuestion!;
    conversation.invalidateQuestion();
    expect(conversation.state.messages.last.questionAnswered, isTrue);
    expect(conversation.choiceText(question.id, ['肩颈']), isNull);
    expect(await conversation.answerChoices(question.id, ['肩颈']), isNull);
  });

  test(
    'state streams/listeners are observable and message lists immutable',
    () async {
      final conversation = controller(FakeLlmClient([_choiceQuestion()]));
      final states = <CoachConversationState>[];
      var notifications = 0;
      void listener() => notifications++;
      conversation.addListener(listener);
      final subscription = conversation.states.listen(states.add);
      addTearDown(subscription.cancel);
      await conversation.send('请澄清这个动作');
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 2);
      expect(states.map((s) => s.isWaiting), [true, false]);
      expect(() => conversation.state.messages.clear(), throwsUnsupportedError);
      expect(
        () => conversation.state.admittedPlans.clear(),
        throwsUnsupportedError,
      );
      final selected = <String>['肩颈'];
      final copy = conversation.state.messages.last.copyWith(
        answeredChoices: selected,
      );
      selected.clear();
      expect(copy.answeredChoices, ['肩颈']);
      expect(() => copy.answeredChoices.clear(), throwsUnsupportedError);
      conversation.removeListener(listener);
      conversation.cancel();
      expect(notifications, 2);
    },
  );

  test(
    'error results are available without inventing an admitted routine',
    () async {
      final conversation = controller(
        FakeLlmClient([const LlmException(LlmErrorKind.auth, 'auth failed')]),
      );
      final result = await conversation.send('请澄清这个动作');
      expect(result!.status, TurnStatus.error);
      expect(conversation.state.lastResult, same(result));
      expect(conversation.state.error, isNotNull);
      expect(conversation.state.admittedPlans, isEmpty);
      expect(conversation.state.pendingQuestion, isNull);
      expect(conversation.state.isWaiting, isFalse);
      expect(conversation.state.messages.last.isFailure, isTrue);
      expect(conversation.state.messages.last.text, isEmpty);
      expect(conversation.state.messages.last.copyWith().isFailure, isTrue);
    },
  );

  test('dispose is idempotent and prevents sends and stale answers', () async {
    final client = FakeLlmClient([_textQuestion()]);
    final conversation = controller(client);
    await conversation.send('请澄清这个动作');
    final question = conversation.state.pendingQuestion!;
    final disposed = conversation.dispose();
    expect(conversation.state.isWaiting, isFalse);
    expect(conversation.state.pendingQuestion, isNull);
    await disposed;
    await conversation.dispose();
    expect(conversation.agent.history, isEmpty);
    expect(await conversation.send('新请求'), isNull);
    expect(await conversation.answerText(question.id, '旧答案'), isNull);
    expect(client.requests, hasLength(1));
  });
}
