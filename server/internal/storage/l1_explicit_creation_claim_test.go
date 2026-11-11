package storage

import (
	"context"
	"errors"
	"testing"
)

func TestL1ExplicitClaimsBeforeGroupCreation(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 3, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	outsider := registerTestMember(t, ctx, store, invite.Code, "outsider")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{bob.Account.ID},
	})
	if err != nil {
		t.Fatal(err)
	}
	addTestDevice(t, ctx, store, bob.Account.ID, "dev_signed_candidate")
	addTestDevice(t, ctx, store, bob.Account.ID, "dev_not_requested")
	addTestDevice(t, ctx, store, owner.Account.ID, "dev_revoked_requester")
	if _, err := store.db.ExecContext(ctx, `UPDATE devices SET revoked_at = ? WHERE id = 'dev_revoked_requester'`, nowString()); err != nil {
		t.Fatal(err)
	}
	for _, requester := range []struct{ account, device string }{
		{outsider.Account.ID, outsider.Device.ID},
		{owner.Account.ID, bob.Device.ID},
		{owner.Account.ID, "dev_revoked_requester"},
	} {
		if _, err := store.ClaimDeviceKeyPackages(ctx, conversation.ID, requester.account, requester.device,
			[]string{"dev_signed_candidate"}); !errors.Is(err, ErrNotMember) {
			t.Fatalf("unauthorized initial claim: %v", err)
		}
	}
	claimed, err := store.ClaimDeviceKeyPackages(ctx, conversation.ID, owner.Account.ID, owner.Device.ID,
		[]string{"dev_signed_candidate"})
	if err != nil || len(claimed) != 1 || claimed[0].DeviceID != "dev_signed_candidate" {
		t.Fatalf("explicit initial claim: %#v %v", claimed, err)
	}
	var unclaimed int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM device_key_packages
		WHERE device_id = 'dev_not_requested' AND claimed_at IS NULL`).Scan(&unclaimed); err != nil || unclaimed != 1 {
		t.Fatalf("unrequested package consumed: %d %v", unclaimed, err)
	}
	// No package left is a partial result, including before initialization.
	claimed, err = store.ClaimDeviceKeyPackages(ctx, conversation.ID, owner.Account.ID, owner.Device.ID,
		[]string{"dev_signed_candidate", "dev_not_requested"})
	if err != nil || len(claimed) != 1 || claimed[0].DeviceID != "dev_not_requested" {
		t.Fatalf("partial initial claim: %#v %v", claimed, err)
	}
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID,
		SenderDeviceID: owner.Device.ID, Epoch: 0, IdempotencyKey: "initial-empty",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ClaimDeviceKeyPackages(ctx, conversation.ID, bob.Account.ID, bob.Device.ID,
		[]string{"dev_not_requested"}); !errors.Is(err, ErrMLSNotInGroup) {
		t.Fatalf("non-leaf claimed after initialization: %v", err)
	}
}

func TestL1ExplicitClaimsDoNotReopenLegacyGroups(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	addTestDevice(t, ctx, store, owner.Account.ID, "dev_sibling")
	if _, _, err := store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Kind: "commit", Payload: []byte("opaque legacy commit"), IdempotencyKey: "legacy",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ClaimDeviceKeyPackages(ctx, conversation.ID, owner.Account.ID, owner.Device.ID,
		[]string{"dev_sibling"}); !errors.Is(err, ErrMLSNotInGroup) {
		t.Fatalf("legacy group reopened: %v", err)
	}
}
