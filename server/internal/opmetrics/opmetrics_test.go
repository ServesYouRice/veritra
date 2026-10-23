package opmetrics

import (
	"strings"
	"sync"
	"testing"
	"time"
)

func TestHistogramBucketsAreCumulativeAndWritten(t *testing.T) {
	h := NewHistogram(time.Millisecond, 10*time.Millisecond, 100*time.Millisecond)
	for _, d := range []time.Duration{0, time.Millisecond, 2 * time.Millisecond, 50 * time.Millisecond, time.Second, -time.Second} {
		h.Observe(d)
	}
	s := h.Snapshot()
	want := []int64{3, 4, 5, 6}
	for i, value := range want {
		if s.Cumulative[i] != value {
			t.Fatalf("cumulative[%d] = %d, want %d (%v)", i, s.Cumulative[i], value, s.Cumulative)
		}
	}
	if s.Count != 6 || s.Sum != time.Second+53*time.Millisecond {
		t.Fatalf("count=%d sum=%s", s.Count, s.Sum)
	}
	var out strings.Builder
	WriteHistogram(&out, "veritra_test_seconds", `provider="fcm"`, s)
	for _, line := range []string{
		`veritra_test_seconds_bucket{provider="fcm",le="0.001"} 3`,
		`veritra_test_seconds_bucket{provider="fcm",le="0.1"} 5`,
		`veritra_test_seconds_bucket{provider="fcm",le="+Inf"} 6`,
		`veritra_test_seconds_sum{provider="fcm"} 1.053000`,
		`veritra_test_seconds_count{provider="fcm"} 6`,
	} {
		if !strings.Contains(out.String(), line+"\n") {
			t.Fatalf("missing %q in:\n%s", line, out.String())
		}
	}
	out.Reset()
	WriteHistogram(&out, "veritra_test_seconds", "", s)
	if !strings.Contains(out.String(), `veritra_test_seconds_bucket{le="0.01"} 4`) || !strings.Contains(out.String(), "veritra_test_seconds_count 6\n") {
		t.Fatalf("unlabelled histogram output:\n%s", out.String())
	}
}

func TestHistogramConcurrentObserve(t *testing.T) {
	h := NewHistogram(time.Millisecond)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 1000; j++ {
				h.Observe(time.Duration(j) * time.Microsecond)
			}
		}()
	}
	wg.Wait()
	if s := h.Snapshot(); s.Count != 8000 {
		t.Fatalf("count = %d", s.Count)
	}
}

func TestNilHistogramObserveIsNoop(t *testing.T) {
	var h *Histogram
	h.Observe(time.Second)
}
