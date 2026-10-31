package main

import (
	"context"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// blockingAttachments answers GET /api/v1/attachments/{id} only after
// release is closed; requests give up when the client cancels.
func blockingAttachments(t *testing.T) (*world, chan struct{}, *atomic.Int64) {
	t.Helper()
	release := make(chan struct{})
	var started atomic.Int64
	w := testWorld(t, http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || !strings.HasPrefix(r.URL.Path, "/api/v1/attachments/") {
			rw.WriteHeader(http.StatusNotFound)
			return
		}
		started.Add(1)
		select {
		case <-release:
			_, _ = rw.Write([]byte("synthetic ciphertext"))
		case <-r.Context().Done():
		}
	}))
	return w, release, &started
}

// TestFullDownloadQueueRecordsDrops: an attachment that does not fit in
// the client's queue is one dropped download, recorded at the event time.
func TestFullDownloadQueueRecordsDrops(t *testing.T) {
	w := testWorld(t, http.NotFoundHandler())
	queue := make(chan download, 2)
	at := time.Now()
	w.queueDownloads(queue, w.devices[0], []string{"a1", "a2", "a3", "a4", "a5"}, at)
	if n := countSamples(w.rec, opDownload, outcomeDropped); n != 3 || countSamples(w.rec, opDownload) != 3 {
		t.Fatalf("%d dropped of %d samples, want 3 of 3", n, countSamples(w.rec, opDownload))
	}
	if len(queue) != 2 || w.rec.liveCount() != 2 {
		t.Fatalf("queued %d, live %d; want 2 and 2", len(queue), w.rec.liveCount())
	}
	w.rec.mu.Lock()
	defer w.rec.mu.Unlock()
	for _, s := range w.rec.samples {
		if s.at != at.Sub(w.rec.started) {
			t.Fatalf("dropped download at %s, want the event time %s", s.at, at.Sub(w.rec.started))
		}
	}
}

// TestDownloadCountsQueueTime: a download is timed from its event, so the
// sample starts at the event and its latency includes the wait.
func TestDownloadCountsQueueTime(t *testing.T) {
	w, release, _ := blockingAttachments(t)
	close(release)
	queue := make(chan download, 4)
	at := time.Now().Add(-300 * time.Millisecond) // the event came 300 ms ago
	w.queueDownloads(queue, w.devices[0], []string{"a1"}, at)
	close(queue)
	w.runDownloads(context.Background(), queue)
	w.rec.mu.Lock()
	defer w.rec.mu.Unlock()
	if len(w.rec.samples) != 1 {
		t.Fatalf("%d samples, want 1", len(w.rec.samples))
	}
	s := w.rec.samples[0]
	if s.result != outcomeOK || s.at != at.Sub(w.rec.started) || s.latency < 300*time.Millisecond {
		t.Fatalf("sample = %+v, want OK at the event with the queue wait in its latency", s)
	}
}

// TestSettleWaitsForQueuedDownloads: a download queued in the window and
// finished after it is counted in that window.
func TestSettleWaitsForQueuedDownloads(t *testing.T) {
	w, release, _ := blockingAttachments(t)
	queue := make(chan download, 4)
	w.queueDownloads(queue, w.devices[0], []string{"a1", "a2"}, time.Now())
	to := time.Since(w.rec.started)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	drained := make(chan struct{})
	go func() { w.runDownloads(ctx, queue); close(drained) }()
	done := settleAsync(w.rec, to, time.Minute)
	expectBlocked(t, done)
	close(release)
	if forced := <-done; forced != 0 {
		t.Fatalf("forced %d", forced)
	}
	ops, _ := w.rec.summarize(0, to)
	if d := ops[opDownload]; d.Count != 2 || d.Errors != 0 {
		t.Fatalf("download summary = %+v, want 2 OK", d)
	}
	close(queue)
	<-drained
}

// TestUnfinishedDownloadCountsOnce: a download still blocked after the
// grace period is one unfinished record; its late completion adds none.
func TestUnfinishedDownloadCountsOnce(t *testing.T) {
	w, release, started := blockingAttachments(t)
	queue := make(chan download, 4)
	w.queueDownloads(queue, w.devices[0], []string{"a1"}, time.Now())
	to := time.Since(w.rec.started)
	close(queue)
	drained := make(chan struct{})
	go func() { w.runDownloads(context.Background(), queue); close(drained) }()
	for started.Load() == 0 {
		time.Sleep(5 * time.Millisecond)
	}
	if forced := w.rec.settle(context.Background(), to, 50*time.Millisecond); forced != 1 {
		t.Fatalf("forced %d, want 1", forced)
	}
	close(release)
	<-drained
	if n := countSamples(w.rec, opDownload); n != 1 || countSamples(w.rec, opDownload, outcomeUnfinished) != 1 {
		t.Fatalf("%d download samples, want one unfinished", n)
	}
}

// TestCancelledDownloadsEndOnce: cancelling the load with downloads queued
// and in progress leaves one record per download and nothing live.
func TestCancelledDownloadsEndOnce(t *testing.T) {
	w, _, started := blockingAttachments(t)
	queue := make(chan download, 8)
	w.queueDownloads(queue, w.devices[0], []string{"a1", "a2", "a3", "a4"}, time.Now())
	ctx, cancel := context.WithCancel(context.Background())
	drained := make(chan struct{})
	go func() { w.runDownloads(ctx, queue); close(drained) }()
	for started.Load() == 0 {
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	// The producer closes the queue once it has stopped.
	w.queueDownloads(queue, w.devices[0], []string{"a5"}, time.Now())
	close(queue)
	<-drained
	if n := countSamples(w.rec, opDownload); n != 5 || countSamples(w.rec, opDownload, outcomeUnfinished) != 5 {
		t.Fatalf("%d download samples (%d unfinished), want 5 unfinished", n, countSamples(w.rec, opDownload, outcomeUnfinished))
	}
	if w.rec.liveCount() != 0 {
		t.Fatalf("%d handles live after the downloader stopped", w.rec.liveCount())
	}
}
