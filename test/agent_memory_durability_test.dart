import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

const _initialText = 'train-in-the-morning';
const _newText = 'improve-hip-mobility';
const _oldReasoning = 'cancelled-turn-private-reasoning';
const _newReasoning = 'fresh-turn-public-reasoning';

List<MemoryEntry> _initial() => [
  MemoryEntry(MemoryKind.goal, _initialText, at: DateTime.utc(2026)),
];

List<String> _texts(Iterable<MemoryEntry> entries) =>
    entries.map((e) => e.text).toList();

List<String> _expected(String operation) =>
    operation == 'remember' ? [_initialText, _newText] : [];

LlmResponse _mutation(
  String operation,
  String id, {
  String reasoning = 'memory-tool-reasoning',
  String? text,
}) => LlmResponse(
  content: '',
  toolCalls: [
    LlmToolCall(
      id: id,
      name: operation,
      arguments: jsonEncode({
        'kind': 'goal',
        'text': text ?? (operation == 'remember' ? _newText : _initialText),
      }),
    ),
  ],
  reasoning: reasoning,
  finishReason: 'tool_calls',
);

Map<String, Object?> _feedback(LlmRequest request, String id) =>
    (jsonDecode(
              request.messages
                  .singleWhere(
                    (m) => m.role == LlmRole.tool && m.toolCallId == id,
                  )
                  .content,
            )
            as Map)
        .cast<String, Object?>();

String _wire(LlmRequest request) =>
    jsonEncode([for (final m in request.messages) m.toJson()]);

/// Each save starts immediately but only changes the persisted snapshot when released.
class _SaveAttempt {
  final started = Completer<List<MemoryEntry>>();
  final finished = Completer<void>();
  final _done = Completer<void>();

  void succeed() {
    if (!_done.isCompleted) _done.complete();
  }

  void fail() => _done.completeError(StateError('disk unavailable'));
}

class _GatedMemoryStore implements UserMemoryStore {
  _GatedMemoryStore(this.attempts) : entries = _initial();

  final List<_SaveAttempt> attempts;
  List<MemoryEntry> entries;
  int calls = 0;
  int completed = 0;

  @override
  Future<List<MemoryEntry>> load() async => List.of(entries);

  @override
  Future<void> save(List<MemoryEntry> entries) async {
    final snapshot = List<MemoryEntry>.of(entries);
    final attempt = attempts[calls++];
    attempt.started.complete(snapshot);
    try {
      await attempt._done.future;
      this.entries = snapshot;
      completed++;
    } finally {
      attempt.finished.complete();
    }
  }

  void release() {
    for (final attempt in attempts) {
      attempt.succeed();
    }
  }
}

