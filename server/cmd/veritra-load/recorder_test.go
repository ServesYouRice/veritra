package main

import (
	"context"
	"testing"
	"time"
)

// settleAsync runs settle in the background and reports its result.
func settleAsync(r *recorder, to, grace time.Duration) <-chan int {
	done := make(chan int, 1)
	go func() { done <- r.settle(context.Background(), to, grace) }()
	return done
}

func expectBlocked(t *testing.T, done <-chan int) {
	t.Helper()
	select {
	case n := <-done:
		t.Fatalf("settle returned (%d forced) while an operation from the window was still running", n)
	case <-time.After(150 * time.Millisecond):
	}
}

// TestSettleCountsAnOperationThatEndsAfterTheWindow: an operation started
// inside the window that ends after it closes is counted in that window.
func TestSettleCountsAnOperationThatEndsAfterTheWindow(t *testing.T) {
	r := newRecorder()
	h := r.begin(opSend, time.Now())
	to := windowEnd(r)
	done := settleAsync(r, to, time.Minute)
	expectBlocked(t, done)
	if !r.end(h, outcomeOK, 30*time.Millisecond) {
		t.Fatal("end of a live handle recorded nothing")
	}
	if forced := <-done; forced != 0 {
		t.Fatalf("forced %d", forced)
	}
	ops, _ := r.summarize(0, to)
	if s := ops[opSend]; s.Count != 1 || s.Errors != 0 {
		t.Fatalf("send summary = %+v, want one OK", s)
	}
}

// TestSettleCountsUnfinishedOnce: an operation still running after the
// grace period is one unfinished error, and its late end adds nothing.
func TestSettleCountsUnfinishedOnce(t *testing.T) {
	r := newRecorder()
	h := r.begin(opSync, time.Now())
	to := windowEnd(r)
	if forced := r.settle(context.Background(), to, 50*time.Millisecond); forced != 1 {
		t.Fatalf("forced = %d, want 1", forced)
	}
	if r.end(h, outcomeOK, time.Millisecond) {
		t.Fatal("a handle settle already counted recorded a second sample")
	}
	if n := countSamples(r, opSync); n != 1 {
		t.Fatalf("%d samples, want 1", n)
	}
	if n := countSamples(r, opSync, outcomeUnfinished); n != 1 {
		t.Fatal("the sample is not the unfinished outcome")
	}
	ops, timeline := r.summarize(0, to)
	if ops[opSync].Errors != 1 || timeline.ErrorSeconds != 1 {
		t.Fatalf("summary = %+v, timeline = %+v; unfinished must count as an error", ops[opSync], timeline)
	}
	if r.liveCount() != 0 {
		t.Fatal("registry not empty")
	}
}

// TestSettleWaitsForABackdatedRegistration: work registered after the
// window closed, with a start inside it (a queued job), is waited for.
func TestSettleWaitsForABackdatedRegistration(t *testing.T) {
	r := newRecorder()
	eventAt := time.Now()
	time.Sleep(20 * time.Millisecond)
	to := windowEnd(r)
	time.Sleep(20 * time.Millisecond) // the window is over in wall time
	h := r.begin(opDownload, eventAt)
	done := settleAsync(r, to, time.Minute)
	expectBlocked(t, done)
	r.end(h, outcomeOK, time.Since(eventAt))
	<-done
	ops, _ := r.summarize(0, to)
	if ops[opDownload].Count != 1 {
		t.Fatalf("download summary = %+v", ops[opDownload])
	}
}

// TestSettleIgnoresLaterWork: work that started after the window does not
// hold up its summary and is not forced.
func TestSettleIgnoresLaterWork(t *testing.T) {
	r := newRecorder()
	to := windowEnd(r)
	time.Sleep(5 * time.Millisecond)
	h := r.begin(opSend, time.Now())
	if forced := r.settle(context.Background(), to, time.Minute); forced != 0 {
		t.Fatalf("forced %d", forced)
	}
	if !r.end(h, outcomeOK, 0) {
		t.Fatal("later work was settled")
	}
}

func TestAbandonRecordsOnce(t *testing.T) {
	r := newRecorder()
	h := r.begin(opDownload, time.Now())
	if !r.abandon(h) || r.abandon(h) || r.end(h, outcomeOK, 0) {
		t.Fatal("abandon or end settled a handle twice")
	}
	if n := countSamples(r, opDownload, outcomeUnfinished); n != 1 || countSamples(r, opDownload) != 1 {
		t.Fatalf("%d unfinished samples, want exactly one sample", n)
	}
	if r.liveCount() != 0 {
		t.Fatal("registry not empty after abandon")
	}
}

func TestSettleStopsOnCancel(t *testing.T) {
	r := newRecorder()
	r.begin(opSend, time.Now())
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan int, 1)
	go func() { done <- r.settle(ctx, windowEnd(r), time.Hour) }()
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("settle ignored cancellation")
	}
}

// windowEnd returns a window end strictly after everything begun so far.
// Coarse clocks (Windows) can repeat a reading, and settle only waits for
// operations that started strictly before the window end.
func windowEnd(r *recorder) time.Duration {
	time.Sleep(20 * time.Millisecond)
	return time.Since(r.started)
}
