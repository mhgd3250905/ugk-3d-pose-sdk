# Scope 守卫首轮真实模型：完整留档与离线审计

本报告只记录首轮，所有失败保留。没有重抽、补答、截断或覆盖 raw；离线审计与文档导出新增 HTTP **0**。正在另行验收的 `d8f531447016c6b97c84cf8d4c2e64d42bd4fff9` 不由本报告判定通过。

[完整 slim 数据](first-pass-results.json) 保留 29 轮全部 `statistics`、范围记录与原话、原始/审计失败、raw case SHA 与不可变版本证据；没有请求/响应大 payload、私有模型 trace 或认证材料。

## 结论与身份

| 宿主 | 案例/轮 | 原 HTTP | 功能案例 | 预算案例 | 总通过案例 |
|---|---|---|---|---|---|
| smartfit | 7/21 | 97 | 7/7 | 4/7 | 4/7 |
| hiplab | 7/8 | 37 | 6/7 | 4/7 | 3/7 |

SF 功能 7/7，三条预算失败 为 five-2、five-5、ten-1 第 3 轮。Hip 功能 6/7，预算失败为 R1、R2、R4 第 1 轮；R6 是真实安全路径失败，不能归为报表误差。两宿主总门禁均未通过。

首轮记录 HEAD 为 `2196326ce8a4b216f60d79ddf4135a6d03fbd13d`，真实源与 harness 指纹为 `7b3fa8dbae0f426103695d165a34bea4caf7e093d47d3bd12a44cf762571d522`。该 HEAD 只是当时基线；首轮含未提交工作，应以实际指纹识别运行代码，不能用后来的终验提交替代。两批 raw 全程源稳定，导出前再次核对全部哈希值。

原 offline auditor 有路径标签缺陷：`rawFilesSha256` 文件名首字符丢失，case 的 `rawCaseSha256` 为 null。哈希值本身前后稳定。本报告按真实文件名重新计算正确 SHA，并与原审计对应哈希值逐一核对；JSON 保留旧标签和 null 字段，原工件未改。

| 宿主 | 授权/可规划 | 范围状态 | 原目录 | 审计目录 |
|---|---|---|---|---|
| smartfit | 219/211 | approved-sf-219 | build/coach-scope-guard/live-smartfit-r1-20261101 | build/coach-scope-guard/audit-smartfit-r1-20261101-v1 |
| hiplab | 45/45 | candidate-test-fixture | build/coach-scope-guard/live-hiplab-r1-20261101 | build/coach-scope-guard/audit-hiplab-r1-20261101-v1 |

SF 为已定 219/211；Hip 45 仍是候选 fixture，未成为用户签核 manifest。时长来自原宿主同一 SessionBuilder；审计没有另估准备/起拍/换侧或重新运行宿主。批次可并行，不能把耗时相加冒充墙钟时间。

## 逐轮交付与双时钟

秒与偏差 %；±10% 含等号。手动阶段仍标估算。无计划的推荐/拒绝轮为 —。

