package franking

import "encoding/binary"

const (
	// Inbox kinds a sealed report is routed to.
	InboxInstanceOwner = "instance_owner"
	InboxCommunity     = "community"
	// PublicKeySize is the X25519 report public key length.
	PublicKeySize = 32

	aadLabel = "veritra-c6-report-aad-v2"
)

// ReportRoute is what a sealed report's associated data binds (C6 condition
// G4, D95): the inbox it goes to (kind, id and the recipient public key, so a
// key rotation also changes it), the conversation it is about, the reporter,
// and the report's own id. The message's envelope id is not here: D95 seals it
// inside the report so the server never sees it. A report id is chosen by the
// reporter's app and is the same in every copy of one report, so the copies
// of one report belong together and a copy cannot be replayed as another
// report. A sealed report cannot be moved into another inbox or attributed to
// another reporter: the recipient's app rebuilds this from the server's
// report row, and a report that was sealed for different values does not
// open. For the instance owners' inbox, InboxID is the owner's account id (one
// sealed copy per owner, D95); for a community it is one moderator's own
// inbox in that community, CommunityModeratorInboxID (one sealed copy per
// moderator, the same rule).
type ReportRoute struct {
	InboxKind         string
	InboxID           string
	RecipientKey      []byte
	ConversationID    string
	ReportID          string
	ReporterAccountID string
}

// CommunityModeratorInboxID names one moderator's inbox in a community:
// "<community id>:<account id>". Ids are "<prefix>_<hex>", so the separator
// never occurs inside one; both are well under 64 bytes, so the result fits
// MaxIDSize and the schema's 128-character inbox id.
func CommunityModeratorInboxID(communityID, accountID string) string {
	return communityID + ":" + accountID
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
	for _, id := range []string{route.InboxID, route.ConversationID, route.ReportID, route.ReporterAccountID} {
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
		[]byte(route.ReportID),
		[]byte(route.ReporterAccountID),
	} {
		var n [4]byte
		binary.BigEndian.PutUint32(n[:], uint32(len(f)))
		out = append(out, n[:]...)
		out = append(out, f...)
	}
	return out, nil
}
