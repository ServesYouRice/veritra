package storage

import (
	"context"
	"strings"
	"testing"

	"private-messenger/server/internal/domain"
)

func TestMessageReferenceColumnsAreIndexed(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	for index, column := range map[string]string{
		"idx_message_envelopes_reply_to":    "reply_to_id",
		"idx_message_envelopes_thread_root": "thread_root_id",
	} {
		if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ? AND tbl_name = 'message_envelopes'`, index); n != 1 {
			t.Fatalf("index %s is missing", index)
		}
		// The lookup the foreign-key action makes for the children of a
		// deleted envelope.
		rows, err := store.db.QueryContext(ctx, `EXPLAIN QUERY PLAN SELECT rowid FROM message_envelopes WHERE `+column+` = ?`, "msg_parent")
		if err != nil {
			t.Fatal(err)
		}
		var plan []string
		for rows.Next() {
			var id, parent, notUsed int
			var detail string
			if err := rows.Scan(&id, &parent, &notUsed, &detail); err != nil {
				t.Fatal(err)
			}
			plan = append(plan, detail)
		}
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}
		rows.Close()
		if !strings.Contains(strings.Join(plan, "; "), index) {
			t.Fatalf("lookup by %s does not use %s: %v", column, index, plan)
		}
	}
}

func TestDeletingAParentMessageStillClearsReplyAndThreadReferences(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	send := func(key string, replyTo, threadRoot *string) domain.MessageEnvelope {
		t.Helper()
		message, _, err := store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
			ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
			IdempotencyKey: key, Ciphertext: []byte("c-" + key), CryptoProtocol: "mls-openmls-todo",
			ReplyToID: replyTo, ThreadRootID: threadRoot,
		})
		if err != nil {
			t.Fatal(err)
		}
		return message
	}
	parent := send("parent", nil, nil)
	reply := send("reply", &parent.ID, nil)
	inThread := send("thread", nil, &parent.ID)
	if _, err := store.db.ExecContext(ctx, `DELETE FROM message_envelopes WHERE id = ?`, parent.ID); err != nil {
		t.Fatal(err)
	}
	for _, check := range []struct{ id, column string }{{reply.ID, "reply_to_id"}, {inThread.ID, "thread_root_id"}} {
		if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM message_envelopes WHERE id = ? AND `+check.column+` IS NULL`, check.id); n != 1 {
			t.Fatalf("%s of %s was not cleared when the parent was deleted", check.column, check.id)
		}
	}
}
