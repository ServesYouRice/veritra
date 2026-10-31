package admission

import (
	"sync"
	"testing"
	"time"
)

func TestBudgetReservesSettlesAndRefills(t *testing.T) {
	counters := &Counters{}
	budget := NewBudget(100, 1<<20, counters)
	now := time.Unix(1_000_000, 0)
	// A message to a full 49-member conversation reserves 50 and, sent as a
	// DM, settles at 2.
	ticket, _ := budget.Reserve("acct_a", 50, 1000, now)
	if ticket == nil {
		t.Fatal("first reservation refused")
	}
	ticket.Settle(2, 1000)
	ticket.Settle(50, 1000) // second settle is ignored
	for i := 0; i < 49; i++ {
		ticket, _ := budget.Reserve("acct_a", 2, 0, now)
		if ticket == nil {
			t.Fatalf("reservation %d refused with %d of 100 used", i, 2+2*i)
		}
		ticket.Settle(2, 0)
	}
	if ticket, wait := budget.Reserve("acct_a", 2, 0, now); ticket != nil || wait < time.Second {
		t.Fatalf("101st delivery admitted (wait %s)", wait)
	}
	// Another account has its own budget.
	if ticket, _ := budget.Reserve("acct_b", 2, 0, now); ticket == nil {
		t.Fatal("a second account shared the first one's budget")
	}
	// Half a minute refills half the bucket.
	if ticket, _ := budget.Reserve("acct_a", 50, 0, now.Add(30*time.Second)); ticket == nil {
		t.Fatal("refill after 30 s did not admit 50")
	}
	var rejected int64
	counters.Each(func(limit string, n int64) {
		if limit == Deliveries {
			rejected = n
		}
	})
	if rejected != 1 {
		t.Fatalf("deliveries rejections = %d, want 1", rejected)
	}
}

func TestBudgetBytesAndRetryAfter(t *testing.T) {
	counters := &Counters{}
	budget := NewBudget(1000, 4<<20, counters)
	now := time.Unix(1_000_000, 0)
	ticket, _ := budget.Reserve("acct_a", 1, 3<<20, now)
	if ticket == nil {
		t.Fatal("3 MiB refused from a 4 MiB hour")
	}
	ticket.Settle(1, 3<<20)
	ticket, wait := budget.Reserve("acct_a", 1, 2<<20, now)
	if ticket != nil {
		t.Fatal("5 MiB in one hour admitted")
	}
	// 1 MiB short at 4 MiB/hour is 15 minutes.
	if wait < 14*time.Minute || wait > 16*time.Minute {
		t.Fatalf("retry after %s, want about 15 min", wait)
	}
	var rejected int64
	counters.Each(func(limit string, n int64) {
		if limit == WriteBytes {
			rejected = n
		}
	})
	if rejected != 1 {
		t.Fatalf("write_bytes rejections = %d", rejected)
	}
}

