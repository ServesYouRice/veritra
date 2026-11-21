package storage

import (
	"context"
	"strings"
	"testing"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/domain"
)

type storedNotice struct {
	account string
	payload string
}

func joinRequestNoticeRows(t *testing.T, ctx context.Context, store *Store) []storedNotice {
	t.Helper()
	rows, err := store.db.QueryContext(ctx, `SELECT COALESCE(account_id, ''), COALESCE(conversation_id, ''), payload_json FROM sync_events WHERE event_type = ? ORDER BY id`, JoinRequestNoticeEventType)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []storedNotice
	for rows.Next() {
		var n storedNotice
		var conversation string
		if err := rows.Scan(&n.account, &conversation, &n.payload); err != nil {
			t.Fatal(err)
		}
		if conversation != "" {
			t.Fatalf("notice bound to a conversation: %s", conversation)
		}
		out = append(out, n)
	}
	return out
}

// Owner decision 2026-11-21: each owner and admin of the target gets one
// content-free account event per new request; members, the requester and a
// repeated ask get none, and the event names no one and nothing.
func TestNewJoinRequestNoticesAdminsOnlyWithoutContent(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice := f.people[0]
	mod := f.people[1]
	f.addMember(t, ctx, mod, domain.RoleModerator)
	f.invite(t, ctx, f.communityTarget(), f.admin, testLocator(11), 9)

	filed, err := f.store.FileJoinRequest(ctx, alice.Account.ID, testLocator(11))
	if err != nil || !filed.Created {
		t.Fatalf("file: %+v err=%v", filed, err)
	}
	want := map[string]bool{f.owner.Account.ID: true, f.admin.Account.ID: true}
	if len(filed.Notices) != len(want) {
		t.Fatalf("notices = %+v", filed.Notices)
	}
	for _, n := range filed.Notices {
		if !want[n.AccountID] || n.EventID == 0 {
			t.Fatalf("notice to %s (event %d)", n.AccountID, n.EventID)
		}
	}
	stored := joinRequestNoticeRows(t, ctx, f.store)
	if len(stored) != 2 {
		t.Fatalf("stored = %+v", stored)
	}
	for _, n := range stored {
		if !want[n.account] {
			t.Fatalf("stored notice for %s", n.account)
		}
		if n.payload != "{}" {
			t.Fatalf("payload = %s", n.payload)
		}
		for _, secret := range []string{alice.Account.ID, alice.Account.Username, f.comm.ID, filed.Request.ID, testLocator(11)} {
			if strings.Contains(n.payload, secret) {
				t.Fatalf("payload %s holds %q", n.payload, secret)
			}
		}
	}
	// Asking again returns the same request and tells no one again.
	again, err := f.store.FileJoinRequest(ctx, alice.Account.ID, testLocator(11))
	if err != nil || again.Created || len(again.Notices) != 0 {
		t.Fatalf("again: %+v err=%v", again, err)
	}
	if got := joinRequestNoticeRows(t, ctx, f.store); len(got) != 2 {
		t.Fatalf("stored after a repeat = %+v", got)
	}
	// Each admin's own device sees it in sync; a member's does not.
	visible := func(who AccountDevice) int {
		t.Helper()
		events, err := f.store.ListSyncEvents(ctx, who.Account.ID, who.Device.ID, 0, 500)
		if err != nil {
			t.Fatal(err)
		}
		n := 0
		for _, event := range events {
			if event.Type == JoinRequestNoticeEventType {
				n++
			}
		}
		return n
	}
	if visible(f.admin) != 1 || visible(f.owner) != 1 || visible(f.member) != 0 || visible(mod) != 0 || visible(alice) != 0 {
		t.Fatal("notice visibility is wrong")
	}

	// A group request tells the group's owner and admin.
	f.invite(t, ctx, f.groupTarget(), f.admin, testLocator(12), 9)
	group, err := f.store.FileJoinRequest(ctx, alice.Account.ID, testLocator(12))
	if err != nil || len(group.Notices) != 2 {
		t.Fatalf("group: %+v err=%v", group, err)
	}
}
