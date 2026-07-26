# I16 — Remove revoked devices from groups

Goal: account/device revocation removes the credential from every affected MLS group, including after offline return.

Read:

- device revocation and membership server paths
- mobile MLS orchestration and sync handling
- Rust remove/update operations

Do:

1. Define durable pending/completed revocation state visible to authorized clients.
2. Generate, deliver, validate, and apply removal commits for affected groups.
3. Rotate remaining credentials/key packages where required.
4. Reject application messages from removed epochs/devices.
5. Test revocation while target and peers are offline, then reconnect in different orders.

Done when: revoked devices cannot decrypt or author post-removal messages and all honest devices converge.

Verify: server tests plus multi-device Rust/Flutter integration tests.

Do not mark server-side revocation complete before cryptographic removal is confirmed.
