/// Optional scope assessment inside the existing set_params protocol.
library;

import '../scope/action_scope.dart';

abstract final class CoachScopeToolProtocol {
  static const schema = <String, Object?>{
    'type': 'object',
    'properties': {
      'quote': {'type': 'string', 'description': '本轮用户原话，逐字复制，不引用系统状态或改写。'},
      'targetBodyCodes': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': '用户实际要求的body.*目录编码；包括名单外目标；仅给时长则空数组。',
      },
      'sourceActionId': {'type': 'string'},
      'sourceActionName': {
        'type': 'string',
        'description':
            '一个动作的完整原名，必须为用户原话的连续子串，不合并多个动作名称；已明确点名的目录外动作由代码自动识别，可省略此字段。',
      },
      'sourceQuote': {'type': 'string'},
      'inScopeQuote': {
        'type': 'string',
        'description': '混合需求中范围内部位/动作的原话连续子串，不用省略号、不改写、不拼接。',
      },
      'insists': {'type': 'boolean'},
      'locked': {'type': 'boolean'},
      'outsideSpecialty': {
        'type': 'boolean',
        'description': '整个需求超出App专长时为true，只能拒绝计划，不能扩大动作权限。',
      },
      'safetyBlocked': {
        'type': 'boolean',
        'description':
            '先检查伤痛风险，再判App范围；用户说正在痛/动作会痛时优先true并引用原话，不能被outsideSpecialty覆盖。',
      },
      'safetyReason': {
        'type': 'string',
        'description': '需要安全暂停时引用用户原话中的风险描述；不降低原安全规则。',
      },
    },
    'required': ['quote', 'targetBodyCodes'],
    'additionalProperties': false,
  };

  static String system(CoachScopeConversationPolicy policy) =>
      '''
# 本 App 的硬范围与本轮处理
${policy.specialty}
每个用户轮先用既有 set_params 的 scope_request 记录范围判断，再交付文字/卡片/问题；
可与 start_task、正常 fields 在同一次回复中批量调用。quote 逐字复制本轮用户原话。
只有时长/一般建议时 targetBodyCodes=[]；点名不可用动作时保留其原名/原话，不编ID。
请求胸背等整体范围外目标应标 outsideSpecialty=true，不猜隐藏body编码，不能换成髋臀后声称满足原目标。
范围内动作只从受限目录的真实 search/get 回执取得；范围处理候选不等于已经搜索。
部分需求采用代码返回的 adoptedActionId；没有合理替代则按回执删去并告知，重新draft。
整个需求超范围或用户坚持不可用动作：不出计划；按回执说明本App专长并给范围内建议。
安全拒绝/澄清始终优先。safetyBlocked 需要风险原话，不得为了交付替代训练而关闭。
先核对用户已确认的伤痛limits：明确正在痛或动作会痛，必须先记录安全暂停，不先推荐替代动作。
${policy.guidanceEnabled ? '范围外引导只使用配置提供的文案：${policy.outOfScopeGuidance}' : '不提及或引导其他App。'}
代码会保存处理记录并补真实告知；不得在note声称含有已删除/未提供的动作。

# 有效工具批次
已知条件尽量一次按 start_task → set_params → search_actions → draft_plan 排列。
start_task已回传相应完整技能，不重复read同一份技能；不要只为开始任务单独占一轮。
已给地点/时长/重点时，同批set_params写齐scene、minutes、goal及已给器械/水平，不能遗漏goal后再补。
同目的的多个body目标可用现有同类OR检索合并，仍保留场景/器械/安全过滤。
同一计划的purpose/body目标尽量一次放入tags，同类OR、跨类AND；不要逐部位重复请求。
先复核已有搜索行的body/purpose/level/allowed，再决定是否真需扩大检索，不能凭名称猜ID。
已可见且当前仍合法的动作可复用；未见ID不能靠猜测绕过来源门禁。
draft_plan 成功回执已含自动 check/review，通过后直接show_plan，勿再做相同check。
出错按具体回执在原重交/步数上限内修正；不能为减少调用而提前交付或忽略双时长门禁。
''';
}
