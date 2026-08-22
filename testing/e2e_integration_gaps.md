# End-to-End, Integration & Release Gate Testing Gap Audit & Plan

## 1. System Overview & Architecture

Veritra's end-to-end reliability requires synchronous harmony across three distinct technology stacks:
1. **Rust Crypto Core**: Low-level cryptographic primitives, OpenMLS group state, and AES-GCM streaming.
2. **Go Backend Monolith**: Transactional key package distribution, encrypted message relay, and generic push wake.
3. **Flutter Mobile App**: Encrypted local database, persistent outbox, WebRTC media peer connections, and reactive UI.

Testing this architecture requires end-to-end integration tests that simulate realistic multi-client messaging, network partitions, device linking, and automated release validation gates.

---

## 2. Current Test Coverage Inventory

### Existing Integration Test Artifacts
- `scripts/test-api-contracts.sh`: Boots a live Go server on loopback, compiles the Rust crypto ABI, and executes the Dart `api_contract_test.dart` against live HTTP endpoints.
- `scripts/release-readiness.sh`: Checks binary symbols, verifies that `PM_CRYPTO_UNAVAILABLE` fails closed, and checks that production gates are active.
- `scripts/license-check.sh` & `check-dart-licenses.sh`: Validates licenses across Go, Rust, and 157 Dart dependencies.
- Compose Fresh-Volume Smoke Test: Boots Docker Compose deployment, validates healthz check, and tears down cleanly.

---

## 3. Critical Testing Gaps Identified

### Gap E2E-01: Multi-Client MLS Protocol & Group Lifecycle Simulation
- **Defect**: Existing tests verify individual components in isolation. There is no automated multi-client integration test executing a complete MLS conversation lifecycle across multiple simulated active mobile clients and a live Go server.
- **Risk**: Protocol race conditions during simultaneous group commits, epoch desync among group members, or silent message drops.
- **Remediation Test Plan**:
  1. Create `tests/e2e/multi_client_mls_test.go` (or Dart integration harness).
  2. Instantiate 4 simulated client nodes (Alice, Bob, Charlie, Dave):
     - **Step 1**: Alice creates a group and invites Bob and Charlie using one-time key packages from the server.
     - **Step 2**: Bob joins, commits the welcome message, and broadcasts an encrypted message.
     - **Step 3**: Alice and Charlie receive, decrypt, and verify the message.
     - **Step 4**: Charlie invites Dave.
     - **Step 5**: Alice revokes Bob; verify Bob can no longer decrypt new messages in subsequent epochs.
  3. Assert 100% message delivery and identical group state transcripts across all active honest members.

### Gap E2E-02: Device Linking & SAS Transcript Verification
- **Defect**: Mobile device linking (scanning QR code, SAS emoji/number comparison, MLS credential exchange) is only tested at the UI mock layer.
- **Risk**: Man-in-the-middle vulnerability during device linking; unverified identity keys in multi-device accounts.
- **Remediation Test Plan**:
  1. Add `tests/e2e/device_linking_e2e_test.dart`.
  2. Spin up Primary Device A and Secondary Device B.
  3. Perform full linking handshake: QR data exchange, SAS derivation from length-prefixed transcript hash, out-of-band confirmation, and key package synchronization.
  4. Inject an intentional MITM transcript tamper and assert linking fails closed.

### Gap E2E-03: Network Degradation, Latency & Packet Loss Resilience
- **Defect**: No automated tests simulate real-world mobile network conditions (cellular to Wi-Fi handoff, 500ms packet jitter, 20% packet drop, intermittent connection drops).
- **Risk**: Outbox stalls, sync cursor desynchronization, WebSocket reconnection thrashing, or WebRTC call drops.
- **Remediation Test Plan**:
  1. Create a proxy-based network simulation test (`tests/e2e/network_chaos_test.go` with Toxiproxy or custom netem).
  2. Subject 2 active clients to:
     - 30-second complete network outage during message transmission.
     - 500ms latency + 15% packet loss on WebRTC signaling.
     - Rapid network flapping (connect/disconnect every 2 seconds).
  3. Verify zero message loss, automatic WebSocket reconnection with exponential backoff, and state convergence.