Future<T> _soon<T>(Future<T> future) =>
    future.timeout(const Duration(seconds: 2));

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');

  CoachAgent agent(
    FakeLlmClient client,
    _GatedMemoryStore store, {
    Duration turnTimeout = const Duration(seconds: 180),
    SessionFallback? fallback,
  }) {
    final result = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      memoryStore: store,
      maxRequestRetries: 0,
      turnTimeout: turnTimeout,
      fallback: fallback,
    );
    addTearDown(() async {
      store.release();
      await result.dispose();
    });
    return result;
  }

  for (final operation in ['remember', 'forget']) {
    group(operation, () {
      test(
        'waits for durable save before tool success and the next model request',
        () async {
          final save = _SaveAttempt();
          final store = _GatedMemoryStore([save]);
          final client = FakeLlmClient([
            _mutation(operation, 'memory-1'),
            (LlmRequest request) {
              expect(store.completed, 1);
              expect(_feedback(request, 'memory-1')['ok'], isTrue);
              expect(_texts(store.entries), _expected(operation));
              return 'Saved.';
            },
          ], latency: Duration.zero);
          final a = agent(client, store);
          var finished = false;
          final pending = a.send('Update my memory.').then((r) {
            finished = true;
            return r;
          });

          expect(
            _texts(await _soon(save.started.future)),
            _expected(operation),
          );
          await Future<void>.delayed(Duration.zero);
          expect(
            client.requests,
            hasLength(1),
            reason: 'A successful tool result must wait for save.',
          );
          expect(finished, isFalse);
          expect(_texts(store.entries), [_initialText]);
          expect(_texts(await a.memory()), [_initialText]);

          save.succeed();
          expect((await _soon(pending)).status, TurnStatus.ok);
          expect(client.requests, hasLength(2));
          expect(_texts(await a.memory()), _expected(operation));
          expect(_texts(store.entries), _expected(operation));
        },
      );

      test(
        'reports save failure without changing cache/store, then a tool retry can recover',
        () async {
          final first = _SaveAttempt();
          final retry = _SaveAttempt();
          final store = _GatedMemoryStore([first, retry]);
          late CoachAgent a;
          final client = FakeLlmClient([
            _mutation(operation, 'memory-failed'),
            (LlmRequest request) async {
              final feedback = _feedback(request, 'memory-failed');
              expect(feedback['ok'], isFalse);
              expect(feedback['error'], isNotNull);
              expect(feedback['error'].toString(), isNotEmpty);
              expect(store.completed, 0);
              expect(_texts(store.entries), [_initialText]);
              expect(_texts(await a.memory()), [_initialText]);
              return _mutation(operation, 'memory-retried');
            },
            (LlmRequest request) {
              expect(store.completed, 1);
              expect(_feedback(request, 'memory-retried')['ok'], isTrue);
              return 'Saved after retry.';
            },
          ], latency: Duration.zero);
          a = agent(client, store);
          final pending = a.send('Update my memory.');

          await _soon(first.started.future);
          expect(client.requests, hasLength(1));
          first.fail();
          expect(
            _texts(await _soon(retry.started.future)),
            _expected(operation),
          );
          await Future<void>.delayed(Duration.zero);
          expect(client.requests, hasLength(2));
          expect(_texts(store.entries), [_initialText]);
          expect(_texts(await a.memory()), [_initialText]);

          retry.succeed();
          final result = await _soon(pending);
          expect(result.status, TurnStatus.ok);
          expect(client.requests, hasLength(3));
          expect(store.calls, 2);
          expect(_texts(store.entries), _expected(operation));
          expect(_texts(await a.memory()), _expected(operation));
        },
      );

      for (final interruption in ['cancel', 'reset']) {
        test(
          '$interruption while save waits stops the old turn and leaves no reasoning in the next turn',
          () async {
            final save = _SaveAttempt();
            final restore = _SaveAttempt();
            final store = _GatedMemoryStore([save, restore]);
            final token = CancelToken();
            final client = FakeLlmClient([
              _mutation(
                operation,
                'cancelled-memory',
                reasoning: _oldReasoning,
              ),
              const LlmResponse(
                content: '',
                toolCalls: [
                  LlmToolCall(
                    id: 'fresh-read',
                    name: 'read',
                    arguments: '{"path":"action-library/SKILL.md"}',
                  ),
                ],
                reasoning: _newReasoning,
                finishReason: 'tool_calls',
              ),
              (LlmRequest request) {
                expect(_wire(request), isNot(contains(_oldReasoning)));
                final response = request.messages.singleWhere(
                  (m) => m.toolCalls.any((t) => t.id == 'fresh-read'),
                );
                expect(
                  response.reasoning,
                  _newReasoning,
                  reason: 'A new memory-off turn must keep its own reasoning.',
                );
                return 'Fresh turn finished.';
              },
            ], latency: Duration.zero);
            final a = agent(client, store);
            final pending = a.send('Update my memory.', cancel: token);

            await _soon(save.started.future);
            expect(client.requests, hasLength(1));
            interruption == 'cancel' ? token.cancel() : a.reset();
            final result = await _soon(pending);
            expect(result.status, TurnStatus.cancelled);
            expect(client.requests, hasLength(1));
            expect(a.history, isEmpty);
            expect(a.turnCount, 0);

            // A late pending save is compensated before a new store load can confirm it.
            save.succeed();
            expect(_texts(await _soon(restore.started.future)), [_initialText]);
            restore.succeed();
            await _soon(restore.finished.future);
            await Future<void>.delayed(Duration.zero);
            expect(client.requests, hasLength(1));
            expect(_texts(store.entries), [_initialText]);
            expect(_texts(await a.memory()), [_initialText]);
            final freshAgent = agent(FakeLlmClient(const []), store);
            expect(_texts(await freshAgent.memory()), [_initialText]);
            a.enableUserMemory = false;
            expect(
              (await _soon(a.send('Start a fresh turn.'))).status,
              TurnStatus.ok,
            );
            expect(client.requests, hasLength(3));
            for (final request in client.requests.skip(1)) {
              expect(_wire(request), isNot(contains(_oldReasoning)));
              expect(_wire(request), isNot(contains('cancelled-memory')));
            }
            expect(
              a.history.map((m) => m.reasoning).join(),
              isNot(contains(_oldReasoning)),
            );
          },
        );
      }
    });
  }

  test(
    'turnTimeout interrupts a pending save and compensates its late write',
    () async {
      final lateSave = _SaveAttempt();
      final compensation = _SaveAttempt();
      final store = _GatedMemoryStore([lateSave, compensation]);
      final client = FakeLlmClient([
        _mutation('remember', 'timed-out-memory'),
        'A timed-out memory tool must not trigger another model request.',
      ], latency: Duration.zero);
      final a = agent(
        client,
        store,
        turnTimeout: const Duration(milliseconds: 80),
        fallback: (_) =>
            const SessionFallbackReply('Memory request timed out.'),
      );
      final pending = a.send('Remember this.');
      await _soon(lateSave.started.future);
      final result = await pending.timeout(const Duration(seconds: 1));
      expect(result.status, TurnStatus.fallback);
      expect(result.fallbackReason, FallbackReason.timeout);
      expect(result.records.single.issueCodes, ['timeout']);
      expect(
        result.error,
        isA<AgentRequestFailed>().having(
          (e) => e.kind,
          'kind',
          AgentFailureKind.turnTimeout,
        ),
      );
      expect(client.requests, hasLength(1));
      expect(_texts(store.entries), [_initialText]);
      expect(_texts(await a.memory()), [_initialText]);

      lateSave.succeed();
      expect(_texts(await _soon(compensation.started.future)), [_initialText]);
      compensation.succeed();
      await _soon(compensation.finished.future);
      await Future<void>.delayed(Duration.zero);
      expect(client.requests, hasLength(1));
      expect(_texts(store.entries), [_initialText]);
      expect(_texts(await a.memory()), [_initialText]);
      final freshAgent = agent(FakeLlmClient(const []), store);
      expect(_texts(await freshAgent.memory()), [_initialText]);
    },
  );

  test(
    'clearMemory during a pending save compensates the late write with the empty snapshot',
    () async {
      final lateSave = _SaveAttempt();
      final compensation = _SaveAttempt();
      final clearSave = _SaveAttempt();
      final store = _GatedMemoryStore([lateSave, compensation, clearSave]);
      final client = FakeLlmClient([
        _mutation('remember', 'cleared-before-confirmation'),
        (LlmRequest request) {
          // 清除作废本轮记忆，将旧调用与结果一并过滤，不能再携带旧参数。
          expect(_wire(request), isNot(contains('cleared-before-confirmation')));
          expect(request.tools.map((t) => t.name), isNot(contains('remember')));
          expect(request.messages.first.content, isNot(contains(_initialText)));
          expect(request.messages.first.content, isNot(contains(_newText)));
          return 'Memory was cleared.';
        },
      ], latency: Duration.zero);
      final a = agent(client, store);
      final pending = a.send('Remember this.');
      await _soon(lateSave.started.future);
      final cleared = a.clearMemory();
      expect(await a.memory(), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(client.requests, hasLength(1));

      lateSave.succeed();
      expect(await _soon(compensation.started.future), isEmpty);
      compensation.succeed();
      expect(await _soon(clearSave.started.future), isEmpty);
      clearSave.succeed();
      await _soon(cleared);
      expect((await _soon(pending)).status, TurnStatus.ok);
      expect(store.entries, isEmpty);
      expect(await a.memory(), isEmpty);
      final freshAgent = agent(FakeLlmClient(const []), store);
      expect(await freshAgent.memory(), isEmpty);
    },
  );

  test(
    'a new turn memory write queues behind reset compensation and survives the old late save',
    () async {
      const freshText = 'practice-balance-daily';
      final lateSave = _SaveAttempt();
      final compensation = _SaveAttempt();
      final freshSave = _SaveAttempt();
      final store = _GatedMemoryStore([lateSave, compensation, freshSave]);
      final newToolEmitted = Completer<void>();
      final client = FakeLlmClient([
        _mutation('remember', 'old-unconfirmed', reasoning: _oldReasoning),
        (LlmRequest request) {
          expect(_wire(request), isNot(contains(_oldReasoning)));
          newToolEmitted.complete();
          return _mutation(
            'remember',
            'new-confirmed',
            reasoning: _newReasoning,
            text: freshText,
          );
        },
        (LlmRequest request) {
          expect(_feedback(request, 'new-confirmed')['ok'], isTrue);
          expect(_wire(request), isNot(contains(_oldReasoning)));
          expect(_wire(request), isNot(contains('old-unconfirmed')));
          expect(_wire(request), contains(_newReasoning));
          expect(_texts(store.entries), [_initialText, freshText]);
          return 'New memory saved.';
        },
      ], latency: Duration.zero);
      final a = agent(client, store);
      final oldTurn = a.send('Remember the old goal.');
      await _soon(lateSave.started.future);
      a.reset();
      expect((await _soon(oldTurn)).status, TurnStatus.cancelled);

      final newTurn = a.send('Remember the new goal.');
      await _soon(newToolEmitted.future);
      await Future<void>.delayed(Duration.zero);
      expect(client.requests, hasLength(2));
      expect(
        store.calls,
        1,
        reason: 'The new operation must wait behind the old in-flight save.',
      );
      lateSave.succeed();
      expect(_texts(await _soon(compensation.started.future)), [_initialText]);
      expect(client.requests, hasLength(2));
      compensation.succeed();
      expect(_texts(await _soon(freshSave.started.future)), [
        _initialText,
        freshText,
      ]);
      expect(
        client.requests,
        hasLength(2),
        reason: 'The new tool must await its own durable write.',
      );
      freshSave.succeed();
      expect((await _soon(newTurn)).status, TurnStatus.ok);
      expect(_texts(store.entries), [_initialText, freshText]);
      expect(_texts(await a.memory()), [_initialText, freshText]);
      final freshAgent = agent(FakeLlmClient(const []), store);
      expect(_texts(await freshAgent.memory()), [_initialText, freshText]);
    },
  );

  test(
    'a completed memory tool remains durable when later model inference is cancelled',
    () async {
      final save = _SaveAttempt();
      final store = _GatedMemoryStore([save]);
      final nextRequest = Completer<void>();
      final modelReply = Completer<Object>();
      final token = CancelToken();
      final client = FakeLlmClient([
        _mutation('remember', 'completed-memory'),
        (LlmRequest request) {
          expect(_feedback(request, 'completed-memory')['ok'], isTrue);
          nextRequest.complete();
          return modelReply.future;
        },
      ], latency: Duration.zero);
      final a = agent(client, store);
      final pending = a.send('Remember this.', cancel: token);
      await _soon(save.started.future);
      save.succeed();
      await _soon(nextRequest.future);
      token.cancel();
      expect((await _soon(pending)).status, TurnStatus.cancelled);
      expect(_texts(store.entries), [_initialText, _newText]);
      expect(_texts(await a.memory()), [_initialText, _newText]);
      modelReply.complete('A late response must not be committed.');
      await Future<void>.delayed(Duration.zero);
      expect(a.history, isEmpty);
    },
  );
}
