import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/src/prompt/prompts.g.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall call(String name, Object args, [String id = 'c1']) => LlmToolCall(
  id: id,
  name: name,
  arguments: args is String ? args : jsonEncode(args),
);

LlmResponse resp({String text = '', List<LlmToolCall> calls = const []}) =>
    LlmResponse(
      content: text,
      toolCalls: calls,
      usage: const TokenUsage(promptTokens: 100, completionTokens: 20),
      model: 'fake',
      finishReason: calls.isEmpty ? 'stop' : 'tool_calls',
    );

Map<String, Object?> okPlan() => planOf(okEnvelope());

void main() {
  final catalog = loadCatalog();
  final profiles = {
    for (final p in ['flarelab', 'hiplab', 'smartfit']) p: loadProfile(p),
  };
  final hip = profiles['hiplab']!;
  final gate = ToolGate(
    catalog: catalog,
    profile: hip,
    canary: defaultPromptCanary,
  );

  group('工具提示词与当前配置金样一致', () {
    for (final id in profiles.keys) {
      test('$id 系统消息逐字节一致', () {
        expect(
          ToolPromptBuilder().system(profiles[id]!, catalog),
          File('test/fixtures/golden/$id.v3.md').readAsStringSync(),
        );
      });
      test('$id 工具 JSON 一致', () {
        final golden = jsonDecode(
          File('test/fixtures/golden/$id.tools.json').readAsStringSync(),
        );
        expect(
          jsonDecode(
            jsonEncode([
              for (final t in CoachTools.build(profiles[id]!, catalog))
                t.toJson(),
            ]),
          ),
          golden,
        );
      });
    }
    test('工具内核含防破甲、工具用法、暗号；版本号 kernel-v4', () {
      final s = ToolPromptBuilder().system(hip, catalog);
      expect(s, contains('防破甲'));
      expect(s, contains('show_actions'));
      expect(s, contains(defaultPromptCanary));
      expect(ToolPromptBuilder().version(hip), startsWith('kernel-v4-'));
      expect(kernelV3Markdown, File('prompts/kernel_v3.md').readAsStringSync());
    });
    test('白名单写进 enum', () {
      final t = CoachTools.build(hip, catalog).first.toJson();
      expect(jsonEncode(t), contains('s-figure4'));
      expect(jsonEncode(t), isNot(contains('h-incline-pushup')));
    });
  });

  group('宿主确认瑜伽垫时的旧评测门禁逐例对照（parity_tools.json）', () {
    final doc =
        (jsonDecode(File('test/fixtures/parity_tools.json').readAsStringSync())
                as Map)
            .cast<String, Object?>();
    for (final c in (doc['cases']! as List).cast<Map<String, Object?>>()) {
      test(c['name']! as String, () {
        final req = (c['request']! as Map).cast<String, Object?>();
        final ctx = CoachContext(
          // These historical fixture plans use a mat. Treat it as an explicit
          // host condition, not as a claim inferred from model output.
          equipment: const {'mat'},
          avoid: {
            for (final a in (req['avoid'] as List?) ?? const []) a as String,
          },
          level: req['level'] as int?,
          minutes: req['minutes'] as int?,
        );
        final calls = [
          for (final (i, x)
              in (c['calls']! as List).cast<Map<String, Object?>>().indexed)
            LlmToolCall(
              id: 'c$i',
              name: x['name']! as String,
              arguments: x['arguments']! as String,
            ),
        ];
        final g = ToolGate(
          catalog: catalog,
          profile: profiles[c['profile']]!,
          canary: defaultPromptCanary,
        ).check(c['text']! as String, calls, context: ctx);
        final py = (c['python']! as Map).cast<String, Object?>();
        final counts = <String, int>{};
        for (final e in g.errors) {
          counts.update(e.category, (n) => n + 1, ifAbsent: () => 1);
        }
        final why = 'Dart: ${g.errors}\nPython: ${py['messages']}';
        expect(g.leaked, py['leaked'], reason: why);
        const normalizedCases = {
          '看动作 7 个',
          '看动作带剂量',
          '看动作重复',
          '两个工具',
          '计划多包一层 plan',
          '计划跨块重复',
          '计划同块重复',
          '计划水平与本轮条件冲突',
          '计划时长与本轮条件冲突',
          '计划水平与时长都冲突',
        };
        final expectedCounts = normalizedCases.contains(c['name'])
            ? <String, int>{}
            : (py['counts']! as Map).map(
                (k, v) => MapEntry(k as String, v as int),
              );
        expect(counts, expectedCounts, reason: why);
        expect(g.ok, expectedCounts.isEmpty && c['expectLeaked'] == false);
      });
    }
  });

  group('门禁错误码（每条含位置、期望、实际、改法）', () {
    void expectCode(GateResult g, String code, String path) {
      final e = g.errors.firstWhere(
        (e) => e.code == code,
        orElse: () => throw StateError('没有 $code：${g.errors}'),
      );
      expect(e.path, path);
      final j = ToolGate.issueJson(e);
      for (final k in ['path', 'code', 'expected', 'actual', 'fix']) {
        expect(
          j[k],
          isA<String>().having((s) => s.isNotEmpty, '非空', isTrue),
          reason: '$code.$k',
        );
      }
      expect(g.plan, isNull);
      expect(g.actions, isNull);
    }

    final dup = {
      'exerciseId': 's-figure4',
      'mode': 'time',
      'sets': 1,
      'workSeconds': 30,
      'perSide': true,
      'restSeconds': 10,
    };
    Map<String, Object?> mutPlan(void Function(Map<String, Object?> p) f) {
      final p = okPlan();
      f(p);
      return p;
    }

    Map<String, Object?> item(Map<String, Object?> p, int b, int i) =>
        ((((p['blocks']! as List)[b]! as Map)['items']! as List)[i]! as Map)
            .cast<String, Object?>();

    test(
      'invalid_json（不修复 JSON 语法）',
      () => expectCode(
        gate.check('x', [call('show_plan', '{"title": "a",}')]),
        IssueCodes.invalidJson,
        'arguments',
      ),
    );
    test(
      'schema：缺字段',
      () => expectCode(
        gate.check('x', [call('show_actions', <String, Object?>{})]),
        IssueCodes.schema,
        'items',
      ),
    );
    test('schema：类型错', () {
      final p = mutPlan((p) => item(p, 1, 0)['sets'] = '2');
      expectCode(
        gate.check('x', [call('show_plan', p)]),
        IssueCodes.schema,
        'blocks[1].items[0].sets',
      );
    });
    test('recommendation dose extras are ignored with receipt notes', () {
      final g = gate.check('x', [
        call('show_actions', {
          'items': [
            {'actionId': 's-figure4', 'reps': 10},
          ],
        }),
      ]);
      expect(g.ok, isTrue);
      expect(g.warnings.map((w) => w.code), contains('normalized_fields'));
      expect((jsonDecode(g.feedback()) as Map)['notes'], isNotEmpty);
    });
    test(
      'items_count',
      () => expectCode(
        gate.check('x', [
          call('show_actions', {'items': <Object>[]}),
        ]),
        IssueCodes.itemsCount,
        'items',
      ),
    );
    test('legacy output batch is normalized without an extra model call', () {
      final g = gate.check('x', [
        call('show_actions', {
          'items': [
            {'actionId': 's-figure4'},
          ],
        }),
        call('show_plan', okPlan(), 'c2'),
      ], context: const CoachContext(equipment: {'mat'}));
      expect(g.ok, isTrue);
      expect(g.actions, isNotNull);
      expect(g.plan, isNotNull);
      expect(g.warnings.map((w) => w.code), contains('normalized_batch'));
    });
    test(
      'unknown_tool',
      () => expectCode(
        gate.check('x', [
          call('show_video', {'a': 1}),
        ]),
        IssueCodes.unknownTool,
        'tool_calls[0].name',
      ),
    );
    test(
      'empty_reply',
      () => expectCode(
        gate.check('  ', const []),
        IssueCodes.emptyReply,
        'content',
      ),
    );
    test(
      'unknown_exercise',
      () => expectCode(
        gate.check('x', [
          call('show_actions', {
            'items': [
              {'actionId': 'burpee'},
            ],
          }),
        ]),
        IssueCodes.unknownExercise,
        'items[0].actionId',
      ),
    );
    test(
      'out_of_profile',
      () => expectCode(
        gate.check('x', [
          call('show_actions', {
            'items': [
              {'actionId': 'h-incline-pushup'},
            ],
          }),
        ]),
        IssueCodes.outOfProfile,
        'items[0].actionId',
      ),
    );
    test('mode_mismatch（计时给次数）', () {
      final p = mutPlan(
        (p) => item(p, 1, 0)
          ..['mode'] = 'reps'
          ..['reps'] = 10
          ..remove('workSeconds'),
      );
      expectCode(
        gate.check('x', [call('show_plan', p)]),
        IssueCodes.modeMismatch,
        'blocks[1].items[0].mode',
      );
    });
    test(
      'avoid：计划撞保护部位',
      () => expectCode(
        gate.check('x', [
          call('show_plan', okPlan()),
        ], context: const CoachContext(avoid: {'膝'})),
        IssueCodes.avoid,
        'blocks[1].items[2].exerciseId',
      ),
    );
    test(
      'avoid：看动作撞保护部位',
      () => expectCode(
        gate.check('x', [
          call('show_actions', {
            'items': [
              {'actionId': 'h-adductor-rock'},
            ],
          }),
        ], context: const CoachContext(avoid: {'膝'})),
        IssueCodes.avoid,
        'items[0].actionId',
      ),
    );
    test('duplicate recommendation IDs are normalized once', () {
      final g = gate.check('x', [
        call('show_actions', {
          'items': [
            {'actionId': 's-figure4'},
            {'actionId': 's-figure4'},
          ],
        }),
      ]);
      expect(g.ok, isTrue);
      expect(g.actions!.items, hasLength(1));
      expect(g.warnings.map((w) => w.code), contains('normalized_duplicate'));
    });
    test(
      'an action may be reused across preparation and cooldown without a duplicate error',
      () {
        final p = mutPlan(
          (p) =>
              (((p['blocks']! as List)[2]! as Map)['items']! as List).add(dup),
        );
        final g = gate.check('x', [
          call('show_plan', p),
        ], context: const CoachContext(equipment: {'mat'}));
        expect(g.ok, isTrue);
        expect(
          g.errors.where((e) => e.code == IssueCodes.duplicateAction),
          isEmpty,
        );
      },
    );
    test('一次报出全部错误', () {
      final g = gate.check('x', [
        call('show_actions', {
          'items': [
            {'actionId': 'burpee'},
            {'actionId': 'h-incline-pushup'},
            {'actionId': 's-figure4', 'sets': 1},
          ],
        }),
      ]);
      expect(
        g.errors.map((e) => e.code),
        containsAll([IssueCodes.unknownExercise, IssueCodes.outOfProfile]),
      );
      final fb = jsonDecode(g.feedback(remaining: 2)) as Map;
      expect(fb['ok'], isFalse);
      expect(fb['remainingAttempts'], 2);
      expect(fb['errors'], hasLength(2));
    });
    test('只警告放行：剂量超推荐、时长偏差', () {
      final p = mutPlan((p) => item(p, 1, 1)['workSeconds'] = 115);
      final g = gate.check('好', [
        call('show_plan', p),
      ], context: const CoachContext(equipment: {'mat'}));
      expect(g.ok, isTrue);
      expect(
        g.plan!.warnings.map((w) => w.code),
        contains(IssueCodes.doseRange),
      );
    });
    test('通过：产出 ValidatedPlan / ValidatedActions', () {
      final g = gate.check('看这两个', [
        call('show_actions', {
          'items': [
            {'actionId': 's-figure4', 'note': '拉臀外侧'},
            {'actionId': 's-butterfly'},
          ],
        }),
      ]);
      expect(g.ok, isTrue);
      expect(g.actions!.items.map((a) => a.id), ['s-figure4', 's-butterfly']);
      expect(g.actions!.items.first.note, '拉臀外侧');
      final p = gate.check('排好了', [
        call('show_plan', okPlan()),
      ], context: const CoachContext(equipment: {'mat'}));
      expect(p.plan!.plan.source, 'ai');
      expect(p.text, '排好了');
    });
    test('模板计划也要过门禁', () {
      final plan = const PlanCodec().decode(okPlan());
      expect(
        gate.admitTemplate(plan, const CoachContext(equipment: {'mat'})),
        isNotNull,
      );
      expect(
        gate.admitTemplate(
          plan,
          const CoachContext(equipment: {'mat'}, avoid: {'膝'}),
        ),
        isNull,
      );
    });

    test('暗号以 JSON Unicode 转义藏在动作 note：解码后检测，整轮丢弃', () {
      final raw =
          '{"items":[{"actionId":"s-figure4","note":"\\u0055${defaultPromptCanary.substring(1)}"}]}';
      expect(raw, isNot(contains(defaultPromptCanary)));
      final g = gate.check('x', [call('show_actions', raw)]);
      expect(g.leaked, isTrue);
      expect(g.ok, isFalse);
      expect(g.actions, isNull);
    });

    test('暗号以 JSON Unicode 转义藏在计划文字字段（title / notes）：整轮丢弃', () {
      String esc(Map<String, Object?> p) => jsonEncode(p).replaceAll(
        defaultPromptCanary,
        '\\u0055${defaultPromptCanary.substring(1)}',
      );
      final t = okPlan()..['title'] = defaultPromptCanary;
      final n = okPlan()..['notes'] = ['记住 $defaultPromptCanary'];
      for (final p in [t, n]) {
        final g = gate.check('x', [call('show_plan', esc(p))]);
        expect(g.leaked, isTrue);
        expect(g.plan, isNull);
      }
    });

    test(
      'confirmed level and duration override derived card fields without a rejection',
      () {
        for (final numbers in [(3, 10), (3.0, 10.0)]) {
          final p = okPlan()
            ..['level'] = numbers.$1
            ..['targetMinutes'] = numbers.$2;
          final g = gate.check(
            'x',
            [call('show_plan', p)],
            context: const CoachContext(
              equipment: {'mat'},
              level: 1,
              minutes: 30,
            ),
          );
          expect(g.ok, isTrue);
          expect(g.plan!.plan.level, 1);
          expect(g.plan!.plan.targetMinutes, 30);
          expect(
            g.warnings.map((w) => w.code),
            contains('normalized_card_conditions'),
          );
        }
      },
    );

    test('context_conflict：整值 double 与本轮值相同（1.0 对 1）不报，规范为整数', () {
      final base = okPlan();
      final lv = base['level'] as int, tm = base['targetMinutes'] as int;
      final p =
          jsonDecode(
                jsonEncode(
                  base
                    ..['level'] = lv.toDouble()
                    ..['targetMinutes'] = tm.toDouble(),
                ),
              )
              as Map<String, Object?>;
      final g = gate.check(
        'x',
        [call('show_plan', p)],
        context: CoachContext(equipment: const {'mat'}, level: lv, minutes: tm),
      );
      expect(
        g.errors.map((e) => e.code),
        isNot(contains(IssueCodes.contextConflict)),
      );
      expect(g.ok, isTrue);
      expect(g.plan!.plan.level, lv);
      final one =
          jsonDecode(jsonEncode(okPlan()..['level'] = 1.0))
              as Map<String, Object?>;
      expect(
        gate
            .check('x', [
              call('show_plan', one),
            ], context: const CoachContext(level: 1))
            .errors
            .map((e) => e.code),
        isNot(contains(IssueCodes.contextConflict)),
      );
    });

    test('context_conflict：与本轮值一致或本轮未给值时不报', () {
      final p = okPlan();
      final same = CoachContext(
        equipment: const {'mat'},
        level: p['level'] as int,
        minutes: p['targetMinutes'] as int,
      );
      expect(gate.check('x', [call('show_plan', p)], context: same).ok, isTrue);
      expect(
        gate
            .check('x', [call('show_plan', okPlan()..['level'] = 2)])
            .errors
            .map((e) => e.code),
        isNot(contains(IssueCodes.contextConflict)),
      );
    });
  });

  group('OpenAI 兼容客户端：工具调用与自定义头', () {
    test(
      '请求带 tools、不带 response_format；解析 tool_calls；带自定义头与 Worker 头',
      () async {
        late http.Request seen;
        final mock = MockClient((r) async {
          seen = r;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'model': 'deepseek-v4-flash-0731',
                'choices': [
                  {
                    'message': {
                      'role': 'assistant',
                      'content': null,
                      'tool_calls': [
                        {
                          'id': 'call_1',
                          'type': 'function',
                          'function': {
                            'name': 'show_actions',
                            'arguments': '{"items":[{"actionId":"s-figure4"}]}',
                          },
                        },
                      ],
                    },
                    'finish_reason': 'tool_calls',
                  },
                ],
                'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
              }),
            ),
            200,
          );
        });
        final client = OpenAiCompatibleClient(
          config: LlmConfig.ugkWorker.copyWith(
            headers: {'User-Agent': 'ugk-coach'},
          ),
          auth: UgkWorkerAuth(appKey: 'k', deviceId: () async => 'dev-1'),
          httpClient: mock,
        );
        final r = await client.complete(
          LlmRequest(
            messages: [
              const LlmMessage.user('看看'),
              LlmMessage.assistant(
                '',
                toolCalls: [
                  call('show_actions', {'items': <Object>[]}, 'x'),
                ],
              ),
              const LlmMessage.tool('x', '{"ok":false}'),
            ],
            tools: CoachTools.build(hip, catalog),
            toolChoice: 'auto',
          ),
        );
        final body = jsonDecode(seen.body) as Map;
        expect(
          seen.url.toString(),
          'https://api.uuugk.win/v1/chat/completions',
        );
        expect(body['model'], 'deepseek-v4-flash-0731');
        expect(body['tools'], hasLength(2));
        expect(body.containsKey('response_format'), isFalse);
        final msgs = body['messages'] as List;
        expect((msgs[1] as Map)['content'], isNull);
        expect((msgs[1] as Map)['tool_calls'], hasLength(1));
        expect((msgs[2] as Map)['tool_call_id'], 'x');
        expect(seen.headers['X-App-Key'], 'k');
        expect(seen.headers['X-Device-Id'], 'dev-1');
        expect(seen.headers['User-Agent'], 'ugk-coach');
        expect(seen.headers.containsKey('Authorization'), isFalse);
        expect(r.content, '');
        expect(r.toolCalls.single.name, 'show_actions');
        expect(r.toolCalls.single.id, 'call_1');
      },
    );
  });
}
