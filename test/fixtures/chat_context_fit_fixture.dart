import 'dart:convert';

import 'package:ugk_coach/ugk_coach.dart';

/// Structural regression only. The supplied runtime export contains event
/// metadata, not request bodies or a session snapshot. All text below is new,
/// impersonal fixture text; its byte counts are not phone measurements.
class ChatContextFitFixture {
  ChatContextFitFixture(this.catalog, this.profile);

  final Catalog catalog;
  final CoachProfile profile;

  List<String> get ids => catalog.drills.take(24).map((d) => d.id).toList();

  String user(int turn) => '第 $turn 轮：请说明这些动作的练习要点。';
  String answer(int turn) => '第 $turn 轮说明：动作放缓，保持自然呼吸，以舒适范围为准。';

  CompletedContextTurn facts(int turn) => CompletedContextTurn(
    turn: turn,
    userText: user(turn),
    finalDeliveryText: answer(turn),
    params: {
      'scene': CoachParamValue(
        value: 'home',
        source: 'user',
        quote: '在家',
        turn: 1,
      ),
      'equipment': CoachParamValue(
        value: <String>[],
        source: 'user',
        quote: '徒手',
        turn: 1,
      ),
      'minutes': CoachParamValue(
        value: 5,
        source: 'user',
        quote: '5 分钟',
        turn: 1,
      ),
      'goal': CoachParamValue(
        value: ['body.core'],
        source: 'user',
        quote: '活动身体',
        turn: 1,
      ),
      'level': CoachParamValue(value: 1, source: 'default', turn: 1),
      'limits': CoachParamValue(value: <String>[], source: 'default', turn: 1),
    },
    task: CoachTaskState(
      type: 'recommend',
      nodes: [
        for (final id in ['understand', 'parameters', 'actions', 'output'])
          CoachNodeState(
            id: id,
            status: 'done',
            stamp: '$id-$turn',
            doneAtTurn: turn,
          ),
      ],
      reused: turn > 1,
    ),
    picks: ids.take(3).toList(),
    candidates: [
      for (final id in ids)
        [id, catalog[id]!.name.of('zh'), 'body.core', 'seconds', 1],
    ],
    seenActionIds: ids,
    deliveries: [
      ContextDeliveryRef(type: 'actions', actionIds: ids.take(3).toList()),
    ],
    loadedSkillNames: const ['action-library', 'action-coaching'],
    outcome: 'completed',
  );

  CoachSessionState state(List<CompletedContextTurn> turns) {
    final last = turns.lastOrNull;
    return CoachSessionState(
      userTurns: [
        for (final turn in turns)
          CoachUserTurn(turn: turn.turn, text: turn.userText),
      ],
      params: last?.params ?? const {},
      task: last?.task,
      picks: last?.picks ?? const [],
      seenActionIds: last?.seenActionIds.toSet() ?? const {},
      completedContextLedger: ContextTurnLedger(turns).toJson(),
    );
  }

  List<LlmMessage> legacySeed() => [
    for (var turn = 1; turn <= 25; turn++) ...[
      LlmMessage.user(user(turn)),
      LlmMessage.assistant('$turn：${'这是旧档中的普通动作讲解，保持自然呼吸，以舒适范围为准。' * 60}'),
    ],
  ];

  List<LlmMessage> completedMessages(int turn) => [
    LlmMessage.user(user(turn)),
    LlmMessage.assistant(
      '',
      reasoning: '沿用已经确认的场景和器材，检索目录中的合法动作。',
      toolCalls: [
        LlmToolCall(
          id: 'search-$turn',
          name: 'search_actions',
          arguments: '{"limit":24}',
        ),
      ],
    ),
    LlmMessage.tool(
      'search-$turn',
      // Real tool receipts include catalogue rows. Their repeated appearance
      // exerts ordinary multi-turn pressure, without any giant user input.
      catalogReceipt(),
    ),
    LlmMessage.assistant(answer(turn)),
  ];

  String catalogReceipt() => jsonEncode({
    'ok': true,
    'items': [
      for (final id in ids)
        {
          'id': id,
          'name': catalog[id]!.name.of('zh'),
          'doseMode': 'seconds',
          'level': 1,
          'note': '按照舒适范围练习，保持自然呼吸。',
        },
    ],
  });
}
