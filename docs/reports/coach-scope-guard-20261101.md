# 第 2 批：scope 守卫、SF 任务连续性与调用观测

`codex/coach-scope-guard`，基于 main `2196326ce8a4b216f60d79ddf4135a6d03fbd13d`。第 1 批 main 已按批准快进并推送；
本批未合 main、不打 tag、不动 App 或 pin，不进入第 3 批。
业务实现固定为 `ba86b060850ff7365422ba5422a86e9661741fd9`；最终模型运行在此提交上，随后仅归档文档，
业务 `lib` tree 为 `0b41fe5f4d7880f2012d7412b49ff1639c46011b`。

**第 2 批整体尚未通过：功能 14/14，实际调用预算 10/14。** 最终 17 份非空计划均在名单内并过卡片/执行双门禁；
7 次推荐全部成功。SF five-3 第 3 轮，以及 Hip R1/R2/R4 第 1 轮的调用预算未达标。
没有用 maxSteps、maxResubmits、提前交付、截断或近似计划换取较低调用数。

## 本地门禁

| 包 | 全量测试 | dart analyze --fatal-infos |
|---|---|---|
| ugk_coach | 1683 | 0 |
| ugk_coach_ui | 178 | 0 |
| ugk_trainer | 578 | 0 |
| ugk_trainer_runtime（额外） | 15 | 0 |

旧测试断言未修改。最初发现的默认 ask/output 错误码回归已修复；所有中间失败日志仍在 build/coach-scope-guard。
默认 golden 16/16，逐像素比较通过；PNG 和 baseline manifest 的 16 份 SHA 全部未变，未更新基线、放宽阈值或跳过。

## 范围和接口

SF fixture 为已确认的 219 授权/211 可规划；Hip fixture 为45授权/45可规划候选，
`candidate-not-user-approved`，未生成正式 App manifest；托马斯51仍为候选。
公开接口、参数、原子性、可信告知与接入例见[Coach Scope](../coach-scope-manifest.md)。
新增 scopeManifest/scopePolicy/onSpan 均可不传，旧接入不要求迁移；UI/runtime 代码无改动。
范围守卫覆盖检索、详情、提示、候选、草稿/出卡、focus、历史/快照、开练和预设入口，
含 segment/替代引用/伪造 ID/目录绑定/版本绑定/篡改摘要的测试。

## 真实模型：最终 SF

| 案例 | 卡片/执行 秒 | HTTP | 耗时 ms | 上轮 HTTP/ms | 变化 HTTP/ms | 估算 | 预算通过 |
|---|---|---|---|---|---|---|---|
| five-1 | 313/315 | 4 | 11687 | 9/23122 | -5/-11435 | False | True |
| five-2 | 311/315 | 4 | 13744 | 5/15876 | -1/-2132 | False | True |
| five-3 | 310/311 | 6 | 30676 | 4/15103 | +2/+15573 | False | False |
| five-4 | 313/314 | 4 | 18169 | 7/21019 | -3/-2850 | False | True |
| five-5 | 281/286 | 6 | 27522 | 8/29001 | -2/-1479 | False | True |
| ten-1 | 622/630 | 4 | 15461 | 5/15601 | -1/-140 | False | True |
| twenty-1 | 1205/1223 | 4 | 17612 | 8/28592 | -4/-10980 | False | True |

上轮最大9次与最长29001ms来自不同案例。当前最终轮最大6次、最长30676ms，
不能宣称整体耗时降低。最慢five-3 的 HTTP 实测29431ms，tool inclusive839763µs，fit29µs；
嵌套时长不相加，未将 HTTP 拆成未经测量的网络/排队/模型时间。
预算按正常≤4、一次修复≤6，多次修复单列失败，未调整门限。真实未通过轮：

| 宿主 | 案例 | 轮 | HTTP | 修复 | search attempt | 实际修复原因 |
|---|---|---|---|---|---|---|
| smartfit | five-3 | 3 | 6 | 2 | 3 | scope_content_without_user_evidence,incompatible_action |
| hiplab | R1-partial-substitute | 1 | 8 | 1 | 5 | adopted_action_missing |
| hiplab | R2-partial-remove | 1 | 6 | 0 | 5 |  |
| hiplab | R4-insist | 1 | 6 | 0 | 6 |  |

Hip R1要求的采用项首次未进草稿而被拒绝，修复后交付；R2/R4主要为串行检索。
首轮和最终 SF 的推荐均最终成功；首轮3个推荐轮曾有合法来源拦截后修正，
不能写成零拦截。原 five-3 固定回放证明真实 search/check/show 使用同一有效任务，
不改变第1轮计划内容，第3轮同 planId 追加版本，旧派生 check 缓存按既有规则失效。

逐轮检索 requested/attempt/uncached/localHit/rejected/deferred/unknown、最大请求、token、
网关缓存命中、重编原因、分项 span、偏差和估算标志全见[SF 全表](coach-scope-guard-20261101/smartfit-final.md)。

