package storage

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"private-messenger/server/internal/domain"
)

func TestDeletingAMessageReleasesItsAttachments(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	attach := func(id, key string) {
		t.Helper()
		if _, err := store.CreateAttachmentEnvelope(ctx, domain.AttachmentEnvelope{
			ID: id, OwnerAccountID: owner.Account.ID, ConversationID: &conversation.ID,
			StorageKey: key, CiphertextSHA256: strings.Repeat("c", 64), SizeBytes: 100,
		}); err != nil {
			t.Fatalf("attachment %s: %v", id, err)
		}
	}
	attach("att_m1_a", "blob_m1_a")
	attach("att_m1_b", "blob_m1_b")
	attach("att_m2", "blob_m2")
	send := func(key string, refs ...string) domain.MessageEnvelope {
		t.Helper()
		raw, _ := json.Marshal(refs)
		message, _, err := store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
			ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
			IdempotencyKey: key, Ciphertext: []byte("c-" + key), CryptoProtocol: "mls-openmls-todo", AttachmentRefs: raw,
		})
		if err != nil {
			t.Fatalf("send %s: %v", key, err)
		}
		return message
	}
	m1 := send("m1", "att_m1_a", "att_m1_b")
	m2 := send("m2", "att_m2")
	if usage := testRowCount(t, ctx, store, `SELECT size_bytes FROM blob_usage_accounts WHERE account_id = ?`, owner.Account.ID); usage != 300 {
		t.Fatalf("setup: blob usage = %d, want 300", usage)
	}

	deleted, eventID, err := store.DeleteMessageEnvelopeWithSyncEvent(ctx, m1.ID, owner.Account.ID, []byte("marker"), "mls-openmls-todo", nil)
	if err != nil {
		t.Fatal(err)
	}
	if string(deleted.AttachmentRefs) != "[]" {
		t.Fatalf("tombstone attachment refs = %s, want []", deleted.AttachmentRefs)
	}
	var refs, payload string
	if err := store.db.QueryRowContext(ctx, `SELECT attachment_refs_json FROM message_envelopes WHERE id = ?`, m1.ID).Scan(&refs); err != nil || refs != "[]" {
		t.Fatalf("stored refs = %q, err = %v, want []", refs, err)
	}
	if err := store.db.QueryRowContext(ctx, `SELECT payload_json FROM sync_events WHERE id = ?`, eventID).Scan(&payload); err != nil {
		t.Fatal(err)
	}
	var event struct {
		Envelope struct {
			AttachmentRefs json.RawMessage `json:"attachment_refs"`
		} `json:"envelope"`
	}
	if err := json.Unmarshal([]byte(payload), &event); err != nil || string(event.Envelope.AttachmentRefs) != "[]" {
		t.Fatalf("delete event refs = %s, err = %v, want []", event.Envelope.AttachmentRefs, err)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM message_attachments WHERE message_id = ?`, m1.ID); n != 0 {
		t.Fatalf("%d attachment links remain on the deleted message", n)
	}
	for _, id := range []string{"att_m1_a", "att_m1_b"} {
		if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM attachment_envelopes WHERE id = ?`, id); n != 0 {
			t.Fatalf("attachment %s of the deleted message was kept", id)
		}
	}
	for _, key := range []string{"blob_m1_a", "blob_m1_b"} {
		if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM blob_deletion_queue WHERE storage_key = ?`, key); n != 1 {
			t.Fatalf("blob %s was not queued for deletion", key)
		}
	}
	// Another message's attachment stays, with its blob.
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM attachment_envelopes WHERE id = 'att_m2'`); n != 1 {
		t.Fatal("an attachment of another message was deleted")
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM message_attachments WHERE message_id = ? AND attachment_id = 'att_m2'`, m2.ID); n != 1 {
		t.Fatal("the other message lost its attachment link")
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM blob_deletion_queue WHERE storage_key = 'blob_m2'`); n != 0 {
		t.Fatal("a blob that is still referenced was queued for deletion")
	}
	if usage := testRowCount(t, ctx, store, `SELECT size_bytes FROM blob_usage_accounts WHERE account_id = ?`, owner.Account.ID); usage != 100 {
		t.Fatalf("blob usage = %d, want 100 after releasing two attachments", usage)
	}

	// Deleting the second message releases its attachment too.
	if _, _, err := store.DeleteMessageEnvelopeWithSyncEvent(ctx, m2.ID, owner.Account.ID, []byte("marker"), "mls-openmls-todo", nil); err != nil {
		t.Fatal(err)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM attachment_envelopes`); n != 0 {
		t.Fatalf("%d attachments remain after both messages were deleted", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM blob_deletion_queue`); n != 3 {
		t.Fatalf("%d blobs queued, want all three", n)
	}
}
