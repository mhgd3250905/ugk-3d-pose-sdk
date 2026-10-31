# Real HipLab main-round fixtures

These two plans were delivered by the real Coach Agent at SDK
`66dd98a549c1ff5fedecb626a7c88583090a1440`. Both contain a two-round
`main` block. The original native replay executed only one main round.

| Captured plan | Source JSON pointer | Coach card, including 10s prep | Broken native plan, excluding prep | Native host prep |
| --- | --- | ---: | ---: | ---: |
| 10-minute plan, version 1 | `/cases/0/plan` | 629s | 446s | 15s |
| 5-minute plan, version 2 | `/cases/2/plan` | 315s | 197s | 15s |

The two versions intentionally share the same plan ID. `manifest.json` records
the original capture, source commit, file hashes and exact extraction pointers.
It contains no conversation state, model requests or credentials.

The plans preserve every captured field and dose. `catalog.json` retains the
original metadata and exact 11 drill objects used by these plans. The 11 action
kits are byte-for-byte source copies. JSON fixtures use LF so their recorded
hashes remain reproducible across checkouts. The plan object hashes use UTF-8
JSON with sorted object keys, no insignificant whitespace and unescaped Unicode.

The regression tests decode the original plans with `PlanCodec.decodeStrict`,
load the real catalog with `Catalog.fromJson`, and build rhythms from each raw
kit with `Rhythm.fromActionKitJson`. They execute every phase and check progress
and completed/planned sets after each main round. Neither doses nor catalog
cadences are adjusted to make a duration match.

Historical card estimates remain capture facts. Current Coach estimates and
Trainer schedules are checked separately. These authored kits add 5s and 2s
of counted-rep lead respectively; the Coach catalog's `repSeconds` describes
the cycle without that lead. HipLab's 15s prep adds another 5s relative to the
Coach default 10s prep. The tests make both differences explicit.

All timings are offline schedule measurements. They are not device, audio or
visual acceptance evidence. Running these tests makes no model requests.