| 案例/轮 | 状态 | 目标秒 | 卡片/执行秒 | 双偏差% | 估算 | 功能/预算/总 |
|---|---|---|---|---|---|---|
| SF/five-1/1 | ok | 600 | 626/630 | 4.333/5 | ✗ | ✓/✓/✓ |
| SF/five-1/2 | ok | — | —/— | —/— | — | ✓/✓/✓ |
| SF/five-1/3 | ok | 300 | 294/296 | -2/-1.333 | ✗ | ✓/✓/✓ |
| SF/five-2/1 | ok | 600 | 568/574 | -5.333/-4.333 | ✗ | ✓/✓/✓ |
| SF/five-2/2 | ok | — | —/— | —/— | — | ✓/✓/✓ |
| SF/five-2/3 | ok | 300 | 305/308 | 1.667/2.667 | ✗ | ✓/✗/✗ |
| SF/five-3/1 | ok | 600 | 620/627 | 3.333/4.5 | ✗ | ✓/✓/✓ |
| SF/five-3/2 | ok | — | —/— | —/— | — | ✓/✓/✓ |
| SF/five-3/3 | ok | 300 | 313/315 | 4.333/5 | ✗ | ✓/✓/✓ |
| SF/five-4/1 | ok | 600 | 620/627 | 3.333/4.5 | ✗ | ✓/✓/✓ |
| SF/five-4/2 | ok | — | —/— | —/— | — | ✓/✓/✓ |
| SF/five-4/3 | ok | 300 | 312/315 | 4/5 | ✗ | ✓/✓/✓ |
| SF/five-5/1 | ok | 600 | 622/627 | 3.667/4.5 | ✓ | ✓/✓/✓ |
| SF/five-5/2 | ok | — | —/— | —/— | — | ✓/✓/✓ |
| SF/five-5/3 | ok | 300 | 310/314 | 3.333/4.667 | ✗ | ✓/✗/✗ |
| SF/ten-1/1 | ok | 600 | 620/629 | 3.333/4.833 | ✗ | ✓/✓/✓ |
| SF/ten-1/2 | ok | — | —/— | —/— | — | ✓/✓/✓ |
| SF/ten-1/3 | ok | 600 | 622/629 | 3.667/4.833 | ✗ | ✓/✗/✗ |
| SF/twenty-1/1 | ok | 600 | 619/627 | 3.167/4.5 | ✗ | ✓/✓/✓ |
| SF/twenty-1/2 | ok | — | —/— | —/— | — | ✓/✓/✓ |
| SF/twenty-1/3 | ok | 1200 | 1141/1144 | -4.917/-4.667 | ✗ | ✓/✓/✓ |
| Hip/R1-partial-substitute/1 | ok | 300 | 303/313 | 1/4.333 | ✗ | ✓/✗/✗ |
| Hip/R2-partial-remove/1 | ok | 300 | 320/330 | 6.667/10 | ✗ | ✓/✗/✗ |
| Hip/R3-whole-outside/1 | ok | — | —/— | —/— | — | ✓/✓/✓ |
| Hip/R4-insist/1 | ok | 300 | 308/318 | 2.667/6 | ✗ | ✓/✗/✗ |
| Hip/R4-insist/2 | ok | — | —/— | —/— | — | ✓/✓/✓ |
| Hip/R5-guidance-off/1 | ok | — | —/— | —/— | — | ✓/✓/✓ |
| Hip/R5-guidance-on/1 | ok | — | —/— | —/— | — | ✓/✓/✓ |
| Hip/R6-safety-first/1 | ok | — | —/— | —/— | — | ✗/✓/✗ |

## 逐轮 HTTP、检索与预算

HTTP 是实际 send 次数。新检索只计显式 `cacheHit=false`，local hit 独立计数，拒绝/延期/未知不补成新检索。正常 ≤4、恰一次修复 ≤6，多次/未知修复不冒充一次修复。

