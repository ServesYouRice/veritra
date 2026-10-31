package storage

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"private-messenger/server/migrations"
)

// A sync cursor expires only when retention pruned an event after it that
// the device could have been sent (migration 0044's prune marks). Sync event
// ids are global, so other accounts' events fill most gaps between one
// account's events; they must not expire its cursors.

// pruneSyncEventsThrough prunes every event up to id through with the
// retention sweeper's own call, as if those events had aged out.
func pruneSyncEventsThrough(t *testing.T, ctx context.Context, store *Store, through int64) {
	t.Helper()
	if _, err := store.db.ExecContext(ctx, `UPDATE sync_events SET created_at = '2000-01-01T00:00:00.000000000Z' WHERE id <= ?`, through); err != nil {
		t.Fatal(err)
	}
	if _, err := store.PruneSyncEvents(ctx, time.Now().UTC().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sync_events WHERE id <= ?`, through); n != 0 {
		t.Fatalf("%d events at or below %d survived the prune", n, through)
	}
}

// accountSyncEvent stores an event for one account, for every device of it
// (device "") or only for device.
func accountSyncEvent(t *testing.T, ctx context.Context, store *Store, accountID, device string) int64 {
	t.Helper()
	id, err := store.SaveSyncEvent(ctx, "test.account", &accountID, "", map[string]string{"kind": "test"})
	if err != nil {
		t.Fatal(err)
	}
	if device != "" {
		if _, err := store.db.ExecContext(ctx, `UPDATE sync_events SET device_id = ? WHERE id = ?`, device, id); err != nil {
			t.Fatal(err)
		}
	}
	return id
}

func conversationSyncEvent(t *testing.T, ctx context.Context, store *Store, eventType, conversationID string) int64 {
	t.Helper()
	id, err := store.SaveSyncEvent(ctx, eventType, nil, conversationID, map[string]string{"conversation_id": conversationID})
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func syncCursorExpiredFor(t *testing.T, ctx context.Context, store *Store, account AccountDevice, after int64) bool {
	t.Helper()
	_, err := store.ListSyncEvents(ctx, account.Account.ID, account.Device.ID, after, 50)
	if errors.Is(err, ErrSyncCursorExpired) {
		return true
	}
	if err != nil {
		t.Fatal(err)
	}
	return false
}

// The review's reproduction: the device saw an event, the next ids went to
// events it cannot see, one more event is new for it, and retention pruned
// everything up to that one. Nothing it could see is lost.
func TestSyncCursorIgnoresPrunedEventsOfOtherAccounts(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	_, seen := f.send(t, ctx, "seen", nil)
	// Ids in the gap: another account's own events, and a conversation the
	// bystander is not in.
	accountSyncEvent(t, ctx, f.store, f.blocker.Account.ID, "")
	accountSyncEvent(t, ctx, f.store, f.sender.Account.ID, "")
	other, err := f.store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: f.sender.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	conversationSyncEvent(t, ctx, f.store, "conversation.updated", other.ID)
	_, fresh := f.send(t, ctx, "fresh", nil)
	if fresh <= seen+3 {
		t.Fatalf("setup: gap %d..%d is too small", seen, fresh)
	}
	pruneSyncEventsThrough(t, ctx, f.store, fresh-1)

	events, err := f.store.ListSyncEvents(ctx, f.bystander.Account.ID, f.bystander.Device.ID, seen, 50)
	if err != nil {
		t.Fatalf("cursor %d after other accounts' pruned events: %v", seen, err)
	}
	if len(events) != 1 || events[0].ID != fresh {
		t.Fatalf("page after %d = %v, want only %d", seen, pageEventIDs(events), fresh)
	}
	// The other accounts lost events they could see.
	if !syncCursorExpiredFor(t, ctx, f.store, f.sender, seen) {
		t.Fatal("the sender's cursor survived the prune of its own account event")
	}
}

// A real gap still fails closed: a conversation event the device could see
// was pruned after its cursor.
func TestSyncCursorExpiresWhenAVisibleConversationEventWasPruned(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	_, seen := f.send(t, ctx, "seen", nil)
	accountSyncEvent(t, ctx, f.store, f.blocker.Account.ID, "")
	_, missed := f.send(t, ctx, "missed", nil)
	accountSyncEvent(t, ctx, f.store, f.blocker.Account.ID, "")
	_, fresh := f.send(t, ctx, "fresh", nil)
	pruneSyncEventsThrough(t, ctx, f.store, fresh-1)

	if !syncCursorExpiredFor(t, ctx, f.store, f.bystander, seen) {
		t.Fatalf("cursor %d survived the prune of visible event %d", seen, missed)
	}
	// A plain (not MLS-filtered) conversation event counts the same way.
	plain := conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)
	accountSyncEvent(t, ctx, f.store, f.blocker.Account.ID, "")
	last := conversationSyncEvent(t, ctx, f.store, "conversation.updated", f.conversation.ID)
	if syncCursorExpiredFor(t, ctx, f.store, f.bystander, missed) {
		t.Fatal("a cursor at the last pruned event expired")
	}
	pruneSyncEventsThrough(t, ctx, f.store, last-1)
	if !syncCursorExpiredFor(t, ctx, f.store, f.bystander, fresh) {
		t.Fatalf("cursor %d survived the prune of plain event %d", fresh, plain)
	}
	if syncCursorExpiredFor(t, ctx, f.store, f.bystander, plain) {
		t.Fatal("a cursor at the last visible pruned event expired")
	}
}

// Account events: the account's events for every device and for this device
// count; another device's (a Welcome) does not.
func TestSyncCursorAccountEventMarks(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	cursor := accountSyncEvent(t, ctx, f.store, f.bystander.Account.ID, "")
	accountSyncEvent(t, ctx, f.store, f.bystander.Account.ID, "dev_other_device")
	fresh := accountSyncEvent(t, ctx, f.store, f.bystander.Account.ID, "")
	pruneSyncEventsThrough(t, ctx, f.store, fresh-1)
	if syncCursorExpiredFor(t, ctx, f.store, f.bystander, cursor) {
		t.Fatal("another device's pruned event expired this device's cursor")
	}

	ownDevice := accountSyncEvent(t, ctx, f.store, f.bystander.Account.ID, f.bystander.Device.ID)
	fresh = accountSyncEvent(t, ctx, f.store, f.bystander.Account.ID, "")
	pruneSyncEventsThrough(t, ctx, f.store, fresh-1)
	if !syncCursorExpiredFor(t, ctx, f.store, f.bystander, cursor) {
		t.Fatalf("cursor %d survived the prune of its device's event %d", cursor, ownDevice)
	}

	cursor = fresh
	shared := accountSyncEvent(t, ctx, f.store, f.bystander.Account.ID, "")
	fresh = accountSyncEvent(t, ctx, f.store, f.bystander.Account.ID, "")
	pruneSyncEventsThrough(t, ctx, f.store, fresh-1)
	if !syncCursorExpiredFor(t, ctx, f.store, f.bystander, cursor) {
		t.Fatalf("cursor %d survived the prune of account event %d", cursor, shared)
	}
	// The state row holds the highest pruned id.
	var through int64
	if err := f.store.db.QueryRowContext(ctx, `SELECT pruned_through FROM sync_prune_state WHERE id = 1`).Scan(&through); err != nil || through != fresh-1 {
		t.Fatalf("pruned_through = %d, err = %v, want %d", through, err, fresh-1)
	}
}

// A conversation the account left sends it nothing more, so its pruned
// events do not count; the account learns of the leave from its own
// membership.left event, which does.
func TestSyncCursorIgnoresConversationsTheAccountLeft(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	left, err := f.store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: f.blocker.Account.ID, MemberAccountIDs: []string{f.bystander.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	removal, err := f.store.RemoveConversationMember(ctx, left.ID, f.bystander.Account.ID, f.bystander.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	_, seen := f.send(t, ctx, "seen", nil)
	conversationSyncEvent(t, ctx, f.store, "conversation.updated", left.ID)
	_, fresh := f.send(t, ctx, "fresh", nil)
	pruneSyncEventsThrough(t, ctx, f.store, fresh-1)
	if syncCursorExpiredFor(t, ctx, f.store, f.bystander, seen) {
		t.Fatal("a pruned event of a conversation the account left expired its cursor")
	}
	if !syncCursorExpiredFor(t, ctx, f.store, f.bystander, removal.RemovedMemberEventID-1) {
		t.Fatal("a cursor before the pruned membership.left event survived")
	}
}

// MLS-filtered events follow the device's roster row (card I51): events
// before it joined, or after it was removed, do not count.
func TestSyncCursorFollowsTheMLSJoinCursor(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	conv := f.conversation.ID
	if _, err := f.store.db.ExecContext(ctx, `INSERT INTO conversation_mls_groups(conversation_id, epoch, updated_at) VALUES(?, 1, ?)`, conv, nowString()); err != nil {
		t.Fatal(err)
	}
	cursor := accountSyncEvent(t, ctx, f.store, f.bystander.Account.ID, "")
	preJoin := conversationSyncEvent(t, ctx, f.store, "mls.message.created", conv)
	if _, err := f.store.db.ExecContext(ctx, `INSERT INTO conversation_mls_devices(conversation_id, device_id, account_id, joined_after_event_id, joined_epoch) VALUES(?, ?, ?, ?, 1)`,
		conv, f.bystander.Device.ID, f.bystander.Account.ID, preJoin); err != nil {
		t.Fatal(err)
	}
	fresh := accountSyncEvent(t, ctx, f.store, f.bystander.Account.ID, "")
	pruneSyncEventsThrough(t, ctx, f.store, fresh-1)
	if syncCursorExpiredFor(t, ctx, f.store, f.bystander, cursor) {
		t.Fatal("an MLS event from before the device joined expired its cursor")
	}
	// The sender's device has no roster row in this group, so sync hides
	// the group's MLS events from it: it lost nothing either.
	if syncCursorExpiredFor(t, ctx, f.store, f.sender, cursor) {
		t.Fatal("an MLS event hidden from a device with no roster row expired its cursor")
	}

	postJoin := conversationSyncEvent(t, ctx, f.store, "mls.message.created", conv)
	fresh = accountSyncEvent(t, ctx, f.store, f.bystander.Account.ID, "")
	pruneSyncEventsThrough(t, ctx, f.store, fresh-1)
	if !syncCursorExpiredFor(t, ctx, f.store, f.bystander, cursor) {
		t.Fatalf("cursor %d survived the prune of MLS event %d after the join", cursor, postJoin)
	}

	// Removed at the cursor: later MLS events were never for this device.
	cursor = fresh
	if _, err := f.store.db.ExecContext(ctx, `UPDATE conversation_mls_devices SET removed_after_event_id = ? WHERE conversation_id = ? AND device_id = ?`, cursor, conv, f.bystander.Device.ID); err != nil {
		t.Fatal(err)
	}
	conversationSyncEvent(t, ctx, f.store, "mls.message.created", conv)
	fresh = accountSyncEvent(t, ctx, f.store, f.bystander.Account.ID, "")
	pruneSyncEventsThrough(t, ctx, f.store, fresh-1)
	if syncCursorExpiredFor(t, ctx, f.store, f.bystander, cursor) {
		t.Fatal("an MLS event after the device's removal expired its cursor")
	}
}

// A disappearing message that expired before retention pruned its events is
// hidden from every cursor, so losing it loses nothing.
func TestSyncCursorIgnoresPrunedEventsOfExpiredMessages(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	_, seen := f.send(t, ctx, "seen", nil)
	soon := time.Now().UTC().Add(time.Hour)
	expiring, _ := f.send(t, ctx, "expiring", &soon)
	f.expire(t, ctx, expiring.ID)
	if _, _, err := f.store.PruneExpiredContent(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	_, fresh := f.send(t, ctx, "fresh", nil)
	pruneSyncEventsThrough(t, ctx, f.store, fresh-1)
	if syncCursorExpiredFor(t, ctx, f.store, f.bystander, seen) {
		t.Fatal("the pruned event of an expired message expired the cursor")
	}
}

// Conservative by design: marks keep no sender (that would keep who wrote
// where past retention), so a pruned event of a sender the account blocked
// still expires its cursor although sync would have hidden it.
func TestSyncCursorCountsBlockedSendersConservatively(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	cursor := accountSyncEvent(t, ctx, f.store, f.blocker.Account.ID, "")
	_, blocked := f.send(t, ctx, "from-blocked", nil)
	fresh := accountSyncEvent(t, ctx, f.store, f.blocker.Account.ID, "")
	if seen := f.eventIDs(t, ctx, f.blocker); seen[blocked] {
		t.Fatal("setup: the blocker sees the blocked sender's message")
	}
	pruneSyncEventsThrough(t, ctx, f.store, fresh-1)
	if !syncCursorExpiredFor(t, ctx, f.store, f.blocker, cursor) {
		t.Fatal("expected the documented conservative expiry for a blocked sender's pruned event")
	}
}

// Upgrading: ids pruned before migration 0044 have no marks, so cursors into
// them keep the old test; cursors past them use the marks.
func TestSyncPruneMarksMigrationOnExistingDatabase(t *testing.T) {
	ctx := context.Background()
	store := openBareStore(t)
	old, _ := migrationsUpTo(t, "0043")
	if err := store.Migrate(ctx, old); err != nil {
		t.Fatal(err)
	}
	seedHistorical(t, store) // event 1: a message in conv_dm (acct_a, acct_b)
	insert := func(accountID, conversationID interface{}) int64 {
		result, err := store.db.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('test.event', ?, ?, '{}', '2026-01-01T00:00:00Z')`, accountID, conversationID)
		if err != nil {
			t.Fatal(err)
		}
		id, _ := result.LastInsertId()
		return id
	}
	aOwn := insert("acct_a", nil)
	insert("acct_b", nil)
	insert("acct_b", nil)
	bLast := insert("acct_b", nil)
	plain := insert(nil, "conv_dm")
	// Retention before the upgrade: no trigger, no marks.
	if _, err := store.db.ExecContext(ctx, `DELETE FROM sync_events WHERE id <= ?`, aOwn); err != nil {
		t.Fatal(err)
	}
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	var legacy, through int64
	if err := store.db.QueryRowContext(ctx, `SELECT legacy_through, pruned_through FROM sync_prune_state WHERE id = 1`).Scan(&legacy, &through); err != nil {
		t.Fatal(err)
	}
	if legacy != aOwn || through != aOwn {
		t.Fatalf("seeded legacy_through=%d pruned_through=%d, want both %d", legacy, through, aOwn)
	}
	expired := func(accountID, deviceID string, after int64) bool {
		t.Helper()
		_, err := store.ListSyncEvents(ctx, accountID, deviceID, after, 50)
		if err != nil && !errors.Is(err, ErrSyncCursorExpired) {
			t.Fatal(err)
		}
		return err != nil
	}
	// Below the seeded boundary the old test still answers (and here it is
	// right: acct_a's own event aOwn is gone).
	if !expired("acct_a", "dev_a", 1) {
		t.Fatal("a cursor into the pre-upgrade pruned range survived")
	}
	// At the boundary nothing after the cursor was pruned. The old test
	// refused this cursor: its event is gone and acct_b's events lie
	// between it and acct_a's next event.
	if expired("acct_a", "dev_a", aOwn) {
		t.Fatal("a cursor at the seeded boundary expired")
	}
	// Retention after the upgrade keeps marks: acct_b's events are gone,
	// which acct_a never could see, but acct_b could.
	if _, err := store.db.ExecContext(ctx, `DELETE FROM sync_events WHERE id <= ?`, bLast); err != nil {
		t.Fatal(err)
	}
	if expired("acct_a", "dev_a", aOwn) {
		t.Fatal("another account's events pruned after the upgrade expired the cursor")
	}
	if !expired("acct_b", "dev_b", aOwn) {
		t.Fatal("acct_b's cursor survived the prune of its own events")
	}
	if _, err := store.db.ExecContext(ctx, `DELETE FROM sync_events WHERE id <= ?`, plain); err != nil {
		t.Fatal(err)
	}
	if !expired("acct_a", "dev_a", aOwn) {
		t.Fatal("acct_a's cursor survived the prune of a conversation event")
	}
}

