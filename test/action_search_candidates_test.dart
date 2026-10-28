import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_search.dart';
import 'package:ugk_coach/src/agent/context_compactor.dart';
import 'package:ugk_coach/src/agent/session_state.dart';
import 'package:ugk_coach/src/catalog/catalog.dart';
import 'package:ugk_coach/src/llm/llm_types.dart';
import 'package:ugk_coach/src/profile/coach_profile.dart';
import 'package:ugk_coach/src/util/json.dart';

import 'support.dart';

void main() {
  final fixture = loadCatalog();
  const profile = CoachProfile(id: 'all', appName: 'all');
  Drill drill(
    String id, {
    List<String> equipment = const [],
    List<String> cautions = const [],
  }) => Drill(
    id: id,
    name: LocalizedText({'zh': '动作$id', 'en': 'Action $id'}),
    category: 'core',
    muscleGroups: const ['abs'],
    equipment: equipment,
    cautions: cautions,
    scenes: const ['home'],
    position: 'standing',
    unilateral: false,
    level: 1,
    defaultDose: const Dose(
      mode: DoseMode.time,
      sets: 1,
      seconds: 30,
      restSeconds: 10,
    ),
  );
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', turn: 1);
  CoachSessionState active({
    Map<String, CoachParamValue> params = const {},
    Set<String> seen = const {},
  }) => CoachSessionState(
    task: CoachTaskState(
      type: 'plan',
      reused: false,
      nodes: const [CoachNodeState(id: 'actions', status: 'current')],
    ),
    params: params,
    seenActionIds: seen,
  );
  Map<String, Object?> summary(CoachSessionState state, Catalog catalog) {
    final messages = const ContextCompactor().compose(
      system: const LlmMessage.system('role'),
      state: state,
      catalog: catalog,
      profile: profile,
      history: const [],
      language: 'en',
    );
    return jsonDecode(messages[1].content.substring('当前状态：'.length))
        as Map<String, Object?>;
  }

  test(
    'active candidates retain first-seen order, localized name and primary body, cap at forty',
    () {
      final catalog = Catalog(
        version: 'test',
        taxonomy: fixture.taxonomy,
        drills: [for (var i = 0; i < 45; i++) drill('a$i')],
      );
      final seen = {for (var i = 44; i >= 0; i--) 'a$i'};
      final state = active(seen: seen);
      final current = summary(state, catalog);
      expect(current['picks'], isEmpty);
      final rows = current['candidates'] as List;
      expect(rows, hasLength(40));
      expect(rows.first, ['a44', 'Action a44', 'body.abs']);
      expect(rows.last, ['a5', 'Action a5', 'body.abs']);
      expect(state.seenActionIds.toList(), seen.toList());
    },
  );

  test(
    'candidate pool rechecks new equipment, scene and safety, excluding unknown IDs',
    () {
      final catalog = Catalog(
        version: 'test',
        taxonomy: fixture.taxonomy,
        drills: [
          drill('free'),
          drill('gear', equipment: ['dumbbell']),
          drill('unsafe', cautions: ['膝']),
        ],
      );
      final state = active(
        seen: {'gear', 'free', 'unsafe', 'missing'},
        params: {
          'scene': param('home'),
          'equipment': param(['equip.dumbbell']),
        },
      );
      expect(
        (summary(state, catalog)['candidates'] as List).map(
          (row) => (row as List<Object?>).first,
        ),
        ['gear', 'free', 'unsafe'],
      );
      final changed = state.copyWith(
        params: {
          'scene': param('home'),
          'equipment': param(<String>[]),
          'limits': param(['limit.knee']),
        },
      );
      expect(summary(changed, catalog)['candidates'], [
        ['free', 'Action free', 'body.abs'],
      ]);
      expect(
        summary(
          changed.copyWith(params: {'scene': param('office')}),
          catalog,
        )['candidates'],
        isEmpty,
      );
      final done = state.copyWith(
        task: CoachTaskState(
          type: 'plan',
          reused: false,
          nodes: const [CoachNodeState(id: 'output', status: 'done')],
        ),
      );
      expect(summary(done, catalog).containsKey('candidates'), isFalse);
    },
  );

  test(
    'two searches without new IDs hint without blocking, and new results reset persisted counter',
    () {
      final catalog = Catalog(
        version: 'test',
        taxonomy: fixture.taxonomy,
        drills: [drill('one'), drill('two')],
      );
      final search = ActionSearch(profile, catalog, minPicks: 3);
      final first = search.search(active(), keywords: 'Action one');
      expect(first.state.consecutiveEmptySearches, 0);
      final repeated = search.search(first.state, keywords: 'Action one');
      expect(repeated.ok, isTrue);
      expect(repeated.state.consecutiveEmptySearches, 1);
      expect(repeated.summary, isNot(contains('请从 candidates')));
      final restored = CoachSessionState.fromJson(
        jsonDecode(jsonEncode(repeated.state.toJson())) as Map<String, Object?>,
      );
      final twice = search.search(restored, keywords: 'Action one');
      expect(twice.ok, isTrue);
      expect(twice.state.consecutiveEmptySearches, 2);
      expect(
        twice.summary,
        contains('候选池已有 1 个，请从 candidates 中选择并 check(actions)'),
      );
      final empty = search.search(
        twice.state,
        keywords: 'not in catalogue',
        language: 'en',
      );
      expect(empty.summary, contains('candidate pool already has 1 action;'));
      final fresh = search.search(empty.state, keywords: 'Action two');
      expect(fresh.state.consecutiveEmptySearches, 0);
      expect(fresh.summary, isNot(contains('请从 candidates')));
    },
  );

  test(
    'few visible matches and at least five hidden actions suggest actual missing equipment once',
    () {
      final catalog = Catalog(
        version: 'test',
        taxonomy: fixture.taxonomy,
        drills: [
          drill('visible'),
          for (var i = 0; i < 3; i++) drill('mat$i', equipment: ['mat']),
          for (var i = 0; i < 3; i++)
            drill('weight$i', equipment: ['dumbbell']),
          for (var i = 0; i < 3; i++)
            drill('unsafe$i', equipment: ['dumbbell'], cautions: ['膝']),
        ],
      );
      final search = ActionSearch(profile, catalog, minPicks: 3);
      final state = active(
        params: {
          'scene': param('home'),
          'limits': param(['limit.knee']),
        },
      );
      final found = search.search(state);
      expect(found.items, hasLength(1));
      expect(found.filter['hiddenEquipmentCount'], 6);
      expect(found.summary, contains('另有 6 个需要'));
      expect(found.summary, contains('ask_user 问一次'));
      expect(found.summary, isNot(contains('equip.')));
      final excluded = search.search(
        state.copyWith(
          params: {
            ...state.params,
            'equipment_exclude': param(['equip.mat']),
          },
        ),
      );
      expect(excluded.filter['hiddenEquipmentCount'], 3);
      expect(excluded.summary, isNot(contains('ask_user 问一次')));
      final available = search.search(
        state.copyWith(
          params: {
            ...state.params,
            'equipment': param(['equip.mat']),
          },
        ),
      );
      expect(available.items, hasLength(4));
      expect(available.summary, isNot(contains('ask_user 问一次')));
    },
  );

  test(
    'archived search while actions unfinished points only to a populated candidates list',
    () {
      final catalog = Catalog(
        version: 'test',
        taxonomy: fixture.taxonomy,
        drills: [drill('one')],
      );
      final state = active(seen: {'one'});
      final messages = const ContextCompactor().compose(
        system: const LlmMessage.system('role'),
        state: state,
        catalog: catalog,
        profile: profile,
        history: [
          LlmMessage.assistant(
            '',
            toolCalls: [
              const LlmToolCall(
                id: 's',
                name: 'search_actions',
                arguments: '{"tags":[]}',
              ),
            ],
          ),
          const LlmMessage.tool(
            's',
            '{"ok":true,"items":[{"id":"one","name":"动作one"}]}',
          ),
          const LlmMessage.assistant('continue'),
        ],
      );
      expect(
        messages.singleWhere((m) => m.toolCallId == 's').content,
        '[已归档，候选见当前状态 candidates]',
      );
      expect(messages[1].content, contains('动作one'));
      final empty = const ContextCompactor().compose(
        system: const LlmMessage.system('role'),
        state: active(),
        catalog: catalog,
        profile: profile,
        history: [
          LlmMessage.assistant(
            '',
            toolCalls: [
              const LlmToolCall(
                id: 's',
                name: 'search_actions',
                arguments: '{"tags":[]}',
              ),
            ],
          ),
          const LlmMessage.tool('s', '{"ok":true,"items":[]}'),
          const LlmMessage.assistant('continue'),
        ],
      );
      expect(
        empty.singleWhere((m) => m.toolCallId == 's').content,
        '[已归档] 本次未返回动作。',
      );
      expect(empty.any((m) => m.content.contains('[已归档，见当前状态]')), isFalse);
    },
  );
}
