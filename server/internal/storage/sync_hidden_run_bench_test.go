package storage

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"testing"
	"time"
)

// Review follow-up to the T49 sync merge: a long run of events the device
// may not see in one conversation, interleaved with a conversation it may
// see, paged from cursor 0. Each page of the per-conversation merge used to
// search the hidden conversation forward from the cursor to its next visible
// event, so every page rescanned the run.
//
// Run: go test -run '^$' -bench SyncHiddenRun -benchtime 3x ./internal/storage

type hiddenRunMode string

const (
	// hiddenJoinedLate: the device joined the group's MLS group after all
	// of its history (a newly linked device paging from 0).
	hiddenJoinedLate hiddenRunMode = "joined_late"
	// hiddenRemoved: the device was removed from the MLS group before the
	// history.
	hiddenRemoved hiddenRunMode = "removed"
	// hiddenBlocked: every message in the group comes from an account the
	// reader blocked.
	hiddenBlocked hiddenRunMode = "blocked"
)

// hiddenRunDataset is account acct_hr_a with device dev_hr_a in conv_hr_hidden
// (the run, written by acct_hr_b) and conv_hr_open (visible, written by
// acct_hr_a), both shared with acct_hr_b. Messages alternate between the two
// conversations, n each; every tenth step also adds a reaction by acct_hr_b
// to the open conversation (hidden when blocked) and an account event. The
// hidden conversation holds nothing the device may see, except its first
// message in hiddenRemoved.
type hiddenRunDataset struct {
	Account, Device string
	LastEventID     int64
}

