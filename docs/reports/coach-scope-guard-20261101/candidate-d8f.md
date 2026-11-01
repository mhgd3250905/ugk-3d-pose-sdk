# d8f 候选：原始验收与严格重审留档

本页是已被后续修复替代的候选，不是最终交付结论。源 d8f531447016c6b97c84cf8d4c2e64d42bd4fff9，原真实调用96+25=121。未重抽、未覆盖原工件。

严格v3审计为0HTTP、raw SHA不变：SF功能7/7；Hip功能6/7。R6的可信安全告知已实际正确，但R1误称“本 App 没有蝴蝶式”，最终计划又含s-butterfly，属于实质告知缺陷。

新增保留失败：known_allowed_source_marked_unavailable:s-butterfly、removed_source_still_in_plan:s-butterfly、false_app_unavailable_claim:s-butterfly。后续ba86b06修复完整标准名解析、记录名/ID一致性和审计合同，不能把该候选记成功能14/14。

以下完整表格来自v3审计；其原失败和正确case SHA仍见SDK build/coach-scope-guard/audit-*-final-d8f5314-20261101-v3/summary.json。

# Offline audit of retained real-run evidence

New HTTP/model requests: **0**. Raw artifacts unchanged: **true**. This audits the originally recorded code; it does not validate current SDK production changes. Original verdicts and file SHA remain attached.

Functional: **true**; budget: **false**; overall: **false**.

# smartfit scope / budget real gate

Fixed inputs, no resampling, no supplementary answers; failures retained. Manual phases are estimates with the same numeric dual gate.

| Case | Turn | Status | HTTP | search requested / attempts | search uncached / local hit / rejected / deferred / unknown | ms | max request B | prompt / completion / total tokens | gateway prompt-cache hit tokens / unknown calls | repair reasons | card / execution s | estimate | pass |
|---|---:|---|---:|---|---|---:|---:|---|---|---|---|---|---|
| five-1 | 1 | ok | 4 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 15122 | 49819 | 40247 / 1673 / 41920 | 25088 / 0 |  | 622.0 / 630.0 | false | true |
| five-1 | 2 | ok | 3 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 9455 | 47716 | 30733 / 954 / 31687 | 24576 / 0 |  | null / null | null | true |
| five-1 | 3 | ok | 4 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 17003 | 59504 | 51335 / 2018 / 53353 | 37504 / 0 |  | 312.0 / 315.0 | false | true |
| five-2 | 1 | ok | 5 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 13471 | 48983 | 50689 / 1643 / 52332 | 39424 / 0 | quote_not_found | 619.0 / 627.0 | false | true |
| five-2 | 2 | ok | 3 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 9033 | 46902 | 30566 / 768 / 31334 | 24576 / 0 |  | null / null | null | true |
| five-2 | 3 | ok | 7 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 24595 | 62355 | 94092 / 2632 / 96724 | 77824 / 0 | replace_too_similar,plan_check_failed,replace_too_similar | 310.0 / 315.0 | false | false |
| five-3 | 1 | ok | 4 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 13399 | 43261 | 37719 / 1204 / 38923 | 28672 / 0 |  | 620.0 / 627.0 | false | true |
| five-3 | 2 | ok | 4 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 11924 | 49240 | 42713 / 1022 / 43735 | 34176 / 0 |  | null / null | null | true |
| five-3 | 3 | ok | 7 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 29564 | 60810 | 91748 / 3490 / 95238 | 75648 / 0 | replace_too_similar,plan_check_failed | 288.0 / 291.0 | false | false |
| five-4 | 1 | ok | 4 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 15430 | 55032 | 42454 / 1872 / 44326 | 29568 / 0 |  | 628.0 / 630.0 | false | true |
| five-4 | 2 | ok | 3 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 8130 | 38580 | 26717 / 627 / 27344 | 19584 / 0 |  | null / null | null | true |
| five-4 | 3 | ok | 8 | 4 / 4 | 4 / 0 / 0 / 0 / 0 | 46003 | 65273 | 115476 / 5908 / 121384 | 75008 / 0 | plan_check_failed | 303.1 / 309.0 | false | false |
| five-5 | 1 | ok | 4 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 11754 | 49454 | 40909 / 1260 / 42169 | 29568 / 0 |  | 620.0 / 627.0 | false | true |
| five-5 | 2 | ok | 3 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 9316 | 46873 | 30770 / 841 / 31611 | 24704 / 0 |  | null / null | null | true |
| five-5 | 3 | ok | 5 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 19688 | 61350 | 69797 / 2563 / 72360 | 54144 / 0 | replace_too_similar | 290.0 / 294.0 | false | true |
| ten-1 | 1 | ok | 6 | 3 / 3 | 3 / 0 / 0 / 0 / 0 | 20216 | 53862 | 64803 / 2286 / 67089 | 51456 / 0 | quote_not_found | 620.0 / 627.0 | false | true |
| ten-1 | 2 | ok | 4 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 12929 | 41053 | 37292 / 1271 / 38563 | 28928 / 0 |  | null / null | null | true |
| ten-1 | 3 | ok | 4 | 4 / 4 | 4 / 0 / 0 / 0 / 0 | 28024 | 62959 | 57042 / 4141 / 61183 | 42368 / 0 |  | 619.0 / 623.0 | false | true |
| twenty-1 | 1 | ok | 4 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 13897 | 47668 | 39787 / 1414 / 41201 | 29312 / 0 |  | 619.0 / 627.0 | false | true |
| twenty-1 | 2 | ok | 4 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 11114 | 45630 | 39189 / 1051 / 40240 | 31872 / 0 |  | null / null | null | true |
| twenty-1 | 3 | ok | 6 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 24590 | 64867 | 85106 / 3404 / 88510 | 58368 / 0 | plan_check_failed | 1141.0 / 1153.0 | false | true |

