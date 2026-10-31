package main

import (
	"context"
	"errors"
	"net/http"
	"sync/atomic"
	"testing"
)

func ackedWorld(t *testing.T, n int, handler http.HandlerFunc) *world {
	t.Helper()
	w := testWorld(t, handler)
	for i := 0; i < n; i++ {
		w.acked = append(w.acked, ackedMessage{id: "m", sender: 0})
	}
	return w
}

// TestCancelledVerifyChecksNothing: a verification cancelled before it
// fetched anything must not report the acknowledged messages as checked.
func TestCancelledVerifyChecksNothing(t *testing.T) {
	w := ackedWorld(t, 5, func(rw http.ResponseWriter, r *http.Request) { _, _ = rw.Write([]byte(`{}`)) })
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	result, err := w.verify(ctx)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want the cancellation", err)
	}
	if result.Checked != 0 || result.Errors != 0 {
		t.Fatalf("result = %+v after a cancelled verification", result)
	}
}

// TestVerifyCancelledMidwayCountsOnlyFetches: of 20 messages two are
// fetched before the rest hang and the run is cancelled; only those two
// are checked, and the fetches cut short are not errors.
func TestVerifyCancelledMidwayCountsOnlyFetches(t *testing.T) {
	var hits atomic.Int64
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	w := ackedWorld(t, 20, func(rw http.ResponseWriter, r *http.Request) {
		if hits.Add(1) <= 2 {
			_, _ = rw.Write([]byte(`{}`))
			return
		}
		<-r.Context().Done()
	})
	done := make(chan struct{})
	var result *verifyResult
	var err error
	go func() { result, err = w.verify(ctx); close(done) }()
	waitFor(t, "the hanging fetches", func() bool { return hits.Load() >= 5 })
	cancel()
	<-done
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want the cancellation", err)
	}
	// At most the two answered fetches count (fewer if the cancellation
	// beat reading an answer); the hanging ones are neither checked nor
	// errors.
	if result.Checked > 2 || result.Missing != 0 || result.Errors != 0 {
		t.Fatalf("result = %+v, want at most 2 checked and nothing else", result)
	}
}

// TestVerifyCountsCompletedFetches keeps the uncancelled semantics: every
// fetch is checked, a 404 is missing and other answers are errors.
func TestVerifyCountsCompletedFetches(t *testing.T) {
	var hits atomic.Int64
	w := ackedWorld(t, 6, func(rw http.ResponseWriter, r *http.Request) {
		switch hits.Add(1) {
		case 1:
			rw.WriteHeader(http.StatusNotFound)
		case 2:
			rw.WriteHeader(http.StatusInternalServerError)
		default:
			_, _ = rw.Write([]byte(`{}`))
		}
	})
	result, err := w.verify(context.Background())
	if err != nil || result.Checked != 6 || result.Missing != 1 || result.Errors != 1 {
		t.Fatalf("result = %+v, err = %v", result, err)
	}
}
