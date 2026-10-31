import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

const _sf = 'test/fixtures/fit-feasible-range/smartfit';
const _hip = 'packages/ugk_trainer/test/fixtures/hiplab/fit-all-blocks';

Map<String, dynamic> _json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

LlmResponse _calls(List<LlmToolCall> calls) => LlmResponse(
  content: '',
  toolCalls: calls,
  finishReason: 'tool_calls',
  model: 'offline-recorded-with-synthetic-repair',
);

LlmToolCall _call(String id, String name, Object args) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(args));

Map<String, dynamic> _receipt(LlmRequest request, String id) =>
    jsonDecode(request.messages.lastWhere((m) => m.toolCallId == id).content)
        as Map<String, dynamic>;

class _OfflineOnly extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('Network disabled in captured duration regression.');
}

void _saveMeasured(String name, double seconds) {
  final file = File('build/fit-feasible-range/replay-card-seconds.json');
  file.parent.createSync(recursive: true);
  final values = file.existsSync() ? _json(file.path) : <String, dynamic>{};
  values[name] = seconds;
  file.writeAsStringSync('${jsonEncode(values)}\n');
}

void main() {
  setUp(() {
    final previous = HttpOverrides.current;
    HttpOverrides.global = _OfflineOnly();
    addTearDown(() => HttpOverrides.global = previous);
  });

  test('SF fixture preserves the original protocol and 336/14044 range', () {
    final manifest = _json('$_sf/manifest.json');
    final files = manifest['files'] as Map;
    for (final entry in files.entries) {
      expect(
        sha256.convert(File('$_sf/${entry.key}').readAsBytesSync()).toString(),
        entry.value,
        reason: 'Frozen fixture bytes changed: ${entry.key}',
      );
    }
    final input = _json('$_sf/input.json');
    expect(
      input['baselineSdkCommit'],
      '99c14495685f160019e10340ea6f0de6418a65b9',
    );
    final receipt = _json('$_sf/baseline-receipt.json');
    expect(receipt['asked'], isTrue);
    final bounds = receipt['feasibility'] as Map<String, dynamic>;
    expect(bounds['minEstimatedSec'], 336);
    expect(bounds['maxEstimatedSec'], 14044);
    final state = CoachSessionState.fromJson(
      _json('$_sf/pre-draft-state.json'),
    );
    expect(state.params.containsKey('dose'), isFalse);
    expect(state.seenActionIds, hasLength(32));
    final catalog = Catalog.fromJson(_json('$_sf/catalog.json'));
    expect(catalog.problems, isEmpty);
    expect(catalog.ids.toSet(), state.seenActionIds);
    expect(catalog['h-chair-sit-to-stand']!.doseRange.sets!.min, 3);
    expect(catalog['h-chair-sit-to-stand']!.doseRange.reps!.min, 12);
    expect(catalog['h-chair-sit-to-stand']!.doseRange.restSeconds!.min, 30);
  });

  test(
    'SF original three batches continue to an accepted five-minute card',
    () async {
      final input = _json('$_sf/input.json');
      final catalog = Catalog.fromJson(_json('$_sf/catalog.json'));
      final profile = CoachProfile.fromJson(_json('$_sf/profile.json'));
      final batches =
          jsonDecode(File('$_sf/recorded-tool-batches.json').readAsStringSync())
              as List;
      final draft = _json('$_sf/original-draft-arguments.json');
      final recordedDraftId =
          ((batches.last as List).single as Map)['id'] as String;
      final originalIds = (input['selectedIds'] as List).cast<String>();
      final recorded = <LlmResponse>[
        for (final batch in batches)
          _calls([
            for (final value in batch as List)
              LlmToolCall(
                id: (value as Map)['id'] as String,
                name: value['name'] as String,
                arguments: value['arguments'] as String,
              ),
          ]),
      ];
      var sawRepairReceipt = false;
      final client = FakeLlmClient([
        ...recorded,
        (LlmRequest request) {
          final failure = _receipt(request, recordedDraftId);
          expect(failure['code'], 'duration_fit_failed', reason: '$failure');
          expect(failure['minEstimatedSec'], 336);
          expect(failure['maxEstimatedSec'], 14044);
          expect(failure['direction'], 'remove_action');
          expect(failure['clarificationAllowed'], isFalse);
          final candidates = (failure['removeCandidates'] as List)
              .cast<Map<String, dynamic>>();
          expect(
            candidates.map((c) => c['actionId']),
            contains('h-chair-sit-to-stand'),
          );
          sawRepairReceipt = true;
          // This is deliberately a synthetic model continuation. The original
          // real capture ended at the preceding clarification, not at this plan.
          return _calls([
            _call('sf-repair-draft', AgentTools.draftPlan, {
              ...draft,
              'blocks': [
                for (final block
                    in (draft['blocks'] as List).cast<Map<String, dynamic>>())
                  if ((block['items'] as List).any(
                    (item) => (item as Map)['id'] != 'h-chair-sit-to-stand',
                  ))
                    {
                      ...block,
                      'items': [
                        for (final item in block['items'] as List)
                          if ((item as Map)['id'] != 'h-chair-sit-to-stand')
                            item,
                      ],
                    },
              ],
            }),
          ]);
        },
        (LlmRequest request) {
          final receipt = _receipt(request, 'sf-repair-draft');
          expect(receipt['ok'], isTrue, reason: '$receipt');
          expect(receipt['withinTolerance'], isTrue);
          return _calls([
            _call('sf-repair-show', CoachTools.showPlan, {
              'plan_id': receipt['plan_id'],
              'note': '在舒适范围内完成。',
            }),
          ]);
        },
      ], latency: Duration.zero);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      final result = await agent.send(input['userText'] as String);
      expect(
        result.status,
        TurnStatus.ok,
        reason: '${result.error}; ${result.issues}',
      );
      expect(result.question, isNull);
      expect(sawRepairReceipt, isTrue);
      expect(result.plan, isNotNull, reason: '${result.issues}');
      expect(client.requests, hasLength(5));
      final plan = result.plan!.plan;
      expect(
        plan.items.map((i) => i.exerciseId),
        originalIds.where((id) => id != 'h-chair-sit-to-stand'),
      );
      final seconds = const PlanDuration().estimateSeconds(plan, catalog);
      expect(seconds, inInclusiveRange(270, 330));
      expect(agent.questionsAsked, 0);
      expect(agent.sessionState.plans[plan.id], hasLength(1));
      _saveMeasured('smartfit', seconds);
    },
  );

  test(
    'HipLab third-turn fixture still delivers its compliant replacement',
    () async {
      final catalog = Catalog.fromJson(_json('$_hip/catalog.json'));
      final profile = CoachProfile.fromJson(_json('$_hip/profile.json'));
      final state = CoachSessionState.fromJson(
        _json('$_hip/state-before-reconstructed.json'),
      );
      final sourcePlanId = state.activePlanId!;
      final preservedV1 = state.plans[sourcePlanId]!.single.toJson();
      final text = state.userTurns.last.text;
      final args = _json('$_hip/draft-arguments.json');
      final client = FakeLlmClient([
        _calls([
          _call('hip-replacement-confirmed', AgentTools.setParams, {
            'fields': {
              'operation': {
                'value': 'replace_all',
                'source': 'user',
                'quote': text,
              },
            },
          }),
          _call('hip-third-draft', AgentTools.draftPlan, args),
        ]),
        (LlmRequest request) {
          final receipt = _receipt(request, 'hip-third-draft');
          expect(receipt['ok'], isTrue, reason: '$receipt');
          expect(receipt['withinTolerance'], isTrue);
          expect(receipt['version'], 2);
          return _calls([
            _call('hip-third-show', CoachTools.showPlan, {
              'plan_id': receipt['plan_id'],
              'note': '轻柔完成，量力而行。',
            }),
          ]);
        },
      ], latency: Duration.zero);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      expect(
        agent.restoreSessionSnapshot(
          CoachSessionSnapshot(
            sessionState: state,
            ledger: state.completedContextLedger == null
                ? ContextTurnLedger(const [])
                : ContextTurnLedger.fromJson(state.completedContextLedger!),
          ),
        ),
        isTrue,
      );
      final result = await agent.send(text);
      expect(
        result.status,
        TurnStatus.ok,
        reason: '${result.error}; ${result.issues}',
      );
      expect(result.question, isNull);
      expect(result.plan, isNotNull, reason: '${result.issues}');
      expect(result.plan!.version, 2);
      expect(result.plan!.plan.id, sourcePlanId);
      expect(
        agent.sessionState.plans[sourcePlanId]!.first.toJson(),
        preservedV1,
      );
      expect(agent.sessionState.plans[sourcePlanId], hasLength(2));
      final plan = result.plan!.plan;
      final seconds = const PlanDuration().estimateSeconds(plan, catalog);
      expect(seconds, inInclusiveRange(270, 330));
      expect(plan.items.map((i) => i.exerciseId), [
        for (final block in args['blocks'] as List)
          for (final item in (block as Map)['items'] as List)
            (item as Map)['id'],
      ]);
      _saveMeasured('hiplab', seconds);
    },
  );
}
