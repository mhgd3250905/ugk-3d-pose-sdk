import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

int _bytes(Object? value) => utf8.encode(jsonEncode(value)).length;

void _enums(
  Object? value,
  String path,
  List<({String path, List<Object?> values})> result,
) {
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key == 'enum' && entry.value is List) {
        result.add((
          path: '$path.enum',
          values: List<Object?>.from(entry.value as List),
        ));
      } else {
        _enums(entry.value, '$path.${entry.key}', result);
      }
    }
  } else if (value is List) {
    for (var i = 0; i < value.length; i++) {
      _enums(value[i], '$path[$i]', result);
    }
  }
}

void _descriptions(Object? value, String path, Map<String, String> result) {
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key == 'description') {
        result['$path.description'] = entry.value as String;
      } else {
        _descriptions(entry.value, '$path.${entry.key}', result);
      }
    }
  } else if (value is List) {
    for (var i = 0; i < value.length; i++) {
      _descriptions(value[i], '$path[$i]', result);
    }
  }
}

// Approved descriptions from 520c3d5. Keep this fixture independent of the
// current implementation so future budget changes cannot silently shorten it.
const _approvedToolDescriptions = {
  'start_task': '开始动作推荐或组装计划；只有完成推荐卡后才能复用节点。',
  'check': '请求完成当前节点；动作节点需要传入已搜索并选择的动作 ID。',
  'read':
      '读技能文件系统里的一个文件（如 action-library/SKILL.md、action-library/index/scene/home.md）。',
  'search_actions': '按目录标签与关键词搜索动作，自动按当前场景、器材和伤痛限制过滤。',
  'get_action': '批量查看动作要领与禁忌；大多数情况不需要调用。',
  'draft_plan': '修改已交付计划时沿用当前任务，整体换一套用 replace_all，局部调整用 edit。',
  'set_params':
      '记录结构化条件；user 引用本次原话，preselect 仅用已保存习惯，default 明示默认。相对时长用 derived、原话和 direction；host 由宿主写入。',
  'check_plan': '按账本中的当前条件核对指定计划的最新版本。',
  'show_actions': '交付已选动作卡；note 用一两句说明安排思路。',
  'show_plan': '交付已通过核对的最新计划卡；note 用一两句说明安排思路。',
  'ask_user': '由模型决定是否需要澄清。调用后暂停，用户回答后继续；不要重问已有条件。',
  'remember': '记住用户主动提供的一条训练相关信息（先读 user-memory/SKILL.md）。',
  'forget': '忘掉一条或一类记忆：给 text 删匹配的条目；只给 kind 删整类。',
};

const _approvedParameterDescriptions = {
  'ask_user.properties.question.description': '简短口语，一次补齐缺项',
  'ask_user.properties.options.description': '仅 choice 模式提供，2–6 个短选项',
  'ask_user.properties.multiple.description': '仅 choice 模式提供，是否多选',
  'ask_user.properties.fields.description':
      '仅旧版 form：scene/equipment/minutes 分组，器械选项来自当前动作库',
  'remember.properties.text.description': '一句短话，用用户的说法',
};

void main() {
  const root = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$root/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$root/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();

  for (final profile in ['smartfit', 'hiplab', 'flarelab']) {
    final tools = AgentTools.build(loadProfile(profile), catalog, memory: true);

    test('$profile schema UTF-8 bytes and repeated enums diagnostic', () {
      final enums = <({String path, List<Object?> values})>[];
      for (final tool in tools) {
        _enums(tool.parameters, tool.name, enums);
      }
      final occurrences = <String, int>{};
      for (final entry in enums) {
        final key = jsonEncode(entry.values);
        occurrences[key] = (occurrences[key] ?? 0) + 1;
      }
      print(
        jsonEncode({
          'profile': profile,
          'memory': true,
          'toolsBytes': _bytes([for (final tool in tools) tool.toJson()]),
          'toolsBytesWithoutMemory': _bytes([
            for (final tool in tools)
              if (tool.name != 'remember' && tool.name != 'forget')
                tool.toJson(),
          ]),
          'enumListBytesTotal': enums.fold<int>(
            0,
            (total, entry) => total + _bytes(entry.values),
          ),
          'tools': [
            for (final tool in tools)
              {
                'name': tool.name,
                'schemaBytes': _bytes(tool.toJson()),
                'parametersBytes': _bytes(tool.parameters),
                'descriptionBytes': utf8.encode(tool.description).length,
              },
          ],
          'enumOccurrences': [
            for (final entry in enums)
              {
                'path': entry.path,
                'bytes': _bytes(entry.values),
                'repetitions': occurrences[jsonEncode(entry.values)],
                'values': entry.values,
              },
          ],
        }),
      );
      expect(tools, isNotEmpty);
      expect(enums, isNotEmpty);
    });

    test('$profile keeps approved tool and parameter descriptions', () {
      expect({
        for (final tool in tools) tool.name: tool.description,
      }, _approvedToolDescriptions);
      final descriptions = <String, String>{};
      for (final tool in tools) {
        _descriptions(tool.parameters, tool.name, descriptions);
      }
      expect(descriptions, _approvedParameterDescriptions);
    });

    test('$profile field enums contain only their own code family', () {
      final enums = <({String path, List<Object?> values})>[];
      _enums(
        tools.singleWhere((tool) => tool.name == 'set_params').parameters,
        'set_params',
        enums,
      );
      List<String> values(String field) => enums
          .singleWhere(
            (entry) =>
                entry.path ==
                'set_params.properties.fields.properties.$field.properties.value.items.enum',
          )
          .values
          .cast<String>();
      expect(values('goal'), isNotEmpty);
      expect(
        values('goal'),
        everyElement(
          predicate<String>(
            (value) =>
                value.startsWith('body.') || value.startsWith('purpose.'),
          ),
        ),
      );
      expect(values('equipment'), everyElement(startsWith('equip.')));
      expect(values('limits'), everyElement(startsWith('limit.')));
      final search = <({String path, List<Object?> values})>[];
      _enums(
        tools.singleWhere((tool) => tool.name == 'search_actions').parameters,
        'search_actions',
        search,
      );
      final allTags = search
          .singleWhere(
            (entry) =>
                entry.path == 'search_actions.properties.tags.items.enum',
          )
          .values
          .cast<String>();
      expect(allTags, containsAll(values('goal')));
      expect(allTags.any((value) => value.startsWith('scene.')), isTrue);
      expect(allTags.any((value) => value.startsWith('pose.')), isTrue);
    });
  }
}
