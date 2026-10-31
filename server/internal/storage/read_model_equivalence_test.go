package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/domain"
)

// T49A/T49B: the rewritten sync-bounds, conversation-list and quota queries
// must return exactly what the original queries returned. The originals are
// kept here as the reference (with D48's reverse read-receipt block added).

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
			  AND NOT (se.event_type = 'read_receipt.updated' AND EXISTS (
			    SELECT 1 FROM account_blocks rb
			    WHERE rb.blocker_account_id = json_extract(se.payload_json, '$.account_id')
			      AND rb.blocked_account_id = m.account_id
			  ))
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

// legacyListSyncEventsQuery is the single-scan page query before the
// per-conversation merge (T49 follow-up), with the MLS join filter as it was
// then. Parameters: after, account, device, after, account, device, now, limit.
//
// It also states the rule of the TASK-207/208 fix, which the merge query
// shares: a message.envelope.* event is served only while its message
// envelope row exists and has not expired, so an expired or removed message
// is never replayed to a device with an old cursor. The reference applies it
// as a plain correlated EXISTS against the Go-side clock, where the merge
// query reads SQLite's clock, so the two are written independently.
const legacyListSyncEventsQuery = `
		SELECT id, event_type, account_id, conversation_id, payload_json, created_at
		FROM (
			SELECT id, event_type, account_id, conversation_id, payload_json, created_at
			FROM sync_events
			WHERE id > ? AND account_id = ? AND (device_id IS NULL OR device_id = ?)
			UNION ALL
			SELECT se.id, se.event_type, se.account_id, se.conversation_id, se.payload_json, se.created_at
			FROM sync_events se
			JOIN memberships m ON m.conversation_id = se.conversation_id
			WHERE se.id > ? AND se.account_id IS NULL AND m.account_id = ?
			  AND (NOT (se.event_type = 'mls.message.created' OR se.event_type LIKE 'message.envelope.%'
			            OR se.event_type LIKE 'call.%')
			       OR (
	NOT EXISTS (SELECT 1 FROM conversation_mls_groups jg WHERE jg.conversation_id = se.conversation_id)
	OR EXISTS (SELECT 1 FROM conversation_mls_devices jd
		WHERE jd.conversation_id = se.conversation_id AND jd.device_id = ?
		AND se.id > jd.joined_after_event_id
		AND (jd.removed_after_event_id IS NULL OR se.id <= jd.removed_after_event_id)
		AND (se.event_type NOT LIKE 'message.envelope.%'
			OR json_type(se.payload_json, '$.envelope.crypto_metadata.mls_epoch') IS NOT 'integer'
			OR json_extract(se.payload_json, '$.envelope.crypto_metadata.mls_epoch') >= jd.joined_epoch))
))
			  AND (se.event_type NOT LIKE 'message.envelope.%' OR EXISTS (
			    SELECT 1 FROM message_envelopes live
			    WHERE live.id = json_extract(se.payload_json, '$.message_id')
			      AND (live.expires_at IS NULL OR live.expires_at > ?)
			  ))
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
		) visible_events
		ORDER BY id ASC
		LIMIT ?`

