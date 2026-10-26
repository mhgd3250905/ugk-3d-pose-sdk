# CoachConversationController：当前分组补问接口（R1 part1）

同一个controller和agent承接初问、一次回答、交付方案。训练组最多补问1轮，多个缺项放一张form，已知的不问；跳过使用合理默认。text/choice接口与已有取消、重置、busy、重复提交保护保留。

```dart
final result = await conversation.send('在家10分钟练核心');
final message = conversation.state.pendingQuestion;
if (message?.question?.mode == AskUserMode.form) {
  // 此例只缺器械；不要额外提交已知scene/minutes。
  await conversation.answerForm(message!.id, {'equipment': ['瑜伽垫']});
  // 或 await conversation.skipQuestion(message.id);
}
```

`answerForm(id, Map<String,List<String>>)` 只接受当前有效form；字段名/选项必须属于表单，每组至少一项，场景/时长单选，器械多选且徒手不能与器械共选。非法、过期、重复或发送中回答返回null，不调用模型。`skipQuestion(id)` 使用已有文字回答通道发送“直接出方案”。

App把fields逐项映射到独立UI包的 `CoachQuestionField`，mode映射为 `CoachQuestionMode.form`，`onFormAnswer` 接 `answerForm`；跳过/自由文本接 `answerText`。不传 `onFormAnswer` 的UI会把可读分组答案回退到已有 `onTextAnswer`。旧mapper的二元mode分支需要升级。

默认值参与该次计划准入，保留既有筛查avoid，不将默认器械或身体状态保存为用户事实。当前参数缺失却直接交付、重问已知项、第二轮追问、器械/场景冲突及实际估时偏差会被门禁打回。

---

以下为0.5.0引入controller时的历史交付记录。其待审/版本/发布状态不表示当前分支状态；通用状态与取消规则仍适用，补问预算以上文为准。

# CoachConversationController 接入（0.5.0，待审）

`CoachConversationController` 在纯 Dart 包 `ugk_coach` 内管理一次 AI 对话。它不依赖 Flutter 或 `ugk_coach_ui`，也不把 `TrainingPlan` 映射为 UI 的 `CoachRoutine`。SmartFit 先接入；HipLab / Flare 本轮只作只读参考，未修改。

当前为待审分支，拟发布 `ugk_coach-v0.5.0`。trainer 为兼容 coach 的版本约束和 Git 来源，拟发布 `ugk_trainer-v0.2.3`；trainer 的运行逻辑不变。UI 运行代码和版本保持 `ugk_coach_ui-v0.1.1`。这些新 tag 在批准并发布前不可作为已发布依赖使用；现有 tag 不移动。

## 创建与监听

App 先构造一个 `CoachAgent`，再把它交给一个 controller。controller 在多轮 send、回答、取消和新对话中始终使用这个实例；新对话 reset 原 agent，不重新构造。

```dart
import 'package:ugk_coach/ugk_coach.dart';

final agent = CoachAgent(
  client: appClient,
  catalog: () => appCatalog,
  profile: appProfile,
  memoryStore: appMemoryStore,
  fallback: appFallback,
);
final conversation = CoachConversationController(agent: agent);
void changed() => renderConversation(conversation.state);
conversation.addListener(changed);

await conversation.send(
  '帮我安排十分钟训练',
  context: const CoachContext(scene: 'home'),
);
// 也可订阅 conversation.states；先读取 state 获得当前快照。
```

`addListener` 在状态更新时同步通知，`states` 是异步 broadcast 流，不回放初始或先前状态；订阅前先读 `state`。Flutter 页面可使用前者触发重建，App 服务也可使用后者。

controller 独占 agent 的 `send` / `reset` / `dispose`。App 可以订阅 `conversation.events` 展示本地化的 agent 进度，或管理 agent 的用户记忆；不要绕过 controller 直接 send，否则状态与 agent 历史可能不一致。`askUser` 过程事件不启用问题，只有 agent `send` 返回的已准入问题才进入待答状态。

## 状态与消息

`state` 为不可变快照，列表也不可修改。

| 字段 | 含义 |
| --- | --- |
| `messages` | 按时间顺序的 `CoachConversationMessage` 列表，包括用户、普通助理文字、已准入问题及计划/动作卡数据 |
| `pendingQuestion` | 当前待答问题消息；提交等待时保留快照，但 `canAnswer(id)` 为 false，不能仅检查非空就启用 |
| `isWaiting` | 正在提交或等待同一轮结果，首个异步等待前即锁定 |
| `admittedPlans` | 对话中通过 SDK 门禁的 `ValidatedPlan`，可交给 App 映射或保存 |
| `error` | 当前轮的错误信息，错误提示文案由 App 决定 |
| `lastResult` | 最近的 `CoachTurnResult`，供 App 处理状态、回落与诊断 |

消息字段为 `id`、`at`、`isUser`、`text`、`question`、`questionAnswered`、`answeredChoices`、`plan`、`actions`、`turnId`。消息身份独立于模型提供的计划 ID。`plan` / `actions` 只能承载门禁结果；消息本身不能替代训练前的 App 安全检查。

