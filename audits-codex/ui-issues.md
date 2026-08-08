# UI and UX Audit

## Scope and method

This review covers the Flutter mobile application and the server-hosted setup page. The primary evidence is source inspection, widget tests, the full Flutter test and analyzer runs, and a live HTTP check of the setup page. Interactive browser rendering was not available in the audit environment, so responsive and accessibility conclusions that require real rendering are explicitly called out as verification gaps rather than treated as passed.

The product currently presents several unavailable areas deliberately because production MLS encryption is not wired. Honest gating is preferable to exposing an unsafe partial implementation, but it also means the present build is not a launch-ready messenger.

## Findings

### UI-01 - The core messaging experience is intentionally unavailable

- **Severity:** Critical
- **Location:** `mobile/lib/features/chat/chat_screen.dart`; `mobile/lib/core/app_state.dart`; `mobile/lib/crypto/`; attachments, calls, recovery, and identity areas
- **Description:** Message bodies are represented by redacted placeholders while `UnavailableCryptoService` is active. Sending attachments is disabled, encryption identity is pending, and calls and recovery are presented as coming soon. These are central product flows, not peripheral settings.
- **Why it matters for production:** A messenger cannot meet its primary user promise until users can safely send, receive, read, and recover encrypted messages. Releasing the current UI as a general-availability product would create a severe expectation mismatch even though the disabled states are honest.
- **Recommended fix:** Complete the production MLS integration and its review gates first. Then run an end-to-end UX pass across first message, reply, edit/delete, attachment, offline send, multi-device, recovery, and error recovery states. Retain explicit fail-closed screens whenever crypto initialization or identity verification fails.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** Release crypto gate; native ABI packaging; device-link and recovery design; LOG-01, LOG-06, SEC-03, TEST-01.

### UI-02 - The composer clears before a message is durably accepted

- **Severity:** High
- **Location:** `mobile/lib/features/chat/chat_screen.dart`, send handler; `mobile/lib/core/app_state.dart`, `sendMessageTo`
- **Description:** The chat screen clears the text controller before encryption and durable outbox insertion have completed. If crypto initialization, encryption, or local database insertion fails, the user's text disappears and there is no queued message to retry.
- **Why it matters for production:** Losing a composed message is a high-friction trust failure, especially during the exact offline and flaky-network conditions an outbox is meant to handle.
- **Recommended fix:** Keep the draft until the message has been encrypted and atomically persisted to the outbox. On failure, restore or retain the draft, focus the composer, and show a human-readable retry action. Persist drafts by conversation if navigation or process death is in scope.
- **Blocker before production:** Yes, for enabling message send.
- **Related risks or dependencies:** The outbox must define a durable acceptance boundary; LOG-02 and LOG-06.

### UI-03 - Session restoration has no explicit startup or recovery state

- **Severity:** High
- **Location:** `mobile/lib/main.dart`; `mobile/lib/core/app_state.dart`, `tryRestoreSession`; root routing around `ConnectScreen`
- **Description:** `runApp` occurs before the unawaited session restore finishes. The app can initially show the connect flow while an existing session is still being restored, and restore failures are collapsed into session reset without a dedicated explanation or recovery action.
- **Why it matters for production:** Users can see a misleading logged-out state, start entering duplicate connection details, or conclude that their account was lost. A secure local-storage failure can also be mistaken for an ordinary logout.
- **Recommended fix:** Introduce explicit `initializing`, `authenticated`, `unauthenticated`, and `restoreFailed` application states. Render a stable branded startup surface while credentials and the encrypted database are opened. Give recoverable failures a safe diagnostic message and clear choices such as retry, restore account, or explicitly clear local data.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** Secure storage and database-key recovery policy; LOG-03 and SEC-05.

### UI-04 - Responsive and accessibility conformance is not evidenced

- **Severity:** High
- **Location:** Entire Flutter UI; `mobile/test/`; setup page in `server/websetup/index.html`
- **Description:** The suite has widget tests but no golden viewport matrix, automated semantics assertions, or recorded real-device accessibility run. The project's own production checklist still requires device and accessibility evidence. The in-app browser backend was unavailable during this audit, so the current screens could not be interactively exercised with viewport and assistive-technology tooling.
- **Why it matters for production:** Layout overflow, inaccessible controls, poor text scaling, incorrect focus order, and contrast regressions frequently escape source review. These failures can make account setup or messaging impossible for real users.
- **Recommended fix:** Establish a release matrix for small Android, large Android, small iPhone, large iPhone, tablet, landscape, 200% text scale, dark/light modes if supported, screen reader traversal, switch/keyboard navigation, reduced motion, and contrast. Add golden and semantics tests for the connect, list, chat, settings, recovery, and destructive-confirmation screens. Record manual sign-off per release.
- **Blocker before production:** Yes, before claiming supported device and accessibility coverage.
- **Related risks or dependencies:** Signed device builds; TEST-04; UI-05 and UI-07.

