# Flutter Mobile Testing Gap Audit & Plan

## 1. System Overview & Architecture

The Veritra mobile client (`mobile/`) is a cross-platform Flutter application (Flutter 3.44.0) targeting Android and iOS. It utilizes:
- **Local Storage**: `drift` 2.34.3 with `sqlite3mc` 3.5.0 and ChaCha20 encryption (`mobile/lib/storage/encrypted_database.dart`), keyed with a random 256-bit key from `flutter_secure_storage`.
- **Sync & Outbox**: `sync_service.dart` providing durable message enqueue, optimistic UI rendering, and incremental catch-up.
- **Push & Calls**: `push_service.dart` (generic APNs/FCM background wake) and `call_service.dart` (WebRTC + TURN signaling).
- **UI Architecture**: K2 Bone design system (`mobile/lib/ui/tokens.dart`, `theme.dart`, `widgets/`), strictly modularized across `features/auth`, `features/chat`, `features/communities`, `features/search`, and `features/settings`.

---

## 2. Current Test Coverage Inventory

### Existing Flutter Test Files (`mobile/test/`)
- `api_contract_test.dart`: Verifies Flutter client models match live Go HTTP endpoints.
- `app_payload_test.dart`: Validates VAP1 payload serialization and 256-byte bucket padding.
- `app_state_test.dart` (17.7 KB): State provider updates, account switching, and auth flow.
- `encrypted_local_store_test.dart`: Local database schema creation, table migrations, and ChaCha20 key initialization.
- `native_crypto_bindings_test.dart`: Basic FFI ABI validation.
- `chat_visuals_test.dart` & `profile_screen_test.dart`: Visual layouts for chat bubbles and user profile views.
- `ui_actionable_test.dart`, `ui_features_test.dart`, `ui_fixes_test.dart`, `ui_remaining_test.dart`: Comprehensive widget interaction tests for non-crypto UI flows (DM creation, member list, mute, block/unblock, channel list).

---

## 3. Critical Testing Gaps Identified

### Gap MB-01: Message Outbox Crash & Interruption Resilience
- **Defect**: Existing outbox tests verify in-memory enqueuing. There are no tests simulating an unexpected app process kill (SIGKILL/power cut) while an outbox message is transitioning from `enqueued` -> `encrypting` -> `uploading` -> `sent`.
- **Risk**: Message duplication, permanent message loss in outbox queue, or deadlocked retry loops on app restart.
- **Remediation Test Plan**:
  1. Add `mobile/test/outbox_recovery_test.dart`.
  2. Enqueue 50 messages, trigger an artificial database connection teardown during step 25, re-instantiate `AppState` and `SyncService`.
  3. Assert that all 50 messages recover their exact prior status, resume transmission, and zero messages are dropped or duplicated.

### Gap MB-02: Encrypted Database Key Recovery Fail-Closed Verification
- **Defect**: `encrypted_local_store_test.dart` tests standard unlock with a valid key. It does not test: (a) secure storage key corruption/deletion, (b) key mismatch (tampered ciphertext header), or (c) device lock status during background wake.
- **Risk**: Silent fallback to unencrypted database or unhandled crash without notifying the user to re-authenticate or restore backup.
- **Remediation Test Plan**:
  1. Add `mobile/test/database_key_failure_test.dart`.
  2. Provide corrupted, truncated, or all-zero 256-bit keys to `EncryptedDatabase`.
  3. Assert that initialization fails closed immediately, throws `EncryptedStorageKeyException`, and prevents any unauthenticated DB access.

### Gap MB-03: Background Push Isolate & Silent Wake Budget
- **Defect**: Push tests only inspect payload JSON formatting. There are no tests executing in an isolated background Dart entrypoint (`background_push.dart`) simulating OS background execution budget limits (30-second OS execution cap on iOS/Android).
- **Risk**: Background push handler being terminated by OS before sync completes, leaving pending notifications unprocessed.
- **Remediation Test Plan**:
  1. Add `mobile/test/background_push_isolate_test.dart`.
  2. Execute the background message handler within an isolated test runner.
  3. Assert that background sync completes within < 3.0 seconds, respects the generic notification contract, and triggers local notification display.

