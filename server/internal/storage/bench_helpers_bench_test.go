package storage

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"path/filepath"
	"testing"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/migrations"
)

// Benchmark datasets are synthetic: random ciphertext bytes only, no
// plaintext, generated with a fixed seed so runs are comparable.

type benchProfile struct {
	Name             string
	Accounts         int
	Conversations    int
	HotMemberships   int // conversations the measured account belongs to
	MembersPerConv   int // other members per conversation
	MessagesPerConv  int
	AccountEvents    int // account-scoped sync events for the hot account
	CiphertextBytes  int
	AttachmentRows   int
	AttachmentBytes  int64
	BackupRows       int
	BlockedByHot     int
	ReadReceiptRatio int // every Nth hot conversation has a read receipt at its midpoint
}

func (p benchProfile) String() string {
	return fmt.Sprintf("%s(accounts=%d conv=%d hot_conv=%d msgs=%d events~%d attach=%d)",
		p.Name, p.Accounts, p.Conversations, p.HotMemberships,
		p.Conversations*p.MessagesPerConv, p.Conversations*p.MessagesPerConv+p.AccountEvents, p.AttachmentRows)
}

var (
	benchSmall = benchProfile{Name: "small", Accounts: 50, Conversations: 100, HotMemberships: 50, MembersPerConv: 4,
		MessagesPerConv: 100, AccountEvents: 200, CiphertextBytes: 256, AttachmentRows: 1_000, AttachmentBytes: 64 << 10,
		BackupRows: 50, BlockedByHot: 1, ReadReceiptRatio: 2}
	benchLarge = benchProfile{Name: "large", Accounts: 500, Conversations: 1_000, HotMemberships: 200, MembersPerConv: 4,
		MessagesPerConv: 100, AccountEvents: 2_000, CiphertextBytes: 256, AttachmentRows: 10_000, AttachmentBytes: 64 << 10,
		BackupRows: 500, BlockedByHot: 5, ReadReceiptRatio: 2}
)

type benchDataset struct {
	Profile    benchProfile
	HotAccount string
	HotDevice  string
	HotConv    string
	DeepMsgID  string // a message in the middle of HotConv's history
	Accounts   []string
	Devices    []string
	MidEventID int64
}

func newBenchStore(tb testing.TB, ctx context.Context) *Store {
	tb.Helper()
	dir := tb.TempDir()
	cfg := config.Config{
		Addr:         ":0",
		DataDir:      dir,
		DatabasePath: filepath.Join(dir, "private-messenger.db"),
		StoragePath:  filepath.Join(dir, "blobs"),
		InstanceName: "Bench Messenger",
	}
	store, err := Open(ctx, cfg)
	if err != nil {
		tb.Fatalf("open store: %v", err)
	}
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		tb.Fatalf("migrate: %v", err)
	}
	tb.Cleanup(func() { _ = store.Close() })
	return store
}

func benchID(prefix string, n int) string {
	return fmt.Sprintf("%s_%032x", prefix, n)
}

