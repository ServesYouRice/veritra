package storage

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/domain"
	"private-messenger/server/migrations"
)

// K0 recovery enrollment, package R2: storage rules.

var testRecoveryAuthKey = bytes.Repeat([]byte{7}, 32)

type testRecoveryClaim struct {
	request        RecoveryRequest
	claimTokenHash string
}

// claimTestRecovery sets the account's recovery key and stores a verified
// claim for it, as the handler does after checking the credentials.
func claimTestRecovery(t *testing.T, ctx context.Context, store *Store, account AccountDevice, wait time.Duration) testRecoveryClaim {
	t.Helper()
	if _, err := store.RecoveryClaimRecord(ctx, account.Account.ID); err != nil {
		t.Fatalf("claim record: %v", err)
	}
	var configured int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM account_recovery_keys WHERE account_id = ?`, account.Account.ID).Scan(&configured); err != nil {
		t.Fatal(err)
	}
	if configured == 0 {
		if _, err := store.SetRecoveryKey(ctx, account.Account.ID, testRecoveryAuthKey, bytes.Repeat([]byte{9}, 16)); err != nil {
			t.Fatalf("set recovery key: %v", err)
		}
	}
	record, err := store.RecoveryClaimRecord(ctx, account.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	reservation, err := store.ReserveRecoveryEnrollment(ctx, account.Account.Username)
	if err != nil {
		t.Fatalf("reserve recovery: %v", err)
	}
	if reservation.AccountID != account.Account.ID {
		t.Fatalf("reservation account = %q, want %q", reservation.AccountID, account.Account.ID)
	}
	claimTokenHash := auth.HashToken("claim-" + reservation.ID)
	claimed, err := store.ClaimRecovery(ctx, RecoveryClaimInput{
		ReservationID: reservation.ID, AccountID: reservation.AccountID, DeviceName: "recovered phone",
		KeyPackage: bytes.Repeat([]byte{3}, 64), SigningKey: bytes.Repeat([]byte{4}, 32),
		DeviceAuthHash: auth.HashToken("device-secret-" + reservation.ID), ClaimTokenHash: claimTokenHash,
		VerifiedPasswordHash: record.PasswordHash, VerifiedAuthKey: record.AuthPublicKey,
		ActiveWindow: 7 * 24 * time.Hour, Wait: wait,
	})
	if err != nil {
		t.Fatalf("claim recovery: %v", err)
	}
	return testRecoveryClaim{request: claimed.Request, claimTokenHash: claimTokenHash}
}

func makeRecoveryReady(t *testing.T, ctx context.Context, store *Store, requestID string) {
	t.Helper()
	if _, err := store.db.ExecContext(ctx, `UPDATE account_recovery_requests SET ready_at = ? WHERE id = ?`, formatTime(time.Now().UTC().Add(-time.Minute)), requestID); err != nil {
		t.Fatal(err)
	}
}

func recoveryRequestState(t *testing.T, ctx context.Context, store *Store, requestID string) (string, string) {
	t.Helper()
	var state string
	var by *string
	if err := store.db.QueryRowContext(ctx, `SELECT state, cancelled_by FROM account_recovery_requests WHERE id = ?`, requestID).Scan(&state, &by); err != nil {
		t.Fatal(err)
	}
	if by == nil {
		return state, ""
	}
	return state, *by
}

func TestRecoveryReservationUsesStableDecoysForEveryNonActiveUsername(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	if _, err := store.ReserveRecoveryEnrollment(ctx, "anyone"); !errors.Is(err, ErrRecoveryUnavailable) {
		t.Fatalf("before setup: err = %v, want %v", err, ErrRecoveryUnavailable)
	}
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	suspended := registerTestMember(t, ctx, store, invite.Code, "suspended")
	if _, err := store.db.ExecContext(ctx, `UPDATE accounts SET status = 'suspended' WHERE id = ?`, suspended.Account.ID); err != nil {
		t.Fatal(err)
	}
	real1, err := store.ReserveRecoveryEnrollment(ctx, "OWNER")
	if err != nil {
		t.Fatal(err)
	}
	real2, err := store.ReserveRecoveryEnrollment(ctx, "owner")
	if err != nil {
		t.Fatalf("second reservation for one account: %v", err)
	}
	if real1.AccountID != owner.Account.ID || real2.AccountID != owner.Account.ID || real1.Kind != "recovery" || real1.DeviceID == real2.DeviceID {
		t.Fatalf("real reservations = %+v / %+v", real1, real2)
	}
	unknown1, err := store.ReserveRecoveryEnrollment(ctx, "nobody")
	if err != nil {
		t.Fatal(err)
	}
	unknown2, err := store.ReserveRecoveryEnrollment(ctx, "Nobody")
	if err != nil {
		t.Fatal(err)
	}
	other, err := store.ReserveRecoveryEnrollment(ctx, "somebody")
	if err != nil {
		t.Fatal(err)
	}
	gone, err := store.ReserveRecoveryEnrollment(ctx, "suspended")
	if err != nil {
		t.Fatal(err)
	}
	if !domain.ValidID("acct", unknown1.AccountID) || unknown1.AccountID != unknown2.AccountID || unknown1.AccountID == other.AccountID {
		t.Fatalf("decoys: %q %q %q", unknown1.AccountID, unknown2.AccountID, other.AccountID)
	}
	if gone.AccountID == suspended.Account.ID || !domain.ValidID("acct", gone.AccountID) {
		t.Fatalf("suspended account got %q (real %q)", gone.AccountID, suspended.Account.ID)
	}
	// Owner and register reservations still never share an account id.
	if _, err := store.db.ExecContext(ctx, `INSERT INTO enrollment_reservations(id, kind, account_id, device_id, challenge, created_at, expires_at) VALUES('enroll_dup', 'register', 'acct_dup', 'dev_dup', zeroblob(64), ?, ?)`, nowString(), nowString()); err != nil {
		t.Fatalf("first register row: %v", err)
	}
	if _, err := store.db.ExecContext(ctx, `INSERT INTO enrollment_reservations(id, kind, account_id, device_id, challenge, created_at, expires_at) VALUES('enroll_dup2', 'owner', 'acct_dup', 'dev_dup2', zeroblob(64), ?, ?)`, nowString(), nowString()); err == nil {
		t.Fatal("two non-recovery reservations shared an account id")
	}
}

func TestRecoveryCompletionRevokesOldDevicesAndReleasesTheirConfirmations(t *testing.T) {
	ctx := context.Background()
	f := newRosteredRevocation(t, ctx)
	store := f.store
	// coordBob must confirm the revocation of Carol's tablet.
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM mls_revocation_required_devices WHERE device_id = ? AND confirmed_at IS NULL`, coordBob); n != 1 {
		t.Fatalf("pending confirmations for coordBob = %d, want 1", n)
	}
	claim := claimTestRecovery(t, ctx, store, f.bob, 0)
	completion, err := store.CompleteRecovery(ctx, claim.request.ID, claim.claimTokenHash, auth.HashToken("session-1"))
	if err != nil {
		t.Fatalf("complete: %v", err)
	}
	if completion.State != RecoveryStateCompleted || !completion.SessionIssued || len(completion.RevokedDevices) != 2 || len(completion.RevokedEventIDs) != 2 {
		t.Fatalf("completion = %+v", completion)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM mls_revocation_required_devices WHERE device_id = ? AND confirmed_at IS NULL`, coordBob); n != 0 {
		t.Fatalf("coordBob still owes %d confirmations after recovery revoked it", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM devices WHERE account_id = ? AND revoked_at IS NULL`, f.bob.Account.ID); n != 1 {
		t.Fatalf("bob has %d live devices, want only the recovered one", n)
	}
	newDevice := claim.request.DeviceID
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM mls_revocations WHERE coordinator_device_id = ?`, newDevice); n != 0 {
		t.Fatalf("the recovered device coordinates %d revocations", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM mls_revocation_required_devices WHERE device_id = ?`, newDevice); n != 0 {
		t.Fatalf("the recovered device must confirm %d revocations", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sessions WHERE device_id = ? AND recent_auth_at IS NULL`, newDevice); n != 1 {
		t.Fatalf("recovered session with no recent auth = %d, want 1", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sessions WHERE account_id = ? AND device_id <> ?`, f.bob.Account.ID, newDevice); n != 0 {
		t.Fatalf("old devices kept %d sessions", n)
	}
	// A lost 200: the next call answers completed without a session.
	again, err := store.CompleteRecovery(ctx, claim.request.ID, claim.claimTokenHash, auth.HashToken("session-2"))
	if err != nil || again.State != RecoveryStateCompleted || again.SessionIssued || again.Device.ID != newDevice {
		t.Fatalf("second status = %+v, err = %v", again, err)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sessions WHERE token_hash = ?`, auth.HashToken("session-2")); n != 0 {
		t.Fatal("a repeated status call created a session")
	}
	if _, err := store.CompleteRecovery(ctx, claim.request.ID, auth.HashToken("wrong"), auth.HashToken("session-3")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("wrong claim token: err = %v, want %v", err, ErrNotFound)
	}
}

// In a legacy group every non-revoked device of a member may coordinate, so
// a recovered device inserted before the revocations, with the lowest id,
// would be elected. Completion revokes first.
func TestRecoveryCompletionInLegacyGroupNeverElectsTheNewDevice(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{bob.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	addTestDevice(t, ctx, store, bob.Account.ID, coordBob)
	makeLegacyMLSGroup(t, ctx, store, conversation.ID, owner)
	claim := claimTestRecovery(t, ctx, store, bob, 0)
	const lowest = "dev-0-recovered"
	if _, err := store.db.ExecContext(ctx, `UPDATE account_recovery_requests SET device_id = ? WHERE id = ?`, lowest, claim.request.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.CompleteRecovery(ctx, claim.request.ID, claim.claimTokenHash, auth.HashToken("legacy-session")); err != nil {
		t.Fatalf("complete: %v", err)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM mls_revocations WHERE conversation_id = ?`, conversation.ID); n != 2 {
		t.Fatalf("legacy revocations = %d, want one per old device", n)
	}
	// No old device coordinates a sibling's revocation: the peer's device
	// does, so the role never falls through to the recovered device.
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM mls_revocations WHERE conversation_id = ? AND coordinator_device_id <> ?`, conversation.ID, owner.Device.ID); n != 0 {
		t.Fatalf("%d revocations are coordinated by an old device of the recovered account", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM mls_revocation_required_devices WHERE device_id = ?`, lowest); n != 0 {
		t.Fatal("the recovered device was made a required confirmer")
	}
	items, err := store.ListMLSRevocations(ctx, owner.Account.ID, owner.Device.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range items {
		if item.CoordinatorDeviceID == lowest {
			t.Fatalf("listed coordinator is the recovered device: %+v", item)
		}
	}
}