### Gap MB-04: Crypto-Gated UI States & Boundary Enforcement
- **Defect**: The UI specification requires that while crypto is unavailable (`PM_CRYPTO_UNAVAILABLE`), user-facing crypto actions (reply, edit, delete, reaction buttons, attachment previews, safety numbers) must remain strictly unavailable/hidden. Existing widget tests do not systematically assert that these controls are disabled across all screen variants.
- **Risk**: Accidental exposure of non-functional or insecure UI elements in release builds before external security review.
- **Remediation Test Plan**:
  1. Add `mobile/test/crypto_gated_ui_test.dart`.
  2. Pump every screen in `features/chat/` with `UnavailableCryptoService`.
  3. Assert zero interactive elements exist for reply, edit, delete, reactions, and attachments.
  4. Pump the same screens with `TestCryptoService` and assert interactive elements render correctly.

### Gap MB-05: Accessibility (a11y), Contrast & Large Font Scaling
- **Defect**: There are currently no automated accessibility audits or Semantics tests.
- **Risk**: App failing WCAG 2.1 AA accessibility requirements; unreadable text on devices with 200% font scaling; unannounced screen-reader buttons.
- **Remediation Test Plan**:
  1. Add `mobile/test/accessibility_test.dart` using Flutter `meetsGuideline` assertions:
     - `androidTapTargetGuideline` (minimum 48x48 dp touch targets).
     - `iOSTapTargetGuideline` (minimum 44x44 dp touch targets).
     - `textContrastGuideline` (minimum 4.5:1 contrast for normal text).
     - `labeledTapTargetGuideline` (all interactive icons have Semantic labels).
  2. Test UI responsiveness at 200% text scale factor without `RenderFlex` overflow errors.

### Gap MB-06: Golden Snapshot Visual Regression Suite
- **Defect**: No golden screenshot tests exist. Visual regressions in the K2 Bone design system (theme colors, spacing tokens, dark/light mode transitions) can occur unnoticed.
- **Risk**: Visual design degradation across Flutter engine upgrades or theme token refactors.
- **Remediation Test Plan**:
  1. Create `mobile/test/goldens/` with `flutter_test` golden file comparisons.
  2. Capture golden baselines for: Chat list, Active DM, Group conversation details, Connect screen, QR scan view, Settings screen (both Light and Dark modes).

---

## 4. Execution & Orchestration Specification

### Model & Advisor Assignment
- **Primary Executor Tier**: `Balanced` (Standard Widget tests, Goldens, a11y tests) / `Balanced+Advisor` (Outbox crash recovery, Encrypted Database key failure).
- **Advisor Requirement**: Advisor review required for Outbox crash recovery state machine and Drift encrypted key fail-closed logic.

### XML Execution Prompt Contract

```xml
<role>You are the specialized Flutter Mobile Test Engineer for Veritra.</role>
<context>
Review mobile/lib/, mobile/test/, and testing/mobile_testing_gaps.md.
</context>
<invariants>
- All UI tests must pass with zero RenderFlex overflow.
- Crypto-gated widgets must remain hidden when crypto is unavailable.
- Accessibility guidelines (tap target, contrast, semantics) must be strictly enforced.
</invariants>
<instructions>
1. Implement accessibility test suite in mobile/test/accessibility_test.dart.
2. Implement crypto-gated UI state verification in mobile/test/crypto_gated_ui_test.dart.
3. Implement outbox crash recovery test in mobile/test/outbox_recovery_test.dart.
4. Run `flutter test` and confirm all tests pass.
</instructions>
<handoff_format>
Task: Mobile Test Remediation
Result: complete | blocked
Checks: flutter test results and accessibility guideline pass report
Advisor Checkpoint: Outbox recovery and fail-closed key storage review
</handoff_format>
```
