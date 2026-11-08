# Opt-in English presentation / 2026-11-07

HipLab's English UI needs shared conversation and action-detail copy to follow
the host locale. Existing Chinese defaults and action admission remain intact.

- `CoachChatStrings.english()` / `forLanguage()` cover base and derived copy.
  Default construction remains Chinese. Guide, cards, preview, menus, doses,
  equipment, section headings and accessibility labels follow the controller's
  language; stored user messages and authored plans are not translated.
- `CoachChatController.updateLocalization(strings, language, library?,
  conversationPolicy?)` updates presentation and future request language without
  recreating the controller, agent, conversation, gateway lease or current plan.
  The host can update scope-response copy using a policy with `languageTag: 'en'`.
  `CoachAgent.updateScopePolicy` refreshes that responder's cache; scope manifests,
  exclusions and plan admission are unchanged.
- `TrainingLibraryConfig.displayText` defaults to null. Hosts may provide a
  `TrainingLibraryActionText` with optional name, metadata, muscles, cues and
  cautions. Partial values retain catalogue fallbacks; search includes the
  localized name as well as the original name. Media and definitions are untouched.
  HipLab owns its translated catalogue content; the SDK does not bundle App text.
- Android reuses an existing notification channel and refreshes only its name
  and description, preserving user importance, sound and other preferences.

Validation on Flutter 3.44.7: conversation suite 89 passed (including 5 English
contracts), library suite 11 passed, core scope/session/manifest 39 passed.
Analysis is clean for both Flutter packages and modified core paths. Android
compilation and phone acceptance belong to the HipLab package/device records;
no phone, iOS, real-model or native notification acceptance is claimed here.

Candidate branch `codex/coach-english-ui-20261107`; no main merge or tag.
