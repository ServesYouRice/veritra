package domain

import (
	"testing"
	"time"
)

func TestOwnerQuietCountsWholeDays(t *testing.T) {
	day := time.Date(2030, 1, 10, 0, 0, 0, 0, time.UTC)
	end := day.Add(24 * time.Hour).Add(OwnerSuccessionQuiet)
	if OwnerQuiet(&day, end.Add(-time.Nanosecond)) {
		t.Fatal("quiet one instant early")
	}
	if !OwnerQuiet(&day, end) {
		t.Fatal("not quiet at the end of the wait")
	}
	if !OwnerQuiet(nil, day) {
		t.Fatal("no recorded activity must count as quiet")
	}
	if got := ActivityDay(time.Date(2030, 1, 10, 23, 59, 0, 0, time.FixedZone("x", -3600))); !got.Equal(time.Date(2030, 1, 11, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("ActivityDay = %v", got)
	}
}

func TestSuccessionQuorumIsMoreThanHalf(t *testing.T) {
	for _, c := range []struct {
		asks, eligible int
		want           bool
	}{{0, 0, false}, {1, 1, true}, {1, 2, false}, {2, 3, true}, {2, 4, false}, {3, 4, true}} {
		if got := SuccessionQuorum(c.asks, c.eligible); got != c.want {
			t.Fatalf("SuccessionQuorum(%d, %d) = %v", c.asks, c.eligible, got)
		}
	}
}
