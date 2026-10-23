package httpapi

import (
	"context"
	"io"
	"math"
	"net/http"
	"strconv"
	"time"

	"private-messenger/server/internal/admission"
	"private-messenger/server/internal/domain"
)

// Write admission (card I49, T49D). Routes that store data and fan it out
// to other members pass through withWriteBudget. Before the handler runs it
// reserves, from the account's in-memory budget, the worst case: one
// delivery for the write plus one per member of a full conversation, and
// the largest body the route may read. When the handler returns it settles
// with what the request used: 1 + the recipients its committed events were
// published to, and the body bytes it read. Because the reservation comes
// first, parallel requests cannot all spend one balance.
//
// The stored limits (storage, devices, conversations, members) are enforced
// in the storage transactions; this layer only meters rates.

// maxFanoutWriteBody is the largest request body a metered route reads (an
// MLS handshake, 4 MiB of payload as base64 in JSON).
const maxFanoutWriteBody = 6 << 20

type writeUsageKey struct{}

type writeUsage struct{ recipients int }

// countRecipients records that a committed event reached n accounts.
func countRecipients(ctx context.Context, n int) {
	if usage, ok := ctx.Value(writeUsageKey{}).(*writeUsage); ok {
		usage.recipients += n
	}
}

type countingBody struct {
	io.ReadCloser
	n int64
}

func (b *countingBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	b.n += int64(n)
	return n, err
}

func (a *API) withWriteBudget(next authedHandler) authedHandler {
	return func(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
		if r.Method == http.MethodGet || r.Method == http.MethodHead {
			next(w, r, principal)
			return
		}
		if a.diskLow(w) {
			return
		}
		if a.Budget == nil {
			next(w, r, principal)
			return
		}
		reserveBytes := int64(maxFanoutWriteBody)
		if r.ContentLength >= 0 && r.ContentLength < reserveBytes {
			reserveBytes = r.ContentLength
		}
		ticket, wait := a.Budget.Reserve(principal.AccountID, 1+a.Store.Limits().ConversationMembers, reserveBytes, time.Now())
		if ticket == nil {
			w.Header().Set("Retry-After", strconv.Itoa(int(math.Min(math.Ceil(wait.Seconds()), 3600))))
			writeError(w, http.StatusTooManyRequests, "write_rate_limited")
			return
		}
		usage := &writeUsage{}
		body := &countingBody{ReadCloser: r.Body}
		r.Body = body
		r = r.WithContext(context.WithValue(r.Context(), writeUsageKey{}, usage))
		defer func() { ticket.Settle(1+usage.recipients, body.n) }()
		next(w, r, principal)
	}
}

// diskLow refuses a write with 507 while the file system holding the data
// is nearly full (below the threshold the app samples), so SQLite and the
// scheduled backups keep room. The disk alert fires earlier, at 10% free.
func (a *API) diskLow(w http.ResponseWriter) bool {
	if a.LowDisk == nil || !a.LowDisk() {
		return false
	}
	a.Admission.Reject(admission.Disk)
	writeError(w, http.StatusInsufficientStorage, "server_storage_low")
	return true
}