func TestRecoveryLoginRehashDoesNotVoidAWaitingRequest(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	claim := claimTestRecovery(t, ctx, store, owner, 7*24*time.Hour)
	record, err := store.RecoveryClaimRecord(ctx, owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	updated, err := auth.HashPassword("owner-password-123")
	if err != nil {
		t.Fatal(err)
	}
	if changed, err := store.UpgradePasswordHash(ctx, owner.Account.ID, record.PasswordHash, updated); err != nil || !changed {
		t.Fatalf("upgrade: changed=%v err=%v", changed, err)
	}
	var verified string
	if err := store.db.QueryRowContext(ctx, `SELECT verified_password_hash FROM account_recovery_requests WHERE id = ?`, claim.request.ID).Scan(&verified); err != nil || verified != updated {
		t.Fatalf("verified hash did not move with the rehash (err %v)", err)
	}
	makeRecoveryReady(t, ctx, store, claim.request.ID)
	if completion, err := store.CompleteRecovery(ctx, claim.request.ID, claim.claimTokenHash, auth.HashToken("s")); err != nil || completion.State != RecoveryStateCompleted {
		t.Fatalf("completion after rehash = %+v, err = %v", completion, err)
	}
}

func TestRecoveryCredentialChangesCancelAWaitingRequest(t *testing.T) {
	ctx := context.Background()
	for _, tc := range []struct {
		name   string
		reason string
		change func(t *testing.T, store *Store, owner AccountDevice)
	}{
		{"password change", RecoveryCancelledPasswordChanged, func(t *testing.T, store *Store, owner AccountDevice) {
			if err := store.ChangePassword(ctx, owner.Account.ID, "", "new-hash"); err != nil {
				t.Fatal(err)
			}
		}},
		{"owner reset", RecoveryCancelledPasswordReset, func(t *testing.T, store *Store, owner AccountDevice) {
			if err := store.ResetOwnerPassword(ctx, "owner", "reset-hash"); err != nil {
				t.Fatal(err)
			}
		}},
		{"recovery key change", RecoveryCancelledKeyChanged, func(t *testing.T, store *Store, owner AccountDevice) {
			if _, err := store.SetRecoveryKey(ctx, owner.Account.ID, bytes.Repeat([]byte{8}, 32), bytes.Repeat([]byte{8}, 16)); err != nil {
				t.Fatal(err)
			}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store, _ := newTestStore(t, ctx)
			defer store.Close()
			owner := createTestOwner(t, ctx, store)
			claim := claimTestRecovery(t, ctx, store, owner, 7*24*time.Hour)
			tc.change(t, store, owner)
			if state, by := recoveryRequestState(t, ctx, store, claim.request.ID); state != "cancelled" || by != tc.reason {
				t.Fatalf("state = %q by %q, want cancelled by %q", state, by, tc.reason)
			}
			if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'account.recovery.cancelled' AND account_id = ?`, owner.Account.ID); n != 1 {
				t.Fatalf("cancel events = %d", n)
			}
			if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM audit_events WHERE event_type = 'account.recovery_cancelled' AND json_extract(metadata_json, '$.reason') = ?`, tc.reason); n != 1 {
				t.Fatalf("cancel audit rows = %d", n)
			}
			makeRecoveryReady(t, ctx, store, claim.request.ID)
			if _, err := store.CompleteRecovery(ctx, claim.request.ID, claim.claimTokenHash, auth.HashToken("s")); !errors.Is(err, ErrRecoveryCancelled) {
				t.Fatalf("completion after %s: err = %v", tc.name, err)
			}
		})
	}
}