### Gap E2E-04: Capability-Based Backup, Wipe & Full Recovery Drill
- **Defect**: `backup_service.dart` has unit tests for encrypted chunk creation, but lacks an end-to-end disaster recovery drill.
- **Risk**: Inability to restore user conversation history after device loss; corrupted local database on restore.
- **Remediation Test Plan**:
  1. Add `tests/e2e/disaster_recovery_e2e_test.dart`.
  2. Generate a client with 1,000 messages, 10 media attachments, and 5 group conversations.
  3. Execute encrypted backup export using a user passphrase; upload to server.
  4. Wipe local client state completely (simulate fresh device install).
  5. Restore from server backup using passphrase and capability key.
  6. Assert all 1,000 messages, group keys, and attachment digests match the original state exactly.

### Gap E2E-05: Real Hardware & Platform Validation Matrix (I24 Gate)
- **Defect**: Release verification currently relies heavily on desktop simulation and emulators. Physical hardware testing requirements defined in I24 are unautomated.
- **Risk**: Native ARM64 JNI crashes, iOS background fetch throttling, or hardware-specific WebRTC audio/video codec failures.
- **Remediation Test Plan**:
  1. Establish physical test lab matrix:
     - Android: Minimum Android 11 (API 30) up to Android 15 (ARM64 physical devices).
     - iOS: Minimum iOS 16 up to iOS 18 (physical Apple Silicon devices).
  2. Implement an automated test runner for hardware smoke testing (Appium/Flutter Driver):
     - APNs/FCM background wake under OS battery optimization.
     - TURN call audio flow between Android and iOS across NAT boundaries.
     - Biometric authentication prompt (FaceID / Fingerprint).

### Gap E2E-06: Automated Positive & Negative Release Gate Enforcement
- **Defect**: Release-readiness script checks for the presence of `PM_CRYPTO_UNAVAILABLE` but does not run a positive verification test where a mock reviewed crypto module passes all gates while an unreviewed build is strictly blocked.
- **Risk**: False sense of release readiness or premature gate removal.
- **Remediation Test Plan**:
  1. Update `scripts/release-readiness.sh` to include both positive and negative gate assertions.
  2. Assert failure when `PM_CRYPTO_UNAVAILABLE` is wired (pre-review state).
  3. Assert full pass only when signed artifacts, SPDX SBOM, checksums, and external review tokens are cryptographically verified.

---

## 4. Execution & Orchestration Specification

### Model & Advisor Assignment
- **Primary Executor Tier**: `Strong` (Opus-class for Multi-Client MLS simulation and Chaos testing) / `Balanced+Advisor` (Backup drills and CI gate automation).
- **Advisor Requirement**: Mandatory Advisor review on Multi-Client MLS concurrency invariants and Disaster Recovery restoration logic.

### XML Execution Prompt Contract

```xml
<role>You are the specialized E2E & Infrastructure Test Engineer for Veritra.</role>
<context>
Review tests/e2e/, scripts/, deploy/, and testing/e2e_integration_gaps.md.
</context>
<invariants>
- Test multi-client MLS protocol convergence with zero message loss.
- Backup restore must restore complete cryptographic group state.
- Release gates must strictly fail closed unless every requirement passes.
</invariants>
<instructions>
1. Implement multi-client MLS simulation in tests/e2e/multi_client_mls_test.go.
2. Implement network chaos and reconnection test in tests/e2e/network_chaos_test.go.
3. Implement disaster recovery backup drill in tests/e2e/disaster_recovery_e2e_test.dart.
4. Run integration scripts and verify all scenarios converge cleanly.
</instructions>
<handoff_format>
Task: E2E Test Remediation
Result: complete | blocked
Checks: E2E multi-client simulation logs and chaos test pass reports
Advisor Checkpoint: Protocol convergence and disaster recovery verification
</handoff_format>
```
