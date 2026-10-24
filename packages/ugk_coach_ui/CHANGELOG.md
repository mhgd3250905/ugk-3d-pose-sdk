# Changelog

## 0.1.1 - 2026-10-24

- Approved and published as `ugk_coach_ui-v0.1.1` at `3302d6235a39e2c2b4b51fa196cc32b37c31b54c`.

- Wrap long localized routine doses within the available width and let each expanded row grow. Keep the same measured geometry for rows, media/flyer destinations and animation collision bands.
- Cover Chinese long doses, circuit/segment labels, 320 px viewports and 2x text in both themes, including expansion, collapse and interruption.
- No network, credential or host application dependencies. Public widget interfaces remain compatible with 0.1.0.

## 0.1.0

- Extract the established conversation list, message/option/greeting/typing
  widgets and routine card layout/expansion choreography into a Flutter package.
- Add text, single-choice and multiple-choice clarification bubbles with
  explicit host-controlled availability and pending-answer protection.
- Expose independent presentation snapshots, theme/copy injection and host
  control builders. Networking, credentials, admission, storage and navigation
  remain with the host application.