| Case | Turn | HTTP / tool / fit / recompile inclusive μs | Recompile reasons | Card / execution deviation % |
|---|---:|---|---|---|
| five-1 | 1 | 13780733 / 808066 / 5838 / 0 | [] | 3.6666666666666665 / 5.0 |
| five-1 | 2 | 8517149 / 466862 / 0 / 0 | [] | null / null |
| five-1 | 3 | 15873867 / 657591 / 2767 / 0 | [] | 4.0 / 5.0 |
| five-2 | 1 | 12163181 / 855460 / 1640 / 12 | [quote_not_found] | 3.166666666666667 / 4.5 |
| five-2 | 2 | 7993598 / 582941 / 0 / 0 | [] | null / null |
| five-2 | 3 | 22393448 / 1574531 / 1298 / 23 | [replace_too_similar, plan_check_failed, replace_too_similar] | 3.3333333333333335 / 5.0 |
| five-3 | 1 | 12309221 / 672693 / 144 / 0 | [] | 3.3333333333333335 / 4.5 |
| five-3 | 2 | 10979817 / 491754 / 0 / 0 | [] | null / null |
| five-3 | 3 | 27959981 / 1154146 / 377 / 17 | [replace_too_similar, plan_check_failed] | -4.0 / -3.0 |
| five-4 | 1 | 14294366 / 731397 / 3777 / 0 | [] | 4.666666666666667 / 5.0 |
| five-4 | 2 | 7181964 / 432799 / 0 / 0 | [] | null / null |
| five-4 | 3 | 44414747 / 1122075 / 315 / 7 | [plan_check_failed] | 1.033333333333341 / 3.0 |
| five-5 | 1 | 10549551 / 739411 / 1230 / 0 | [] | 3.3333333333333335 / 4.5 |
| five-5 | 2 | 8429766 / 444511 / 0 / 0 | [] | null / null |
| five-5 | 3 | 18338391 / 891039 / 90 / 6 | [replace_too_similar] | -3.3333333333333335 / -2.0 |
| ten-1 | 1 | 18877740 / 896398 / 952 / 10 | [quote_not_found] | 3.3333333333333335 / 4.5 |
| ten-1 | 2 | 11976531 / 516971 / 0 / 0 | [] | null / null |
| ten-1 | 3 | 26576027 / 898204 / 80 / 0 | [] | 3.166666666666667 / 3.833333333333333 |
| twenty-1 | 1 | 12662646 / 754491 / 508 / 0 | [] | 3.166666666666667 / 4.5 |
| twenty-1 | 2 | 10170234 / 513087 / 0 / 0 | [] | null / null |
| twenty-1 | 3 | 23219804 / 881585 / 167 / 6 | [plan_check_failed] | -4.916666666666666 / -3.916666666666667 |

| Case | Final HTTP/ms | Previous final HTTP/ms | HTTP/ms delta | Current card/execution | Functional / budget / overall |
|---|---|---|---|---|---|
| five-1 | 4 / 17003 | 9 / 23122 | -5 / -6119 | 312.0 / 315.0 | true / true / true |
| five-2 | 7 / 24595 | 5 / 15876 | 2 / 8719 | 310.0 / 315.0 | true / false / false |
| five-3 | 7 / 29564 | 4 / 15103 | 3 / 14461 | 288.0 / 291.0 | true / false / false |
| five-4 | 8 / 46003 | 7 / 21019 | 1 / 24984 | 303.1 / 309.0 | true / false / false |
| five-5 | 5 / 19688 | 8 / 29001 | -3 / -9313 | 290.0 / 294.0 | true / true / true |
| ten-1 | 4 / 28024 | 5 / 15601 | -1 / 12423 | 619.0 / 623.0 | true / true / true |
| twenty-1 | 6 / 24590 | 8 / 28592 | -2 / -4002 | 1141.0 / 1153.0 | true / true / true |

Baseline source: docs/reports/fit-executed-duration-20261101/results.json, SF final third turns. Maximum 9 calls and longest 29001 ms belong to different baseline cases. Unknown token/cache values stay null, never zero.

## Retained failures

- five-2: turn3:http_call_budget_exceeded
- five-3: turn3:http_call_budget_exceeded
- five-4: turn3:http_call_budget_exceeded


# Offline audit of retained real-run evidence