| 案例/轮 | HTTP | 检索请求/attempt | 新/local/拒绝/延期/未知 | 轮/HTTP ms | HTTP已知/未知 | max request B | 修复/限额/分类 |
|---|---|---|---|---|---|---|---|
| SF/five-1/1 | 4 | 1/1 | 1/0/0/0/0 | 18205/17037 | 4/0 | 48474 | 0/4/normal |
| SF/five-1/2 | 3 | 2/2 | 2/0/0/0/0 | 10892/10017 | 3/0 | 46449 | 0/4/normal |
| SF/five-1/3 | 5 | 2/2 | 2/0/0/0/0 | 28449/26622 | 5/0 | 60910 | 1/6/one_repair |
| SF/five-2/1 | 4 | 1/1 | 1/0/0/0/0 | 12794/11393 | 4/0 | 42526 | 0/4/normal |
| SF/five-2/2 | 3 | 2/2 | 2/0/0/0/0 | 12155/10240 | 3/0 | 51055 | 0/4/normal |
| SF/five-2/3 | 7 | 3/3 | 3/0/0/0/0 | 26819/25015 | 7/0 | 58968 | 1/6/one_repair |
| SF/five-3/1 | 5 | 2/2 | 2/0/0/0/0 | 15572/14403 | 5/0 | 47126 | 1/6/one_repair |
| SF/five-3/2 | 5 | 2/2 | 2/0/0/0/0 | 12666/11753 | 5/0 | 50855 | 1/6/one_repair |
| SF/five-3/3 | 5 | 2/2 | 2/0/0/0/0 | 20571/19325 | 5/0 | 60489 | 1/6/one_repair |
| SF/five-4/1 | 4 | 2/2 | 2/0/0/0/0 | 11137/10084 | 4/0 | 44217 | 0/4/normal |
| SF/five-4/2 | 3 | 2/2 | 2/0/0/0/0 | 7715/6850 | 3/0 | 42382 | 0/4/normal |
| SF/five-4/3 | 4 | 3/3 | 3/0/0/0/0 | 16668/15438 | 4/0 | 59489 | 0/4/normal |
| SF/five-5/1 | 4 | 2/2 | 2/0/0/0/0 | 13679/12519 | 4/0 | 50997 | 0/4/normal |
| SF/five-5/2 | 3 | 3/3 | 3/0/0/0/0 | 8674/7772 | 3/0 | 48597 | 0/4/normal |
| SF/five-5/3 | 6 | 1/1 | 1/0/0/0/0 | 24364/22901 | 6/0 | 64871 | 2/—/multiple_or_unknown_repairs |
| SF/ten-1/1 | 6 | 2/2 | 1/0/0/1/0 | 17237/16177 | 6/0 | 50916 | 1/6/one_repair |
| SF/ten-1/2 | 6 | 3/3 | 3/0/0/0/0 | 15268/14194 | 6/0 | 47994 | 1/6/one_repair |
| SF/ten-1/3 | 7 | 5/5 | 5/0/0/0/0 | 29066/27738 | 7/0 | 61501 | 0/4/normal |
| SF/twenty-1/1 | 4 | 1/1 | 1/0/0/0/0 | 13899/12906 | 4/0 | 45025 | 0/4/normal |
| SF/twenty-1/2 | 5 | 2/2 | 2/0/0/0/0 | 13066/12064 | 5/0 | 50890 | 1/6/one_repair |
| SF/twenty-1/3 | 4 | 3/3 | 3/0/0/0/0 | 19684/18522 | 4/0 | 64129 | 0/4/normal |
| Hip/R1-partial-substitute/1 | 12 | 5/5 | 5/0/0/0/0 | 36613/35986 | 12/0 | 63848 | 4/—/multiple_or_unknown_repairs |
| Hip/R2-partial-remove/1 | 6 | 4/4 | 4/0/0/0/0 | 17786/17547 | 6/0 | 51062 | 0/4/normal |
| Hip/R3-whole-outside/1 | 2 | 0/0 | 0/0/0/0/0 | 10298/10197 | 2/0 | 19057 | 0/4/normal |
| Hip/R4-insist/1 | 5 | 4/4 | 4/0/0/0/0 | 13538/13328 | 5/0 | 46856 | 0/4/normal |
| Hip/R4-insist/2 | 2 | 0/0 | 0/0/0/0/0 | 6166/6064 | 2/0 | 48992 | 0/4/normal |
| Hip/R5-guidance-off/1 | 2 | 0/0 | 0/0/0/0/0 | 6108/6020 | 2/0 | 18294 | 0/4/normal |
| Hip/R5-guidance-on/1 | 2 | 0/0 | 0/0/0/0/0 | 6623/6529 | 2/0 | 19450 | 0/4/normal |
| Hip/R6-safety-first/1 | 6 | 3/3 | 3/0/0/0/0 | 23872/23662 | 6/0 | 49697 | 1/6/one_repair |

## 逐轮公开 token 与网关缓存

Token 格式为已知合计（已知/未知调用）。网关 prompt-cache token 与本地检索缓存分列；未知保留 null/—。