// The backstop: credentials that moved without the cancel (here a direct
// write) still stop completion.
func TestRecoveryCompletionRefusesChangedCredentials(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	claim := claimTestRecovery(t, ctx, store, owner, 0)
	if _, err := store.db.ExecContext(ctx, `UPDATE accounts SET password_hash = 'moved' WHERE id = ?`, owner.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.CompleteRecovery(ctx, claim.request.ID, claim.claimTokenHash, auth.HashToken("s")); !errors.Is(err, ErrRecoveryCancelled) {
		t.Fatalf("err = %v, want %v", err, ErrRecoveryCancelled)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM devices WHERE account_id = ? AND revoked_at IS NULL`, owner.Account.ID); n != 1 {
		t.Fatalf("live devices = %d, want the old one untouched", n)
	}
}

func TestRecoveryClaimReplacesTheWaitingRequestAndConsumesTheReservation(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	// Without a live session the owner's device is not active: no wait.
	first := claimTestRecovery(t, ctx, store, owner, 7*24*time.Hour)
	if !first.request.ReadyAt.Equal(first.request.CreatedAt) {
		t.Fatalf("no active device, yet the request waits: %+v", first.request)
	}
	if err := store.CreateSession(ctx, auth.HashToken("owner-session"), owner.Account.ID, owner.Device.ID, time.Now().UTC().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	second := claimTestRecovery(t, ctx, store, owner, 7*24*time.Hour)
	if second.request.ReadyAt.Sub(second.request.CreatedAt) < 7*24*time.Hour-time.Minute {
		t.Fatalf("an active device must start the wait: %+v", second.request)
	}
	// A device seen longer ago than the window is not active.
	old := formatTime(time.Now().UTC().Add(-8 * 24 * time.Hour))
	if _, err := store.db.ExecContext(ctx, `UPDATE devices SET last_seen_at = ?, created_at = ? WHERE id = ?`, old, old, owner.Device.ID); err != nil {
		t.Fatal(err)
	}
	third := claimTestRecovery(t, ctx, store, owner, 7*24*time.Hour)
	if !third.request.ReadyAt.Equal(third.request.CreatedAt) {
		t.Fatalf("an idle device started the wait: %+v", third.request)
	}
	if state, by := recoveryRequestState(t, ctx, store, second.request.ID); state != "cancelled" || by != RecoveryCancelledReplaced {
		t.Fatalf("second request = %s/%s", state, by)
	}
	second = third
	if state, by := recoveryRequestState(t, ctx, store, first.request.ID); state != "cancelled" || by != RecoveryCancelledReplaced {
		t.Fatalf("first request = %s/%s", state, by)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM enrollment_reservations WHERE kind = 'recovery' AND consumed_at IS NULL`); n != 0 {
		t.Fatalf("%d recovery reservations left unconsumed", n)
	}
	// The reservation's 10 minutes do not bound completion.
	if _, err := store.db.ExecContext(ctx, `UPDATE enrollment_reservations SET expires_at = ? WHERE kind = 'recovery'`, formatTime(time.Now().UTC().Add(-time.Hour))); err != nil {
		t.Fatal(err)
	}
	makeRecoveryReady(t, ctx, store, second.request.ID)
	if completion, err := store.CompleteRecovery(ctx, second.request.ID, second.claimTokenHash, auth.HashToken("s")); err != nil || completion.State != RecoveryStateCompleted {
		t.Fatalf("completion = %+v, err = %v", completion, err)
	}
}

func TestRecoveryAttemptsCapNoticeOnceADayAndSurviveRestart(t *testing.T) {
	ctx := context.Background()
	store, cfg := newTestStore(t, ctx)
	owner := createTestOwner(t, ctx, store)
	now := time.Now().UTC()
	for i := 0; i < 3; i++ {
		attempt, err := store.RecordRecoveryAttempt(ctx, owner.Account.ID, true, 2, now)
		if err != nil {
			t.Fatal(err)
		}
		if (i == 2) != (attempt.LeakEventID != 0) || attempt.Failures != i+1 {
			t.Fatalf("attempt %d = %+v", i, attempt)
		}
	}
	attempt, err := store.RecordRecoveryAttempt(ctx, owner.Account.ID, true, 2, now)
	if err != nil || attempt.LeakEventID != 0 || attempt.Failures != 4 {
		t.Fatalf("after the notice = %+v, err = %v", attempt, err)
	}
	attempt, err = store.RecordRecoveryAttempt(ctx, owner.Account.ID, false, 2, now)
	if err != nil || attempt.Failures != 4 {
		t.Fatalf("an uncounted attempt changed the count: %+v, err = %v", attempt, err)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'account.password_leak_suspected' AND account_id = ?`, owner.Account.ID); n != 1 {
		t.Fatalf("leak notices = %d, want 1", n)
	}
	// A decoy id counts and never notifies.
	decoy := RecoveryDecoyAccountID(bytes.Repeat([]byte{1}, 32), "nobody")
	for i := 0; i < 4; i++ {
		if attempt, err := store.RecordRecoveryAttempt(ctx, decoy, true, 2, now); err != nil || attempt.LeakEventID != 0 {
			t.Fatalf("decoy attempt = %+v, err = %v", attempt, err)
		}
	}
	// Tomorrow starts again.
	if attempt, err := store.RecordRecoveryAttempt(ctx, owner.Account.ID, true, 2, now.Add(24*time.Hour)); err != nil || attempt.Failures != 1 {
		t.Fatalf("next day = %+v, err = %v", attempt, err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if err := reopened.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	attempt, err = reopened.RecordRecoveryAttempt(ctx, owner.Account.ID, false, 2, now)
	if err != nil || attempt.Failures != 4 {
		t.Fatalf("after restart = %+v, err = %v", attempt, err)
	}
	attempt, err = reopened.RecordRecoveryAttempt(ctx, decoy, false, 2, now)
	if err != nil || attempt.Failures != 4 {
		t.Fatalf("decoy after restart = %+v, err = %v", attempt, err)
	}
}

func TestRecoveryRowsArePrunedAndDeletedWithTheAccount(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	member := registerTestMember(t, ctx, store, invite.Code, "member")
	claim := claimTestRecovery(t, ctx, store, owner, 0)
	now := time.Now().UTC()
	if _, err := store.RecordRecoveryAttempt(ctx, owner.Account.ID, true, 50, now.Add(-72*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RecordRecoveryAttempt(ctx, owner.Account.ID, true, 50, now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE account_recovery_requests SET expires_at = ? WHERE id = ?`, formatTime(now.Add(-OperationalRowRetention-time.Hour)), claim.request.ID); err != nil {
		t.Fatal(err)
	}
	backlog, err := store.RetentionBacklog(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.PruneOperationalRows(ctx, now); err != nil {
		t.Fatal(err)
	}
	after, err := store.RetentionBacklog(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	if backlog.Rows < 2 || after.Rows != 0 {
		t.Fatalf("backlog before = %d, after = %d", backlog.Rows, after.Rows)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM account_recovery_requests`); n != 0 {
		t.Fatalf("requests left = %d", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM recovery_attempts`); n != 1 {
		t.Fatalf("attempt rows left = %d, want today's", n)
	}
	claimTestRecovery(t, ctx, store, member, 7*24*time.Hour)
	if err := store.DeleteAccount(ctx, member.Account.ID); err != nil {
		t.Fatal(err)
	}
	if n := testRowCount(t, ctx, store, `SELECT (SELECT COUNT(*) FROM account_recovery_keys WHERE account_id = ?) + (SELECT COUNT(*) FROM account_recovery_requests WHERE account_id = ?)`, member.Account.ID, member.Account.ID); n != 0 {
		t.Fatalf("deleted account kept %d recovery rows", n)
	}
}

func TestRecoveryMigrationBackfillsTheDecoyKeyAndKeepsReservations(t *testing.T) {
	ctx := context.Background()
	store := openBareStore(t)
	old, _ := migrationsUpTo(t, "0044")
	if err := store.Migrate(ctx, old); err != nil {
		t.Fatal(err)
	}
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	pending, err := store.ReserveRegistrationEnrollment(ctx, invite.Code)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	var key []byte
	if err := store.db.QueryRowContext(ctx, `SELECT recovery_decoy_key FROM instances WHERE id = 1`).Scan(&key); err != nil || len(key) != 32 {
		t.Fatalf("decoy key = %x, err = %v", key, err)
	}
	kept, err := store.EnrollmentReservation(ctx, pending.ID)
	if err != nil || kept.AccountID != pending.AccountID || kept.Kind != "register" || !bytes.Equal(kept.Challenge, pending.Challenge) {
		t.Fatalf("reservation after migration = %+v, err = %v", kept, err)
	}
	reservation, err := store.ReserveRecoveryEnrollment(ctx, "owner")
	if err != nil || reservation.AccountID != owner.Account.ID {
		t.Fatalf("recovery reservation = %+v, err = %v", reservation, err)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name IN ('idx_enrollment_reservations_expiry', 'idx_enrollment_reservations_retention', 'idx_enrollment_reservations_account')`); n != 3 {
		t.Fatalf("reservation indexes = %d, want 3", n)
	}
}