New HTTP/model requests: **0**. Raw artifacts unchanged: **true**. This audits the originally recorded code; it does not validate current SDK production changes. Original verdicts and file SHA remain attached.

Functional: **false**; budget: **false**; overall: **false**.

# hiplab scope / budget real gate

Fixed inputs, no resampling, no supplementary answers; failures retained. Manual phases are estimates with the same numeric dual gate.

| Case | Turn | Status | HTTP | search requested / attempts | search uncached / local hit / rejected / deferred / unknown | ms | max request B | prompt / completion / total tokens | gateway prompt-cache hit tokens / unknown calls | repair reasons | card / execution s | estimate | pass |
|---|---:|---|---:|---|---|---:|---:|---|---|---|---|---|---|
| R1-partial-substitute | 1 | ok | 5 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 18143 | 49088 | 51316 / 2348 / 53664 | 35072 / 0 |  | 293.0 / 302.0 | false | false |
| R2-partial-remove | 1 | ok | 5 | 3 / 3 | 3 / 0 / 0 / 0 / 0 | 16320 | 50566 | 51507 / 1750 / 53257 | 38912 / 0 |  | 300.0 / 311.0 | false | false |
| R3-whole-outside | 1 | ok | 2 | 0 / 0 | 0 / 0 / 0 / 0 / 0 | 5586 | 19796 | 10242 / 480 / 10722 | 8960 / 0 |  | null / null | null | true |
| R4-insist | 1 | ok | 4 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 13440 | 43670 | 37251 / 1569 / 38820 | 27776 / 0 |  | 290.0 / 301.0 | false | true |
| R4-insist | 2 | ok | 2 | 0 / 0 | 0 / 0 / 0 / 0 / 0 | 5384 | 45686 | 23729 / 527 / 24256 | 21760 / 0 |  | null / null | null | true |
| R5-guidance-off | 1 | ok | 2 | 0 / 0 | 0 / 0 / 0 / 0 / 0 | 6432 | 19498 | 10173 / 467 / 10640 | 8960 / 0 |  | null / null | null | true |
| R5-guidance-on | 1 | ok | 3 | 0 / 0 | 0 / 0 / 0 / 0 / 0 | 8785 | 22423 | 16166 / 879 / 17045 | 10240 / 0 | invalid_json | null / null | null | true |
| R6-safety-first | 1 | ok | 2 | 0 / 0 | 0 / 0 / 0 / 0 / 0 | 11136 | 23013 | 11089 / 1234 / 12323 | 8832 / 0 |  | null / null | null | true |

| Case | Turn | HTTP / tool / fit / recompile inclusive μs | Recompile reasons | Card / execution deviation % |
|---|---:|---|---|---|
| R1-partial-substitute | 1 | 17797490 / 201595 / 3789 / 0 | [] | -2.3333333333333335 / 0.6666666666666667 |
| R2-partial-remove | 1 | 16142089 / 109535 / 1652 / 0 | [] | 0.0 / 3.6666666666666665 |
| R3-whole-outside | 1 | 5494560 / 18437 / 0 / 0 | [] | null / null |
| R4-insist | 1 | 13268010 / 99931 / 180 / 0 | [] | -3.3333333333333335 / 0.33333333333333337 |
| R4-insist | 2 | 5283926 / 26365 / 0 / 0 | [] | null / null |
| R5-guidance-off | 1 | 6330350 / 18742 / 0 / 0 | [] | null / null |
| R5-guidance-on | 1 | 8635142 / 57131 / 0 / 14 | [invalid_json] | null / null |
| R6-safety-first | 1 | 11002597 / 21398 / 0 / 0 | [] | null / null |

| Case | Final HTTP/ms | Previous final HTTP/ms | HTTP/ms delta | Current card/execution | Functional / budget / overall |
|---|---|---|---|---|---|
| R1-partial-substitute | 5 / 18143 | null / null | null / null | 293.0 / 302.0 | false / false / false |
| R2-partial-remove | 5 / 16320 | null / null | null / null | 300.0 / 311.0 | true / false / false |
| R3-whole-outside | 2 / 5586 | null / null | null / null | null / null | true / true / true |
| R4-insist | 2 / 5384 | null / null | null / null | null / null | true / true / true |
| R5-guidance-off | 2 / 6432 | null / null | null / null | null / null | true / true / true |
| R5-guidance-on | 3 / 8785 | null / null | null / null | null / null | true / true / true |
| R6-safety-first | 2 / 11136 | null / null | null / null | null / null | true / true / true |

Baseline source: docs/reports/fit-executed-duration-20261101/results.json, SF final third turns. Maximum 9 calls and longest 29001 ms belong to different baseline cases. Unknown token/cache values stay null, never zero.

## Retained failures

- R1-partial-substitute: turn1:known_allowed_source_marked_unavailable:s-butterfly
- R1-partial-substitute: turn1:removed_source_still_in_plan:s-butterfly
- R1-partial-substitute: turn1:false_app_unavailable_claim:s-butterfly
- R1-partial-substitute: turn1:http_call_budget_exceeded
- R2-partial-remove: turn1:http_call_budget_exceeded
