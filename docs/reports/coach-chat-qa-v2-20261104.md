# 聊天页 QA v2 接入验证

基线：`f584c126925a3776faf9ed22893826aa63cdbb44`（main / `ugk_trainer-v0.7.0`）。
分支：`codex/coach-chat-qa-v2`。实现不改 App，也不携带 AI 标签数据或新增依赖。

## 接线与兼容

`CoachAppProfile.agentMode` 默认 `legacy`，显式 `qaV2` 时由同一个网关 lease 驱动
`CoachQaAgent`；原核心保留动作范围、计划准入、存储与训练接口。App 可通过 `aiTags`
配置注入自己的标签。QA 会话状态单独放在可选快照字段，旧 envelope 仍有效。

新增回归覆盖条件单选/多选、失效问题不能重提、说明与快捷按钮、推荐编号、全计划
编号（含热身与收操）、按第二项替换、保存/恢复一致性、调用用量、取消和新对话隔离。
QA 原型计划未提供摘要，适配层补用已有模型正文，并使用现有 `ai` 来源标记，保证
计划仍经过原门禁并在恢复时重新校验，未放宽范围或训练门槛。

## 静态检查与全量回归

| 包 | analyze | 全量测试 |
| --- | --- | ---: |
| ugk_coach（根目录） | 通过 | 1557 |
| ugk_trainer_runtime | 通过 | 71 |
| ugk_trainer | 通过 | 581 |
| ugk_coach_ui | 通过 | 183 |
| ugk_coach_chat | 通过 | 73 |

合计 **2465 通过、0 失败**，含新增 8 项控制器测试与 3 项组件测试；未过滤小屏或
大字号专项。根目录执行 `dart analyze` / `dart test --reporter expanded`，Flutter 包
对 `lib test`（UI 另含 `tool`）执行 `dart analyze --fatal-infos`，执行
`flutter test --no-pub --reporter expanded` 全量测试。日志保留在
`build/qa-v2-validation/`。真实模型页面测试另外 1 项通过。

## 真实模型聊天页

2026-11-04，`deepseek-v4.1-flash`，挂载真实 `CoachChatPage` 并点击页面控件：

| 输入 / 页面操作 | 结果 | 模型调用 | 耗时 |
| --- | --- | ---: | ---: |
| 想练背 | 显示地点单选 | 2 | 4.113 秒 |
| 点击居家 | 显示器械多选 | 2 | 4.193 秒 |
| 选择都没有（徒手），点击确认 | 推荐 4 张编号为 1–4 的动作卡，显示快捷按钮 | 2 | 10.679 秒 |
| 换第 2 个 | 正确定位 `[2]`，说明当前徒手库无替代，保留原动作；其他三卡不变 | 2 | 6.559 秒 |

成功流程 4 轮、8 次请求，模型耗时合计约 25.5 秒。第 2 项为 `lats-A`，
本次没有发生实际替换，不能把“目标定位正确”写成“替换成功”；有候选时的第二项
替换由离线控制器测试覆盖。模型本轮未返回 assumption，相关渲染由组件测试覆盖。

本地证据：`build/qa-v2-live-20261104-04/report.json`、`run.log` 和四张 PNG。
标签从 Pose-Hub 只读 Git 快照 `5d17c24` 提取到忽略的 build 目录，仅作为 App 注入。
运行器前几次因原生 HTTP / WidgetTester 异步截图与手势等待问题中止；修正运行器后
完整流程退出码为 0。没有启动模拟器或连接设备；此记录不代表原生媒体或真机验收。
