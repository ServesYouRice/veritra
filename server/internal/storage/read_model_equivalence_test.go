package storage

import (
	"context"
	"database/sql"
	"fmt"
	"reflect"
	"testing"
	"time"

	"private-messenger/server/internal/domain"
)

// T49A/T49B: the rewritten sync-bounds, conversation-list and quota queries
// must return exactly what the original queries returned. The originals are
// kept here verbatim as the reference.

const legacySyncBoundsQuery = `
		SELECT MIN(id), MAX(id) FROM (
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
		)`

const legacyListConversationsPageQuery = `
		WITH conversation_activity AS (
			SELECT c.id, c.kind, c.title, c.community_id, c.channel_id,
			       c.created_by, c.retention_seconds, c.created_at,
			       m.role AS current_role, lm.last_message_at,
			       COALESCE(lm.last_message_at, c.created_at) AS activity_at,
			       COALESCE((
			           SELECT COUNT(*) FROM message_envelopes me
			           WHERE me.conversation_id = c.id
			             AND me.sender_account_id != ?
			             AND NOT EXISTS (SELECT 1 FROM account_blocks b WHERE b.blocker_account_id = ? AND b.blocked_account_id = me.sender_account_id)
			             AND me.deleted_at IS NULL
			             AND (me.expires_at IS NULL OR me.expires_at > ?)
			             AND (rr.message_id IS NULL OR me.created_at > (
			                 SELECT created_at FROM message_envelopes WHERE id = rr.message_id
			             ))
			       ), 0) AS unread_count,
			       CASE WHEN c.kind = 'dm' THEN (
			           SELECT m2.account_id FROM memberships m2
			           WHERE m2.conversation_id = c.id AND m2.account_id != ?
			           ORDER BY m2.created_at, m2.account_id LIMIT 1
			       ) END AS peer_account_id,
			       CASE WHEN c.kind = 'dm' THEN (
			           SELECT COALESCE(a2.username, '') FROM memberships m2
			           LEFT JOIN accounts a2 ON a2.id = m2.account_id
			           WHERE m2.conversation_id = c.id AND m2.account_id != ?
			           ORDER BY m2.created_at, m2.account_id LIMIT 1
			       ) END AS peer_username
			FROM conversations c
			JOIN memberships m ON m.conversation_id = c.id
			LEFT JOIN read_receipts rr
			  ON rr.conversation_id = c.id AND rr.account_id = ?
			LEFT JOIN (
				SELECT conversation_id, MAX(created_at) AS last_message_at
				FROM message_envelopes
				WHERE deleted_at IS NULL
				  AND (expires_at IS NULL OR expires_at > ?)
				  AND NOT EXISTS (SELECT 1 FROM account_blocks b WHERE b.blocker_account_id = ? AND b.blocked_account_id = message_envelopes.sender_account_id)
				GROUP BY conversation_id
			) lm ON lm.conversation_id = c.id
			WHERE m.account_id = ?
		)
		SELECT id, kind, title, community_id, channel_id, created_by,
		       retention_seconds, created_at, current_role, last_message_at,
		       unread_count, peer_account_id, peer_username
		FROM conversation_activity
		WHERE (? = '' OR (activity_at, id) < (
			SELECT activity_at, id FROM conversation_activity WHERE id = ?
		))
		ORDER BY activity_at DESC, id DESC
		LIMIT ?`

const legacyBlobUsageQuery = `SELECT COALESCE(SUM(size_bytes), 0) FROM (
		SELECT owner_account_id AS account_id, size_bytes FROM attachment_envelopes
		UNION ALL SELECT account_id, size_bytes FROM backup_blobs
	)`

func legacySyncBounds(t *testing.T, store *Store, accountID string) (int64, int64) {
	t.Helper()
	var oldest, latest sql.NullInt64
	if err := store.db.QueryRowContext(context.Background(), legacySyncBoundsQuery, accountID, accountID).Scan(&oldest, &latest); err != nil {
		t.Fatal(err)
	}
	return oldest.Int64, latest.Int64
}