### UI-05 - Authentication form labels are not reliably exposed as accessible names

- **Severity:** Medium
- **Location:** `mobile/lib/features/auth/connect_screen.dart`, `_Field` and password fields
- **Description:** Visible labels are separate `Text` widgets placed before `TextFormField` rather than being connected through `InputDecoration.labelText`, `Semantics`, or another explicit association. Hints are not a durable substitute for labels, and the confirm-password field has no equivalent identifying hint.
- **Why it matters for production:** Screen-reader users may hear an unlabeled edit control, especially when navigating directly between fields. Hints also disappear after input and should not be the sole identifier.
- **Recommended fix:** Give every field a persistent, programmatically associated label and meaningful autofill hints, keyboard types, actions, and error semantics. Verify announcement order with TalkBack and VoiceOver rather than relying only on widget structure.
- **Blocker before production:** Yes if accessibility is a launch requirement; otherwise it remains a high-priority pre-launch defect.
- **Related risks or dependencies:** UI-04; localization work will need to cover semantics strings.

### UI-06 - Push settings contradict implemented platform behavior

- **Severity:** Medium
- **Location:** `mobile/lib/features/settings/settings_screen.dart`, `_PushStatusRow` and push provider UI; `mobile/ios/Runner/AppDelegate.swift`; Android push registration code
- **Description:** The settings UI always states that push is unavailable on iOS and that Apple integration is pending, even though the iOS delegate implements APNs registration and background wake handling and the server has an APNs provider. It also exposes an Android UnifiedPush provider row without platform-specific filtering. Separately, Android FCM registration is blocked by a VAPID precondition even though the server supports FCM-only registration.
- **Why it matters for production:** Users and support staff cannot tell whether push is unsupported, misconfigured, or functioning. Incorrect platform controls erode confidence and make notification troubleshooting much harder.
- **Recommended fix:** Drive the screen from a typed platform/provider capability model. Show actual permission, OS token, server subscription, and last-registration status; hide irrelevant providers; provide retry and test-wake actions. Remove the VAPID requirement from the FCM-only path.
- **Blocker before production:** Yes if push is part of the launch promise; otherwise the UI discrepancy itself is Medium.
- **Related risks or dependencies:** LOG-09; real FCM/APNs/UnifiedPush integration tests; privacy-safe notification product decision.

### UI-07 - The web setup card can overflow narrow mobile viewports

- **Severity:** Medium
- **Location:** `server/websetup/index.html`, `main` width and padding rules
- **Description:** The setup card uses `width: min(560px, calc(100vw - 32px))` plus 32px padding without a global `box-sizing: border-box`. Under the default content-box model, total rendered width can exceed the viewport on narrow screens.
- **Why it matters for production:** Initial setup is often performed from a phone. Horizontal clipping can hide input edges or actions at the first interaction with the product.
- **Recommended fix:** Apply `box-sizing: border-box` consistently, use a mobile-first inline padding scale, and test at 320px width, large text, zoom, and landscape. Add an automated screenshot or browser layout assertion for the smallest supported viewport.
- **Blocker before production:** No, but should be fixed before a public self-hosted release.
- **Related risks or dependencies:** UI-04; browser visual verification.

### UI-08 - Connection setup defaults to a misleading phone-local address and hides probe status

- **Severity:** Medium
- **Location:** `mobile/lib/features/auth/connect_screen.dart`, default server URL and setup-status probe
- **Description:** The server field defaults to `http://localhost:8080`. On a physical phone, `localhost` means the phone rather than the user's Veritra server. The setup-status probe runs without a clear loading, success, or actionable failure state.
- **Why it matters for production:** A first-time user can repeatedly fail with an address that looks endorsed by the app, while network, TLS, DNS, and setup-state errors are difficult to distinguish.
- **Recommended fix:** Use an empty field or a clearly marked development-only default, explain the expected HTTPS origin, and provide QR/deep-link onboarding. Show probe progress and translate failures into actionable categories: invalid URL, insecure transport, DNS, TLS, timeout, server not Veritra, setup required, or server version incompatible.
- **Blocker before production:** No for an expert-only preview; yes for a general self-hosted onboarding claim.
- **Related risks or dependencies:** Certificate policy, invite/deep-link design, product onboarding.