| 案例/轮 | prompt | completion | total | 网关命中 token | 缓存已知/未知/coverage |
|---|---|---|---|---|---|
| SF/five-1/1 | 38585 (4/0) | 2207 (4/0) | 40792 (4/0) | 23808 | 4/0/complete |
| SF/five-1/2 | 31094 (3/0) | 1149 (3/0) | 32243 (3/0) | 24448 | 3/0/complete |
| SF/five-1/3 | 68451 (5/0) | 3637 (5/0) | 72088 (5/0) | 52992 | 5/0/complete |
| SF/five-2/1 | 37166 (4/0) | 1114 (4/0) | 38280 (4/0) | 27776 | 4/0/complete |
| SF/five-2/2 | 34505 (3/0) | 1069 (3/0) | 35574 (3/0) | 25856 | 3/0/complete |
| SF/five-2/3 | 91504 (7/0) | 3165 (7/0) | 94669 (7/0) | 75264 | 7/0/complete |
| SF/five-3/1 | 48961 (5/0) | 1743 (5/0) | 50704 (5/0) | 37888 | 5/0/complete |
| SF/five-3/2 | 56206 (5/0) | 1061 (5/0) | 57267 (5/0) | 48256 | 5/0/complete |
| SF/five-3/3 | 67100 (5/0) | 2620 (5/0) | 69720 (5/0) | 47744 | 5/0/complete |
| SF/five-4/1 | 38103 (4/0) | 1262 (4/0) | 39365 (4/0) | 28416 | 4/0/complete |
| SF/five-4/2 | 29061 (3/0) | 734 (3/0) | 29795 (3/0) | 22912 | 3/0/complete |
| SF/five-4/3 | 50904 (4/0) | 2184 (4/0) | 53088 (4/0) | 37632 | 4/0/complete |
| SF/five-5/1 | 40781 (4/0) | 1694 (4/0) | 42475 (4/0) | 28800 | 4/0/complete |
| SF/five-5/2 | 30004 (3/0) | 741 (3/0) | 30745 (3/0) | 24320 | 3/0/complete |
| SF/five-5/3 | 84901 (6/0) | 3057 (6/0) | 87958 (6/0) | 59136 | 6/0/complete |
| SF/ten-1/1 | 60034 (6/0) | 2013 (6/0) | 62047 (6/0) | 46976 | 6/0/complete |
| SF/ten-1/2 | 60224 (6/0) | 1366 (6/0) | 61590 (6/0) | 50176 | 6/0/complete |
| SF/ten-1/3 | 97215 (7/0) | 3461 (7/0) | 100676 (7/0) | 72576 | 7/0/complete |
| SF/twenty-1/1 | 38246 (4/0) | 1543 (4/0) | 39789 (4/0) | 28416 | 4/0/complete |
| SF/twenty-1/2 | 53304 (5/0) | 1239 (5/0) | 54543 (5/0) | 43520 | 5/0/complete |
| SF/twenty-1/3 | 55439 (4/0) | 2595 (4/0) | 58034 (4/0) | 39552 | 4/0/complete |
| Hip/R1-partial-substitute/1 | 154729 (12/0) | 4528 (12/0) | 159257 (12/0) | 115456 | 12/0/complete |
| Hip/R2-partial-remove/1 | 60939 (6/0) | 2140 (6/0) | 63079 (6/0) | 47488 | 6/0/complete |
| Hip/R3-whole-outside/1 | 9859 (2/0) | 616 (2/0) | 10475 (2/0) | 8448 | 2/0/complete |
| Hip/R4-insist/1 | 49207 (5/0) | 1612 (5/0) | 50819 (5/0) | 37504 | 5/0/complete |
| Hip/R4-insist/2 | 25568 (2/0) | 490 (2/0) | 26058 (2/0) | 23552 | 2/0/complete |
| Hip/R5-guidance-off/1 | 9675 (2/0) | 379 (2/0) | 10054 (2/0) | 8448 | 2/0/complete |
| Hip/R5-guidance-on/1 | 9950 (2/0) | 573 (2/0) | 10523 (2/0) | 4864 | 2/0/complete |
| Hip/R6-safety-first/1 | 61165 (6/0) | 2963 (6/0) | 64128 (6/0) | 48768 | 6/0/complete |

## 逐轮 context 观测

LCP/tail 单位 bytes；prefix 为完整/变化/未知数。soft 超限不替代 hard 门禁。

