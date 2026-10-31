package app

import (
	"sync"
	"time"
)

// A provider can refuse a send about the target (APNs BadDeviceToken or
// DeviceTokenNotForTopic, an FCM 404 without UNREGISTERED) without proving the
// subscription dead: Apple also says BadDeviceToken for a token sent to the
// wrong environment, and a 404 can come from the project. Retrying the job
// would be refused the same way every five minutes for its whole day, so the
// job is dropped and the rejection counted here. A subscription that is
// refused rejectedTargetMinCount times over more than rejectedTargetMinSpan,
// with no successful send in between, is treated as dead and retired.
//
// The count is in memory: a restart forgets it, which only delays retiring a
// dead target, never retires a live one. It holds at most
// maxTrackedRejectedTargets subscriptions.
const (
	rejectedTargetMinCount    = 10
	rejectedTargetMinSpan     = 24 * time.Hour
	maxTrackedRejectedTargets = 4096
)

type rejectedTargets struct {
	mu   sync.Mutex
	byID map[string]rejectedTarget
}

type rejectedTarget struct {
	first time.Time
	count int
}

// note records a rejection of subscriptionID at now and reports whether the
// subscription has now been refused often enough, for long enough, to retire.
func (t *rejectedTargets) note(subscriptionID string, now time.Time) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.byID == nil {
		t.byID = map[string]rejectedTarget{}
	}
	entry, ok := t.byID[subscriptionID]
	if !ok {
		if len(t.byID) >= maxTrackedRejectedTargets {
			for id := range t.byID {
				delete(t.byID, id)
				break
			}
		}
		entry.first = now
	}
	entry.count++
	if entry.count >= rejectedTargetMinCount && now.Sub(entry.first) > rejectedTargetMinSpan {
		delete(t.byID, subscriptionID)
		return true
	}
	t.byID[subscriptionID] = entry
	return false
}

// clear forgets subscriptionID: a send to it worked.
func (t *rejectedTargets) clear(subscriptionID string) {
	t.mu.Lock()
	delete(t.byID, subscriptionID)
	t.mu.Unlock()
}