### UI-09 - Search can expose raw implementation errors to users

- **Severity:** Medium
- **Location:** `mobile/lib/features/search/search_screen.dart`, search exception handler
- **Description:** The search screen displays `err.toString()` in a snackbar instead of consistently using the application's human-readable error mapping.
- **Why it matters for production:** Raw transport, parsing, or server error text is confusing, may disclose implementation details, and produces inconsistent support messages.
- **Recommended fix:** Route search failures through a centralized error-to-UX mapper. Give expected cases dedicated states: offline, session expired, query too short, server unavailable, and retryable failure. Log only a privacy-safe diagnostic code for support correlation.
- **Blocker before production:** No.
- **Related risks or dependencies:** Logging/privacy policy; localization; observability identifiers.

### UI-10 - Device refresh failures have no contained error state

- **Severity:** Medium
- **Location:** `mobile/lib/features/settings/settings_screen.dart`, direct device refresh action and devices section
- **Description:** A direct device-list refresh path awaits the API call without local error handling. Failure can surface as an unhandled async error or leave stale content without explaining whether the account has no other devices or the refresh failed.
- **Why it matters for production:** Device management is a security-sensitive area. Users must be able to distinguish an empty device list from a failed security check.
- **Recommended fix:** Model loading, loaded-empty, loaded, stale-with-warning, and failed states. Preserve the last known list on retryable failure, show the last refresh time, and provide retry. Make revoke progress and failure similarly explicit.
- **Blocker before production:** No, unless multi-device management is enabled at launch.
- **Related risks or dependencies:** Device-link/revoke backend semantics; session-expiry handling.

### UI-11 - Creation dialogs rely too heavily on server-side validation

- **Severity:** Medium
- **Location:** Community and channel creation dialogs in `mobile/lib/features/communities/`; invite and profile forms
- **Description:** Several dialogs do not consistently enforce local trimmed non-empty values, documented maximum lengths, or immediate field-level feedback before making the API request. Server errors then become generic dialog or snackbar failures.
- **Why it matters for production:** Avoidable round trips and generic errors make forms feel unfinished and are particularly frustrating on slow or intermittent connections.
- **Recommended fix:** Share validation rules with clearly documented server limits, validate on submit and after first interaction, keep user input after failure, disable duplicate submission, and attach errors to the relevant field. Server validation must remain authoritative.
- **Blocker before production:** No.
- **Related risks or dependencies:** API contract/versioning; localization of validation text.

### UI-12 - User-facing strings are hard-coded and have no localization framework

- **Severity:** Low
- **Location:** Flutter feature screens and widgets throughout `mobile/lib/`
- **Description:** User-facing text is embedded directly in widgets with no localization catalog or locale-aware formatting strategy.
- **Why it matters for production:** Copy becomes difficult to audit and update consistently. Accessibility labels, dates, counts, and future translations will require broad code edits.
- **Recommended fix:** Introduce Flutter localization generation, extract product and semantics strings, and centralize relative time/count formatting. Keep server-provided protocol values separate from localized display copy.
- **Blocker before production:** No for an explicitly English-only launch.
- **Related risks or dependencies:** UI-05; error mapping; copy review.

## Recommended UI Priorities Before Production

1. Keep release blocked until encrypted messaging and its primary send/receive/recovery flows are genuinely usable (UI-01).
2. Establish durable composer acceptance so a failed send cannot erase user content (UI-02).
3. Make startup and secure-storage recovery an explicit, deterministic flow (UI-03).
4. Complete real-device responsive, accessibility, and text-scaling evidence (UI-04 and UI-05).
5. Correct and instrument provider-specific push settings (UI-06).
6. Make first-run server connection actionable and remove the misleading production default (UI-08).
7. Fix setup-page mobile sizing and verify it in a browser matrix (UI-07).
8. Standardize error, empty, loading, and retry states across search, devices, and creation dialogs (UI-09 through UI-11).
9. Add localization infrastructure before the UI surface becomes significantly larger (UI-12).

## UI launch checklist

- [ ] Production crypto path enables safe message rendering and sending.
- [ ] Draft survives every pre-outbox failure.
- [ ] Startup never flashes a false unauthenticated state.
- [ ] Connect, chat, list, settings, recovery, and destructive actions pass the device/accessibility matrix.
- [ ] Push status matches actual platform and provider state.
- [ ] Every networked surface has loading, empty, error, offline, and retry behavior.
- [ ] Setup page passes 320px, zoom, and large-text checks.
