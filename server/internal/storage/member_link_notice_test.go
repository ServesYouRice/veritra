package storage

import (
	"context"
	"encoding/json"
	"testing"
)

func TestMemberLinkNoticeWakesOnlyTheCoordinatorAccount(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	carol := registerTestMember(t, ctx, store, invite.Code, "carol")
	// "dev-" ids sort before generated ones, so coordBob coordinates.
	addTestDevice(t, ctx, store, bob.Account.ID, coordBob)
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID,
		MemberAccountIDs: []string{bob.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis", Commit: []byte("commit-0"), Welcome: []byte("welcome-0"),
		Added: []MLSDeviceRef{{AccountID: bob.Account.ID, DeviceID: coordBob}},
	}); err != nil {
		t.Fatal(err)
	}
	notify := func(account, device string) []MemberLinkNotice {
		t.Helper()
		tx, err := store.db.BeginTx(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback()
		notices, err := insertMemberLinkNotices(ctx, tx, account, device, nowString())
		if err != nil {
			t.Fatal(err)
		}
		if err := tx.Commit(); err != nil {
			t.Fatal(err)
		}
		return notices
	}

	// The owner links a device: bob's device coordinates, so bob is told.
	notices := notify(owner.Account.ID, "dev-new-owner")
	if len(notices) != 1 || notices[0].AccountID != bob.Account.ID || notices[0].EventID == 0 {
		t.Fatalf("notices = %+v, want one for bob", notices)
	}
	events, err := store.ListSyncEvents(ctx, bob.Account.ID, coordBob, 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	var found bool
	for _, event := range events {
		if event.Type != MemberLinkEventType {
			continue
		}
		found = true
		var payload map[string]string
		if err := json.Unmarshal(event.Payload, &payload); err != nil {
			t.Fatal(err)
		}
		if len(payload) != 2 || payload["account_id"] != owner.Account.ID || payload["device_id"] != "dev-new-owner" || event.ConversationID != "" {
			t.Fatalf("payload = %v conversation = %q: want the two ids only", payload, event.ConversationID)
		}
	}
	if !found {
		t.Fatal("bob's sync does not list the notice")
	}
	ownerEvents, err := store.ListSyncEvents(ctx, owner.Account.ID, owner.Device.ID, 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	for _, event := range ownerEvents {
		if event.Type == MemberLinkEventType {
			t.Fatal("the linking account was told about its own link")
		}
	}

	// Bob links a device: the owner's device is not the coordinator, so
	// nobody else is told (the owner is a member but bob's device leads).
	if got := notify(bob.Account.ID, "dev-new-bob"); len(got) != 0 {
		t.Fatalf("bob's own device coordinates, got %+v", got)
	}
	// An account in no group tells nobody.
	if got := notify(carol.Account.ID, "dev-new-carol"); len(got) != 0 {
		t.Fatalf("carol is in no group, got %+v", got)
	}
}