## 真实模型：最终 HipLab 候选 R1–R6

| 案例 | 最终代码决策 | 卡片/执行 秒 | 最终轮HTTP | ms | 功能 | 全案例预算 |
|---|---|---|---|---|---|---|
| R1-partial-substitute | inScope,substituted | 298/308 | 8 | 27464 | True | False |
| R2-partial-remove | removed | 319/326 | 6 | 20261 | True | False |
| R3-whole-outside | outOfScope | 无计划 | 2 | 7011 | True | True |
| R4-insist | insistedUnavailable | 无计划 | 2 | 4779 | True | False |
| R5-guidance-off | outOfScope | 无计划 | 2 | 6992 | True | True |
| R5-guidance-on | outOfScope | 无计划 | 2 | 7195 | True | True |
| R6-safety-first | safetyBlocked | 无计划 | 3 | 13696 | True | True |

R4首轮实际生成范围内替代计划，第二轮明确坚持时不出计划，旧计划保留。
R5关闭/开启分别独立运行；R6 safetyBlocked、allowPlan=false、plan=null，无动作卡或采用动作，
真实安全暂停说明、专长与范围内建议完整。逐轮全部观测见[Hip 全表](coach-scope-guard-20261101/hiplab-final.md)。

## 原始失败与审计口径

首轮97+37=134次真实HTTP，所有失败保留，见[首轮全表](coach-scope-guard-20261101/first-pass.md)。
修复安全路径后的d8f候选运行96+25=121次，随后发现R1误称已存在的蝴蝶式缺失，
该候选功能通过结论撤销，严格审计新增实质失败，详见[d8f候选留档](coach-scope-guard-20261101/candidate-d8f.md)。
精确名称解析修复后的 `ba86b060850ff7365422ba5422a86e9661741fd9` 仅完整运行一次同组固定样本（83+31=114次）。
共三份不同代码快照，每版一次完整样本，三轮369次真实HTTP全部留档；不补用户答案、
不中断失败后的固定后续轮，没有在同代码下重复抽样或从不同版本挑选成功case拼表。
模型/网关/配置与同时间线回调沿用已授权桥接，App只读；没有设备操作。

全部原工件与原报表保持不变，离线审计新增HTTP为0，六套共42个case SHA非空并核对真实文件，原目录前后SHA一致。
派生问题明确纠正：旧版本顶层check缓存不属于不可变计划内容；
URI尾分隔符不能导致工件名丢首字母；安全告知必须核对当前可信policy模板，不能信任可篡改record.message。
d8f候选R6原报表的字符串误报保留在originalFailures，真实safetyBlocked与安全告知仍严格验证，
缺暂停/专长/建议的反例都不能通过。首轮R6确为实际安全路径缺失，d8f R1确为错误缺失告知，
两项实质失败都保留。最终严格检验已知动作不得假删、删除项不得仍在计划，标准名仅精确解析、不授seen。

[完整 slim JSON](coach-scope-guard-20261101/final-results.json)保留所有逐轮statistics、范围原话/记录、
实际时钟/各block、估算、原始失败、版本内容SHA、rawCase SHA；不包含HTTP请求/响应、私有推理或认证材料。
运行、0HTTP审计与span接口见[工具说明](coach-scope-guard-evaluation.md)。

## Golden 16张

| 文件 | 实际像素差 | 基线SHA未变 |
|---|---|---|
| focus-enter-90ms-dark.png | 0 像素 | True |
| focus-enter-90ms-light.png | 0 像素 | True |
| focus-exit-60ms-dark.png | 0 像素 | True |
| focus-exit-60ms-light.png | 0 像素 | True |
| focus-old-icon-data-dark.png | 0 像素 | True |
| focus-old-icon-data-light.png | 0 像素 | True |
| focus-visible-dark.png | 0 像素 | True |
| focus-visible-light.png | 0 像素 | True |
| task-breath-450ms-dark.png | 0 像素 | True |
| task-breath-450ms-light.png | 0 像素 | True |
| task-complete-260ms-dark.png | 0 像素 | True |
| task-complete-260ms-light.png | 0 像素 | True |
| task-cutout-crossfade-1025ms-dark.png | 0 像素 | True |
| task-cutout-crossfade-1025ms-light.png | 0 像素 | True |
| task-cutout-reveal-305ms-dark.png | 0 像素 | True |
| task-cutout-reveal-305ms-light.png | 0 像素 | True |

## 文件行数和边界

实现提交对main共50文件，+14642/-516行；精确名称修复与审计合同已在该实现提交内。
完整分支文件行数（含归档）见[changes.tsv](coach-scope-guard-20261101/changes.tsv)，最终SHA以Git回执为准。
保留 cupertino_icons：runtime 的 pose_hub_action_browser/trainer_player 实际使用 CupertinoIcons。
iOS、真机播放/性能与各App迁移未验收，仍由各App换pin时验证。Hip/托马斯名单待用户签核。
本批调用预算仍未全部达到，保持独立待审，不据此合main或继续下一批。
