# T44C — Localization, identity, settings and platform-link coherence

| Field | Contract |
|---|---|
| Consensus source | I44 product scope; UI-12/NTH-09; U12/U13/U14/U17/U21; R10/R11 |
| Initial eligibility | Prepared; claim after release blockers |
| Risk | Medium/Low; some store-submission relevance |
| Executor | Balanced |
| Advisor | Required only for dependency/license or link trust changes |
| Depends on | Release blockers |
| Blocks | Store-ready product polish |
| Parallel safety | One owner for package identity, localization framework and manifests |

## Objective

Use one product identity, establish localization, add licenses/about and
appearance settings, confirm destructive actions, and either support emitted
deep links on both platforms or stop emitting them.

## Read first

- `docs/audit-consensus.md` I44.
- Named source findings.
- `mobile/pubspec.yaml`, `main.dart`, settings, UI formatting, Android/iOS
  manifests, device-link UI and release metadata.

## Invariants

- New localization/license dependencies require license review and notices.
- Deep links validate origin/capability and require user confirmation.
- Appearance changes retain T43A contrast in both themes.

## Work

1. Reconcile package/app/product naming in user-visible and release metadata.
2. Add localization delegates/resources and locale-aware dates.
3. Add About/Licenses and System/Light/Dark setting.
4. Confirm sign-out/destructive actions.
5. Implement safe device-link URI handling on both platforms or remove URI emission.

## Acceptance

- Identity is consistent and localization framework handles supported strings/dates.
- Licenses are accessible; appearance persists and passes contrast tests.
- URI handling works safely on both platforms or no unsupported URI is produced.

## Required checks

```sh
cd mobile && flutter test test/platform_config_test.dart test/ui_remaining_test.dart test/ui_fixes_test.dart
cd mobile && flutter analyze
```