// seedBenchDataset bulk-inserts the profile in one write transaction. It
// bypasses the public write paths on purpose: those are measured separately.
func seedBenchDataset(tb testing.TB, ctx context.Context, store *Store, p benchProfile) benchDataset {
	tb.Helper()
	rng := rand.New(rand.NewPCG(49, uint64(p.Conversations)))
	tx, err := store.db.BeginTx(ctx, nil)
	if err != nil {
		tb.Fatalf("begin seed: %v", err)
	}
	defer tx.Rollback()
	must := func(err error) {
		if err != nil {
			tb.Fatalf("seed: %v", err)
		}
	}
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	tick := 0
	nextTime := func() string {
		tick++
		return formatTime(base.Add(time.Duration(tick) * time.Millisecond))
	}

	ds := benchDataset{Profile: p}
	for i := 0; i < p.Accounts; i++ {
		accountID := benchID("acct", i)
		deviceID := benchID("dev", i)
		role := "member"
		if i == 0 {
			role = "owner"
		}
		_, err := tx.ExecContext(ctx, `INSERT INTO accounts(id, username, password_hash, role, created_at) VALUES(?, ?, 'x', ?, ?)`,
			accountID, fmt.Sprintf("user%05d", i), role, nextTime())
		must(err)
		_, err = tx.ExecContext(ctx, `INSERT INTO devices(id, account_id, name, key_package, created_at) VALUES(?, ?, 'phone', ?, ?)`,
			deviceID, accountID, []byte("synthetic-key-package"), nextTime())
		must(err)
		ds.Accounts = append(ds.Accounts, accountID)
		ds.Devices = append(ds.Devices, deviceID)
	}
	ds.HotAccount, ds.HotDevice = ds.Accounts[0], ds.Devices[0]
	for i := 1; i <= p.BlockedByHot && i < p.Accounts; i++ {
		_, err := tx.ExecContext(ctx, `INSERT INTO account_blocks(blocker_account_id, blocked_account_id, created_at) VALUES(?, ?, ?)`,
			ds.HotAccount, ds.Accounts[p.Accounts-i], nextTime())
		must(err)
	}

	ciphertext := make([]byte, p.CiphertextBytes)
	membership := 0
	msgSeq := 0
	insMsg, err := tx.PrepareContext(ctx, `INSERT INTO message_envelopes(id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, created_at) VALUES(?, ?, ?, ?, ?, ?, 'mls', '{}', '[]', ?)`)
	must(err)
	defer insMsg.Close()
	insEvent, err := tx.PrepareContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES(?, ?, ?, ?, ?)`)
	must(err)
	defer insEvent.Close()

	for c := 0; c < p.Conversations; c++ {
		convID := benchID("conv", c)
		kind := "group"
		others := p.MembersPerConv
		if c%4 == 0 {
			kind, others = "dm", 1
		}
		_, err := tx.ExecContext(ctx, `INSERT INTO conversations(id, kind, created_by, created_at) VALUES(?, ?, ?, ?)`, convID, kind, ds.HotAccount, nextTime())
		must(err)
		members := make([]int, 0, others+1)
		if c < p.HotMemberships {
			members = append(members, 0)
		}
		for len(members) < others+1 {
			candidate := 1 + rng.IntN(p.Accounts-1)
			dup := false
			for _, m := range members {
				dup = dup || m == candidate
			}
			if !dup {
				members = append(members, candidate)
			}
		}
		for _, m := range members {
			membership++
			_, err := tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, 'member', ?)`,
				benchID("mem", membership), ds.Accounts[m], convID, nextTime())
			must(err)
		}
		var midMsg string
		for j := 0; j < p.MessagesPerConv; j++ {
			msgSeq++
			sender := members[rng.IntN(len(members))]
			msgID := benchID("msg", msgSeq)
			for k := range ciphertext {
				ciphertext[k] = byte(rng.Uint32())
			}
			at := nextTime()
			_, err := insMsg.ExecContext(ctx, msgID, convID, ds.Accounts[sender], ds.Devices[sender], fmt.Sprintf("k%d", msgSeq), ciphertext, at)
			must(err)
			payload, _ := json.Marshal(map[string]interface{}{
				"message_id": msgID, "conversation_id": convID,
				"envelope": map[string]interface{}{"id": msgID, "ciphertext": base64.StdEncoding.EncodeToString(ciphertext), "crypto_protocol": "mls"},
			})
			result, err := insEvent.ExecContext(ctx, "message.envelope.created", nil, convID, string(payload), at)
			must(err)
			if j == p.MessagesPerConv/2 {
				midMsg = msgID
				if c == 0 {
					ds.DeepMsgID = msgID
				}
				if c == p.Conversations/2 {
					ds.MidEventID, _ = result.LastInsertId()
				}
			}
		}
		if c == 0 {
			ds.HotConv = convID
		}
		if c < p.HotMemberships && p.ReadReceiptRatio > 0 && c%p.ReadReceiptRatio == 0 && midMsg != "" {
			_, err := tx.ExecContext(ctx, `INSERT INTO read_receipts(account_id, conversation_id, message_id, read_at) VALUES(?, ?, ?, ?)`, ds.HotAccount, convID, midMsg, nextTime())
			must(err)
		}
	}
	for i := 0; i < p.AccountEvents; i++ {
		_, err := insEvent.ExecContext(ctx, "device.updated", ds.HotAccount, "", `{"device_id":"x"}`, nextTime())
		must(err)
	}
	for i := 0; i < p.AttachmentRows; i++ {
		owner := ds.Accounts[i%p.Accounts]
		_, err := tx.ExecContext(ctx, `INSERT INTO attachment_envelopes(id, owner_account_id, storage_key, ciphertext_sha256, size_bytes, crypto_metadata_json, created_at) VALUES(?, ?, ?, ?, ?, '{}', ?)`,
			benchID("att", i), owner, benchID("blob", i), fmt.Sprintf("%064x", i), p.AttachmentBytes, nextTime())
		must(err)
	}
	for i := 0; i < p.BackupRows; i++ {
		owner := ds.Accounts[i%p.Accounts]
		_, err := tx.ExecContext(ctx, `INSERT INTO backup_blobs(id, account_id, storage_key, size_bytes, key_derivation_metadata_json, created_at) VALUES(?, ?, ?, ?, '{}', ?)`,
			benchID("bak", i), owner, benchID("blob", 1_000_000+i), int64(1<<20), nextTime())
		must(err)
	}
	// No ANALYZE: production never runs it, so plans stay production-like.
	must(tx.Commit())
	return ds
}