func seedHiddenRun(tb testing.TB, ctx context.Context, store *Store, n int, mode hiddenRunMode) hiddenRunDataset {
	tb.Helper()
	tx, err := store.db.BeginTx(ctx, nil)
	if err != nil {
		tb.Fatal(err)
	}
	defer tx.Rollback()
	exec := func(query string, args ...interface{}) int64 {
		tb.Helper()
		result, err := tx.ExecContext(ctx, query, args...)
		if err != nil {
			tb.Fatalf("%s: %v", query, err)
		}
		id, _ := result.LastInsertId()
		return id
	}
	const at = "2026-01-01T00:00:00Z"
	for _, who := range []string{"a", "b"} {
		exec(`INSERT INTO accounts(id, username, password_hash, role, created_at) VALUES(?, ?, 'x', 'member', ?)`, "acct_hr_"+who, "hr_"+who, at)
		exec(`INSERT INTO devices(id, account_id, name, key_package, created_at) VALUES(?, ?, 'phone', x'00', ?)`, "dev_hr_"+who, "acct_hr_"+who, at)
	}
	convs := []string{"conv_hr_hidden", "conv_hr_open"}
	for _, conv := range convs {
		exec(`INSERT INTO conversations(id, kind, created_by, created_at) VALUES(?, 'group', 'acct_hr_a', ?)`, conv, at)
		for _, who := range []string{"a", "b"} {
			exec(`INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, 'member', ?)`,
				"mem_"+conv+"_"+who, "acct_hr_"+who, conv, at)
		}
	}
	if mode == hiddenBlocked {
		exec(`INSERT INTO account_blocks(blocker_account_id, blocked_account_id, created_at) VALUES('acct_hr_a', 'acct_hr_b', ?)`, at)
	} else {
		exec(`INSERT INTO conversation_mls_groups(conversation_id, epoch, updated_at) VALUES('conv_hr_hidden', 5, ?)`, at)
	}
	insMsg, err := tx.PrepareContext(ctx, `INSERT INTO message_envelopes(id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, created_at) VALUES(?, ?, ?, ?, ?, x'00', 'mls', '{}', '[]', ?)`)
	if err != nil {
		tb.Fatal(err)
	}
	defer insMsg.Close()
	insEvent, err := tx.PrepareContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES(?, ?, ?, ?, ?)`)
	if err != nil {
		tb.Fatal(err)
	}
	defer insEvent.Close()
	event := func(eventType string, accountID interface{}, conv interface{}, payload string) int64 {
		tb.Helper()
		result, err := insEvent.ExecContext(ctx, eventType, accountID, conv, payload, at)
		if err != nil {
			tb.Fatal(err)
		}
		id, _ := result.LastInsertId()
		return id
	}
	ciphertext := base64.StdEncoding.EncodeToString(make([]byte, 256))
	var firstHidden int64
	for i := 0; i < n; i++ {
		for _, conv := range convs {
			msgID := fmt.Sprintf("msg_hr_%s_%d", conv, i)
			sender := map[string]string{"conv_hr_hidden": "hr_b", "conv_hr_open": "hr_a"}[conv]
			if _, err := insMsg.ExecContext(ctx, msgID, conv, "acct_"+sender, "dev_"+sender, msgID, at); err != nil {
				tb.Fatal(err)
			}
			payload, _ := json.Marshal(map[string]interface{}{
				"message_id": msgID, "conversation_id": conv,
				"envelope": map[string]interface{}{"id": msgID, "ciphertext": ciphertext,
					"crypto_metadata": map[string]interface{}{"mls_epoch": 5}},
			})
			id := event("message.envelope.created", nil, conv, string(payload))
			if firstHidden == 0 {
				firstHidden = id
			}
		}
		if i%10 == 9 {
			event("reaction.created", nil, "conv_hr_open", `{"account_id":"acct_hr_b"}`)
			event("device.updated", "acct_hr_a", nil, `{}`)
		}
	}
	var last int64
	if err := tx.QueryRowContext(ctx, `SELECT MAX(id) FROM sync_events`).Scan(&last); err != nil {
		tb.Fatal(err)
	}
	switch mode {
	case hiddenJoinedLate:
		exec(`INSERT INTO conversation_mls_devices(conversation_id, device_id, account_id, joined_after_event_id, joined_epoch) VALUES('conv_hr_hidden', 'dev_hr_a', 'acct_hr_a', ?, 5)`, last)
	case hiddenRemoved:
		exec(`INSERT INTO conversation_mls_devices(conversation_id, device_id, account_id, joined_after_event_id, joined_epoch, removed_after_event_id) VALUES('conv_hr_hidden', 'dev_hr_a', 'acct_hr_a', 0, 5, ?)`, firstHidden)
	}
	if err := tx.Commit(); err != nil {
		tb.Fatal(err)
	}
	return hiddenRunDataset{Account: "acct_hr_a", Device: "dev_hr_a", LastEventID: last}
}

// pageAllSyncEvents pages the account's stream from cursor 0 and returns
// the number of pages, events and the slowest page.
func pageAllSyncEvents(tb testing.TB, list func(after int64) ([]int64, error)) (pages, events int, worst time.Duration) {
	tb.Helper()
	after := int64(0)
	for {
		start := time.Now()
		ids, err := list(after)
		if d := time.Since(start); d > worst {
			worst = d
		}
		if err != nil {
			tb.Fatal(err)
		}
		if len(ids) == 0 {
			return pages, events, worst
		}
		pages++
		events += len(ids)
		after = ids[len(ids)-1]
	}
}

// singleScanSyncPage is a page as ListSyncEvents read it before the
// per-conversation merge: SyncBounds for the cursor check (already the
// T49A query), then the legacy single-scan query.
func singleScanSyncPage(tb testing.TB, store *Store, accountID, deviceID string, afterID int64, limit int) []int64 {
	tb.Helper()
	ctx := context.Background()
	if _, _, _, err := store.SyncBounds(ctx, accountID); err != nil {
		tb.Fatal(err)
	}
	rows, err := store.db.QueryContext(ctx, legacyListSyncEventsQuery, afterID, accountID, deviceID, afterID, accountID, deviceID, limit)
	if err != nil {
		tb.Fatal(err)
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		event, err := scanSyncEvent(rows)
		if err != nil {
			tb.Fatal(err)
		}
		ids = append(ids, event.ID)
	}
	if err := rows.Err(); err != nil {
		tb.Fatal(err)
	}
	return ids
}

func BenchmarkSyncHiddenRun(b *testing.B) {
	ctx := context.Background()
	for _, n := range []int{10_000, 40_000} {
		for _, mode := range []hiddenRunMode{hiddenJoinedLate, hiddenRemoved, hiddenBlocked} {
			store := newBenchStore(b, ctx)
			ds := seedHiddenRun(b, ctx, store, n, mode)
			paths := map[string]func(after int64) ([]int64, error){
				"ListSyncEvents": func(after int64) ([]int64, error) {
					events, err := store.ListSyncEvents(ctx, ds.Account, ds.Device, after, 100)
					return pageEventIDs(events), err
				},
				"SingleScan": func(after int64) ([]int64, error) {
					return singleScanSyncPage(b, store, ds.Account, ds.Device, after, 100), nil
				},
			}
			for _, path := range []string{"ListSyncEvents", "SingleScan"} {
				b.Run(fmt.Sprintf("%dx2/%s/%s/PageAllFrom0_100", n, mode, path), func(b *testing.B) {
					var pages, events int
					var worst time.Duration
					for b.Loop() {
						p, e, w := pageAllSyncEvents(b, paths[path])
						pages, events = p, e
						if w > worst {
							worst = w
						}
					}
					b.ReportMetric(float64(pages), "pages")
					b.ReportMetric(float64(events), "events")
					b.ReportMetric(float64(worst.Microseconds())/1000, "worst-page-ms")
				})
			}
			// The HTTP handler adds these bounds to every page; a blocked
			// run at a conversation's edges is walked each time.
			b.Run(fmt.Sprintf("%dx2/%s/SyncBounds", n, mode), func(b *testing.B) {
				for b.Loop() {
					if _, _, _, err := store.SyncBounds(ctx, ds.Account); err != nil {
						b.Fatal(err)
					}
				}
			})
		}
	}
}
