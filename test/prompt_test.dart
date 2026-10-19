import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/src/prompt/prompts.g.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();

  group('系统提示词与评测逐字节一致（ai-coach-eval tools/build_prompt.py 金样）', () {
    for (final id in ['flarelab', 'hiplab', 'smartfit']) {
      test(id, () {
        final golden = File('test/fixtures/golden/$id.md').readAsStringSync();
        expect(PromptBuilder().system(loadProfile(id), catalog), golden);
      });
    }
  });

  test('prompts.g.dart 与 prompts/*.md 同步（改 md 后要跑 tool/embed_prompts.dart）', () {
    expect(kernelMarkdown, File('prompts/kernel.md').readAsStringSync());
    expect(contextMarkdown, File('prompts/context.md').readAsStringSync());
    expect(rewriteMarkdown, File('prompts/rewrite.md').readAsStringSync());
    expect(kernelMarkdownHash, sha256.convert(utf8.encode(kernelMarkdown)).toString().substring(0, 8));
  });

  test('内核按标题切段', () {
    expect(defaultPromptSet.sectionNames, ['intro', 'rules', 'composition', 'focus', 'output', 'catalog']);
  });

  test('版本号含内核哈希与 profile 版本', () {
    final v = PromptBuilder().version(loadProfile('hiplab'));
    expect(kernelRevision, 2);
    expect(v, startsWith('kernel-v2-$kernelMarkdownHash'));
    expect(v, endsWith('@hiplab-1'));
  });

  test('App 覆盖：替换段、追加段（默认插在目录前）、版本号带覆盖版本', () {
    final b = PromptBuilder(overrides: const PromptOverrides(
      version: 'hl2',
      replace: {'composition': '# 编排原则\n- 每次最多 4 个动作。'},
      append: [PromptSection('extra', '# 季节提示\n- 冬天先多热身。')],
    ));
    final s = b.system(loadProfile('hiplab'), catalog);
    expect(s, contains('每次最多 4 个动作'));
    expect(s, isNot(contains('肌群平衡')));
    expect(s.indexOf('冬天先多热身'), lessThan(s.indexOf('# 动作目录')));
    expect(b.version(loadProfile('hiplab')), contains('+hl2@'));
  });

  test('覆盖不存在的段报错', () {
    expect(() => PromptBuilder(overrides: const PromptOverrides(replace: {'nope': 'x'})), throwsA(isA<PromptRenderException>()));
  });

  test('模板缺变量报错', () {
    expect(() => const PromptTemplate('你好 {{who}}').render({}), throwsA(isA<PromptRenderException>()));
    expect(const PromptTemplate('你好 {{ who }}').render({'who': '开哥'}), '你好 开哥');
  });

  test('自定义变量进模板', () {
    final b = PromptBuilder(overrides: const PromptOverrides(
      append: [PromptSection('tone', '# 称呼\n称呼用户为{{nick}}。')],
      vars: {'nick': '同学'},
    ));
    expect(b.system(loadProfile('hiplab'), catalog), contains('称呼用户为同学。'));
  });

  group('本轮消息', () {
    final hip = loadProfile('hiplab');
    test('App 什么都不知道：只发用户原话（与评测一致）', () {
      expect(PromptBuilder().contextMessage(hip, catalog, const CoachContext(), ' 睡前想放松一下 '), '睡前想放松一下');
    });
    test('有已知条件：前置一行', () {
      final m = PromptBuilder().contextMessage(
          hip, catalog, const CoachContext(scene: 'office', equipment: {}, avoid: {'膝'}, minutes: 10), '来一套');
      expect(m, '（App 已知条件：场所 办公室（office）；除场所默认外没有器械；要保护 膝；时长 10 分钟）\n来一套');
    });
  });

  test('重写消息：附上次输出与错误分类清单', () {
    final msgs = PromptBuilder().rewrite(const [LlmMessage.system('s'), LlmMessage.user('u')], '{"bad":1}', const [
      PlanIssue(IssueCodes.repsRange, '深蹲：次数 40 超出 1–30'),
      PlanIssue.warning(IssueCodes.duration, '只是警告'),
    ]);
    expect(msgs, hasLength(4));
    expect(msgs[2].role, LlmRole.assistant);
    expect(msgs[3].content, contains('- E_DOSE 深蹲：次数 40 超出 1–30'));
    expect(msgs[3].content, isNot(contains('只是警告')));
  });

  test('重写消息：输出疑似截断时追加「少想一点」提示（与评测 format_feedback 一致）', () {
    List<LlmMessage> rw(String msg) =>
        PromptBuilder().rewrite(const [LlmMessage.user('u')], '{"kind":"plan","plan":{', [PlanIssue(IssueCodes.notJson, msg)]);
    expect(rw('JSON 对象没有闭合（可能被截断）').last.content, contains(PromptBuilder.truncationHint));
    expect(rw('正文里没有 JSON 对象').last.content, contains(PromptBuilder.truncationHint));
    expect(rw('JSON 语法错误').last.content, isNot(contains(PromptBuilder.truncationHint)));
    // 提示在错误清单之后、「请只改正」之前。
    final c = rw('JSON 对象没有闭合（可能被截断）').last.content;
    expect(c.indexOf(PromptBuilder.truncationHint), greaterThan(c.indexOf('- E_JSON')));
    expect(c.indexOf(PromptBuilder.truncationHint), lessThan(c.indexOf('请只改正')));
  });

  test('内核 v2：plan 先于 text、要求 plan 必填、思考简短', () {
    expect(kernelMarkdown, contains('按 kind → plan → text 的顺序写'));
    expect(kernelMarkdown, contains('思考保持简短'));
    expect(kernelMarkdown, contains('{"kind":"plan","plan":{"schemaVersion":1'));
    expect(kernelMarkdown, contains('"safetyNotes":[]},"text":"一两句说明"}'));
  });

  test('build：系统 + 历史 + 本轮；系统消息不随条件变化（利于前缀缓存）', () {
    final hip = loadProfile('hiplab');
    final conv = CoachConversation()
      ..addUser('想开胯', DateTime(2026))
      ..addAssistant(const CoachReply.ask('在家还是办公室？', ['在家', '办公室']), DateTime(2026));
    final b = PromptBuilder();
    final a = b.build(profile: hip, catalog: catalog, context: const CoachContext(scene: 'home'), userText: '在家', conversation: conv);
    final c = b.build(profile: hip, catalog: catalog, context: const CoachContext(scene: 'office', minutes: 5), userText: '办公室');
    expect(a.messages.map((m) => m.role), [LlmRole.system, LlmRole.user, LlmRole.assistant, LlmRole.user]);
    expect(a.hash, c.hash);
    expect(a.messages.first.content, c.messages.first.content);
  });

  group('HistoryPolicy', () {
    final plan = const PlanCodec().decode(planOf(okEnvelope()));
    CoachConversation conv(int n) {
      final c = CoachConversation();
      for (var i = 0; i < n; i++) {
        c
          ..addUser('第 $i 次', DateTime(2026))
          ..addAssistant(CoachReply.plan('计划 $i', plan), DateTime(2026));
      }
      return c;
    }

    test('只保留最近 maxTurns 条，且以用户消息开头', () {
      final m = const HistoryPolicy(maxTurns: 5).select(conv(6));
      expect(m.first.role, LlmRole.user);
      expect(m.length, lessThanOrEqualTo(5));
      expect(m.last.content, contains('计划 5'));
    });
    test('只有最近一份计划保留完整 JSON，更早的压成摘要', () {
      final m = const HistoryPolicy(maxTurns: 10, maxChars: 100000).select(conv(3));
      final assistants = m.where((x) => x.role == LlmRole.assistant).toList();
      expect(assistants.last.content, contains('"blocks"'));
      expect(assistants.first.content, contains('planSummary'));
      expect(assistants.first.content, contains('n-windshield 1×8次'));
    });
    test('总字数上限', () {
      final m = const HistoryPolicy(maxTurns: 20, maxChars: 1500).select(conv(5));
      expect(m.fold<int>(0, (s, x) => s + x.content.length), lessThanOrEqualTo(1500 + 2000));
      expect(m.length, lessThan(10));
    });
  });

  test('目录表一行的格式', () {
    final row = PromptBuilder.catalogRow(catalog['s-figure4']!);
    expect(row, startsWith('s-figure4|仰卧 4 字拉伸|拉伸|臀大|mat|仰卧*|单|1|家|1×30秒 休10|组1-2 秒15-60|-|'));
  });
}
