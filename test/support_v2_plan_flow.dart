// Scripted model protocol over a real Agent and local catalogue.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

class ScriptedV2PlanFlow {
  ScriptedV2PlanFlow(this.catalog);
  final Catalog catalog;
  String? planId;
  static const ids = [
    's-kneel-hipflex',
    'n-thomas-test',
    's-butterfly',
    'h-bilateral-upper-back-hug',
  ];

  LlmToolCall _tool(String id, String name, Object arguments) =>
      LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments));
  LlmResponse _calls(List<LlmToolCall> values, {String content = ''}) =>
      LlmResponse(
        content: content,
        toolCalls: values,
        finishReason: 'tool_calls',
        model: 'fake',
      );
  Map<String, dynamic> _response(LlmRequest request, String id) =>
      jsonDecode(
            request.messages
                .singleWhere((message) => message.toolCallId == id)
                .content,
          )
          as Map<String, dynamic>;

  /// The caller's user message must include each literal quotation below.
  List<Object> initial({
    String note = '量力而行。',
    String modelContent = '',
    List<String>? mainActions,
  }) {
    final main = mainActions ?? ids.take(3).toList();
    final selected = [...main, ids.last];
    return [
      _calls([
        _tool('start', AgentTools.startTask, {'type': 'plan'}),
        _tool('understand', AgentTools.check, {'node': 'understand'}),
        _tool('parameters-set', AgentTools.setParams, {
          'fields': {
            'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
            'equipment': {
              'value': ['equip.mat'],
              'source': 'user',
              'quote': '瑜伽垫',
            },
            'minutes': {'value': 10, 'source': 'user', 'quote': '10分钟'},
            'goal': {
              'value': ['body.hip_flexors', 'purpose.stretch'],
              'source': 'user',
              'quote': '髋部放松',
            },
          },
        }),
        _tool('parameters-check', AgentTools.check, {'node': 'parameters'}),
        for (var i = 0; i < selected.length; i++)
          _tool('search-$i', AgentTools.searchActions, {
            'tags': <String>[],
            'keywords': catalog[selected[i]]!.name.of('en'),
          }),
      ]),
      (LlmRequest request) {
        expect(_response(request, 'parameters-set')['ok'], isTrue);
        for (var i = 0; i < selected.length; i++) {
          final result = _response(request, 'search-$i');
          expect(result['ok'], isTrue, reason: '$result');
          expect(
            (result['items'] as List).map((item) => (item as Map)['id']),
            contains(selected[i]),
          );
        }
        return _calls([
          _tool('actions-check', AgentTools.check, {
            'node': 'actions',
            'picks': selected,
          }),
          _tool('draft', AgentTools.draftPlan, {
            'title': '髋部放松',
            'blocks': [
              {
                'kind': 'main',
                'items': [
                  for (final id in main) {'id': id},
                ],
              },
              {
                'kind': 'cooldown',
                'items': [
                  {'id': ids.last},
                ],
              },
            ],
          }),
        ]);
      },
      (LlmRequest request) {
        final draft = _response(request, 'draft');
        expect(draft['ok'], isTrue, reason: '$draft');
        planId = draft['plan_id'] as String;
        return _calls([
          _tool('planning-check', AgentTools.check, {'node': 'planning'}),
          _tool('plan-check', AgentTools.checkPlan, {'plan_id': planId}),
        ]);
      },
      (LlmRequest request) {
        final checked = _response(request, 'plan-check');
        expect(checked['ok'], isTrue, reason: '$checked');
        return _calls([
          _tool('review-check', AgentTools.check, {'node': 'review'}),
          _tool('show-plan', AgentTools.showPlan, {
            'plan_id': planId,
            'note': note,
          }),
        ], content: modelContent);
      },
    ];
  }

  List<Object> changeMinutes(int minutes, String quote, {String? direction}) =>
      [
        _calls([
          _tool('new-minutes', AgentTools.setParams, {
            'fields': {
              'minutes': {
                'value': minutes,
                'source': direction == null ? 'user' : 'derived',
                'quote': quote,
                'direction': ?direction,
              },
            },
          }),
        ]),
        (LlmRequest request) {
          expect(_response(request, 'new-minutes')['ok'], isTrue);
          return _calls([
            _tool('new-draft', AgentTools.draftPlan, {
              'plan_id': planId,
              'operation': 'edit',
              'title': '髋部放松',
              'blocks': [
                {
                  'kind': 'main',
                  'items': [
                    for (final id in ids.take(3)) {'id': id},
                  ],
                },
                {
                  'kind': 'cooldown',
                  'items': [
                    {'id': ids.last},
                  ],
                },
              ],
            }),
          ]);
        },
        (LlmRequest request) {
          final draft = _response(request, 'new-draft');
          expect(draft['ok'], isTrue, reason: '$draft');
          expect(draft['version'], greaterThanOrEqualTo(2));
          return _calls([
            _tool('new-planning', AgentTools.check, {'node': 'planning'}),
            _tool('new-plan-check', AgentTools.checkPlan, {'plan_id': planId}),
          ]);
        },
        (LlmRequest request) {
          final checked = _response(request, 'new-plan-check');
          expect(checked['ok'], isTrue, reason: '$checked');
          return _calls([
            _tool('new-review', AgentTools.check, {'node': 'review'}),
            _tool('new-show', AgentTools.showPlan, {
              'plan_id': planId,
              'note': '按新时长安排。',
            }),
          ]);
        },
      ];

  List<Object> changeToBodyweight({bool office = false}) {
    const actions = [
      'n-pelvis-circle',
      'o-stand-sidebend',
      'h-bilateral-upper-back-hug',
    ];
    return [
      _calls([
        _tool('new-equipment', AgentTools.setParams, {
          'fields': {
            if (office)
              'scene': {'value': 'office', 'source': 'user', 'quote': '办公室'},
            'equipment': {'value': <String>[], 'source': 'user', 'quote': '徒手'},
          },
        }),
      ]),
      (LlmRequest request) {
        expect(_response(request, 'new-equipment')['ok'], isTrue);
        return _calls([
          for (var i = 0; i < actions.length; i++)
            _tool('body-search-$i', AgentTools.searchActions, {
              'tags': <String>[],
              'keywords': catalog[actions[i]]!.name.of('en'),
            }),
          _tool('body-actions', AgentTools.check, {
            'node': 'actions',
            'picks': actions,
          }),
          _tool('body-draft', AgentTools.draftPlan, {
            'plan_id': planId,
            'operation': 'edit',
            'title': '居家徒手放松',
            'blocks': [
              {
                'kind': 'main',
                'items': [
                  for (final id in actions.take(2)) {'id': id},
                ],
              },
              {
                'kind': 'cooldown',
                'items': [
                  {'id': actions.last},
                ],
              },
            ],
          }),
        ]);
      },
      (LlmRequest request) {
        expect(_response(request, 'body-actions')['ok'], isTrue);
        final draft = _response(request, 'body-draft');
        expect(draft['ok'], isTrue, reason: '$draft');
        return _calls([
          _tool('body-planning', AgentTools.check, {'node': 'planning'}),
          _tool('body-plan-check', AgentTools.checkPlan, {'plan_id': planId}),
        ]);
      },
      (LlmRequest request) {
        final checked = _response(request, 'body-plan-check');
        expect(checked['ok'], isTrue, reason: '$checked');
        return _calls([
          _tool('body-review', AgentTools.check, {'node': 'review'}),
          _tool('body-show', AgentTools.showPlan, {
            'plan_id': planId,
            'note': '按徒手条件安排。',
          }),
        ]);
      },
    ];
  }

  /// Rebuild a task after a pre-v2 card, without inventing completed nodes.
  /// When there is no prior user message, the goal is explicitly a default.
  List<Object> legacyEdit({
    int? minutes,
    bool bodyweight = false,
    bool hasGoalQuote = true,
  }) {
    final actions = bodyweight
        ? ['n-pelvis-circle', 'o-stand-sidebend', 'h-bilateral-upper-back-hug']
        : ids;
    return [
      _calls([
        _tool('legacy-start', AgentTools.startTask, {'type': 'plan'}),
        _tool('legacy-understand', AgentTools.check, {'node': 'understand'}),
        _tool('legacy-params', AgentTools.setParams, {
          'fields': {
            'goal': {
              'value': ['body.hip_flexors', 'purpose.stretch'],
              'source': hasGoalQuote ? 'user' : 'default',
              if (hasGoalQuote) 'quote': '髋部放松',
            },
            if (minutes != null)
              'minutes': {
                'value': minutes,
                'source': 'user',
                'quote': '$minutes 分钟',
              },
            if (bodyweight)
              'equipment': {
                'value': <String>[],
                'source': 'user',
                'quote': '徒手',
              },
          },
        }),
        _tool('legacy-parameters', AgentTools.check, {'node': 'parameters'}),
        for (var i = 0; i < actions.length; i++)
          _tool('legacy-search-$i', AgentTools.searchActions, {
            'tags': <String>[],
            'keywords': catalog[actions[i]]!.name.of('en'),
          }),
      ]),
      (LlmRequest request) {
        for (final id in [
          'legacy-start',
          'legacy-understand',
          'legacy-params',
          'legacy-parameters',
        ]) {
          final result = _response(request, id);
          expect(result['ok'], isTrue, reason: '$id: $result');
        }
        return _calls([
          _tool('legacy-actions', AgentTools.check, {
            'node': 'actions',
            'picks': actions,
          }),
          _tool('legacy-draft', AgentTools.draftPlan, {
            'plan_id': planId,
            'operation': 'edit',
            'title': '髋部放松',
            'blocks': [
              {
                'kind': 'main',
                'items': [
                  for (final id in actions.take(actions.length - 1)) {'id': id},
                ],
              },
              {
                'kind': 'cooldown',
                'items': [
                  {'id': actions.last},
                ],
              },
            ],
          }),
        ]);
      },
      (LlmRequest request) {
        expect(_response(request, 'legacy-actions')['ok'], isTrue);
        final draft = _response(request, 'legacy-draft');
        expect(draft['ok'], isTrue, reason: '$draft');
        expect(draft['plan_id'], planId);
        expect(draft['version'], 2);
        return _calls([
          _tool('legacy-planning', AgentTools.check, {'node': 'planning'}),
          _tool('legacy-plan-check', AgentTools.checkPlan, {'plan_id': planId}),
        ]);
      },
      (LlmRequest request) {
        final checked = _response(request, 'legacy-plan-check');
        expect(checked['ok'], isTrue, reason: '$checked');
        return _calls([
          _tool('legacy-review', AgentTools.check, {'node': 'review'}),
          _tool('legacy-show', AgentTools.showPlan, {
            'plan_id': planId,
            'note': '量力而行。',
          }),
        ]);
      },
    ];
  }

  /// Search the new actions through the real tool before drafting an edit.
  List<Object> changeActions({
    required bool replaceAll,
    bool rejectSimilarFirst = false,
    bool shorter = false,
    bool keepSame = false,
  }) {
    const candidates = ['n-pelvis-circle', 'o-stand-sidebend', 'h-squat'];
    final main = keepSame
        ? ids.take(3).toList()
        : replaceAll
        ? candidates.take(2).toList()
        : [ids[0], ids[1], candidates[0]];
    Map<String, Object?> draft(List<String> mainIds) => {
      'plan_id': planId,
      'operation': replaceAll ? 'replace_all' : 'edit',
      'title': '髋部放松',
      'blocks': [
        {
          'kind': 'main',
          'items': [
            for (final id in mainIds) {'id': id},
          ],
        },
        {
          'kind': 'cooldown',
          'items': [
            {'id': ids.last},
          ],
        },
      ],
    };
    return [
      _calls([
        _tool('edit-start', AgentTools.startTask, {
          'type': 'plan',
          'reuse': true,
        }),
        if (shorter)
          _tool('edit-minutes', AgentTools.setParams, {
            'fields': {
              'minutes': {
                'value': 5,
                'source': 'derived',
                'quote': '短一点',
                'direction': 'shorter',
              },
            },
          }),
        for (var i = 0; i < candidates.length; i++)
          _tool('edit-search-$i', AgentTools.searchActions, {
            'tags': <String>[],
            'keywords': catalog[candidates[i]]!.name.of('en'),
          }),
      ]),
      (LlmRequest request) {
        if (shorter) expect(_response(request, 'edit-minutes')['ok'], isTrue);
        for (var i = 0; i < candidates.length; i++) {
          final result = _response(request, 'edit-search-$i');
          expect(result['ok'], isTrue, reason: '$result');
          expect(
            (result['items'] as List).map((item) => (item as Map)['id']),
            contains(candidates[i]),
          );
        }
        return _calls([
          _tool(
            'edit-draft',
            AgentTools.draftPlan,
            draft(rejectSimilarFirst ? [ids[0], ids[1], candidates[0]] : main),
          ),
        ]);
      },
      if (rejectSimilarFirst)
        (LlmRequest request) {
          final rejected = _response(request, 'edit-draft');
          expect(rejected['ok'], isFalse, reason: '$rejected');
          expect(rejected['code'], 'replace_too_similar');
          return _calls([
            _tool('edit-corrected', AgentTools.draftPlan, draft(main)),
          ]);
        },
      (LlmRequest request) {
        final result = _response(
          request,
          rejectSimilarFirst ? 'edit-corrected' : 'edit-draft',
        );
        expect(result['ok'], isTrue, reason: '$result');
        expect(result['plan_id'], planId);
        return _calls([
          _tool('edit-planning', AgentTools.check, {'node': 'planning'}),
          _tool('edit-check', AgentTools.checkPlan, {'plan_id': planId}),
        ]);
      },
      (LlmRequest request) {
        final result = _response(request, 'edit-check');
        expect(result['ok'], isTrue, reason: '$result');
        return _calls([
          _tool('edit-review', AgentTools.check, {'node': 'review'}),
          _tool('edit-show', AgentTools.showPlan, {
            'plan_id': planId,
            'note': '量力而行。',
          }),
        ]);
      },
    ];
  }

  static const thresholdOld = [
    's-kneel-hipflex',
    'n-thomas-test',
    'n-leg-circles',
    's-butterfly',
    'h-adductor-rock',
    'h-banana',
  ];

  List<Object> sixActionThreshold() {
    const fresh = ['n-pelvis-circle', 'o-stand-sidebend', 'h-squat'];
    Map<String, Object?> draft(List<String> main) => {
      'plan_id': planId,
      'operation': 'replace_all',
      'title': '髋部放松',
      'blocks': [
        {
          'kind': 'main',
          'items': [
            for (final id in main) {'id': id},
          ],
        },
        {
          'kind': 'cooldown',
          'items': [
            {'id': ids.last},
          ],
        },
      ],
    };
    return [
      _calls([
        _tool('six-start', AgentTools.startTask, {
          'type': 'plan',
          'reuse': true,
        }),
        for (var i = 0; i < fresh.length; i++)
          _tool('six-search-$i', AgentTools.searchActions, {
            'tags': <String>[],
            'keywords': catalog[fresh[i]]!.name.of('en'),
          }),
      ]),
      (LlmRequest request) {
        for (var i = 0; i < fresh.length; i++) {
          final result = _response(request, 'six-search-$i');
          expect(result['ok'], isTrue, reason: '$result');
          expect(
            (result['items'] as List).map((row) => (row as Map)['id']),
            contains(fresh[i]),
          );
        }
        return _calls([
          _tool(
            'six-reject',
            AgentTools.draftPlan,
            draft([...thresholdOld.take(4), ...fresh.take(2)]),
          ),
        ]);
      },
      (LlmRequest request) {
        final result = _response(request, 'six-reject');
        expect(result['ok'], isFalse, reason: '$result');
        expect(result['code'], 'replace_too_similar');
        return _calls([
          _tool(
            'six-accept',
            AgentTools.draftPlan,
            draft([
              thresholdOld[0],
              thresholdOld[1],
              fresh[1],
              thresholdOld[2],
              fresh[0],
              fresh[2],
            ]),
          ),
        ]);
      },
      (LlmRequest request) {
        final result = _response(request, 'six-accept');
        expect(result['ok'], isTrue, reason: '$result');
        return _calls([
          _tool('six-planning', AgentTools.check, {'node': 'planning'}),
          _tool('six-check', AgentTools.checkPlan, {'plan_id': planId}),
        ]);
      },
      (LlmRequest request) {
        final result = _response(request, 'six-check');
        expect(result['ok'], isTrue, reason: '$result');
        return _calls([
          _tool('six-review', AgentTools.check, {'node': 'review'}),
          _tool('six-show', AgentTools.showPlan, {
            'plan_id': planId,
            'note': '量力而行。',
          }),
        ]);
      },
    ];
  }
}
