# Changelog

## 0.3.0 — 2026-10-26

- Give expanded routine headers 22 px outer-card top/left clearance, 5 px title/meta spacing, 12 px muted metadata and collapse-button alignment with the first title line. Preserve complete wrapping of large Chinese dose text and shared animation measurements.
- Increase multi-action transparent-cutout card height from 240 to 288 px. Enlarge the actual hero contain frame approximately 30%, preserving text/control clearance, host top-inset semantics, reduced motion and hero-to-first-row continuity. Single-action horizontal cards retain their existing layout.
- Add grouped form question fields, single/multiple selection and a skip action. Keep text/choice presentation supported; hosts must map the new form mode and bind its answer/skip callbacks. Keep the selected solid colors; Kai approved main integration and the minor tag.

## 0.2.1 - 2026-10-26（扁平实色收尾，main 待真机确认）

- Finalize the selected flat UI from `c4d251d` and rerun the complete package suite. Runtime source and interaction/layout contracts are unchanged from 0.2.0; the shelved micro-skeuomorphic candidate is excluded.
- **Migration from 0.1.x:** remove `CoachUiColors.thumb`, `mediaScrim`, `landingHighlight` and `CoachChatList.topColor`; provide `background`, `surfaceRaised`, `outline`, `shadow`, `mediaLabelSurface`. Use `surfaceRaised` and opaque `mediaLabelSurface` for the removed colour roles. These repeat the 0.2.0 breaking changes; this patch adds none.
- Glass dependencies, background filters and glass switches remain absent. Main merge/push waits for Kai's device confirmation. Final SDK-wide checks are recorded in `../ugk_trainer/docs/flat-closeout-2026-10-26.md`.

## 0.2.0 - 2026-10-26

- **Breaking:** replace decorative material configuration with opaque semantic surfaces. `CoachUiColors.thumb` is removed in favour of `surfaceRaised`; `mediaScrim` is removed in favour of the opaque `mediaLabelSurface`; `landingHighlight` is removed without a compatibility field. Add `background`, `outline`, `shadow`, complete `copyWith`, and `light` / `dark` defaults.
- **Breaking:** remove `CoachChatList.topColor` and the example adapter's matching argument. The established optional top-edge fade now reads `CoachUiColors.background`; `topInset`, `fadeTop`, viewport geometry and system-bar ownership stay unchanged.
- Use three opaque levels, a quiet 1 px edge and a shallow fixed shadow for default content and controls. Remove the landing highlight and the hero's translucent gradient; retain a local opaque title backer and normal media cross-fades. No glass switch, compatibility alias, backdrop group, filter or shader path remains.
- Preserve routine expansion/collapse measurements, media flight/source rectangles, cutout builder requests, original control slots, haptics and callbacks. Custom builders still own their widgets and must preserve these layout and interaction contracts.
- Add light/dark and injected-palette checks for opaque pixels, borders, unchanged control geometry and taps. Update the existing system-inset tests to take their fade colour from the injected theme. Verification results are reported with the final candidate; this entry does not assert device validation or publication.

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