| 案例/轮 | LCP max | prefix完整/变化/未知 | 架构失败 | 折叠请求 | tail内容/序列化 max | soft/hard超限 |
|---|---|---|---|---|---|---|
| SF/five-1/1 | 28260 | 3/0/1 | 0 | 0 | 3146/3498 | 0/0 |
| SF/five-1/2 | 33402 | 2/1/0 | 0 | 1 | 2276/2552 | 0/0 |
| SF/five-1/3 | 42273 | 4/1/0 | 0 | 1 | 3791/4237 | 2/0 |
| SF/five-2/1 | 25617 | 3/0/1 | 0 | 0 | 3234/3594 | 0/0 |
| SF/five-2/2 | 28105 | 2/1/0 | 0 | 1 | 2005/2251 | 0/0 |
| SF/five-2/3 | 41496 | 6/1/0 | 0 | 1 | 2959/3311 | 3/0 |
| SF/five-3/1 | 29851 | 4/0/1 | 0 | 0 | 3164/3516 | 0/0 |
| SF/five-3/2 | 35638 | 4/1/0 | 0 | 1 | 1816/2054 | 0/0 |
| SF/five-3/3 | 39572 | 4/1/0 | 0 | 1 | 3221/3609 | 2/0 |
| SF/five-4/1 | 27492 | 3/0/1 | 0 | 0 | 3006/3336 | 0/0 |
| SF/five-4/2 | 29307 | 2/1/0 | 0 | 1 | 2175/2437 | 0/0 |
| SF/five-4/3 | 36261 | 3/1/0 | 0 | 1 | 3069/3425 | 1/0 |
| SF/five-5/1 | 28609 | 3/0/1 | 0 | 0 | 3539/3935 | 0/0 |
| SF/five-5/2 | 35488 | 2/1/0 | 0 | 1 | 1261/1387 | 0/0 |
| SF/five-5/3 | 41004 | 4/2/0 | 0 | 2 | 3473/3881 | 3/0 |
| SF/ten-1/1 | 30875 | 5/0/1 | 0 | 0 | 4143/4587 | 0/0 |
| SF/ten-1/2 | 34755 | 5/1/0 | 0 | 1 | 2180/2442 | 0/0 |
| SF/ten-1/3 | 38569 | 5/2/0 | 0 | 2 | 4011/4483 | 4/0 |
| SF/twenty-1/1 | 26640 | 3/0/1 | 0 | 0 | 3063/3413 | 0/0 |
| SF/twenty-1/2 | 30722 | 4/1/0 | 0 | 1 | 2102/2362 | 0/0 |
| SF/twenty-1/3 | 41479 | 3/1/0 | 0 | 1 | 5009/5591 | 2/0 |
| Hip/R1-partial-substitute/1 | 47470 | 10/1/1 | 0 | 1 | 4677/5161 | 6/0 |
| Hip/R2-partial-remove/1 | 34044 | 5/0/1 | 0 | 0 | 3641/4019 | 0/0 |
| Hip/R3-whole-outside/1 | 4523 | 1/0/1 | 0 | 0 | 781/859 | 0/0 |
| Hip/R4-insist/1 | 30344 | 4/0/1 | 0 | 0 | 3109/3459 | 0/0 |
| Hip/R4-insist/2 | 33460 | 2/0/0 | 0 | 0 | 1332/1446 | 0/0 |
| Hip/R5-guidance-off/1 | 4520 | 1/0/1 | 0 | 0 | 775/853 | 0/0 |
| Hip/R5-guidance-on/1 | 4613 | 1/0/1 | 0 | 0 | 864/946 | 0/0 |
| Hip/R6-safety-first/1 | 33119 | 5/0/1 | 0 | 0 | 2099/2339 | 0/0 |

## 逐轮 span 分项

各类为 count/inclusive μs。HTTP 是完整响应往返，不拆造网络/模型时段；tool 含 fit，不能把各类耗时相加当轮耗时。首轮 ten-1/1 将 `skipped_after_error` 误标 recompile，预算仍按真实失败 batch=1；原 span 未篡改。

