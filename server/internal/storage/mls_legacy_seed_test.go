package storage

import (
	"context"
	"testing"

	"private-messenger/server/internal/domain"
)

// seedLegacyMLSMessage stores the first MLS message of a legacy group (pre-I51:
// no roster) as a server from before the legacy-only rule did. The
// single-message route no longer writes a conversation's first MLS message
// (CreateMLSMessage refuses with ErrMLSBundleRequired), so a fixture that
// needs a legacy group seeds its first message here; every later message
// goes through the real route. The row, its sync event and the migration
// 0096 evidence triggers are exactly those the route used to write.
func seedLegacyMLSMessage(t *testing.T, store *Store, input CreateMLSMessageInput) domain.MLSMessage {
	t.Helper()
	ctx := context.Background()
	tx, err := store.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, rostered, err := mlsGroupEpoch(ctx, tx, input.ConversationID); err != nil || rostered {
		t.Fatalf("seed legacy message into rostered group %s: %v", input.ConversationID, err)
	}
	id, eventID, createdAt, err := insertLegacyMLSMessage(ctx, tx, input)
	if err != nil {
		t.Fatalf("seed legacy message: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	return domain.MLSMessage{
		ID: id, ConversationID: input.ConversationID, SenderAccountID: input.SenderAccountID,
		SenderDeviceID: input.SenderDeviceID, RecipientDeviceID: input.RecipientDeviceID,
		Kind: input.Kind, Payload: input.Payload, IdempotencyKey: input.IdempotencyKey,
		SyncEventID: eventID, CreatedAt: createdAt,
	}
}