// legacyListSyncEvents is ListSyncEvents as it was: the cursor check on the
// full bounds, then the single-scan query. oldest is the account's legacy
// oldest bound (legacySyncBounds). The bounds query scans the account's whole
// history, so callers compute it once while the data is unchanged instead of
// once per page, which made this check dominate the package under -race.
func legacyListSyncEvents(t testing.TB, store *Store, oldest int64, accountID, deviceID string, afterID int64, limit int) ([]domain.SyncEvent, error) {
	t.Helper()
	ctx := context.Background()
	if afterID > 0 && oldest > 0 && afterID < oldest-1 {
		return nil, ErrSyncCursorExpired
	}
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	rows, err := store.db.QueryContext(ctx, legacyListSyncEventsQuery, afterID, accountID, deviceID, afterID, accountID, deviceID, nowString(), limit)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var events []domain.SyncEvent
	for rows.Next() {
		event, err := scanSyncEvent(rows)
		if err != nil {
			t.Fatal(err)
		}
		events = append(events, event)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return events, nil
}

// checkSyncPage compares one page with the legacy query. oldest is the
// legacy oldest bound of accountID for the current data.
func checkSyncPage(t *testing.T, store *Store, oldest int64, accountID, deviceID string, afterID int64, limit int) []domain.SyncEvent {
	t.Helper()
	got, gotErr := store.ListSyncEvents(context.Background(), accountID, deviceID, afterID, limit)
	want, wantErr := legacyListSyncEvents(t, store, oldest, accountID, deviceID, afterID, limit)
	if !errors.Is(gotErr, wantErr) {
		t.Fatalf("sync page %s/%q after %d limit %d: err %v want %v", accountID, deviceID, afterID, limit, gotErr, wantErr)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("sync page %s/%q after %d limit %d differs:\n got %d events %v\nwant %d events %v",
			accountID, deviceID, afterID, limit, len(got), pageEventIDs(got), len(want), pageEventIDs(want))
	}
	return got
}

func pageEventIDs(events []domain.SyncEvent) []int64 {
	ids := make([]int64, len(events))
	for i, event := range events {
		ids[i] = event.ID
	}
	return ids
}

// checkSyncEventsMatch pages through the account's whole stream with the
// new and the legacy query and compares every page, then tries cursors that
// are not page ends: the middle of history, before the oldest event, past
// the newest, and the limit normalisation.
func checkSyncEventsMatch(t *testing.T, store *Store, accountID string, devices []string, paged, requireEvents bool, mid int64) {
	t.Helper()
	var maxID int64
	if err := store.db.QueryRowContext(context.Background(), `SELECT COALESCE(MAX(id), 0) FROM sync_events`).Scan(&maxID); err != nil {
		t.Fatal(err)
	}
	// Nothing below writes, so the legacy bound is the same for every page.
	oldest, _ := legacySyncBounds(t, store, accountID)
	for _, device := range devices {
		if paged {
			after, pages, seen := int64(0), 0, 0
			for {
				page := checkSyncPage(t, store, oldest, accountID, device, after, 7)
				if len(page) == 0 {
					break
				}
				pages++
				seen += len(page)
				after = page[len(page)-1].ID
			}
			if requireEvents && pages < 2 {
				t.Fatalf("%s/%q: %d events in %d pages; paging would be vacuous", accountID, device, seen, pages)
			}
			for _, limit := range []int{-1, 0, 1, 200, 201} {
				checkSyncPage(t, store, oldest, accountID, device, mid, limit)
			}
		}
		for _, after := range []int64{0, 1, mid / 2, mid, mid + 1, maxID - 3, maxID, maxID + 5} {
			checkSyncPage(t, store, oldest, accountID, device, after, 50)
		}
	}
}

const legacyBlobUsageQuery = `SELECT COALESCE(SUM(size_bytes), 0) FROM (
		SELECT owner_account_id AS account_id, size_bytes FROM attachment_envelopes
		UNION ALL SELECT account_id, size_bytes FROM backup_blobs
	)`

func legacySyncBounds(t testing.TB, store *Store, accountID string) (int64, int64) {
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
	// Accounts[2] blocked the hot account: its read receipts are hidden from
	// the hot account too (D48), though the hot account blocked nobody there.
	exec(`INSERT OR IGNORE INTO account_blocks(blocker_account_id, blocked_account_id, created_at) VALUES(?, ?, '2026-02-01T00:00:00Z')`, ds.Accounts[2], ds.HotAccount)
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

	// Sync pages: a second device of the hot account that joined the hot
	// group later and was removed again, encrypted events that name an
	// epoch before and after the hot device's join epoch, MLS and call
	// events, and Welcomes for each device. They interleave with the edge
	// conversation's events above.
	var last int64
	if err := store.db.QueryRowContext(ctx, `SELECT MAX(id) FROM sync_events`).Scan(&last); err != nil {
		t.Fatal(err)
	}
	exec(`INSERT INTO conversation_mls_devices(conversation_id, device_id, account_id, joined_after_event_id, joined_epoch, removed_after_event_id) VALUES(?, 'dev_hot_2', ?, 60, 3, ?)`,
		ds.HotConv, ds.HotAccount, last+4)
	hotEvent := func(eventType, payload string) {
		exec(`INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES(?, NULL, ?, ?, '2026-03-05T00:00:00Z')`, eventType, ds.HotConv, payload)
	}
	hotEvent("message.envelope.created", `{"message_id":"msg_epoch_1","envelope":{"crypto_metadata":{"mls_epoch":1}}}`)
	hotEvent("message.envelope.created", `{"message_id":"msg_epoch_4","envelope":{"crypto_metadata":{"mls_epoch":4}}}`)
	hotEvent("mls.message.created", `{"message_id":"mls_1"}`)
	exec(`INSERT INTO sync_events(event_type, account_id, conversation_id, device_id, payload_json, created_at) VALUES('mls.welcome', ?, ?, ?, '{}', '2026-03-05T00:00:00Z')`, ds.HotAccount, ds.HotConv, ds.HotDevice)
	exec(`INSERT INTO sync_events(event_type, account_id, conversation_id, device_id, payload_json, created_at) VALUES('mls.welcome', ?, ?, 'dev_hot_2', '{}', '2026-03-05T00:00:00Z')`, ds.HotAccount, ds.HotConv)
	hotEvent("call.created", fmt.Sprintf(`{"created_by":%q}`, ds.Accounts[2]))
	hotEvent("message.envelope.created", `{"message_id":"msg_epoch_x","envelope":{"crypto_metadata":{"mls_epoch":"3"}}}`)
	addEvent("conversation.updated", `{}`)
	hotEvent("conversation.updated", `{}`)
}

func checkReadModelsMatch(t *testing.T, store *Store, ds benchDataset) {
	t.Helper()
	ctx := context.Background()
	now := nowString()
	for i, account := range append(ds.Accounts[:len(ds.Accounts):len(ds.Accounts)], "acct_unknown") {
		// Paging and cursor checks on the hot account and three blockers;
		// whole-list checks on everyone (keeps the race run short).
		paged := i < 4
		devices := []string{"dev_unknown"}
		if i < len(ds.Devices) {
			devices[0] = ds.Devices[i]
		}
		if paged {
			devices = append(devices, "dev_hot_2", "")
		}
		checkSyncEventsMatch(t, store, account, devices, paged, i == 0, ds.MidEventID)
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
	checkReadModelsMatch(t, store, ds)
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
	checkReadModelsMatch(t, store, ds)
	if _, err := store.db.ExecContext(ctx, `DELETE FROM sync_events WHERE id <= ?`, ds.MidEventID/2); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `DELETE FROM read_receipts WHERE rowid % 2 = 0`); err != nil {
		t.Fatal(err)
	}
	checkReadModelsMatch(t, store, ds)

	// Account deletion removes memberships; bounds and lists follow.
	if err := store.DeleteAccount(ctx, ds.Accounts[2]); err != nil {
		t.Fatal(err)
	}
	checkReadModelsMatch(t, store, ds)
}

// The review scenario for the sync merge: a long run of events the device
// may not see in one group (it joined the MLS group after the history, was
// removed before it, or blocked the sender) interleaved with a visible
// conversation, reactions and account events, paged from 0. Pages match
// the legacy query for the affected device, the other member's device
// (never in the MLS group), no device and an unknown one.
func TestSyncHiddenRunMatchesLegacy(t *testing.T) {
	ctx := context.Background()
	for _, mode := range []hiddenRunMode{hiddenJoinedLate, hiddenRemoved, hiddenBlocked} {
		t.Run(string(mode), func(t *testing.T) {
			store := newBenchStore(t, ctx)
			ds := seedHiddenRun(t, ctx, store, 60, mode)
			checkSyncEventsMatch(t, store, ds.Account, []string{ds.Device, "", "dev_unknown"}, true, true, ds.LastEventID/2)
			checkSyncEventsMatch(t, store, "acct_hr_b", []string{"dev_hr_b"}, true, true, ds.LastEventID/2)
			// The hidden run is really hidden: the device sees none (or, once
			// removed, only the first) of the group's messages.
			var hidden int
			after := int64(0)
			for {
				page, err := store.ListSyncEvents(ctx, ds.Account, ds.Device, after, 100)
				if err != nil {
					t.Fatal(err)
				}
				if len(page) == 0 {
					break
				}
				for _, event := range page {
					if event.ConversationID == "conv_hr_hidden" && event.Type == "message.envelope.created" {
						hidden++
					}
				}
				after = page[len(page)-1].ID
			}
			if want := map[hiddenRunMode]int{hiddenRemoved: 1}[mode]; hidden != want {
				t.Fatalf("device saw %d hidden-run messages, want %d", hidden, want)
			}
			// After retention, cursors into the pruned range expire as
			// before, whether or not the event at the cursor counts.
			if _, err := store.db.ExecContext(ctx, `DELETE FROM sync_events WHERE id <= ?`, ds.LastEventID/4); err != nil {
				t.Fatal(err)
			}
			checkSyncEventsMatch(t, store, ds.Account, []string{ds.Device}, true, true, ds.LastEventID/2)
			oldest, _ := legacySyncBounds(t, store, ds.Account)
			for after := int64(1); after <= ds.LastEventID+1; after += 7 {
				checkSyncPage(t, store, oldest, ds.Account, ds.Device, after, 5)
			}
			if _, err := store.ListSyncEvents(ctx, ds.Account, ds.Device, 1, 5); !errors.Is(err, ErrSyncCursorExpired) {
				t.Fatalf("cursor in the pruned range: err=%v, want expired", err)
			}
		})
	}
}

// The page bound rests on SQLite running the merge as a co-routine that
// advances only as rows are read. Were it materialized, every page would
// read all of the account's history after the cursor.
func TestListSyncEventsQueryStreams(t *testing.T) {
	ctx := context.Background()
	store := newBenchStore(t, ctx)
	ds := seedHiddenRun(t, ctx, store, 5, hiddenJoinedLate)
	rows, err := store.db.QueryContext(ctx, "EXPLAIN QUERY PLAN "+listSyncEventsQuery, ds.Account, 0, ds.Device)
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
	joined := strings.Join(plan, "\n")
	if !strings.Contains(joined, "CO-ROUTINE candidates") || strings.Contains(joined, "MATERIALIZE candidates") {
		t.Fatalf("sync merge is not streamed:\n%s", joined)
	}
	for _, want := range []string{
		"SEARCH n USING INDEX idx_sync_events_conversation (conversation_id=? AND id>?)",
		"SEARCH n USING INDEX idx_sync_events_account (account_id=? AND id>?)",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("plan lacks %q:\n%s", want, joined)
		}
	}
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
