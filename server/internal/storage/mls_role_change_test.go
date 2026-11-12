package storage

import (
	"context"
	"errors"
	"testing"
	"time"
)

// A bundle declared role_change is unverifiable here: it skips the
// self-update interval, but has its own, so it cannot churn epochs.
func TestMLSRoleOnlyCommitHasItsOwnInterval(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{bob.Account.ID},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis", Commit: []byte("commit-0"), Welcome: []byte("welcome-0"),
		Added: []MLSDeviceRef{{AccountID: bob.Account.ID, DeviceID: bob.Device.ID}},
	}); err != nil {
		t.Fatal(err)
	}
	role := func(epoch int64, key string) (MLSCommitBundleResult, error) {
		return store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
			ConversationID: conversation.ID, SenderAccountID: bob.Account.ID, SenderDeviceID: bob.Device.ID,
			Epoch: epoch, IdempotencyKey: key, Commit: []byte("role-" + key), RoleChange: true,
		})
	}
	// A self-update and then a role change: the role change is not held by
	// the self-update interval.
	if _, err := selfUpdate(ctx, store, conversation.ID, bob, 1, "u1"); err != nil {
		t.Fatal(err)
	}
	if _, err := role(2, "r1"); err != nil {
		t.Fatalf("role change after a self-update: %v", err)
	}
	// A second one inside the interval is refused with the time to wait.
	_, err = role(3, "r2")
	wait, ok := MLSSelfUpdateRetryAfter(err)
	if !errors.Is(err, ErrMLSSelfUpdateLimit) || !ok || wait <= 0 || wait > MLSRoleChangeInterval {
		t.Fatalf("second role change err=%v wait=%v", err, wait)
	}
	// A retry of the accepted one still answers.
	if retry, err := role(2, "r1"); err != nil || !retry.Duplicate {
		t.Fatalf("retry=%#v err=%v", retry, err)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE conversation_mls_devices SET last_role_change_at = ? WHERE device_id = ?`,
		formatTime(time.Now().Add(-2*MLSRoleChangeInterval)), bob.Device.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := role(3, "r3"); err != nil {
		t.Fatalf("role change after the interval: %v", err)
	}
}