// Parallel requests each reserve before running, so they cannot all spend
// the same balance: at most the bucket's capacity is admitted.
func TestBudgetParallelReservationsCannotOvershoot(t *testing.T) {
	budget := NewBudget(1000, 1<<30, nil)
	now := time.Unix(1_000_000, 0)
	var wg sync.WaitGroup
	var mu sync.Mutex
	admitted := 0
	for i := 0; i < 200; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if ticket, _ := budget.Reserve("acct_a", 101, 0, now); ticket != nil {
				mu.Lock()
				admitted++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if admitted != 9 {
		t.Fatalf("admitted %d reservations of 101 from 1000, want 9", admitted)
	}
}

func TestBudgetOveruseIsChargedAndEntriesAreBounded(t *testing.T) {
	budget := NewBudget(100, 1<<20, nil)
	now := time.Unix(1_000_000, 0)
	ticket, _ := budget.Reserve("acct_a", 10, 0, now)
	ticket.Settle(150, 0) // used more than reserved: balance goes negative
	if ticket, _ := budget.Reserve("acct_a", 1, 0, now.Add(20*time.Second)); ticket != nil {
		t.Fatal("overuse was not charged")
	}
	for i := 0; i < maxBudgetEntries+10; i++ {
		budget.Reserve(string(rune('a'+i%26))+time.Duration(i).String(), 1, 0, now.Add(time.Hour))
	}
	if n := budget.Len(); n > maxBudgetEntries {
		t.Fatalf("budget holds %d accounts, bound is %d", n, maxBudgetEntries)
	}
}

// A depleted account's bucket is never evicted to make room: the next
// account would otherwise start with a full bucket (VAL-205).
func TestBudgetEvictionNeverForgetsDepletedBuckets(t *testing.T) {
	budget := NewBudget(100, 1<<20, nil)
	budget.maxEntries = 2
	now := time.Unix(1_000_000, 0)
	for _, id := range []string{"acct_a", "acct_b"} {
		ticket, _ := budget.Reserve(id, 100, 0, now)
		if ticket == nil {
			t.Fatalf("%s: first reservation refused", id)
		}
		ticket.Settle(100, 0)
	}
	for i := 0; i < 20; i++ {
		id := "new_" + time.Duration(i).String()
		if ticket, _ := budget.Reserve(id, 1, 0, now); ticket != nil {
			ticket.Settle(1, 0)
		}
		if n := budget.Len(); n > 2 {
			t.Fatalf("budget holds %d accounts, cap is 2", n)
		}
	}
	for _, id := range []string{"acct_a", "acct_b"} {
		ticket, wait := budget.Reserve(id, 1, 0, now)
		if ticket != nil || wait < time.Second {
			t.Fatalf("%s: depleted account was forgiven (ticket %v, wait %s)", id, ticket != nil, wait)
		}
	}
}

// Accounts admitted through the overflow bucket share it, and a ticket from
// it settles against it (VAL-205).
func TestBudgetOverflowBucketIsSharedAndSettled(t *testing.T) {
	budget := NewBudget(100, 1<<20, nil)
	budget.maxEntries = 1
	now := time.Unix(1_000_000, 0)
	held, _ := budget.Reserve("acct_a", 100, 0, now)
	if held == nil {
		t.Fatal("first reservation refused")
	}
	ticket, _ := budget.Reserve("acct_b", 60, 0, now)
	if ticket == nil {
		t.Fatal("overflow account refused its first reservation")
	}
	if budget.Len() != 1 {
		t.Fatalf("overflow account got a map entry: %d", budget.Len())
	}
	if other, _ := budget.Reserve("acct_c", 60, 0, now); other != nil {
		t.Fatal("overflow accounts did not share one bucket")
	}
	// Overuse on the overflow ticket is charged to the overflow bucket.
	ticket.Settle(100, 0)
	if again, _ := budget.Reserve("acct_d", 1, 0, now); again != nil {
		t.Fatal("overflow ticket settled against the wrong bucket")
	}
	held.Settle(100, 0)
}

// A bucket with an unsettled ticket survives eviction even after it has
// refilled, so later debt reaches the bucket the account uses next (VAL-298).
// A settled, refilled bucket is still evictable (positive control).
func TestBudgetEvictionKeepsBucketsWithOutstandingTickets(t *testing.T) {
	run := func(settleBeforeFill bool) {
		budget := NewBudget(100, 1<<20, nil)
		budget.maxEntries = 2
		now := time.Unix(1_000_000, 0)
		ticket, _ := budget.Reserve("acct_a", 10, 0, now)
		if ticket == nil {
			t.Fatal("first reservation refused")
		}
		if settleBeforeFill {
			ticket.Settle(10, 0)
		}
		later := now.Add(2 * time.Hour) // acct_a's bucket is full again
		for _, id := range []string{"acct_b", "acct_c", "acct_d", "acct_e"} {
			if tk, _ := budget.Reserve(id, 1, 0, later); tk != nil {
				tk.Settle(1, 0)
			}
			if n := budget.Len(); n > 2 {
				t.Fatalf("budget holds %d accounts, cap is 2", n)
			}
		}
		budget.mu.Lock()
		_, kept := budget.buckets["acct_a"]
		budget.mu.Unlock()
		if settleBeforeFill {
			if kept {
				t.Fatal("a settled, refilled bucket was never evicted")
			}
			return
		}
		if !kept {
			t.Fatal("a bucket with an outstanding ticket was evicted")
		}
		ticket.Settle(500, 0) // far beyond the window
		next, wait := budget.Reserve("acct_a", 1, 0, later)
		if next != nil || wait < time.Second {
			t.Fatalf("debt on an outstanding ticket was lost (ticket %v, wait %s)", next != nil, wait)
		}
	}
	run(false)
	run(true)
}

func TestCountersIgnoreUnknownAndNil(t *testing.T) {
	var nilCounters *Counters
	nilCounters.Reject(Storage)
	counters := &Counters{}
	counters.Reject("not-a-limit")
	counters.Reject(Devices)
	seen := 0
	counters.Each(func(limit string, n int64) {
		seen++
		if (limit == Devices) != (n == 1) {
			t.Fatalf("%s = %d", limit, n)
		}
	})
	if seen != len(Names) {
		t.Fatalf("Each visited %d limits", seen)
	}
}
