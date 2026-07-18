package messaging

import (
	"context"

	"private-messenger/server/internal/domain"
)

// Repository is the narrow persistence boundary required to accept a message.
// Implementations must commit the envelope and durable sync event atomically.
type Repository interface {
	SaveMessageEnvelopeWithSyncEvent(context.Context, domain.MessageEnvelope) (domain.MessageEnvelope, bool, int64, error)
	ListConversationMemberIDs(context.Context, string) ([]string, error)
}

type Service struct {
	repository Repository
}

type CreateResult struct {
	Envelope   domain.MessageEnvelope
	Recipients []string
	EventID    int64
	Duplicate  bool
}

func New(repository Repository) *Service {
	return &Service{repository: repository}
}

// Create persists the envelope/event transaction before resolving recipients.
// Duplicate idempotent retries intentionally produce no recipients so callers
// cannot publish a second realtime or push notification.
func (s *Service) Create(ctx context.Context, envelope domain.MessageEnvelope) (CreateResult, error) {
	stored, duplicate, eventID, err := s.repository.SaveMessageEnvelopeWithSyncEvent(ctx, envelope)
	if err != nil {
		return CreateResult{}, err
	}
	result := CreateResult{Envelope: stored, EventID: eventID, Duplicate: duplicate}
	if duplicate {
		return result, nil
	}
	recipients, err := s.repository.ListConversationMemberIDs(ctx, stored.ConversationID)
	if err != nil {
		// The durable event is committed. Returning the error avoids an HTTP
		// acknowledgement that would claim realtime fan-out was attempted;
		// clients still recover through sync catch-up.
		return CreateResult{}, err
	}
	result.Recipients = recipients
	return result, nil
}
