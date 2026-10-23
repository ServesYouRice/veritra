// Package admission bounds what one account can make the instance do (card
// I49, T49D). Stored limits (storage, devices, conversations, members) are
// enforced inside the storage write transactions; this package holds the
// aggregate rejection counters they share and the in-memory per-account
// write budget for fan-out and stored bytes.
//
// Nothing here is exported with an account identifier: counters are by
// limit name only, and the budget's keys never leave the process.
package admission

import (
	"math"
	"sync"
	"sync/atomic"
	"time"
)

// Limit names, used as the closed label set of
// veritra_admission_rejections_total.
const (
	Storage       = "storage"
	Blobs         = "blobs"
	Devices       = "devices"
	DeviceLinks   = "device_links"
	Conversations = "conversations"
	Members       = "conversation_members"
	Deliveries    = "deliveries"
	WriteBytes    = "write_bytes"
	Disk          = "disk"
)

// Names lists every limit in a fixed order.
var Names = [...]string{Storage, Blobs, Devices, DeviceLinks, Conversations, Members, Deliveries, WriteBytes, Disk}

// Counters counts refused requests by limit. The zero value is ready; a nil
// *Counters ignores Reject.
type Counters struct {
	counts [len(Names)]atomic.Int64
}

func (c *Counters) Reject(limit string) {
	if c == nil {
		return
	}
	for i, name := range Names {
		if name == limit {
			c.counts[i].Add(1)
			return
		}
	}
}

// Each calls fn for every limit in Names order.
func (c *Counters) Each(fn func(limit string, rejected int64)) {
	for i, name := range Names {
		var n int64
		if c != nil {
			n = c.counts[i].Load()
		}
		fn(name, n)
	}
}

// Budget is a pair of token buckets per account: deliveries per minute (one
// for the write plus one per recipient it is published to) and stored bytes
// per hour (request bodies of fan-out writes). A bucket holds one window's
// allowance and starts full, so a burst of a full window is allowed.
//
// A request reserves its worst case before it runs and settles with what it
// used, so parallel requests cannot all spend the same balance.
type Budget struct {
	deliveriesPerMinute float64
	bytesPerHour        float64
	counters            *Counters

	mu      sync.Mutex
	buckets map[string]*bucket
}

type bucket struct {
	deliveries float64
	bytes      float64
	updated    time.Time
}

// maxBudgetEntries bounds memory. Accounts are invite-only, so the map
// rarely approaches it; past it, buckets that have refilled completely (and
// so are equivalent to a new one) are dropped first.
const maxBudgetEntries = 65536

func NewBudget(deliveriesPerMinute int, bytesPerHour int64, counters *Counters) *Budget {
	return &Budget{
		deliveriesPerMinute: float64(deliveriesPerMinute),
		bytesPerHour:        float64(bytesPerHour),
		counters:            counters,
		buckets:             map[string]*bucket{},
	}
}

func (b *Budget) refill(bk *bucket, now time.Time) {
	if elapsed := now.Sub(bk.updated); elapsed > 0 {
		bk.deliveries = math.Min(b.deliveriesPerMinute, bk.deliveries+elapsed.Minutes()*b.deliveriesPerMinute)
		bk.bytes = math.Min(b.bytesPerHour, bk.bytes+elapsed.Hours()*b.bytesPerHour)
		bk.updated = now
	}
}

func (b *Budget) full(bk *bucket) bool {
	return bk.deliveries >= b.deliveriesPerMinute && bk.bytes >= b.bytesPerHour
}

// Ticket is one admitted reservation.
type Ticket struct {
	budget     *Budget
	accountID  string
	deliveries float64
	bytes      float64
	once       sync.Once
}

// Reserve admits a write that may fan out to deliveries (including the write
// itself) and store bytes, or returns nil and how long until it would fit.
func (b *Budget) Reserve(accountID string, deliveries int, bytes int64, now time.Time) (*Ticket, time.Duration) {
	need := float64(max(deliveries, 1))
	needBytes := float64(max(bytes, 0))
	b.mu.Lock()
	defer b.mu.Unlock()
	bk := b.buckets[accountID]
	if bk == nil {
		if len(b.buckets) >= maxBudgetEntries {
			b.evictLocked(now)
		}
		bk = &bucket{deliveries: b.deliveriesPerMinute, bytes: b.bytesPerHour, updated: now}
		b.buckets[accountID] = bk
	}
	b.refill(bk, now)
	var wait time.Duration
	limit := ""
	if bk.deliveries < need {
		wait = time.Duration((need - bk.deliveries) / b.deliveriesPerMinute * float64(time.Minute))
		limit = Deliveries
	}
	if bk.bytes < needBytes {
		if byteWait := time.Duration((needBytes - bk.bytes) / b.bytesPerHour * float64(time.Hour)); byteWait > wait {
			wait = byteWait
		}
		limit = WriteBytes
	}
	if limit != "" {
		b.counters.Reject(limit)
		return nil, max(wait, time.Second)
	}
	bk.deliveries -= need
	bk.bytes -= needBytes
	return &Ticket{budget: b, accountID: accountID, deliveries: need, bytes: needBytes}, 0
}

// Settle charges what the write used and refunds the rest of its
// reservation. Use beyond the reservation is charged too, so the balance can
// go below zero and delays the next request. Only the first call counts.
func (t *Ticket) Settle(deliveries int, bytes int64) {
	if t == nil {
		return
	}
	t.once.Do(func() {
		b := t.budget
		b.mu.Lock()
		defer b.mu.Unlock()
		bk := b.buckets[t.accountID]
		if bk == nil {
			return
		}
		bk.deliveries = math.Min(b.deliveriesPerMinute, bk.deliveries+t.deliveries-float64(max(deliveries, 0)))
		bk.bytes = math.Min(b.bytesPerHour, bk.bytes+t.bytes-float64(max(bytes, 0)))
	})
}

func (b *Budget) evictLocked(now time.Time) {
	var oldestKey string
	var oldest time.Time
	sampled := 0
	for key, bk := range b.buckets {
		b.refill(bk, now)
		if b.full(bk) {
			delete(b.buckets, key)
			return
		}
		if oldestKey == "" || bk.updated.Before(oldest) {
			oldestKey, oldest = key, bk.updated
		}
		if sampled++; sampled >= 64 {
			break
		}
	}
	delete(b.buckets, oldestKey)
}

// Len reports how many accounts hold a bucket (for tests).
func (b *Budget) Len() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.buckets)
}
