import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/append_only_context.dart';
import 'package:ugk_coach/src/agent/context_turn_ledger.dart';
import 'package:ugk_coach/ugk_coach.dart';

const _system = '稳定 system\n"角色与底线" 🧭';
const _tools = [
  LlmTool(
    name: 'search_actions',
    description: '稳定检索说明',
    parameters: {
      'type': 'object',
      'properties': {
        'keywords': {'type': 'string'},
      },
    },
  ),
  LlmTool(
    name: 'get_action',
    description: '稳定动作详情说明',
    parameters: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
      },
    },
  ),
];

// This fixed, test-only wire envelope measures UTF-8 JSON including tools.
// Production uses its client encoder; these tests never infer cache tokens.
int _encodedBytes(LlmRequest request) => utf8
    .encode(
      jsonEncode({
        'model': 'fixture',
        'tools': [for (final tool in request.tools) tool.toJson()],
        'messages': [for (final message in request.messages) message.toJson()],
        'tool_choice': request.toolChoice,
      }),
    )
    .length;
List<int> _messageBytes(LlmMessage message) =>
    utf8.encode(jsonEncode(message.toJson()));
List<Object?> _messages(Iterable<LlmMessage> messages) => [
  for (final message in messages) message.toJson(),
];
LlmMessage _state(String value) =>
    LlmMessage.system('${AppendOnlyContext.statePrefix}$value');
LlmMessage _assistant(String id, String reasoning) => LlmMessage.assistant(
  '完整工具说明 "$id"\n😀',
  reasoning: reasoning,
  toolCalls: [
    LlmToolCall(
      id: id,
      name: 'search_actions',
      arguments: jsonEncode({'keywords': '完整原参数 "$id"\n😀'}),
    ),
  ],
);

AppendOnlyContext _context({
  ContextBudgetConfig budget = const ContextBudgetConfig(),
  List<LlmMessage> seedMessages = const [],
  bool seedCoveredByLedger = false,
}) =>
    AppendOnlyContext(
      budget: budget,
      encodedBytes: _encodedBytes,
      measurement: 'test-only exact UTF-8 JSON envelope',
    )..activate(
      system: _system,
      tools: _tools,
      seedMessages: seedMessages,
      seedCoveredByLedger: seedCoveredByLedger,
    );

CompletedContextTurn _facts(int turn, String userText, String finalText) {
  final params = {
    'minutes': CoachParamValue(
      value: 15,
      source: 'derived',
      turn: turn,
      quote: '短一点\n"原文" 😀',
      direction: 'shorter',
      basedOn: CoachParamValue(
        value: 20,
        source: 'user',
        turn: turn - 1,
        quote: '20 分钟\n完整原话 🕑',
      ),
    ),
  };
  return CompletedContextTurn(
    turn: turn,
    userText: userText,
    finalDeliveryText: finalText,
    params: params,
    askQuestions: [
      {
        'question': '在哪里？\n"完整" 😀',
        'mode': 'form',
        'fields': [
          {
            'key': 'scene',
            'options': ['在家', '办公室'],
            'preselected': ['办公室'],
            'extra': {'preserve': true},
          },
        ],
      },
    ],
    answeredAsk: ContextAskReplyRef(
      questionTurn: turn - 1,
      answerJson: {
        'scene': ['办公室'],
        'literal': '选"办公室"\n😀',
      },
    ),
    task: CoachTaskState(
      type: 'plan',
      reused: true,
      nodes: [
        for (final id in [
          'understand',
          'parameters',
          'actions',
          'planning',
          'review',
          'output',
        ])
          CoachNodeState(
            id: id,
            status: 'done',
            stamp: '"$id"\n✅',
            doneAtTurn: turn,
          ),
      ],
    ),
    picks: ['b', 'a'],
    candidates: [
      for (var i = 0; i < 87; i++)
        [
          'a-$i',
          '名称 "$i"\n😀',
          'body.abs',
          'seconds',
          {
            'extra': ['完整字段', i],
          },
        ],
    ],
    deliveries: [
      ContextDeliveryRef(
        type: 'plan',
        planId: 'p',
        version: turn,
        actionIds: ['a', 'b'],
      ),
    ],
    currentPlanRef: ContextDeliveryRef(
      type: 'plan',
      planId: 'p',
      version: turn,
      actionIds: ['a', 'b'],
    ),
    loadedSkillNames: ['ask', 'action-library', 'plan-training'],
    seenActionIds: ['b', 'a', 'c'],
    outcome: 'completed',
  );
}

