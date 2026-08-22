package messaging

import (
	"context"
	"testing"

	"private-messenger/server/internal/domain"
)

type commitRepository struct {
	recipients []string
}

func (r commitRepository) SaveMessageEnvelopeWithSyncEventAndRecipients(context.Context, domain.MessageEnvelope) (domain.MessageEnvelope, bool, int64, []string, error) {
	return domain.MessageEnvelope{ID: "msg-1", ConversationID: "conv-1"}, false, 17, r.recipients, nil
}

func TestCreateUsesRecipientsReturnedByCommit(t *testing.T) {
	service := New(commitRepository{recipients: []string{"account-a", "account-b"}})

	result, err := service.Create(context.Background(), domain.MessageEnvelope{ConversationID: "conv-1"})
	if err != nil {
		t.Fatal(err)
	}
	if result.EventID != 17 || result.Duplicate || len(result.Recipients) != 2 {
		t.Fatalf("unexpected result: %#v", result)
	}
}

func TestCreateDoesNotRepublishIdempotentDuplicate(t *testing.T) {
	service := New(duplicateRepository{})

	result, err := service.Create(context.Background(), domain.MessageEnvelope{ConversationID: "conv-1"})
	if err != nil {
		t.Fatal(err)
	}
	if !result.Duplicate || len(result.Recipients) != 0 {
		t.Fatalf("duplicate returned fanout recipients: %#v", result.Recipients)
	}
}

type duplicateRepository struct{}

func (duplicateRepository) SaveMessageEnvelopeWithSyncEventAndRecipients(context.Context, domain.MessageEnvelope) (domain.MessageEnvelope, bool, int64, []string, error) {
	return domain.MessageEnvelope{ID: "msg-1", ConversationID: "conv-1"}, true, 0, []string{"account-a"}, nil
}
