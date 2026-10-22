package app

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"testing"
	"time"
)

func TestShutdownBudgetFitsSupervisorStopGrace(t *testing.T) {
	// deploy/docker-compose.yml stop_grace_period and the systemd unit's
	// TimeoutStopSec are 30s; leave headroom for process exit.
	const supervisorStopGrace = 30 * time.Second
	if ShutdownBudget >= supervisorStopGrace-2*time.Second {
		t.Fatalf("shutdown budget %s leaves no headroom under %s", ShutdownBudget, supervisorStopGrace)
	}
	// Handlers cut off after the drain need time for 5s blob cleanup.
	if ShutdownBudget-ShutdownDrain < 5*time.Second {
		t.Fatalf("drain %s leaves under 5s of the %s budget for cleanup", ShutdownDrain, ShutdownBudget)
	}
}

// A request that cannot finish within the drain (here a stalled request
// body, as with a slow upload) is cut off, and Serve returns only after its
// handler has finished, so the caller never closes storage underneath it.
func TestShutdownCutsOffStalledRequestWithinBudget(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := listener.Addr().String()
	listener.Close()
	cfg := deploymentConfig(t)
	cfg.Addr = addr
	application, err := New(context.Background(), cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer application.Close()
	application.shutdownDrain = 200 * time.Millisecond
	application.shutdownBudget = 2 * time.Second
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	serveDone := make(chan error, 1)
	go func() { serveDone <- application.Serve(ctx) }()

	waitUntil(t, func() bool {
		response, err := (&http.Client{Timeout: time.Second}).Get("http://" + addr + "/readyz")
		if err != nil {
			return false
		}
		response.Body.Close()
		return response.StatusCode == http.StatusOK
	})
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	// Promise a body and send only part of it so the handler blocks reading.
	if _, err := fmt.Fprintf(conn, "POST /api/v1/auth/login HTTP/1.1\r\nHost: test\r\nContent-Type: application/json\r\nContent-Length: 4096\r\n\r\n{\"user"); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, func() bool { return application.inflight.Load() > 0 })

	started := time.Now()
	cancel()
	select {
	case err := <-serveDone:
		if err != nil {
			t.Fatalf("serve returned: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("shutdown exceeded its budget")
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second+500*time.Millisecond {
		t.Fatalf("shutdown took %s", elapsed)
	}
	if n := application.inflight.Load(); n != 0 {
		t.Fatalf("%d handlers still running when Serve returned", n)
	}
}

func waitUntil(t *testing.T, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatal("condition not reached")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
