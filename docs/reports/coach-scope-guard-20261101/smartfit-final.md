# Offline audit of retained real-run evidence

New HTTP/model requests: **0**. Raw artifacts unchanged: **true**. This audits the originally recorded code; it does not validate current SDK production changes. Original verdicts and file SHA remain attached.

Functional: **true**; budget: **false**; overall: **false**.

# smartfit scope / budget real gate

Fixed inputs, no resampling, no supplementary answers; failures retained. Manual phases are estimates with the same numeric dual gate.

| Case | Turn | Status | HTTP | search requested / attempts | search uncached / local hit / rejected / deferred / unknown | ms | max request B | prompt / completion / total tokens | gateway prompt-cache hit tokens / unknown calls | repair reasons | card / execution s | estimate | pass |
|---|---:|---|---:|---|---|---:|---:|---|---|---|---|---|---|
| five-1 | 1 | ok | 4 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 11735 | 45556 | 38801 / 1232 / 40033 | 28800 / 0 |  | 619.0 / 627.0 | false | true |
| five-1 | 2 | ok | 3 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 6786 | 43491 | 28842 / 580 / 29422 | 23296 / 0 |  | null / null | null | true |
| five-1 | 3 | ok | 4 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 11687 | 54524 | 50497 / 1169 / 51666 | 34048 / 0 |  | 313.0 / 315.0 | false | true |
| five-2 | 1 | ok | 4 | 3 / 3 | 3 / 0 / 0 / 0 / 0 | 15305 | 50010 | 42656 / 1797 / 44453 | 31232 / 0 |  | 576.0 / 581.0 | false | true |
| five-2 | 2 | ok | 2 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 6872 | 47744 | 22164 / 681 / 22845 | 17152 / 0 |  | null / null | null | true |
| five-2 | 3 | ok | 4 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 13744 | 55230 | 48808 / 1749 / 50557 | 36864 / 0 |  | 311.0 / 315.0 | false | true |
| five-3 | 1 | ok | 3 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 13121 | 44550 | 28538 / 1434 / 29972 | 19584 / 0 |  | 623.0 / 630.0 | false | true |
| five-3 | 2 | ok | 3 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 8280 | 42523 | 29907 / 791 / 30698 | 23552 / 0 |  | null / null | null | true |
| five-3 | 3 | ok | 6 | 3 / 3 | 2 / 0 / 0 / 1 / 0 | 30676 | 62525 | 81275 / 4097 / 85372 | 65792 / 0 | scope_content_without_user_evidence,incompatible_action | 310.0 / 311.0 | false | false |
| five-4 | 1 | ok | 4 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 13580 | 47587 | 40902 / 1550 / 42452 | 30464 / 0 |  | 619.0 / 627.0 | false | true |
| five-4 | 2 | ok | 3 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 9005 | 45843 | 30668 / 942 / 31610 | 24320 / 0 |  | null / null | null | true |
| five-4 | 3 | ok | 4 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 18169 | 52568 | 49027 / 2335 / 51362 | 37760 / 0 |  | 313.0 / 314.0 | false | true |
| five-5 | 1 | ok | 5 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 17344 | 49182 | 50411 / 2114 / 52525 | 39040 / 0 | quote_not_found | 623.0 / 629.0 | false | true |
| five-5 | 2 | ok | 4 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 9385 | 46936 | 38925 / 784 / 39709 | 32128 / 0 |  | null / null | null | true |
| five-5 | 3 | ok | 6 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 27522 | 59770 | 78533 / 3403 / 81936 | 63872 / 0 | replace_too_similar | 281.0 / 286.0 | false | true |
| ten-1 | 1 | ok | 4 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 12828 | 44228 | 38385 / 1247 / 39632 | 28800 / 0 |  | 568.0 / 574.0 | false | true |
| ten-1 | 2 | ok | 4 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 10760 | 49621 | 43011 / 930 / 43941 | 34688 / 0 |  | null / null | null | true |
| ten-1 | 3 | ok | 4 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 15461 | 57138 | 50676 / 1865 / 52541 | 38144 / 0 |  | 622.0 / 630.0 | false | true |
| twenty-1 | 1 | ok | 4 | 1 / 1 | 1 / 0 / 0 / 0 / 0 | 12778 | 51732 | 41196 / 1455 / 42651 | 29312 / 0 |  | 627.0 / 629.0 | false | true |
| twenty-1 | 2 | ok | 4 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 8960 | 49114 | 40144 / 917 / 41061 | 33152 / 0 |  | null / null | null | true |
| twenty-1 | 3 | ok | 4 | 2 / 2 | 2 / 0 / 0 / 0 / 0 | 17612 | 60056 | 52852 / 2133 / 54985 | 39168 / 0 |  | 1205.0 / 1223.0 | false | true |

