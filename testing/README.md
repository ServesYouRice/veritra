# Testing follow-ups

The original testing-gap reports were removed because they contained stale
inventory, invalid commands, and conflicting status. Their reviewed outcome is
[`review_findings.md`](review_findings.md), and the only executable assignments
are the bounded [QA contracts](../implementation/tasks/test-followups/README.md).

Executors receive one QA contract, not this directory. `docs/board.md` owns
eligibility and status; `docs/audit-consensus.md` owns product scope. The raw
reports remain recoverable from Git history at `bfb3922` if provenance is
needed.

Every testing task preserves these boundaries:

- Server message and attachment bodies remain ciphertext-only.
- Logs never contain message text, bodies, secrets, tokens, or ciphertext.
- `PM_CRYPTO_UNAVAILABLE` and `UnavailableCryptoService` remain fail-closed
  until G25.
- Push data stays generic, without sender or message content.
- Mobile MLS state, cursor, message, and dedupe changes remain atomic.
- Simulator or inspection evidence is never presented as signed-device proof.
