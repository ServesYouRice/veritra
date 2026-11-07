package storage

import (
	"bytes"
	"context"
	"encoding/json"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
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

// claimLegacyLink creates and claims a legacy v2 device link for the account.
func claimLegacyLink(t *testing.T, ctx context.Context, store *Store, account AccountDevice) (linkID string, transcript []byte) {
	t.Helper()
	link, err := store.CreateDeviceLink(ctx, account.Account.ID, account.Device.ID, time.Minute, testLinkLocator(t))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ReserveDeviceLinkEnrollment(ctx, link.Code); err != nil {
		t.Fatal(err)
	}
	_, claimTokenHash, err := auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	transcript = bytes.Repeat([]byte{3}, 32)
	if _, err := store.ClaimDeviceLink(ctx, link.Code, "Tablet", []byte("tablet-key-package"), bytes.Repeat([]byte{2}, 32), transcript, bytes.Repeat([]byte{8}, 32), claimTokenHash, auth.HashToken("tablet-device-secret")); err != nil {
		t.Fatal(err)
	}
	return link.ID, transcript
}

// The shipped app approves links through the legacy v2 route, so that route
// must tell the coordinator too (D96); the event-less variant stays silent.
func TestLegacyDeviceLinkApprovalTellsTheCoordinator(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
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
	noticeCount := func() int {
		t.Helper()
		events, err := store.ListSyncEvents(ctx, bob.Account.ID, coordBob, 0, 100)
		if err != nil {
			t.Fatal(err)
		}
		n := 0
		for _, event := range events {
			if event.Type == MemberLinkEventType {
				n++
			}
		}
		return n
	}

	// The event-less variant writes nothing.
	silentID, silentTranscript := claimLegacyLink(t, ctx, store, owner)
	if _, _, err := store.ApproveDeviceLink(ctx, silentID, owner.Account.ID, silentTranscript, bytes.Repeat([]byte{9}, 32)); err != nil {
		t.Fatal(err)
	}
	if got := noticeCount(); got != 0 {
		t.Fatalf("ApproveDeviceLink wrote %d notices, want 0", got)
	}

	// The route the app uses writes one for the coordinator, in the same
	// transaction as the device row.
	linkID, transcript := claimLegacyLink(t, ctx, store, owner)
	_, device, eventID, notices, err := store.ApproveDeviceLinkWithSyncEvent(ctx, linkID, owner.Account.ID, transcript, bytes.Repeat([]byte{9}, 32))
	if err != nil {
		t.Fatal(err)
	}
	if eventID == 0 || len(notices) != 1 || notices[0].AccountID != bob.Account.ID || notices[0].DeviceID != device.ID ||
		notices[0].LinkedAccountID != owner.Account.ID || notices[0].EventID == 0 {
		t.Fatalf("event %d notices %+v, want one for bob about %s", eventID, notices, device.ID)
	}
	if got := noticeCount(); got != 1 {
		t.Fatalf("bob's sync lists %d notices, want 1", got)
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
}