| 案例/轮 | HTTP | tool | fit | recompile | 原 recompile 原因 |
|---|---|---|---|---|---|
| SF/five-1/1 | 4/17080785 | 5/655232 | 1/2452 | 0/0 | — |
| SF/five-1/2 | 3/10041671 | 5/489311 | 0/0 | 0/0 | — |
| SF/five-1/3 | 5/26685073 | 7/1292328 | 1/60 | 1/17 | incompatible_action |
| SF/five-2/1 | 4/11431037 | 5/929315 | 1/136 | 0/0 | — |
| SF/five-2/2 | 3/10301603 | 5/1041591 | 0/0 | 0/0 | — |
| SF/five-2/3 | 7/25078411 | 8/876750 | 1/38 | 1/14 | incompatible_action |
| SF/five-3/1 | 5/14435885 | 7/773410 | 1/243 | 1/11 | quote_not_found |
| SF/five-3/2 | 5/11801943 | 5/476942 | 0/0 | 1/7 | unseen_actions |
| SF/five-3/3 | 5/19370333 | 7/821247 | 2/1616 | 1/8 | replace_too_similar |
| SF/five-4/1 | 4/10109489 | 6/677323 | 1/177 | 0/0 | — |
| SF/five-4/2 | 3/6872527 | 5/462186 | 0/0 | 0/0 | — |
| SF/five-4/3 | 4/15469320 | 7/767464 | 1/1112 | 0/0 | — |
| SF/five-5/1 | 4/12549404 | 6/757557 | 1/1843 | 0/0 | — |
| SF/five-5/2 | 3/7794484 | 5/504967 | 0/0 | 0/0 | — |
| SF/five-5/3 | 6/22954241 | 7/968756 | 3/2063 | 2/15 | replace_too_similar；plan_check_failed |
| SF/ten-1/1 | 6/16219323 | 7/653863 | 1/430 | 2/13 | quote_not_found；skipped_after_error |
| SF/ten-1/2 | 6/14238982 | 7/622264 | 0/0 | 1/9 | unseen_actions |
| SF/ten-1/3 | 7/27799161 | 9/857219 | 1/595 | 0/0 | — |
| SF/twenty-1/1 | 4/12934321 | 5/587676 | 1/288 | 0/0 | — |
| SF/twenty-1/2 | 5/12104301 | 6/587593 | 0/0 | 1/10 | unseen_actions |
| SF/twenty-1/3 | 4/18556754 | 7/726454 | 1/85 | 0/0 | — |
| Hip/R1-partial-substitute/1 | 12/36104562 | 16/361447 | 2/3204 | 4/49 | scope_source_without_user_evidence；scope_source_without_user_evidence；missing_parameters；plan_check_failed |
| Hip/R2-partial-remove/1 | 6/17601575 | 8/122089 | 1/58 | 0/0 | — |
| Hip/R3-whole-outside/1 | 2/10210067 | 1/18057 | 0/0 | 0/0 | — |
| Hip/R4-insist/1 | 5/13365718 | 8/111577 | 1/58 | 0/0 | — |
| Hip/R4-insist/2 | 2/6083972 | 1/18769 | 0/0 | 0/0 | — |
| Hip/R5-guidance-off/1 | 2/6029526 | 1/18366 | 0/0 | 0/0 | — |
| Hip/R5-guidance-on/1 | 2/6544689 | 1/18376 | 0/0 | 0/0 | — |
| Hip/R6-safety-first/1 | 6/23705984 | 8/102695 | 0/0 | 1/7 | missing_parameters |

## 原始失败与审计结论

只列原始或审计有失败的轮；未列出的轮两套失败列表都为空。审计纠正旧版本顶层派生 check 缓存被当作不可变计划，以及历史拒绝回执串入当前轮原因；内容、剂量、安全、范围、双时长阈值与预算没有放宽。Hip 原本未纳入的预算明确独立列失败。

