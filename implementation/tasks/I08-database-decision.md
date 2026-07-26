# I08 — Select the encrypted mobile database

Goal: recommend one transactional Android/iOS database for local ciphertext, MLS state, cursors, and outbox.

Read:

- `mobile/pubspec.yaml`, `mobile/lib/data/`, `mobile/lib/state/`
- `THIRD_PARTY_NOTICES.md`
- current official package docs and licenses for viable choices

Do:

1. Compare at most three maintained options for encryption, transactions, Android/iOS support, migrations, backup behavior, binary size, and AGPL compatibility.
2. Prefer the smallest supported dependency surface.
3. Run a minimal open/write/transaction/reopen spike if needed; keep it isolated.
4. Put a one-line recommendation and tradeoff under D01 in `KANBAN.md`.

Done when: the user can approve one exact package/version and key-custody design.

Do not add the production dependency before D01 approval. Use a strong advisor only if license, key custody, or rollback behavior remains ambiguous.
