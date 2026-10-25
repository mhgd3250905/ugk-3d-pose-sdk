# Changelog

## 0.1.3 - 2026-10-25

- Add optional host media rendering via `CoachUiBuilders.media` and `CoachMediaRequest`. Use the same renderer for folded covers, still cutout flyers and thumbnails; null falls back to the original asset image.
- Add opt-in `CoachPlanCard.cutoutTopInset` in outer-card coordinates. Cutouts can paint into the existing top padding without changing card height, controls or row measurements. Folded cover and flyer share the same start rectangle.
- Keep default placement, expansion timing, reduced motion and host-owned navigation. No asset processing, networking or application dependencies are added.

## 0.1.2 - 2026-10-24

- Add host-controlled `CoachChatList.topInset` and `fadeTop` for content scrolling beneath transparent system bars. The inset is part of list content; it does not shrink or offset the viewport. Turning the fade off removes its overlay entirely.
- Preserve the default 48 px content padding and top fade for existing hosts. Safe-area and system-bar decisions remain with the host.
- Cover default compatibility, a 32 px content inset, and actual painted message pixels entering the top 32 px after scrolling.

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