| 案例/轮 | 原始失败 | 审计功能失败 | 审计预算失败 |
|---|---|---|---|
| SF/five-1/3 | edit_did_not_preserve_first_plan_baseline | — | — |
| SF/five-2/3 | http_call_budget_exceeded；edit_did_not_preserve_first_plan_baseline | — | http_call_budget_exceeded |
| SF/five-3/3 | edit_did_not_preserve_first_plan_baseline | — | — |
| SF/five-4/3 | edit_did_not_preserve_first_plan_baseline | — | — |
| SF/five-5/3 | http_call_budget_exceeded；edit_did_not_preserve_first_plan_baseline | — | http_call_budget_exceeded |
| SF/ten-1/3 | http_call_budget_exceeded；edit_did_not_preserve_first_plan_baseline | — | http_call_budget_exceeded |
| SF/twenty-1/3 | edit_did_not_preserve_first_plan_baseline | — | — |
| Hip/R1-partial-substitute/1 | — | — | http_call_budget_exceeded |
| Hip/R2-partial-remove/1 | — | — | http_call_budget_exceeded |
| Hip/R4-insist/1 | — | — | http_call_budget_exceeded |
| Hip/R6-safety-first/1 | missing_actual_safetyBlocked_code_decision；missing_safety_explanation | missing_actual_safetyBlocked_code_decision；missing_safety_explanation | — |

five-2 第 3 轮：start/set → 三次独立 search（第二次 0 结果）→ draft 因 `n-windshield` 不在当轮合法已见候选被 `incompatible_action` 拦截 → 修正 draft → show，共 7 HTTP / 1 修复，无本地命中。HTTP 25015ms、轮 26819ms、fit 38μs；超预算来源是额外检索/修复，不能归咎于配时。ten-1 最终 5 次检索 / 0 修复、7 HTTP 仍超正常预算；five-5 两次修复仍保留为多修复失败。

## 不可变版本证据

SF 第 2 轮原版本完整不变；第 3 轮原 v1 只有顶层 `check` 变 null，其余字段、计划/剂量与数组顺序完全相同。每次同 planId 连续追加，最新交付 check 通过且计划与实际交付相同。JSON 逐轮保留 immutable 前后 SHA、完整差异路径与交付计划 SHA；不使用空列表子集通过。

| SF案例 | 原版本数 | 最终版本号 | immutable前缀相同 | 旧前缀全部差异 | 最新check/交付相同 |
|---|---|---|---|---|---|
| five-1 | 1 | 1,2 | ✓ | $.check | ✓/✓ |
| five-2 | 1 | 1,2 | ✓ | $.check | ✓/✓ |
| five-3 | 1 | 1,2,3 | ✓ | $.check | ✓/✓ |
| five-4 | 1 | 1,2 | ✓ | $.check | ✓/✓ |
| five-5 | 1 | 1,2,3,4 | ✓ | $.check | ✓/✓ |
| ten-1 | 1 | 1,2 | ✓ | $.check | ✓/✓ |
| twenty-1 | 1 | 1,2 | ✓ | $.check | ✓/✓ |

five-3/five-5 的未交付中间草稿仍在；five-5 v3 check=false，随后 v4 修复通过。只核对最终交付新版，不假称每个历史草稿都通过。首轮嵌套 fit 的旧 epoch 观测也留在 raw，不改写。

## Hip 范围原话与实际路径

R5 off/on 为独立会话，R4 为固定两轮。R6 离线预检可得 safetyBlocked，真实首轮却为 outOfScope 且缺安全说明，因此功能失败；这与后来的终验 R6 分开。公开记录和告知原文在 JSON。

| 案例 | 固定逐轮原话 | 最终实际kind | 功能/预算 |
|---|---|---|---|
| R1-partial-substitute | 在家入门开胯5分钟，徒手和瑜伽垫，无不适。把蝴蝶式和站姿侧抬腿安排进去；本App没有的动作用同部位动作替代并说明。 | substituted,inScope | ✓/✗ |
| R2-partial-remove | 在家入门5分钟，徒手、瑜伽垫和弹力带，无不适。练蝴蝶式做大腿内侧拉伸并加入弹力带坐姿划船练背；没有练背动作就去掉练背部分并告诉我，保留开胯计划。 | removed | ✓/✗ |
| R3-whole-outside | 在家，入门，徒手和瑜伽垫，无不适。只练胸背5分钟，不练髋部、腿或臀部。 | outOfScope | ✓/✓ |
| R4-insist | 在家入门5分钟，徒手和瑜伽垫，无不适。我想安排站姿侧抬腿这个动作。<br>不要换动作，只能是站姿侧抬腿，不接受替代。没有就直接告诉我，不要假装已经安排。 | insistedUnavailable | ✓/✗ |
| R5-guidance-off | 在家入门，只练胸背5分钟，徒手和瑜伽垫，无不适，不练髋部、腿或臀部。 | outOfScope | ✓/✓ |
| R5-guidance-on | 在家入门，只练胸背5分钟，徒手和瑜伽垫，无不适，不练髋部、腿或臀部。 | outOfScope | ✓/✓ |
| R6-safety-first | 膝盖有不适，做动作会痛，请避免加重疼痛。在家入门只有瑜伽垫，想练胸背5分钟，还指定站姿侧抬腿，给最相似替代就行。 | outOfScope | ✗/✓ |

