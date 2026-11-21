package storage

import (
	"context"
	"strings"
	"testing"
	"time"

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

	// A group request tells the group's owner and admin (once the quiet
	// window after the community notice has passed).
	backdateJoinRequestNotices(t, ctx, f.store)
	f.invite(t, ctx, f.groupTarget(), f.admin, testLocator(12), 9)
	group, err := f.store.FileJoinRequest(ctx, alice.Account.ID, testLocator(12))
	if err != nil || len(group.Notices) != 2 {
		t.Fatalf("group: %+v err=%v", group, err)
	}
}

// backdateJoinRequestNotices moves every stored notice to before the quiet
// window, as if it had been sent long ago.
func backdateJoinRequestNotices(t *testing.T, ctx context.Context, store *Store) {
	t.Helper()
	if _, err := store.db.ExecContext(ctx, `UPDATE sync_events SET created_at = ? WHERE event_type = ?`, formatTime(time.Now().UTC().Add(-joinRequestNoticeQuiet-time.Minute)), JoinRequestNoticeEventType); err != nil {
		t.Fatal(err)
	}
}

// Anyone holding an invitation link can cancel and refile (or be declined and
// refile) as fast as the write budget allows. Each owner and admin is told at
// most once per quiet window, whoever files and for whichever target, so the
// generic push cannot be turned into a flood. Fails if the window is removed.
func TestJoinRequestNoticeCannotBeRepeatedByRefiling(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice, bob := f.people[0], f.people[1]
	f.invite(t, ctx, f.communityTarget(), f.admin, testLocator(13), 9)

	perAdmin := func() map[string]int {
		t.Helper()
		counts := map[string]int{}
		for _, n := range joinRequestNoticeRows(t, ctx, f.store) {
			counts[n.account]++
		}
		return counts
	}
	first, err := f.store.FileJoinRequest(ctx, alice.Account.ID, testLocator(13))
	if err != nil || !first.Created || len(first.Notices) != 2 {
		t.Fatalf("first: %+v err=%v", first, err)
	}
	requestID := first.Request.ID
	for i := 0; i < 5; i++ {
		if i%2 == 0 {
			if err := f.store.CancelJoinRequest(ctx, alice.Account.ID, requestID); err != nil {
				t.Fatalf("cancel %d: %v", i, err)
			}
		} else if _, err := f.store.DecideJoinRequest(ctx, f.admin.Account.ID, requestID, false); err != nil {
			t.Fatalf("decline %d: %v", i, err)
		}
		again, err := f.store.FileJoinRequest(ctx, alice.Account.ID, testLocator(13))
		if err != nil || !again.Created {
			t.Fatalf("refile %d: %+v err=%v", i, again, err)
		}
		if len(again.Notices) != 0 {
			t.Fatalf("refile %d told admins again: %+v", i, again.Notices)
		}
		requestID = again.Request.ID
	}
	// Another requester inside the window tells no one either.
	other, err := f.store.FileJoinRequest(ctx, bob.Account.ID, testLocator(13))
	if err != nil || !other.Created || len(other.Notices) != 0 {
		t.Fatalf("second requester: %+v err=%v", other, err)
	}
	if got := perAdmin(); len(got) != 2 || got[f.owner.Account.ID] != 1 || got[f.admin.Account.ID] != 1 {
		t.Fatalf("notices per admin = %v", got)
	}
	// After the window a new request is told again.
	backdateJoinRequestNotices(t, ctx, f.store)
	if err := f.store.CancelJoinRequest(ctx, alice.Account.ID, requestID); err != nil {
		t.Fatal(err)
	}
	later, err := f.store.FileJoinRequest(ctx, alice.Account.ID, testLocator(13))
	if err != nil || !later.Created || len(later.Notices) != 2 {
		t.Fatalf("after the window: %+v err=%v", later, err)
	}
}
