package franking

import "encoding/binary"

const (
	// Inbox kinds a sealed report is routed to.
	InboxInstanceOwner = "instance_owner"
	InboxCommunity     = "community"
	// InstanceInboxID is the inbox id of the instance owners' inbox.
	InstanceInboxID = "instance"

	// PublicKeySize is the X25519 report public key length.
	PublicKeySize = 32

	aadLabel = "veritra-c6-report-aad-v1"
)

// ReportRoute is what a sealed report's associated data binds (C6 condition
// G4): the inbox it goes to (kind, id and the recipient public key, so a key
// rotation also changes it), the conversation and message it is about, and
// the reporter. A sealed report cannot be replayed into another inbox or
// attributed to another reporter: the recipient's app rebuilds this from the
// server's report row, and a report that was sealed for different values
// does not open.
type ReportRoute struct {
	InboxKind         string
	InboxID           string
	RecipientKey      []byte
	ConversationID    string
	EnvelopeID        string
	ReporterAccountID string
}

// ReportAAD returns the HPKE aad for a report: the label, then each field
// length-prefixed (uint32 big endian), in the order of ReportRoute. The ids
// are bounded like the commitment's (1 to 128 bytes); the result is far below
// the Rust core's 1024-byte aad limit.
func ReportAAD(route ReportRoute) ([]byte, error) {
	if route.InboxKind != InboxInstanceOwner && route.InboxKind != InboxCommunity {
		return nil, ErrInvalidInput
	}
	if len(route.RecipientKey) != PublicKeySize {
		return nil, ErrInvalidInput
	}
	for _, id := range []string{route.InboxID, route.ConversationID, route.EnvelopeID, route.ReporterAccountID} {
		if len(id) == 0 || len(id) > MaxIDSize {
			return nil, ErrInvalidInput
		}
	}
	out := []byte(aadLabel)
	for _, f := range [][]byte{
		[]byte(route.InboxKind),
		[]byte(route.InboxID),
		route.RecipientKey,
		[]byte(route.ConversationID),
		[]byte(route.EnvelopeID),
		[]byte(route.ReporterAccountID),
	} {
		var n [4]byte
		binary.BigEndian.PutUint32(n[:], uint32(len(f)))
		out = append(out, n[:]...)
		out = append(out, f...)
	}
	return out, nil
}
