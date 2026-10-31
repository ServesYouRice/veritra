package main

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"sync"
	"time"
)

// Operation classes measured by the load. "interactive" ones carry the
// latency targets; transfers and the socket are reported separately.
const (
	opSend = iota
	opSync
	opConversations
	opHistory
	opUpload
	opDownload
	opSocket
	opDelivery
	opColdSync
	opCount
)

var opNames = [opCount]string{"send", "sync", "conversations", "history", "upload", "download", "socket_connect", "realtime_delivery", "sync_cold"}

var interactiveOps = []int{opSend, opSync, opConversations, opHistory}

func printStep(w io.Writer, step stepResult) {
	status := "PASS"
	if !step.Verdict.Pass {
		status = "MISS"
	}
	_, _ = fmt.Fprintf(w, "\nstep %.2f msgs/device/min (offered %.2f): %s\n", step.Rate, step.Offered, status)
	_, _ = fmt.Fprintf(w, "%-18s %8s %8s %6s %6s %6s %9s %9s %9s %9s\n", "op", "count", "per_s", "err", "429", "4xx", "p50_ms", "p95_ms", "p99_ms", "max_ms")
	for _, s := range step.Ops {
		if s.Count == 0 {
			continue
		}
		_, _ = fmt.Fprintf(w, "%-18s %8d %8.2f %6d %6d %6d %9.1f %9.1f %9.1f %9.1f\n", s.Op, s.Count, s.PerSecond, s.Errors, s.RateLimited, s.ClientErrors, s.P50Ms, s.P95Ms, s.P99Ms, s.MaxMs)
	}
	t := step.Timeline
	_, _ = fmt.Fprintf(w, "timeline: %d s with errors, longest outage %d s", t.ErrorSeconds, t.LongestOutageS)
	if t.ErrorSeconds > 0 {
		_, _ = fmt.Fprintf(w, ", first error at %.0f s, recovered after %.0f s", t.FirstErrorAtS, t.RecoveredAfterS)
	}
	_, _ = fmt.Fprintln(w)
	if step.ServerError != "" {
		_, _ = fmt.Fprintln(w, "server metrics:", step.ServerError)
	}
	if len(step.Server) > 0 {
		keys := make([]string, 0, len(step.Server))
		for key := range step.Server {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		_, _ = fmt.Fprintln(w, "server metrics (gauges at the end of the window; *_delta over it):")
		for _, key := range keys {
			_, _ = fmt.Fprintf(w, "  %-36s %.4g\n", key, step.Server[key])
		}
	}
	for _, missed := range step.Verdict.Missed {
		_, _ = fmt.Fprintln(w, "  missed:", missed)
	}
}

type outcome uint8

const (
	outcomeOK outcome = iota
	outcomeRateLimited
	outcomeClientError
	outcomeServerError
	outcomeTransportError
	// outcomeDropped is work the tool generated but could not start
	// because too much was still waiting on the server (a device's send
	// cap). It counts as an error, never as skipped work.
	outcomeDropped
)

// failedOutcome reports whether result means the server did not complete
// the work, for the outage timeline. Rate limits and client errors are
// answers, so they do not count.
func failedOutcome(result outcome) bool {
	switch result {
	case outcomeServerError, outcomeTransportError, outcomeDropped:
		return true
	}
	return false
}

type sample struct {
	at      time.Duration // since the load started
	latency time.Duration
	op      uint8
	result  outcome
}

type recorder struct {
	started time.Time
	mu      sync.Mutex
	samples []sample
}

func newRecorder() *recorder {
	return &recorder{started: time.Now(), samples: make([]sample, 0, 1<<16)}
}

func classify(status int, err error) outcome {
	var se statusError
	switch {
	case err != nil && !errors.As(err, &se):
		return outcomeTransportError
	case err != nil:
		status = se.status
	}
	switch {
	case status == http.StatusTooManyRequests:
		return outcomeRateLimited
	case status >= 500:
		return outcomeServerError
	case status >= 400:
		return outcomeClientError
	default:
		return outcomeOK
	}
}

func (r *recorder) record(op int, started time.Time, latency time.Duration, result outcome) {
	r.mu.Lock()
	r.samples = append(r.samples, sample{at: started.Sub(r.started), latency: latency, op: uint8(op), result: result})
	r.mu.Unlock()
}

type opSummary struct {
	Op           string  `json:"op"`
	Count        int     `json:"count"`
	PerSecond    float64 `json:"per_second"`
	Errors       int     `json:"errors"`
	RateLimited  int     `json:"rate_limited"`
	ClientErrors int     `json:"client_errors"`
	P50Ms        float64 `json:"p50_ms"`
	P95Ms        float64 `json:"p95_ms"`
	P99Ms        float64 `json:"p99_ms"`
	MaxMs        float64 `json:"max_ms"`
}

type timelineSummary struct {
	ErrorSeconds        int     `json:"error_seconds"`
	LongestOutageS      int     `json:"longest_outage_seconds"`
	FirstErrorAtS       float64 `json:"first_error_at_seconds,omitempty"`
	RecoveredAfterS     float64 `json:"recovered_after_seconds,omitempty"`
	SecondsWithoutReply int     `json:"seconds_without_success"`
}

// summarize computes per-operation percentiles over the measurement window
// [from, to) and an error timeline over the whole run.
func (r *recorder) summarize(from, to time.Duration) ([]opSummary, timelineSummary) {
	r.mu.Lock()
	samples := append([]sample(nil), r.samples...)
	r.mu.Unlock()
	window := (to - from).Seconds()
	latencies := make([][]time.Duration, opCount)
	summaries := make([]opSummary, opCount)
	for i := range summaries {
		summaries[i].Op = opNames[i]
	}
	for _, s := range samples {
		if s.at < from || s.at >= to {
			continue
		}
		summary := &summaries[s.op]
		summary.Count++
		switch s.result {
		case outcomeOK:
			latencies[s.op] = append(latencies[s.op], s.latency)
		case outcomeRateLimited:
			summary.RateLimited++
		case outcomeClientError:
			summary.ClientErrors++
		default:
			summary.Errors++
		}
	}
	for i := range summaries {
		values := latencies[i]
		sort.Slice(values, func(a, b int) bool { return values[a] < values[b] })
		summaries[i].P50Ms = percentileMs(values, 0.50)
		summaries[i].P95Ms = percentileMs(values, 0.95)
		summaries[i].P99Ms = percentileMs(values, 0.99)
		if len(values) > 0 {
			summaries[i].MaxMs = ms(values[len(values)-1])
		}
		if window > 0 {
			summaries[i].PerSecond = float64(summaries[i].Count) / window
		}
	}
	return summaries, timeline(samples)
}

// timeline buckets requests per second (sockets and deliveries excluded) and
// reports how long the server was unreachable, for the restart scenario.
func timeline(samples []sample) timelineSummary {
	type second struct{ ok, failed int }
	buckets := map[int]*second{}
	last := 0
	for _, s := range samples {
		if s.op == opDelivery || s.op == opSocket {
			continue
		}
		index := int(s.at / time.Second)
		bucket := buckets[index]
		if bucket == nil {
			bucket = &second{}
			buckets[index] = bucket
		}
		if failedOutcome(s.result) {
			bucket.failed++
		} else {
			bucket.ok++
		}
		last = max(last, index)
	}
	var summary timelineSummary
	firstError, recovered, outage, run := -1, -1, 0, 0
	for i := 0; i <= last; i++ {
		bucket := buckets[i]
		if bucket == nil {
			continue
		}
		if bucket.failed > 0 {
			summary.ErrorSeconds++
			if firstError < 0 {
				firstError = i
			}
		}
		if bucket.ok == 0 && bucket.failed > 0 {
			summary.SecondsWithoutReply++
			run++
			outage = max(outage, run)
		} else {
			run = 0
			if firstError >= 0 && recovered < 0 && bucket.failed == 0 {
				recovered = i
			}
		}
	}
	summary.LongestOutageS = outage
	if firstError >= 0 {
		summary.FirstErrorAtS = float64(firstError)
		if recovered >= 0 {
			summary.RecoveredAfterS = float64(recovered - firstError)
		}
	}
	return summary
}

func percentileMs(sorted []time.Duration, q float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	index := int(q*float64(len(sorted))+0.5) - 1
	index = min(max(index, 0), len(sorted)-1)
	return ms(sorted[index])
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

// Capacity targets (docs/operations.md, "Capacity contract").
const (
	targetP95Ms        = 150
	targetP99Ms        = 500
	targetErrorRatio   = 0.001
	targetDeliveryP99S = 2
	targetColdP99Ms    = 1000
)

type verdict struct {
	Pass   bool     `json:"pass"`
	Missed []string `json:"missed,omitempty"`
}

func evaluateStep(step stepResult) verdict {
	var v verdict
	total, failed := 0, 0
	for _, op := range interactiveOps {
		s := step.Ops[op]
		total += s.Count
		failed += s.Errors + s.RateLimited + s.ClientErrors
		if s.Count == 0 {
			continue
		}
		if s.P95Ms > targetP95Ms {
			v.Missed = append(v.Missed, fmt.Sprintf("%s p95 %.0f ms > %d ms", s.Op, s.P95Ms, targetP95Ms))
		}
		if s.P99Ms > targetP99Ms {
			v.Missed = append(v.Missed, fmt.Sprintf("%s p99 %.0f ms > %d ms", s.Op, s.P99Ms, targetP99Ms))
		}
	}
	if s := step.Ops[opColdSync]; s.Count > 0 && s.P99Ms > targetColdP99Ms {
		v.Missed = append(v.Missed, fmt.Sprintf("cold catch-up page p99 %.0f ms > %d ms", s.P99Ms, targetColdP99Ms))
	}
	for _, op := range []int{opUpload, opDownload, opSocket, opColdSync} {
		s := step.Ops[op]
		total += s.Count
		failed += s.Errors + s.RateLimited + s.ClientErrors
	}
	if total > 0 && float64(failed)/float64(total) > targetErrorRatio {
		v.Missed = append(v.Missed, fmt.Sprintf("error ratio %.4f > %.3f", float64(failed)/float64(total), targetErrorRatio))
	}
	if d := step.Ops[opDelivery]; d.Count > 0 && d.P99Ms > targetDeliveryP99S*1000 {
		v.Missed = append(v.Missed, fmt.Sprintf("realtime delivery p99 %.0f ms > %d s", d.P99Ms, targetDeliveryP99S))
	}
	v.Pass = len(v.Missed) == 0
	return v
}

// finish sets the rated step and the overall verdict: every step met the
// targets and no acknowledged message went missing.
func finish(result *runResult) {
	result.Verdict = verdict{Pass: true}
	rated := true
	for _, step := range result.Steps {
		if !step.Verdict.Pass {
			rated = false
			result.Verdict.Pass = false
			for _, missed := range step.Verdict.Missed {
				result.Verdict.Missed = append(result.Verdict.Missed, fmt.Sprintf("at %.2f msgs/device/min: %s", step.Rate, missed))
			}
		}
		if rated {
			result.RatedStep = step.Rate
		}
	}
	if v := result.Verify; v != nil && (v.Missing > 0 || v.Errors > 0) {
		result.Verdict.Pass = false
		result.Verdict.Missed = append(result.Verdict.Missed, fmt.Sprintf("%d acknowledged messages missing and %d unreadable after the run", v.Missing, v.Errors))
	}
}

func printReport(w io.Writer, r *runResult) {
	_, _ = fmt.Fprintf(w, "\nprofile %s: %d accounts, %d conversations, %d seeded messages, %d attachments (seeded in %s)\n",
		r.Profile.Name, r.Profile.Accounts, r.Conversations, r.Profile.History, r.Profile.Attachments, r.SeedDuration)
	_, _ = fmt.Fprintf(w, "load: %d online devices (+%d companion clients, %d cold devices), %s measured per step after %s warmup\n",
		r.Online, r.Companions, r.Cold, r.Measured, r.Warmup)
	for _, step := range r.Steps {
		printStep(w, step)
	}
	_, _ = fmt.Fprintf(w, "socket reconnects %d\n", r.SocketReconnects)
	if r.Verify != nil {
		_, _ = fmt.Fprintf(w, "verify: %d acknowledged messages checked, %d missing, %d unreadable\n", r.Verify.Checked, r.Verify.Missing, r.Verify.Errors)
	}
	_, _ = fmt.Fprintf(w, "rated step: %.2f msgs/device/min\n", r.RatedStep)
	if r.Verdict.Pass {
		_, _ = fmt.Fprintln(w, "verdict: PASS")
	} else {
		_, _ = fmt.Fprintln(w, "verdict: MISS")
		for _, missed := range r.Verdict.Missed {
			_, _ = fmt.Fprintln(w, "  -", missed)
		}
	}
}