// With every event already pruned, the seed is the last id ever issued.
func TestSyncPruneMarksMigrationSeedsFromTheSequenceWhenEmpty(t *testing.T) {
	ctx := context.Background()
	store := openBareStore(t)
	old, _ := migrationsUpTo(t, "0043")
	if err := store.Migrate(ctx, old); err != nil {
		t.Fatal(err)
	}
	seedHistorical(t, store)
	for i := 0; i < 3; i++ {
		if _, err := store.db.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('test.event', 'acct_a', NULL, '{}', '2026-01-01T00:00:00Z')`); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := store.db.ExecContext(ctx, `DELETE FROM sync_events`); err != nil {
		t.Fatal(err)
	}
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	var legacy int64
	if err := store.db.QueryRowContext(ctx, `SELECT legacy_through FROM sync_prune_state WHERE id = 1`).Scan(&legacy); err != nil || legacy != 4 {
		t.Fatalf("legacy_through = %d, err = %v, want 4", legacy, err)
	}
}

// The marks query must stay on indexes: the membership walk on
// memberships(account_id, conversation_id) and primary-key reads of the
// marks and the roster, never a scan of a table.
func TestSyncPruneMarksQueryUsesIndexes(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	rows, err := f.store.db.QueryContext(ctx, "EXPLAIN QUERY PLAN "+syncPruneMarksExpiredQuery, f.bystander.Account.ID, 1, f.bystander.Device.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var plan []string
	for rows.Next() {
		var id, parent, unused int
		var detail string
		if err := rows.Scan(&id, &parent, &unused, &detail); err != nil {
			t.Fatal(err)
		}
		plan = append(plan, detail)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	for _, step := range plan {
		if strings.HasPrefix(step, "SCAN ") && step != "SCAN CONSTANT ROW" {
			t.Fatalf("marks query scans a table: %q in %q", step, plan)
		}
	}
}
