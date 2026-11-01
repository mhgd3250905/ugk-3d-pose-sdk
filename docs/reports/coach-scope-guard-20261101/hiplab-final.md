# Offline audit of retained real-run evidence

New HTTP/model requests: **0**. Raw artifacts unchanged: **true**. This audits the originally recorded code; it does not validate current SDK production changes. Original verdicts and file SHA remain attached.

Functional: **true**; budget: **false**; overall: **false**.

# hiplab scope / budget real gate

Fixed inputs, no resampling, no supplementary answers; failures retained. Manual phases are estimates with the same numeric dual gate.

| Case | Turn | Status | HTTP | search requested / attempts | search uncached / local hit / rejected / deferred / unknown | ms | max request B | prompt / completion / total tokens | gateway prompt-cache hit tokens / unknown calls | repair reasons | card / execution s | estimate | pass |
|---|---:|---|---:|---|---|---:|---:|---|---|---|---|---|---|
| R1-partial-substitute | 1 | ok | 8 | 5 / 5 | 5 / 0 / 0 / 0 / 0 | 27464 | 58612 | 93656 / 2929 / 96585 | 75008 / 0 | adopted_action_missing | 298.0 / 308.0 | false | false |
| R2-partial-remove | 1 | ok | 6 | 5 / 5 | 5 / 0 / 0 / 0 / 0 | 20261 | 56617 | 67089 / 2403 / 69492 | 52096 / 0 |  | 319.0 / 326.0 | false | false |
| R3-whole-outside | 1 | ok | 2 | 0 / 0 | 0 / 0 / 0 / 0 / 0 | 7011 | 20797 | 10515 / 541 / 11056 | 9088 / 0 |  | null / null | null | true |
| R4-insist | 1 | ok | 6 | 6 / 6 | 6 / 0 / 0 / 0 / 0 | 15954 | 51782 | 64994 / 1850 / 66844 | 51584 / 0 |  | 297.0 / 307.0 | false | false |
| R4-insist | 2 | ok | 2 | 0 / 0 | 0 / 0 / 0 / 0 / 0 | 4779 | 50037 | 20231 / 397 / 20628 | 17408 / 0 |  | null / null | null | true |
| R5-guidance-off | 1 | ok | 2 | 0 / 0 | 0 / 0 / 0 / 0 / 0 | 6992 | 19628 | 10209 / 566 / 10775 | 9088 / 0 |  | null / null | null | true |
| R5-guidance-on | 1 | ok | 2 | 0 / 0 | 0 / 0 / 0 / 0 / 0 | 7195 | 20990 | 10517 / 690 / 11207 | 9088 / 0 |  | null / null | null | true |
| R6-safety-first | 1 | ok | 3 | 0 / 0 | 0 / 0 / 0 / 0 / 0 | 13696 | 24984 | 17965 / 1276 / 19241 | 14976 / 0 |  | null / null | null | true |

| Case | Turn | HTTP / tool / fit / recompile inclusive μs | Recompile reasons | Card / execution deviation % |
|---|---:|---|---|---|
| R1-partial-substitute | 1 | 27090564 / 235819 / 2279 / 10 | [adopted_action_missing] | -0.6666666666666667 / 2.666666666666667 |
| R2-partial-remove | 1 | 20067034 / 119556 / 40 / 0 | [] | 6.333333333333334 / 8.666666666666668 |
| R3-whole-outside | 1 | 6926312 / 21970 / 0 / 0 | [] | null / null |
| R4-insist | 1 | 15739329 / 146265 / 141 / 0 | [] | -1.0 / 2.3333333333333335 |
| R4-insist | 2 | 4696699 / 22749 / 0 / 0 | [] | null / null |
| R5-guidance-off | 1 | 6904033 / 19752 / 0 / 0 | [] | null / null |
| R5-guidance-on | 1 | 7106600 / 17629 / 0 / 0 | [] | null / null |
| R6-safety-first | 1 | 13587642 / 40559 / 0 / 0 | [] | null / null |

| Case | Final HTTP/ms | Previous final HTTP/ms | HTTP/ms delta | Current card/execution | Functional / budget / overall |
|---|---|---|---|---|---|
| R1-partial-substitute | 8 / 27464 | null / null | null / null | 298.0 / 308.0 | true / false / false |
| R2-partial-remove | 6 / 20261 | null / null | null / null | 319.0 / 326.0 | true / false / false |
| R3-whole-outside | 2 / 7011 | null / null | null / null | null / null | true / true / true |
| R4-insist | 2 / 4779 | null / null | null / null | null / null | true / false / false |
| R5-guidance-off | 2 / 6992 | null / null | null / null | null / null | true / true / true |
| R5-guidance-on | 2 / 7195 | null / null | null / null | null / null | true / true / true |
| R6-safety-first | 3 / 13696 | null / null | null / null | null / null | true / true / true |

Baseline source: docs/reports/fit-executed-duration-20261101/results.json, SF final third turns. Maximum 9 calls and longest 29001 ms belong to different baseline cases. Unknown token/cache values stay null, never zero.

## Retained failures

- R1-partial-substitute: turn1:http_call_budget_exceeded
- R2-partial-remove: turn1:http_call_budget_exceeded
- R4-insist: turn1:http_call_budget_exceeded
