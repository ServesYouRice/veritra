// Tests for smoke-client.go. Like the client, they build without a module:
//
//	cd scripts/smoke-deploy && go test smoke-client.go smoke_client_test.go
package main

import (
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// waitReady must give up near its -timeout even when one /readyz probe
// stalls: before the response headers, after them in the body, or in the
// TLS handshake. Before, a probe could run for the client's 2-minute header
// timeout or its 15-minute overall timeout.
func TestWaitReadyHonoursTimeoutWhenAProbeStalls(t *testing.T) {
	const timeout = 2 * time.Second
	// Generous: the machine running the tests may be loaded.
	const slack = 8 * time.Second

	stall := func(t *testing.T, beforeHeaders bool) string {
		release := make(chan struct{})
		var once sync.Once
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !beforeHeaders {
				w.Header().Set("Content-Length", "100")
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte("ok"))
				w.(http.Flusher).Flush()
			}
			select {
			case <-release:
			case <-r.Context().Done():
			}
		}))
		t.Cleanup(func() {
			once.Do(func() { close(release) })
			server.CloseClientConnections()
			server.Close()
		})
		return server.URL
	}

	handshake := func(t *testing.T) string {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		var mu sync.Mutex
		var held []net.Conn
		go func() {
			for {
				conn, err := listener.Accept()
				if err != nil {
					return
				}
				mu.Lock()
				held = append(held, conn) // accepted, never answered
				mu.Unlock()
			}
		}()
		t.Cleanup(func() {
			_ = listener.Close()
			mu.Lock()
			defer mu.Unlock()
			for _, conn := range held {
				_ = conn.Close()
			}
		})
		return "https://" + listener.Addr().String()
	}

	for _, tc := range []struct {
		name string
		base func(*testing.T) string
	}{
		{"before headers", func(t *testing.T) string { return stall(t, true) }},
		{"in the body", func(t *testing.T) string { return stall(t, false) }},
		{"in the TLS handshake", handshake},
	} {
		t.Run(tc.name, func(t *testing.T) {
			base := tc.base(t)
			done := make(chan error, 1)
			start := time.Now()
			go func() { done <- waitReady([]string{"-base", base, "-timeout", timeout.String()}) }()
			select {
			case err := <-done:
				if err == nil {
					t.Fatal("waitReady reported ready for a stalled probe")
				}
				if !strings.Contains(err.Error(), "not ready") {
					t.Fatalf("unexpected error: %v", err)
				}
				if elapsed := time.Since(start); elapsed > timeout+slack {
					t.Fatalf("waitReady took %s for a %s timeout", elapsed, timeout)
				}
			case <-time.After(timeout + slack):
				t.Fatalf("waitReady did not return within %s of its %s timeout", slack, timeout)
			}
		})
	}
}

// A healthy server is still reported ready.
func TestWaitReadySucceedsAgainstAHealthyServer(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/readyz" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()
	if err := waitReady([]string{"-base", server.URL, "-timeout", "5s"}); err != nil {
		t.Fatal(err)
	}
}