## 正确 raw case SHA

以下 SHA 按真实文件名重算，已与旧 audit 对应值核对；不是沿用其 null 字段。

| 宿主/案例 | 原文件 | SHA-256 |
|---|---|---|
| smartfit/five-1 | build/coach-scope-guard/live-smartfit-r1-20261101/five-1.json | e408715bb715f7214c417e55ea8fb8a80abe5c4d96ee1f673d59e68024308565 |
| smartfit/five-2 | build/coach-scope-guard/live-smartfit-r1-20261101/five-2.json | 9075d35825e5d392a6a916dfa09df648624c339eeb584a08f33de5414ae0ec59 |
| smartfit/five-3 | build/coach-scope-guard/live-smartfit-r1-20261101/five-3.json | 191be6117cdb07d7efeb542edeae419e09f769d3f42838d7571e1c5bd70d40b7 |
| smartfit/five-4 | build/coach-scope-guard/live-smartfit-r1-20261101/five-4.json | 8290f264f1bb3582c5c187b46cc6f9c6ac365c1a7e3217360331e142bd0e5ae5 |
| smartfit/five-5 | build/coach-scope-guard/live-smartfit-r1-20261101/five-5.json | da643b22393d893f2cf05559c408a4157d24fad785c042bb23955f826ca59b14 |
| smartfit/ten-1 | build/coach-scope-guard/live-smartfit-r1-20261101/ten-1.json | beb18adb178470fe7f413fe3aad8674e4980ebf630ca5d7def34338bc8296dec |
| smartfit/twenty-1 | build/coach-scope-guard/live-smartfit-r1-20261101/twenty-1.json | f39e634c02fff262c1693617a1f862faaa5c02ccc4a30928b5b528a5b6b43d42 |
| hiplab/R1-partial-substitute | build/coach-scope-guard/live-hiplab-r1-20261101/R1-partial-substitute.json | d157cb3afcd8eca3158a1940d9f4fe2aac79f5d84703ef1adb66984f940aa660 |
| hiplab/R2-partial-remove | build/coach-scope-guard/live-hiplab-r1-20261101/R2-partial-remove.json | 30b9b7bed84b9cb17e9eccdfca88bd4312da63ccca5de6c6bb2aed6759d31efc |
| hiplab/R3-whole-outside | build/coach-scope-guard/live-hiplab-r1-20261101/R3-whole-outside.json | f6b0aa0d9356ad79896ba9b016a51a53cbbd54550938d93edd289d939ddd178a |
| hiplab/R4-insist | build/coach-scope-guard/live-hiplab-r1-20261101/R4-insist.json | c67e7ffc9e860f2a967a670d99fb4ed7d79170a853446cba3b1844564cbc0b68 |
| hiplab/R5-guidance-off | build/coach-scope-guard/live-hiplab-r1-20261101/R5-guidance-off.json | 04221d3ace18017437d97947f612e2359347282567a67ccac875dc31f5f889a0 |
| hiplab/R5-guidance-on | build/coach-scope-guard/live-hiplab-r1-20261101/R5-guidance-on.json | c54ad69d18a669685df1d63b64665caee80c48506a7b17071a3a209bf1512241 |
| hiplab/R6-safety-first | build/coach-scope-guard/live-hiplab-r1-20261101/R6-safety-first.json | 612483624264188b82bf7d9dc5c7c31d29706eb4b1e01da626e4e5c7b72257c3 |

完整 raw 留在忽略的 build 目录，不提交压缩大文件，不以新摘要取代原失败。首轮 gate 均未通过；后续提交与最终真实门禁由独立报表说明。
