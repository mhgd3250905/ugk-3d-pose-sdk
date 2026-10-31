# Captured SmartFit five-minute v3

`plan-v3.json` is the exact SDK-accepted third-turn edit from the +43 saved-plan
probe, SDK `b490eec43b408a8a35ce81a7830833bc6a3ff278`. It is a real model edit
of an imported diagnostic saved plan, not a newly invented five-minute sample.
Its inherited summary remains untouched. `manifest.json` identifies both matching
capture locations, source hashes, SDK/App commits and the host timing adapter.

The catalog contains only the six actual SDK AI-projected drill objects used by
this plan. It was extracted with
`PoseHubAppTestCatalog.fromBytes(originalPackBytes).toAiCatalog().raw`, exactly as
the original host probe. All raw action fields, including nested execution rhythm
and unreviewed/release flags, are retained. Neither repSeconds nor doses are added.

This plan has one `main` round. The main-round fix leaves its timing unchanged:

| Clock | Seconds |
| --- | ---: |
| Captured and current Coach estimate, including default 10s prep | 313 |
| Actual host execution, excluding prep | 335 |
| Actual host execution, including default 10s prep | 345 |

The 32s difference is a separate existing cadence mismatch. The AI projection
has no `assets.videos.repSeconds`, so Coach estimates counted reps at 3s. The
host loads `rhythm.execution`: squat uses 4s cycles plus a 1s lead (+10s), wall
angel uses 4s cycles (+10s), and reverse crunch uses 4s cycles (+12s). Dead bug
uses 3s cycles and contributes no difference. Tests preserve and explain these
facts rather than changing the fixture or weakening a generic timing contract.

Replay uses the source execution-rhythm overrides, advances the real engine
through all phases, and checks all six occurrences and planned/completed sets.
These are offline schedule measurements, with no new model requests or device
operation. The original SDK card acceptance is not device or visual acceptance.

File hashes use source-preserving LF JSON. Object hashes use UTF-8 JSON with
sorted object keys, no insignificant whitespace and unescaped Unicode. No user
turns, conversation state, requests or credentials are included.