func listConversations(t *testing.T, store *Store, query string, args ...interface{}) []domain.Conversation {
	t.Helper()
	rows, err := store.db.QueryContext(context.Background(), query, args...)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []domain.Conversation
	for rows.Next() {
		c, err := scanConversationWithRole(rows)
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

func legacyConversationsPage(t *testing.T, store *Store, accountID string, limit int, beforeID, now string) []domain.Conversation {
	return listConversations(t, store, legacyListConversationsPageQuery,
		accountID, accountID, now, accountID, accountID, accountID, now, accountID, accountID, beforeID, beforeID, limit)
}

func newConversationsPage(t *testing.T, store *Store, accountID string, limit int, beforeID, now string) []domain.Conversation {
	return listConversations(t, store, listConversationsPageQuery, accountID, now, beforeID, limit)
}

// seedEquivalenceEdges adds the cases the bench seed lacks: more blockers,
// deleted and expired messages, edge events from blocked accounts, reaction,
// read-receipt and call events, account events for another device, MLS join
// cursors, empty conversations with tied creation times, and attachments in
// conversations.
func seedEquivalenceEdges(t *testing.T, store *Store, ds benchDataset) {
	t.Helper()
	ctx := context.Background()
	exec := func(query string, args ...interface{}) {
		t.Helper()
		if _, err := store.db.ExecContext(ctx, query, args...); err != nil {
			t.Fatalf("%s: %v", query, err)
		}
	}
	n := len(ds.Accounts)
	for i := 1; i <= 12; i++ {
		exec(`INSERT OR IGNORE INTO account_blocks(blocker_account_id, blocked_account_id, created_at) VALUES(?, ?, '2026-02-01T00:00:00Z')`,
			ds.Accounts[i], ds.Accounts[(i*7)%n])
	}
	exec(`INSERT OR IGNORE INTO account_blocks(blocker_account_id, blocked_account_id, created_at) VALUES(?, ?, '2026-02-01T00:00:00Z')`, ds.HotAccount, ds.Accounts[1])
	exec(`UPDATE message_envelopes SET deleted_at = '2026-02-01T00:00:00Z' WHERE rowid % 11 = 0`)
	exec(`UPDATE message_envelopes SET expires_at = '2020-01-01T00:00:00Z' WHERE rowid % 13 = 0`)
	exec(`UPDATE message_envelopes SET expires_at = '2099-01-01T00:00:00Z' WHERE rowid % 17 = 0`)
	// The newest message of every fifth conversation is deleted, so the
	// last visible message is further back.
	exec(`UPDATE message_envelopes SET deleted_at = '2026-02-01T00:00:00Z'
		WHERE id IN (SELECT MAX(id) FROM message_envelopes GROUP BY conversation_id) AND rowid % 5 = 0`)

	// A conversation whose first and last events come from accounts the hot
	// account blocked, bracketing visible ones.
	blocked := ds.Accounts[1]
	conv := "conv_edges"
	exec(`INSERT INTO conversations(id, kind, created_by, created_at) VALUES(?, 'group', ?, '2026-03-01T00:00:00Z')`, conv, ds.HotAccount)
	for i, member := range []string{ds.HotAccount, blocked, ds.Accounts[2]} {
		exec(`INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, 'member', '2026-03-01T00:00:00Z')`,
			fmt.Sprintf("mem_edges_%d", i), member, conv)
	}
	devices := map[string]string{blocked: ds.Devices[1], ds.Accounts[2]: ds.Devices[2]}
	addMessage := func(id, sender, at string) {
		exec(`INSERT INTO message_envelopes(id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, created_at)
			VALUES(?, ?, ?, ?, ?, X'0102', 'mls', '{}', '[]', ?)`, id, conv, sender, devices[sender], id, at)
		exec(`INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('message.envelope.created', NULL, ?, ?, ?)`,
			conv, fmt.Sprintf(`{"message_id":%q}`, id), at)
	}
	addEvent := func(eventType, payload string) {
		exec(`INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES(?, NULL, ?, ?, '2026-03-02T00:00:00Z')`, eventType, conv, payload)
	}
	addMessage("msg_edge_1", blocked, "2026-03-01T00:00:01Z")
	addEvent("reaction.created", fmt.Sprintf(`{"account_id":%q}`, blocked))
	addMessage("msg_edge_2", ds.Accounts[2], "2026-03-01T00:00:02Z")
	addEvent("read_receipt.updated", fmt.Sprintf(`{"account_id":%q}`, ds.Accounts[2]))
	addEvent("message.envelope.deleted", `{"message_id":"msg_gone"}`)
	addMessage("msg_edge_3", blocked, "2026-03-01T00:00:03Z")
	addEvent("call.created", fmt.Sprintf(`{"created_by":%q}`, blocked))
	addEvent("read_receipt.updated", fmt.Sprintf(`{"account_id":%q}`, blocked))

	// A conversation with only blocked events: no visible bound from it.
	exec(`INSERT INTO conversations(id, kind, created_by, created_at) VALUES('conv_all_blocked', 'dm', ?, '2026-03-01T00:00:00Z')`, ds.HotAccount)
	exec(`INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES('mem_ab_0', ?, 'conv_all_blocked', 'member', '2026-03-01T00:00:00Z')`, ds.HotAccount)
	exec(`INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES('mem_ab_1', ?, 'conv_all_blocked', 'member', '2026-03-01T00:00:00Z')`, blocked)
	exec(`INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('call.created', NULL, 'conv_all_blocked', ?, '2026-03-03T00:00:00Z')`,
		fmt.Sprintf(`{"created_by":%q}`, blocked))

	// Empty conversations with tied creation times order by id.
	for _, id := range []string{"conv_tie_a", "conv_tie_b", "conv_tie_c"} {
		exec(`INSERT INTO conversations(id, kind, created_by, created_at) VALUES(?, 'group', ?, '2026-01-01T00:00:05Z')`, id, ds.HotAccount)
		exec(`INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, 'member', '2026-01-01T00:00:05Z')`, "mem_"+id, ds.HotAccount, id)
	}

	// Account events, including a Welcome for another device of the account.
	exec(`INSERT INTO sync_events(event_type, account_id, conversation_id, device_id, payload_json, created_at) VALUES('mls.welcome', ?, NULL, 'dev_other', '{}', '2026-03-04T00:00:00Z')`, ds.Accounts[3])

	// MLS join cursors on the hot conversation do not change bounds.
	exec(`INSERT INTO conversation_mls_groups(conversation_id, epoch, updated_at) VALUES(?, 3, '2026-03-01T00:00:00Z')`, ds.HotConv)
	exec(`INSERT INTO conversation_mls_devices(conversation_id, device_id, account_id, joined_after_event_id, joined_epoch) VALUES(?, ?, ?, 40, 2)`, ds.HotConv, ds.HotDevice, ds.HotAccount)
}

func checkReadModelsMatch(t *testing.T, store *Store, accounts []string) {
	t.Helper()
	ctx := context.Background()
	now := nowString()
	for i, account := range append(accounts, "acct_unknown") {
		// Paging and cursor checks on the hot account and three blockers;
		// whole-list checks on everyone (keeps the race run short).
		paged := i < 4
		_, oldest, latest, err := store.SyncBounds(ctx, account)
		if err != nil {
			t.Fatal(err)
		}
		wantOldest, wantLatest := legacySyncBounds(t, store, account)
		if oldest != wantOldest || latest != wantLatest {
			t.Fatalf("sync bounds differ: got %d..%d want %d..%d", oldest, latest, wantOldest, wantLatest)
		}

		for _, limit := range []int{7, 1000} {
			if limit == 7 && !paged {
				continue
			}
			before := ""
			for page := 0; ; page++ {
				got := newConversationsPage(t, store, account, limit, before, now)
				want := legacyConversationsPage(t, store, account, limit, before, now)
				if !reflect.DeepEqual(got, want) {
					t.Fatalf("conversation page %d (limit %d) differs:\n got %+v\nwant %+v", page, limit, got, want)
				}
				if len(got) < limit {
					break
				}
				before = got[len(got)-1].ID
			}
		}
		if !paged {
			continue
		}
		// Unknown and foreign cursors yield nothing on both.
		for _, before := range []string{"conv_missing", "conv_all_blocked"} {
			got := newConversationsPage(t, store, account, 50, before, now)
			want := legacyConversationsPage(t, store, account, 50, before, now)
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("cursor %s differs: got %d want %d rows", before, len(got), len(want))
			}
		}
	}
}

func TestReadModelQueriesMatchLegacy(t *testing.T) {
	ctx := context.Background()
	store := newBenchStore(t, ctx)
	ds := seedBenchDataset(t, ctx, store, benchProfile{Name: "equivalence", Accounts: 16, Conversations: 32, HotMemberships: 16,
		MembersPerConv: 4, MessagesPerConv: 20, AccountEvents: 40, CiphertextBytes: 32, BlockedByHot: 2, ReadReceiptRatio: 2})
	seedEquivalenceEdges(t, store, ds)

	var unreadSum, blockedHidden int64
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM account_blocks`).Scan(&blockedHidden); err != nil || blockedHidden < 10 {
		t.Fatalf("blocks=%d err=%v", blockedHidden, err)
	}
	checkReadModelsMatch(t, store, ds.Accounts)
	for _, c := range newConversationsPage(t, store, ds.HotAccount, 1000, "", nowString()) {
		unreadSum += c.UnreadCount
	}
	if unreadSum == 0 {
		t.Fatal("dataset has no unread messages; equivalence would be vacuous")
	}

	// The edge conversation's bounds exclude its blocked first and last
	// events for the hot account but not for the third member.
	var first, last int64
	if err := store.db.QueryRowContext(ctx, `SELECT MIN(id), MAX(id) FROM sync_events WHERE conversation_id = 'conv_edges'`).Scan(&first, &last); err != nil {
		t.Fatal(err)
	}
	if _, _, latest, _ := store.SyncBounds(ctx, ds.Accounts[2]); latest < last {
		t.Fatalf("third member latest=%d want >= %d", latest, last)
	}

	// Retention: pruning expired messages and old sync events moves both
	// bounds and conversation activity; the queries still agree.
	if _, _, err := store.PruneExpiredContent(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	checkReadModelsMatch(t, store, ds.Accounts)
	if _, err := store.db.ExecContext(ctx, `DELETE FROM sync_events WHERE id <= ?`, ds.MidEventID/2); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `DELETE FROM read_receipts WHERE rowid % 2 = 0`); err != nil {
		t.Fatal(err)
	}
	checkReadModelsMatch(t, store, ds.Accounts)

	// Account deletion removes memberships; bounds and lists follow.
	if err := store.DeleteAccount(ctx, ds.Accounts[2]); err != nil {
		t.Fatal(err)
	}
	checkReadModelsMatch(t, store, ds.Accounts)
}

func blobUsage(t *testing.T, store *Store) (map[string]int64, int64, map[string]int64, int64) {
	t.Helper()
	ctx := context.Background()
	counters := map[string]int64{}
	rows, err := store.db.QueryContext(ctx, `SELECT account_id, size_bytes FROM blob_usage_accounts WHERE size_bytes != 0`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var id string
		var size int64
		if err := rows.Scan(&id, &size); err != nil {
			t.Fatal(err)
		}
		counters[id] = size
	}
	rows.Close()
	sums := map[string]int64{}
	rows, err = store.db.QueryContext(ctx, `SELECT account_id, SUM(size_bytes) FROM (
		SELECT owner_account_id AS account_id, size_bytes FROM attachment_envelopes
		UNION ALL SELECT account_id, size_bytes FROM backup_blobs) GROUP BY account_id HAVING SUM(size_bytes) != 0`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var id string
		var size int64
		if err := rows.Scan(&id, &size); err != nil {
			t.Fatal(err)
		}
		sums[id] = size
	}
	rows.Close()
	var counterTotal, sumTotal int64
	if err := store.db.QueryRowContext(ctx, `SELECT size_bytes FROM blob_usage_instance WHERE id = 1`).Scan(&counterTotal); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRowContext(ctx, legacyBlobUsageQuery).Scan(&sumTotal); err != nil {
		t.Fatal(err)
	}
	return counters, counterTotal, sums, sumTotal
}

func checkBlobUsageMatches(t *testing.T, store *Store, step string) {
	t.Helper()
	counters, counterTotal, sums, sumTotal := blobUsage(t, store)
	if !reflect.DeepEqual(counters, sums) || counterTotal != sumTotal {
		t.Fatalf("%s: counters %v total %d, row sums %v total %d", step, counters, counterTotal, sums, sumTotal)
	}
}

func TestBlobUsageCountersMatchRowSums(t *testing.T) {
	ctx := context.Background()
	store := newBenchStore(t, ctx)
	ds := seedBenchDataset(t, ctx, store, benchProfile{Name: "q", Accounts: 6, AttachmentRows: 40, AttachmentBytes: 1000, BackupRows: 6})
	checkBlobUsageMatches(t, store, "seed")

	exec := func(query string, args ...interface{}) {
		t.Helper()
		if _, err := store.db.ExecContext(ctx, query, args...); err != nil {
			t.Fatalf("%s: %v", query, err)
		}
	}
	exec(`INSERT INTO conversations(id, kind, created_by, created_at) VALUES('conv_q', 'group', ?, '2026-01-01T00:00:00Z')`, ds.Accounts[1])
	exec(`INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES('mem_q', ?, 'conv_q', 'owner', '2026-01-01T00:00:00Z')`, ds.Accounts[1])
	for i := 0; i < 5; i++ {
		convID := "conv_q"
		if _, err := store.CreateAttachmentEnvelope(ctx, domain.AttachmentEnvelope{
			OwnerAccountID: ds.Accounts[1], ConversationID: &convID, StorageKey: fmt.Sprintf("blob_q_%d", i),
			CiphertextSHA256: fmt.Sprintf("%064x", i), SizeBytes: int64(100 + i),
		}); err != nil {
			t.Fatal(err)
		}
	}
	checkBlobUsageMatches(t, store, "create attachments")
	recoveryHash := make([]byte, 32)
	if err := store.CreateBackupBlob(ctx, ds.Accounts[2], ds.Devices[2], "blob_backup_q", fmt.Sprintf("%064x", 9), 777, []byte(`{"state_counter":1}`), recoveryHash); err != nil {
		t.Fatal(err)
	}
	checkBlobUsageMatches(t, store, "create backup")
	attachments, err := store.ListAttachments(ctx, ds.Accounts[0], 1)
	if err != nil || len(attachments) == 0 {
		t.Fatalf("list attachments: %d %v", len(attachments), err)
	}
	if _, err := store.DeleteAttachment(ctx, attachments[0].ID, ds.Accounts[0]); err != nil {
		t.Fatal(err)
	}
	checkBlobUsageMatches(t, store, "delete attachment")
	exec(`UPDATE attachment_envelopes SET size_bytes = size_bytes * 3 WHERE rowid % 4 = 0`)
	exec(`UPDATE attachment_envelopes SET owner_account_id = ? WHERE rowid % 5 = 0`, ds.Accounts[4])
	exec(`UPDATE backup_blobs SET size_bytes = 5, account_id = ? WHERE rowid = 1`, ds.Accounts[5])
	checkBlobUsageMatches(t, store, "update size and owner")
	// Foreign-key cascade: deleting the conversation drops its attachments.
	exec(`DELETE FROM conversations WHERE id = 'conv_q'`)
	checkBlobUsageMatches(t, store, "conversation cascade")
	// Orphan attachments older than a day are pruned by retention.
	if _, _, err := store.PruneExpiredContent(ctx, time.Now().Add(48*time.Hour)); err != nil {
		t.Fatal(err)
	}
	checkBlobUsageMatches(t, store, "retention prune")
	if err := store.DeleteAccount(ctx, ds.Accounts[2]); err != nil {
		t.Fatal(err)
	}
	checkBlobUsageMatches(t, store, "account deletion")
	exec(`DELETE FROM accounts WHERE id = ?`, ds.Accounts[3])
	checkBlobUsageMatches(t, store, "account row cascade")
}

func TestBlobQuotaAdmissionBoundaryUnchanged(t *testing.T) {
	ctx := context.Background()
	store := newBenchStore(t, ctx)
	ds := seedBenchDataset(t, ctx, store, benchProfile{Name: "q", Accounts: 3})
	accountLimit := store.Limits().AccountStorageBytes
	check := func(account string, incoming int64, want error) {
		t.Helper()
		tx, err := store.db.BeginTx(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback()
		if err := store.enforceBlobQuota(ctx, tx, account, incoming); err != want {
			t.Fatalf("incoming=%d err=%v want %v", incoming, err, want)
		}
	}
	check(ds.Accounts[1], 0, nil)
	check(ds.Accounts[1], accountLimit, nil)
	check(ds.Accounts[1], accountLimit+1, ErrStorageQuota)
	check(ds.Accounts[1], -1, ErrStorageQuota)
	if _, err := store.CreateAttachmentEnvelope(ctx, domain.AttachmentEnvelope{
		OwnerAccountID: ds.Accounts[1], StorageKey: "blob_big", CiphertextSHA256: fmt.Sprintf("%064x", 1), SizeBytes: accountLimit - 10,
	}); err != nil {
		t.Fatal(err)
	}
	check(ds.Accounts[1], 10, nil)
	check(ds.Accounts[1], 11, ErrStorageQuota)
	check(ds.Accounts[2], 11, nil)
	if _, err := store.CreateAttachmentEnvelope(ctx, domain.AttachmentEnvelope{
		OwnerAccountID: ds.Accounts[1], StorageKey: "blob_over", CiphertextSHA256: fmt.Sprintf("%064x", 2), SizeBytes: 11,
	}); err != ErrStorageQuota {
		t.Fatalf("over-quota admission err=%v", err)
	}
	// Instance limit: other accounts fill the instance to its limit - 5.
	instanceLimit := store.Limits().InstanceStorageBytes
	exec := `INSERT INTO attachment_envelopes(id, owner_account_id, storage_key, ciphertext_sha256, size_bytes, crypto_metadata_json, created_at) VALUES(?, ?, ?, ?, ?, '{}', '2026-01-01T00:00:00Z')`
	if _, err := store.db.ExecContext(ctx, exec, "att_fill", ds.Accounts[0], "blob_fill", fmt.Sprintf("%064x", 3), instanceLimit-5-(accountLimit-10)); err != nil {
		t.Fatal(err)
	}
	check(ds.Accounts[2], 5, nil)
	check(ds.Accounts[2], 6, ErrStorageQuota)
}