| Case | Turn | HTTP / tool / fit / recompile inclusive μs | Recompile reasons | Card / execution deviation % |
|---|---:|---|---|---|
| five-1 | 1 | 10627241 / 657889 / 2712 / 0 | [] | 3.166666666666667 / 4.5 |
| five-1 | 2 | 6046589 / 372936 / 0 / 0 | [] | null / null |
| five-1 | 3 | 10747279 / 569896 / 1502 / 0 | [] | 4.333333333333334 / 5.0 |
| five-2 | 1 | 14258473 / 665901 / 46 / 0 | [] | -4.0 / -3.166666666666667 |
| five-2 | 2 | 6183294 / 356679 / 0 / 0 | [] | null / null |
| five-2 | 3 | 12840832 / 544792 / 1183 / 0 | [] | 3.6666666666666665 / 5.0 |
| five-3 | 1 | 12199621 / 589591 / 44 / 0 | [] | 3.833333333333333 / 5.0 |
| five-3 | 2 | 7482810 / 446684 / 0 / 0 | [] | null / null |
| five-3 | 3 | 29477666 / 839763 / 29 / 27 | [scope_content_without_user_evidence, incompatible_action] | 3.3333333333333335 / 3.6666666666666665 |
| five-4 | 1 | 11990386 / 1253642 / 799 / 0 | [] | 3.166666666666667 / 4.5 |
| five-4 | 2 | 8188882 / 428883 / 0 / 0 | [] | null / null |
| five-4 | 3 | 17269505 / 565815 / 167 / 0 | [] | 4.333333333333334 / 4.666666666666667 |
| five-5 | 1 | 16358515 / 628613 / 736 / 9 | [quote_not_found] | 3.833333333333333 / 4.833333333333333 |
| five-5 | 2 | 8592231 / 447011 / 0 / 0 | [] | null / null |
| five-5 | 3 | 25875527 / 1291590 / 125 / 6 | [replace_too_similar] | -6.333333333333334 / -4.666666666666667 |
| ten-1 | 1 | 10862142 / 989560 / 31 / 0 | [] | -5.333333333333334 / -4.333333333333334 |
| ten-1 | 2 | 9950062 / 447667 / 0 / 0 | [] | null / null |
| ten-1 | 3 | 14471352 / 643854 / 487 / 0 | [] | 3.6666666666666665 / 5.0 |
| twenty-1 | 1 | 11868490 / 561471 / 1153 / 0 | [] | 4.5 / 4.833333333333333 |
| twenty-1 | 2 | 8169737 / 442724 / 0 / 0 | [] | null / null |
| twenty-1 | 3 | 16636417 / 628668 / 243 / 0 | [] | 0.4166666666666667 / 1.9166666666666665 |

| Case | Final HTTP/ms | Previous final HTTP/ms | HTTP/ms delta | Current card/execution | Functional / budget / overall |
|---|---|---|---|---|---|
| five-1 | 4 / 11687 | 9 / 23122 | -5 / -11435 | 313.0 / 315.0 | true / true / true |
| five-2 | 4 / 13744 | 5 / 15876 | -1 / -2132 | 311.0 / 315.0 | true / true / true |
| five-3 | 6 / 30676 | 4 / 15103 | 2 / 15573 | 310.0 / 311.0 | true / false / false |
| five-4 | 4 / 18169 | 7 / 21019 | -3 / -2850 | 313.0 / 314.0 | true / true / true |
| five-5 | 6 / 27522 | 8 / 29001 | -2 / -1479 | 281.0 / 286.0 | true / true / true |
| ten-1 | 4 / 15461 | 5 / 15601 | -1 / -140 | 622.0 / 630.0 | true / true / true |
| twenty-1 | 4 / 17612 | 8 / 28592 | -4 / -10980 | 1205.0 / 1223.0 | true / true / true |

Baseline source: docs/reports/fit-executed-duration-20261101/results.json, SF final third turns. Maximum 9 calls and longest 29001 ms belong to different baseline cases. Unknown token/cache values stay null, never zero.

## Retained failures

- five-3: turn3:http_call_budget_exceeded