当 `result.text == result.question.question` 时，消息的普通 `text` 为空，只显示问题气泡。两者不同时保留普通文字，App 应分别渲染 `text` 和 `question`，不要采用“有问题就隐藏所有普通文字”的分支。

## 回答与有效期

```dart
final question = conversation.state.pendingQuestion;
if (question != null && conversation.canAnswer(question.id)) {
  // 文字回答；同一个 agent 的下一条消息。
  await conversation.answerText(question.id, '十分钟左右');
}

// choice 气泡将原始选项字符串交给 SDK。
// 即使用户先点“椅子”再点“瑜伽垫”，仍按 question.options 顺序发送。
await conversation.answerChoices(questionId, ['椅子', '瑜伽垫']);
```

单选要求一个合法选项；多选要求非空、无重复、均来自原问题选项。SDK 按原选项顺序整理，用构造参数 `choiceSeparator` 拼接，默认 `、`。`choiceText(id, selected)` 可在不发送时取得同一份合法、已排序文字；格式无效返回 `null`。`answerText` 去除首尾空白，空白回答不发送。普通输入框的 `send` 也能继续当前问题。

首次提交会同步锁定，再次点击不会产生第二次请求。问题只有在 `send` 返回后才可答；新问题/计划、取消、新对话、恢复历史或销毁后，旧问题失效。`inputTooLong` 等未消费输入保留原问题，用户可缩短后重试。`invalidateQuestion()` 用于 App 明确转入本地命令等场景，主动结束问题的交互资格。

`send` / `answerText` / `answerChoices` 返回 `Future<CoachTurnResult?>`：空输入、失效问题、非法选项、重复提交或销毁后的调用可返回 `null`。正常完成的 agent 轮次返回其结果；调用 `cancel()`、取消外部 `CancelToken`，以及新对话/恢复/销毁作废的轮次可返回 `null`，不能假定每次 await 都有 `CoachTurnResult`。App 可以用原有状态文案处理非空结果的 `inputTooLong`、`limitReached`、`fallback` 等状态。每轮可传入 `CoachContext` 与可选 `CancelToken`。

## 取消、新对话与恢复历史

```dart
conversation.cancel(); // 保留展示历史；当前问题和在途结果失效。
conversation.newConversation(); // reset 同一个 agent，并清空展示状态。
conversation.restoreHistory(savedMessages); // App 负责读取和解析存储。

// 页面/会话真正销毁时：
conversation.removeListener(changed);
await conversation.dispose();
// HTTP client 的关闭仍由 App 负责。
```

取消和重置以会话世代屏蔽迟到结果，迟到回复不能追加消息或复活问题。`cancel()` 不清空已完成的展示历史或 agent 历史；`newConversation()` 与 `restoreHistory()` 才 reset 同一个 agent。恢复历史只恢复展示快照，所有历史问题均不可答，不把序列化消息重建为 agent 的工具协议历史。App 应先通过当前门禁重新准入存储的计划/动作，再传入历史消息。恢复后新的输入开始原 agent reset 后的新任务；App 可通过 `CoachContext` 提供当前已采用计划或条件。

`dispose()` 幂等，取消在途、reset 并销毁所持有 agent，关闭状态通知。App 应解除自己的监听并关闭自有 HTTP client。不要把同一个 agent 同时交给两个 controller。

## App 与 UI 的边界

| SDK controller | App |
| --- | --- |
| 同 agent 多轮发送、取消、重置与销毁 | HTTP client、接口地址和 Key；是否显示 AI 入口 |
| 待答问题有效期与提交门禁 | 动作白名单、catalog、profile、CoachContext、安全脚本与本地快捷命令 |
| 单选/多选整理、文字去重、不可变可监听状态 | 存储格式、持久化、错误与进度文案、保存、导航和训练启动 |
| 已门禁的 `ValidatedPlan` / `ValidatedActions` | `TrainingPlan` → `CoachRoutine`、素材解析、训练前检查 |

Flutter 的监听和询问气泡映射示例见 [`ugk_coach_ui` README](../packages/ugk_coach_ui/README.md#接入-ask_user)。UI 包仍只接收呈现 DTO 与操作回调，不依赖 controller 或 coach 包。

## 本轮验收与发布

本轮新增 14 个常规 controller 用例，覆盖多轮澄清到套路、文字/单选/多选及排序、重复提交保护、send 返回后启用、取消/新对话/恢复历史使旧问题失效、同 agent 复用、重复正文去重、未消费输入重试和可监听不可变状态。使用 Flutter 3.44.7 附带的 Dart 3.12.2，新增用例 14/14、SDK 全量 `dart test` 471/471 通过，`dart analyze` 无问题。待审 SHA 见交付回执；尚未合入或发布。

批准后按顺序发布 SDK 新 tag，再从正式远端验证 SmartFit 固定依赖，最后合入 SmartFit main。`release/1.0` 不在本轮写入范围。
