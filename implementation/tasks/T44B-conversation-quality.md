# T44B — Conversation, list and form quality

| Field | Contract |
|---|---|
| Consensus source | I44 interaction scope; UI-11; U5/U6/U7/U8/U11/U19/U23 |
| Initial eligibility | Prepared; claim after release blockers |
| Risk | Medium/Low |
| Executor | Balanced |
| Advisor | Not required unless gated-crypto behavior changes |
| Depends on | Release blockers |
| Blocks | Product-quality baseline |
| Parallel safety | UI files can split only with disjoint screen ownership and one test integrator |

## Objective

Make chat/list/form interactions usable at supported sizes: relative time,
correct breakpoints, jump-to-live, explanatory gated actions, inline validation,
keyboard send/length feedback and supported row actions.

## Read first

- `docs/audit-consensus.md` I44.
- Named source findings.
- Chat list/screen, new conversation sheet, app shell, format helpers, shared
  widgets and UI tests.

## Invariants

- Gated crypto actions stay unavailable but explain why on touch and semantics.
- Do not add plaintext drafts/search or bypass durable send acceptance.
- Row actions keep server authorization as the source of truth.

## Work

1. Add locale-aware relative list time and correct phone/tablet breakpoints.
2. Add scroll-to-live/new-message affordance without disrupting history position.
3. Make gated controls focusable/explanatory.
4. Add inline form validation, keyboard handling and composer length feedback.
5. Add only already-supported row actions.

## Acceptance

- Interactions work at 320 px, landscape and 200% text without clipping.
- Validation stays with its field; keyboard cannot hide required actions.
- No control implies unavailable crypto is functional.

## Required checks

```sh
cd mobile && flutter test test/ui_features_test.dart test/ui_actionable_test.dart test/chat_visuals_test.dart
cd mobile && flutter analyze
```

