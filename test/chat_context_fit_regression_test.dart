import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/append_only_context.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'fixtures/chat_context_fit_fixture.dart';
import 'request_context_support.dart';
import 'support.dart';

void main() {
  const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$pack/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$pack/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');
  final fixture = ChatContextFitFixture(catalog, profile);

  OpenAiCompatibleClient serializer() {
    final result = OpenAiCompatibleClient(
      config: LlmConfig.ugkWorker.copyWith(model: 'deepseek-flash'),
    );
    addTearDown(result.close);
    return result;
  }

  String messagesJson(Iterable<LlmMessage> messages) =>
      jsonEncode(messages.map((message) => message.toJson()).toList());

  String system() => AgentPromptBuilder().system(
    profile,
    SkillFiles.build(profile, catalog, memory: false),
    memory: false,
  );

  List<LlmTool> tools() => AgentTools.build(profile, catalog, memory: false);

  LlmMessage tail(List<CompletedContextTurn> turns) =>
      AppendOnlyContext.stateMessage(
        state: fixture.state(turns),
        catalog: catalog,
        profile: profile,
        language: 'zh',
      );

  test(
    '25 completed rounds fit without folding while source ledger and history remain intact',
    () {
      final client = serializer();
      int bytes(LlmRequest request) =>
          utf8.encode(jsonEncode(client.buildBody(request))).length;
      final context = AppendOnlyContext(
        budget: const ContextBudgetConfig(),
        encodedBytes: bytes,
      )..activate(system: system(), tools: tools());
      final turns = <CompletedContextTurn>[];
      final history = <LlmMessage>[];
      var folded = false;
      for (var turn = 1; turn <= 26; turn++) {
        final sourceLedger = ContextTurnLedger(turns);
        final ledgerBefore = jsonEncode(sourceLedger.toJson());
        final historyBefore = messagesJson(history);
        final current = LlmMessage.user(fixture.user(turn));
        final state = tail(turns);
        final prepared = context.compose(
          currentMessages: [current],
          stateMessage: state,
          ledger: sourceLedger,
          thinking: false,
        );
        expect(prepared.diagnostics.afterBytes, bytes(prepared.request));
        expect(
          prepared.diagnostics.fitsHardLimit,
          isTrue,
          reason: 'round $turn',
        );
        expect(bytes(prepared.request), lessThanOrEqualTo(262144));
        expect(prepared.request.messages, contains(same(current)));
        expect(prepared.request.messages.last, same(state));
        expect(jsonEncode(sourceLedger.toJson()), ledgerBefore);
        expect(messagesJson(history), historyBefore);
        folded = folded || prepared.diagnostics.folded;
        final completed = fixture.completedMessages(turn);
        context.markConsumed(prepared.request);
        context.finishTurn(messages: completed);
        history.addAll(completed);
        turns.add(fixture.facts(turn));
      }
      expect(folded, isFalse);
      expect(turns.map((turn) => turn.userText), [
        for (var turn = 1; turn <= 26; turn++) fixture.user(turn),
      ]);
      expect(history, hasLength(104));
    },
  );

  test(
    'oversized legacy seed fits without changing restored source messages',
    () {
      final client = serializer();
      int bytes(LlmRequest request) =>
          utf8.encode(jsonEncode(client.buildBody(request))).length;
      final seed = [...fixture.legacySeed(), ...fixture.legacySeed()];
      final before = messagesJson(seed);
      final context = AppendOnlyContext(
        budget: const ContextBudgetConfig(),
        encodedBytes: bytes,
      )..activate(system: system(), tools: tools(), seedMessages: seed);
      final current = LlmMessage.user(fixture.user(26));
      final prepared = context.compose(
        currentMessages: [current],
        stateMessage: tail(const []),
        ledger: ContextTurnLedger(const []),
        thinking: false,
      );
      expect(prepared.diagnostics.beforeBytes, greaterThan(262144));
      expect(prepared.diagnostics.fitsHardLimit, isTrue);
      expect(prepared.diagnostics.afterBytes, bytes(prepared.request));
      expect(bytes(prepared.request), lessThanOrEqualTo(262144));
      expect(prepared.request.messages, contains(same(current)));
      expect(messagesJson(seed), before);
    },
  );

  test(
    'restoring 25 rich completed turns permits consecutive sends and another restore',
    () async {
      final turns = [
        for (var turn = 1; turn <= 25; turn++) fixture.facts(turn),
      ];
      final original = ContextTurnLedger(turns);
      final originalJson = jsonEncode(original.toJson());
      final snapshot = CoachSessionSnapshot(
        sessionState: fixture.state(turns),
        ledger: original,
      );
      final replay = FakeLlmClient([
        const LlmResponse(content: '动作保持平稳即可。'),
        const LlmResponse(content: '可以，下次再继续。'),
      ], latency: Duration.zero);
      final client = OfflineConfiguredClient(
        replay: replay,
        config: LlmConfig.ugkWorker.copyWith(model: 'deepseek-flash'),
      );
      addTearDown(client.close);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
        maxTurns: 100,
        maxHistoryChars: 100000,
      );
      addTearDown(agent.dispose);
      expect(agent.restoreSessionSnapshot(snapshot), isTrue);
      final first = await agent.send('请继续。');
      expect(first.status, TurnStatus.ok, reason: '${first.error}');
      expect(first.error, isNull);
      final saved = agent.exportSession();
      expect(agent.restoreSessionSnapshot(saved), isTrue);
      final second = await agent.send('谢谢。');
      expect(second.status, TurnStatus.ok, reason: '${second.error}');
      expect(replay.requests, hasLength(2));
      expect(
        agent.contextRequestDiagnostics.every((d) => d.fitsHardLimit),
        isTrue,
      );
      expect(jsonEncode(original.toJson()), originalJson);
      final persisted = ContextTurnLedger.fromJson(
        agent.sessionState.completedContextLedger!,
      );
      expect(
        persisted.turns.take(25).map((turn) => turn.toJson()),
        turns.map((turn) => turn.toJson()),
      );
      expect(
        agent.sessionState.userTurns.map((turn) => turn.text).take(25),
        turns.map((turn) => turn.userText),
      );
      for (final request in replay.requests) {
        expect(
          utf8.encode(jsonEncode(client.buildBody(request))).length,
          lessThanOrEqualTo(262144),
        );
      }
    },
  );
}
