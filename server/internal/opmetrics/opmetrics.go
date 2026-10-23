// Package opmetrics holds the small, dependency-free primitives behind the
// server's private /metrics endpoint (card I47).
//
// Every series is instance-wide. Callers pass only fixed label values (a
// provider, pool or volume name chosen from a closed set), never a user,
// account, conversation, device, token, endpoint, message or ciphertext
// identifier.
package opmetrics

import (
	"fmt"
	"io"
	"strconv"
	"sync/atomic"
	"time"
)

// Histogram counts durations into fixed buckets. It is safe for concurrent
// use; Observe costs one bucket search and three atomic adds.
type Histogram struct {
	bounds   []time.Duration
	counts   []atomic.Int64 // one per bound, then +Inf; not cumulative
	sumNanos atomic.Int64
}

// NewHistogram returns a histogram with the given ascending upper bounds.
func NewHistogram(bounds ...time.Duration) *Histogram {
	for i := 1; i < len(bounds); i++ {
		if bounds[i] <= bounds[i-1] {
			panic("opmetrics: histogram bounds must ascend")
		}
	}
	return &Histogram{bounds: bounds, counts: make([]atomic.Int64, len(bounds)+1)}
}

// Observe records one duration. Negative durations count as zero.
func (h *Histogram) Observe(d time.Duration) {
	if h == nil {
		return
	}
	if d < 0 {
		d = 0
	}
	bucket := len(h.bounds)
	for i, bound := range h.bounds {
		if d <= bound {
			bucket = i
			break
		}
	}
	h.counts[bucket].Add(1)
	h.sumNanos.Add(int64(d))
}

// Snapshot is a point-in-time copy of a histogram.
type Snapshot struct {
	Bounds     []time.Duration
	Cumulative []int64 // per bound, then +Inf (equal to Count)
	Count      int64
	Sum        time.Duration
}

// Snapshot copies the counters. Concurrent observations may land between
// bucket reads; the cumulative counts stay monotonic.
func (h *Histogram) Snapshot() Snapshot {
	snapshot := Snapshot{Bounds: h.bounds, Cumulative: make([]int64, len(h.counts))}
	var running int64
	for i := range h.counts {
		running += h.counts[i].Load()
		snapshot.Cumulative[i] = running
	}
	snapshot.Count = running
	snapshot.Sum = time.Duration(h.sumNanos.Load())
	return snapshot
}

// WriteHistogram writes the bucket, sum and count series of one histogram
// in the Prometheus text format. labels is empty or a comma-separated list
// of key="value" pairs built from fixed values; the caller writes the TYPE
// line once per metric name.
func WriteHistogram(w io.Writer, name, labels string, s Snapshot) {
	prefix := ""
	if labels != "" {
		prefix = labels + ","
	}
	for i, bound := range s.Bounds {
		_, _ = fmt.Fprintf(w, "%s_bucket{%sle=%q} %d\n", name, prefix, strconv.FormatFloat(bound.Seconds(), 'f', -1, 64), s.Cumulative[i])
	}
	_, _ = fmt.Fprintf(w, "%s_bucket{%sle=\"+Inf\"} %d\n", name, prefix, s.Count)
	suffix := ""
	if labels != "" {
		suffix = "{" + labels + "}"
	}
	_, _ = fmt.Fprintf(w, "%s_sum%s %s\n", name, suffix, strconv.FormatFloat(s.Sum.Seconds(), 'f', 6, 64))
	_, _ = fmt.Fprintf(w, "%s_count%s %d\n", name, suffix, s.Count)
}
