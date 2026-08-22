package messaging

import (
	"context"

	"private-messenger/server/internal/domain"
)

// Repository is the narrow persistence boundary required to accept a message.
// Implementations must commit the envelope and durable sync event atomically.
type Repository interface {
	SaveMessageEnvelopeWithSyncEventAndRecipients(context.Context, domain.MessageEnvelope) (domain.MessageEnvelope, bool, int64, []string, error)
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

// Create persists the envelope, sync event, and recipient authorization result
// in one transaction. Duplicate idempotent retries intentionally produce no
// recipients so callers cannot publish a second realtime or push notification.
func (s *Service) Create(ctx context.Context, envelope domain.MessageEnvelope) (CreateResult, error) {
	stored, duplicate, eventID, recipients, err := s.repository.SaveMessageEnvelopeWithSyncEventAndRecipients(ctx, envelope)
	if err != nil {
		return CreateResult{}, err
	}
	result := CreateResult{Envelope: stored, EventID: eventID, Duplicate: duplicate}
	if duplicate {
		return result, nil
	}
	result.Recipients = recipients
	return result, nil
}
