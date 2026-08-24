# Implementation queue entrypoint

[`docs/board.md`](../docs/board.md) is the only status board. This file does not
copy mutable card status because duplicated boards drift.

For audit-derived work:

1. Confirm current status in [`docs/board.md`](../docs/board.md).
2. Select an eligible contract from the live index in [`README.md`](README.md).
3. Follow [`WORKFLOW.md`](WORKFLOW.md).
4. Claim one task. One coordinator records the claim/completion on the board
   and updates [`docs/audit-consensus.md`](../docs/audit-consensus.md) when its
   truth changes.

Contracts not linked from the live index are not executor context. Completed
contracts and old routing snapshots are available only from Git history.
