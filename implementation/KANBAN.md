# Implementation queue entrypoint

[`docs/board.md`](../docs/board.md) is the only status board. This file does not
copy mutable card status because duplicated boards drift.

For audit-derived work:

1. Confirm current status in [`docs/board.md`](../docs/board.md).
2. Select an eligible contract from [`README.md`](README.md).
3. Follow [`WORKFLOW.md`](WORKFLOW.md).
4. Claim one task. One coordinator records the claim/completion on the board
   and updates [`docs/audit-consensus.md`](../docs/audit-consensus.md) when its
   truth changes.

At the 2026-08-13 split, no task is claimed. The mandated start is T29, then
deadline-sensitive T40A. Treat that sentence as historical if the board has
since changed.
