package storage

import (
	"context"
	"database/sql"
	"testing"
)

// visibleSyncLatestReference is the latest edge of legacySyncBoundsQuery
// with the envelope visibility sync applies to message events: an event for
// an expired, gone or deleted envelope is never served, so it is not the
// latest bound. The oldest bound is the legacy one.
const visibleSyncLatestReference = `
		SELECT MAX(id) FROM (
			SELECT id FROM sync_events WHERE account_id = ?
			UNION ALL
			SELECT se.id FROM sync_events se
			JOIN memberships m ON m.conversation_id = se.conversation_id
			WHERE se.account_id IS NULL AND m.account_id = ?
			  AND NOT EXISTS (
			    SELECT 1 FROM account_blocks b
			    WHERE b.blocker_account_id = m.account_id
			      AND b.blocked_account_id = CASE
			        WHEN se.event_type LIKE 'message.%' THEN (SELECT sender_account_id FROM message_envelopes WHERE id = json_extract(se.payload_json, '$.message_id'))
			        WHEN se.event_type LIKE 'reaction.%' OR se.event_type = 'read_receipt.updated' THEN json_extract(se.payload_json, '$.account_id')
			        WHEN se.event_type LIKE 'call.%' THEN json_extract(se.payload_json, '$.created_by')
			        ELSE NULL
			      END
			  )
			  AND NOT (se.event_type = 'read_receipt.updated' AND EXISTS (
			    SELECT 1 FROM account_blocks rb
			    WHERE rb.blocker_account_id = json_extract(se.payload_json, '$.account_id')
			      AND rb.blocked_account_id = m.account_id
			  ))
			  AND (se.event_type NOT LIKE 'message.envelope.%' OR EXISTS (
			    SELECT 1 FROM message_envelopes live
			    WHERE live.id = json_extract(se.payload_json, '$.message_id')
			      AND (live.expires_at IS NULL OR live.expires_at > ` + sqlNowText + `)
			      AND (live.deleted_at IS NULL OR se.event_type = 'message.envelope.deleted')))
		)`

// rewrittenSyncBounds runs the T49A rewrite of the bounds, without the
// envelope visibility SyncBounds adds.
func rewrittenSyncBounds(t testing.TB, store *Store, accountID string) (int64, int64) {
	t.Helper()
	var oldest, latest sql.NullInt64
	if err := store.db.QueryRowContext(context.Background(), `SELECT `+syncOldestExpr+`, `+syncLatestExpr, accountID).Scan(&oldest, &latest); err != nil {
		t.Fatal(err)
	}
	return oldest.Int64, latest.Int64
}

// visibleSyncBounds is the oldest bound of legacySyncBoundsQuery and the
// latest of visibleSyncLatestReference.
func visibleSyncBounds(t testing.TB, store *Store, accountID string) (int64, int64) {
	t.Helper()
	oldest, _ := legacySyncBounds(t, store, accountID)
	var latest sql.NullInt64
	if err := store.db.QueryRowContext(context.Background(), visibleSyncLatestReference, accountID, accountID).Scan(&latest); err != nil {
		t.Fatal(err)
	}
	return oldest, latest.Int64
}

// checkSyncBoundsVisible compares SyncBounds with the visible reference.
func checkSyncBoundsVisible(t testing.TB, ctx context.Context, store *Store, accountID string) {
	t.Helper()
	_, oldest, latest, err := store.SyncBounds(ctx, accountID)
	if err != nil {
		t.Fatal(err)
	}
	wantOldest, wantLatest := visibleSyncBounds(t, store, accountID)
	if oldest != wantOldest || latest != wantLatest {
		t.Fatalf("SyncBounds(%s) = %d..%d, want %d..%d", accountID, oldest, latest, wantOldest, wantLatest)
	}
}

// The equivalence dataset hides the newest message of some conversations,
// so the visible latest bound really differs from the reference for some
// account; otherwise checkSyncBoundsVisible would be vacuous there.
func TestSyncBoundsVisibilityIsNotVacuous(t *testing.T) {
	ctx := context.Background()
	store := newBenchStore(t, ctx)
	ds := seedBenchDataset(t, ctx, store, benchProfile{Name: "equivalence", Accounts: 16, Conversations: 32, HotMemberships: 16,
		MembersPerConv: 4, MessagesPerConv: 20, AccountEvents: 40, CiphertextBytes: 32, BlockedByHot: 2, ReadReceiptRatio: 2})
	seedEquivalenceEdges(t, store, ds)
	differs := false
	for _, account := range ds.Accounts {
		checkSyncBoundsVisible(t, ctx, store, account)
		_, legacyLatest := legacySyncBounds(t, store, account)
		if _, visibleLatest := visibleSyncBounds(t, store, account); visibleLatest < legacyLatest {
			differs = true
		}
	}
	if !differs {
		t.Fatal("no account has an envelope-hidden latest edge; the visibility check is vacuous")
	}
}