void main() {
  for (final thinking in [false, true]) {
    test(
      'below soft keeps system tools and sent journal byte prefix; thinking=$thinking',
      () {
        final context = _context();
        const user = LlmMessage.user('第一轮用户原话\n"别改" 😀');
        final current = <LlmMessage>[user];
        final first = context.compose(
          currentMessages: current,
          stateMessage: _state('snapshot-1'),
          ledger: ContextTurnLedger([]),
          thinking: thinking,
        );
        expect(first.diagnostics.folded, isFalse);
        expect(context.journal, isEmpty);
        final assistant = _assistant('first', '原始推理 "保留"\n🧠' * 48);
        final receipt = LlmMessage.tool(
          'first',
          jsonEncode({
            'ok': true,
            'items': [
              {'id': 'a', 'name': '原名'},
            ],
          }),
        );
        current.addAll([assistant, receipt]);
        final second = context.compose(
          currentMessages: current,
          stateMessage: _state('snapshot-2'),
          ledger: ContextTurnLedger([]),
          thinking: thinking,
        );
        final stablePrefix = first.request.messages.take(
          first.request.messages.length - 1,
        );
        expect(
          _messages(second.request.messages.take(stablePrefix.length)),
          _messages(stablePrefix),
        );
        expect(
          utf8.encode(
            jsonEncode(
              _messages(second.request.messages.take(stablePrefix.length)),
            ),
          ),
          utf8.encode(jsonEncode(_messages(stablePrefix))),
        );
        expect(
          jsonEncode(second.request.tools.map((t) => t.toJson()).toList()),
          jsonEncode(first.request.tools.map((t) => t.toJson()).toList()),
        );
        expect(second.request.messages.first.content, _system);
        expect(
          second.diagnostics.beforeBytes,
          lessThan(second.diagnostics.softLimitBytes),
        );
        expect(second.diagnostics.folded, isFalse);
        expect(
          _messageBytes(second.request.messages[2]),
          _messageBytes(assistant),
        );
        expect(
          second.request.messages.last.content,
          '${AppendOnlyContext.statePrefix}snapshot-2',
        );
        expect(
          first.request.messages.last.content,
          '${AppendOnlyContext.statePrefix}snapshot-1',
        );
        expect(context.journal, isEmpty);
        final finished = [
          ...current,
          const LlmMessage.assistant('最终交付\n"全文" ✅'),
        ];
        context.finishTurn(messages: finished);
        expect(_messages(context.journal), _messages(finished));
        final third = context.compose(
          currentMessages: const [LlmMessage.user('下一轮')],
          stateMessage: _state('snapshot-3'),
          ledger: ContextTurnLedger([
            _facts(1, user.content, finished.last.content),
          ]),
          thinking: thinking,
        );
        expect(third.diagnostics.folded, isFalse);
        expect(
          _messages(third.request.messages.skip(1).take(finished.length)),
          _messages(finished),
        );
        expect(
          context.journal.any(
            (m) => m.content.startsWith(AppendOnlyContext.statePrefix),
          ),
          isFalse,
        );
        expect(
          third.diagnostics.tailStateBytes,
          _messageBytes(third.request.messages.last).length,
        );
        expect(
          first.request.messages.first.toJson(),
          third.request.messages.first.toJson(),
        );
      },
    );
  }

  test(
    'soft folds only finished user turns into one user summary immediately after system',
    () {
      // A deliberately smaller soft boundary exercises the policy with compact
      // fixtures. The approved 64 KiB hard limit is unchanged in this test.
      const budget = ContextBudgetConfig(
        softOffBytes: 8000,
        softOnBytes: 10000,
      );
      final context = _context(budget: budget);
      const oldUser = '旧轮完整原话\n"不可省略" 😀';
      const finalText = '旧轮最终交付\n"完整说明" ✅';
      final ended = <LlmMessage>[
        const LlmMessage.user(oldUser),
        _assistant('old-search', '允许整轮替换的旧推理\n' * 512),
        LlmMessage.tool(
          'old-search',
          jsonEncode({'ok': true, 'raw': '旧回执正文\n' * 4096}),
        ),
        const LlmMessage.assistant(finalText),
      ];
      context.finishTurn(messages: ended);
      final facts = _facts(1, oldUser, finalText);
      final ledger = ContextTurnLedger([facts]);
      final ledgerBefore = ledger.toJson();
      final state = CoachSessionState(
        params: facts.params,
        task: facts.task,
        picks: facts.picks,
        seenActionIds: facts.seenActionIds.toSet(),
      );
      final stateBefore = state.toJson();
      final current = <LlmMessage>[
        const LlmMessage.user('本轮完整用户消息\n😀'),
        _assistant('current-search', '本轮原始推理 "不能改"\n🧠' * 128),
        const LlmMessage.tool(
          'current-search',
          '{"ok":true,"items":[{"id":"current"}]}',
        ),
      ];
      final currentBefore = _messages(current);
      final tail = _state(jsonEncode(state.toJson()));
      final prepared = context.compose(
        currentMessages: current,
        stateMessage: tail,
        ledger: ledger,
        thinking: false,
      );
      expect(
        prepared.diagnostics.beforeBytes,
        greaterThan(budget.softOffBytes),
      );
      expect(prepared.diagnostics.completedTurnsFolded, 1);
      expect(prepared.diagnostics.receiptBodiesFolded, 0);
      expect(
        prepared.diagnostics.afterBytes,
        lessThan(prepared.diagnostics.beforeBytes),
      );
      expect(prepared.diagnostics.fitsHardLimit, isTrue);
      final messages = prepared.request.messages;
      expect(messages[0].role, LlmRole.system);
      expect(messages[1].role, LlmRole.user);
      expect(messages[1].content, ledger.summaryMessage().content);
      expect(
        messages.where(
          (m) => m.content.startsWith(ContextTurnLedger.summaryPrefix),
        ),
        hasLength(1),
      );
      expect(
        messages
            .take(1)
            .any((m) => {LlmRole.assistant, LlmRole.tool}.contains(m.role)),
        isFalse,
      );
      expect(_messages(messages.skip(2).take(current.length)), currentBefore);
      for (var i = 0; i < current.length; i++) {
        expect(_messageBytes(messages[i + 2]), _messageBytes(current[i]));
      }
      final summary =
          jsonDecode(
                messages[1].content.substring(
                  ContextTurnLedger.summaryPrefix.length + 1,
                ),
              )
              as Map<String, dynamic>;
      expect(summary, ledgerBefore);
      final recorded = (summary['turns'] as List).single as Map;
      expect(recorded['userText'], oldUser);
      expect(recorded['finalDeliveryText'], finalText);
      expect(recorded['params'], facts.toJson()['params']);
      expect(recorded['askQuestions'], facts.toJson()['askQuestions']);
      expect(recorded['candidates'], hasLength(87));
      expect(recorded['candidates'], facts.toJson()['candidates']);
      expect(messages.last, same(tail));
      expect(_messages(current), currentBefore);
      expect(ledger.toJson(), ledgerBefore);
      expect(state.toJson(), stateBefore);
      expect(
        context.journal.any(
          (m) => m.content.startsWith(AppendOnlyContext.statePrefix),
        ),
        isFalse,
      );
    },
  );

  test(
    'over soft with no finished turn never folds a current user tool batch',
    () {
      const budget = ContextBudgetConfig(softOffBytes: 1000, softOnBytes: 2000);
      final context = _context(budget: budget);
      final current = <LlmMessage>[
        const LlmMessage.user('仍在本轮'),
        _assistant('active', '本轮思考 "保持原样" 🧠\n' * 512),
        const LlmMessage.tool('active', '{"ok":true}'),
      ];
      final before = _messages(current);
      final prepared = context.compose(
        currentMessages: current,
        stateMessage: _state('latest'),
        ledger: ContextTurnLedger([]),
        thinking: true,
      );
      expect(prepared.diagnostics.beforeBytes, greaterThan(budget.softOnBytes));
      expect(prepared.diagnostics.beforeBytes, lessThan(budget.hardBytes));
      expect(prepared.diagnostics.folded, isFalse);
      expect(prepared.diagnostics.afterBytes, prepared.diagnostics.beforeBytes);
      expect(
        _messages(prepared.request.messages.skip(1).take(current.length)),
        before,
      );
      expect(context.journal, isEmpty);
    },
  );

  test(
    'hard archives only explicitly consumed receipt bodies and preserves every assistant byte',
    () {
      // All pressures here use the approved default 65,536-byte hard boundary.
      // Reasoning fixtures are fixed; no threshold is raised to obtain a fit.
      const budget = ContextBudgetConfig();
      final context = _context();
      final oldAssistant = _assistant(
        'old',
        'first reasoning "keep" 😀\n' * 256,
      );
      final oldReceipt = LlmMessage.tool(
        'old',
        jsonEncode({
          'ok': true,
          'items': [
            {'id': 'a', 'name': 'old action'},
          ],
          'detail': 'row old 0123456789 😀\n' * 1536,
        }),
      );
      final initial = <LlmMessage>[
        const LlmMessage.user('同一轮用户请求'),
        oldAssistant,
        oldReceipt,
      ];
      final first = context.compose(
        currentMessages: initial,
        stateMessage: _state('before'),
        ledger: ContextTurnLedger([]),
        thinking: true,
      );
      expect(first.diagnostics.fitsHardLimit, isTrue);
      expect(first.diagnostics.beforeBytes, lessThan(budget.hardBytes));
      final nextAssistant = _assistant(
        'fresh',
        'second reasoning "keep" 🧠\n' * 256,
      );
      final freshReceipt = LlmMessage.tool(
        'fresh',
        jsonEncode({'ok': true, 'detail': 'new MUST STAY 😀\n' * 1024}),
      );
      final current = [...initial, nextAssistant, freshReceipt];
      final rawBefore = _messages(current);
      final notConsumed = context.compose(
        currentMessages: current,
        stateMessage: _state('after'),
        ledger: ContextTurnLedger([]),
        thinking: true,
      );
      expect(
        notConsumed.diagnostics.beforeBytes,
        greaterThan(budget.hardBytes),
      );
      expect(
        notConsumed.diagnostics.receiptBodiesFolded,
        0,
        reason:
            'preparing a request and seeing a later assistant are not consumption evidence',
      );
      expect(notConsumed.diagnostics.fitsHardLimit, isFalse);
      expect(
        _messages(notConsumed.request.messages.skip(1).take(current.length)),
        rawBefore,
      );
      context.markConsumed(first.request);
      final prepared = context.compose(
        currentMessages: current,
        stateMessage: _state('after'),
        ledger: ContextTurnLedger([]),
        thinking: true,
      );
      expect(prepared.diagnostics.receiptBodiesFolded, 1);
      expect(prepared.diagnostics.completedTurnsFolded, 0);
      expect(
        prepared.diagnostics.afterBytes,
        lessThanOrEqualTo(budget.hardBytes),
      );
      expect(prepared.diagnostics.fitsHardLimit, isTrue);
      final sent = prepared.request.messages
          .skip(1)
          .take(current.length)
          .toList();
      for (var i = 0; i < current.length; i++) {
        if (identical(current[i], oldReceipt)) {
          expect(sent[i].role, LlmRole.tool);
          expect(sent[i].toolCallId, oldReceipt.toolCallId);
          expect(sent[i].content, isNot(oldReceipt.content));
        } else {
          expect(_messageBytes(sent[i]), _messageBytes(current[i]));
        }
      }
      expect(_messages(current), rawBefore);
      expect(
        utf8.encode(sent[1].reasoning!),
        utf8.encode(oldAssistant.reasoning!),
      );
      expect(
        utf8.encode(sent[3].reasoning!),
        utf8.encode(nextAssistant.reasoning!),
      );
      expect(sent[4].content, freshReceipt.content);
      expect(context.journal, isEmpty);
    },
  );

  test(
    'reasoning alone above hard cannot be silently removed to claim a fit',
    () {
      final context = _context();
      final reasoning = '不可裁剪的当前推理 "原文" 🧠\n' * 4096;
      final current = [
        const LlmMessage.user('完整当前用户消息'),
        LlmMessage.assistant('仍在同一用户轮', reasoning: reasoning),
      ];
      final prepared = context.compose(
        currentMessages: current,
        stateMessage: _state('unchanged'),
        ledger: ContextTurnLedger([]),
        thinking: true,
      );
      expect(
        utf8.encode(reasoning).length,
        greaterThan(const ContextBudgetConfig().hardBytes),
      );
      expect(prepared.diagnostics.fitsHardLimit, isFalse);
      expect(prepared.diagnostics.folded, isFalse);
      expect(prepared.diagnostics.afterBytes, prepared.diagnostics.beforeBytes);
      expect(
        _messages(prepared.request.messages.skip(1).take(current.length)),
        _messages(current),
      );
      expect(
        utf8.encode(prepared.request.messages[2].reasoning!),
        utf8.encode(reasoning),
      );
    },
  );

  test(
    'soft folding includes caller-identified completed seed turns before its sole summary',
    () {
      const budget = ContextBudgetConfig(
        softOffBytes: 8000,
        softOnBytes: 10000,
      );
      final seed = <LlmMessage>[
        const LlmMessage.user('已结束种子轮'),
        _assistant('seed', '完整种子推理\n' * 256),
        LlmMessage.tool(
          'seed',
          jsonEncode({'ok': true, 'detail': '种子回执\n' * 2048}),
        ),
        const LlmMessage.assistant('种子最终交付'),
      ];
      final context = _context(
        budget: budget,
        seedMessages: seed,
        seedCoveredByLedger: true,
      );
      context.finishTurn(
        messages: const [
          LlmMessage.user('另一完整结束轮'),
          LlmMessage.assistant('第二轮最终交付'),
        ],
      );
      final ledger = ContextTurnLedger([
        _facts(1, '已结束种子轮', '种子最终交付'),
        _facts(2, '另一完整结束轮', '第二轮最终交付'),
      ]);
      final prepared = context.compose(
        currentMessages: const [LlmMessage.user('当前轮')],
        stateMessage: _state('tail'),
        ledger: ledger,
        thinking: false,
      );
      expect(prepared.diagnostics.folded, isTrue);
      expect(prepared.request.messages[1].role, LlmRole.user);
      expect(
        prepared.request.messages[1].content,
        ledger.summaryMessage().content,
      );
      expect(prepared.request.messages[2].content, '当前轮');
      expect(
        prepared.request.messages.where((m) => m.role == LlmRole.tool),
        isEmpty,
      );
    },
  );

  test('a complete covered seed can fold without a newly finished turn', () {
    const budget = ContextBudgetConfig(softOffBytes: 8000, softOnBytes: 10000);
    final seed = <LlmMessage>[
      const LlmMessage.user('完整恢复轮原话'),
      _assistant('restored', '恢复轮原始推理\n' * 512),
      LlmMessage.tool(
        'restored',
        jsonEncode({'ok': true, 'detail': '完整回执\n' * 2048}),
      ),
      const LlmMessage.assistant('恢复轮最终交付'),
    ];
    final context = _context(
      budget: budget,
      seedMessages: seed,
      seedCoveredByLedger: true,
    );
    final ledger = ContextTurnLedger([_facts(1, '完整恢复轮原话', '恢复轮最终交付')]);
    final prepared = context.compose(
      currentMessages: const [LlmMessage.user('本轮')],
      stateMessage: _state('tail'),
      ledger: ledger,
      thinking: false,
    );
    expect(prepared.diagnostics.completedTurnsFolded, 1);
    expect(
      prepared.request.messages[1].content,
      ledger.summaryMessage().content,
    );
    expect(prepared.request.messages[2].content, '本轮');
    expect(prepared.request.messages, hasLength(4));
  });

  test(
    'legacy seed without ledger coverage is retained after the sole summary',
    () {
      const budget = ContextBudgetConfig(
        softOffBytes: 8000,
        softOnBytes: 10000,
      );
      final seed = <LlmMessage>[
        const LlmMessage.user('旧快照原话\n"不能丢" 😀'),
        _assistant('legacy', '旧快照推理\n' * 256),
        LlmMessage.tool(
          'legacy',
          jsonEncode({'ok': true, 'detail': '旧快照工具正文\n' * 1024}),
        ),
        const LlmMessage.assistant('旧快照完整最终交付'),
      ];
      final context = _context(budget: budget, seedMessages: seed);
      context.finishTurn(
        messages: const [
          LlmMessage.user('新的已结束轮'),
          LlmMessage.assistant('新轮交付'),
        ],
      );
      final ledger = ContextTurnLedger([_facts(2, '新的已结束轮', '新轮交付')]);
      final prepared = context.compose(
        currentMessages: const [LlmMessage.user('本轮')],
        stateMessage: _state('tail'),
        ledger: ledger,
        thinking: false,
      );
      expect(prepared.diagnostics.completedTurnsFolded, 1);
      expect(
        prepared.request.messages[1].content,
        ledger.summaryMessage().content,
      );
      final retained = prepared.request.messages
          .skip(2)
          .take(seed.length)
          .toList();
      for (var i = 0; i < seed.length; i++) {
        expect(_messageBytes(retained[i]), _messageBytes(seed[i]));
      }
      expect(prepared.request.messages[2 + seed.length].content, '本轮');
      expect(
        prepared.request.messages.where(
          (m) => m.content.startsWith(ContextTurnLedger.summaryPrefix),
        ),
        hasLength(1),
      );
    },
  );
}
