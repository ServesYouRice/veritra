package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"testing"
)

// redirectPair starts a destination server that counts every request and an
// origin server that answers every request with code and a Location on the
// destination.
func redirectPair(t *testing.T, code int) (origin *url.URL, hits *atomic.Int64) {
	t.Helper()
	hits = &atomic.Int64{}
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"id":"x"}`))
	}))
	t.Cleanup(destination.Close)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, destination.URL+r.URL.Path, code)
	}))
	t.Cleanup(server.Close)
	parsed, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	return parsed, hits
}

// TestClientRefusesRedirects keeps the local-target guard meaningful: a
// checked target that redirects must not move any request to another host.
func TestClientRefusesRedirects(t *testing.T) {
	for _, code := range []int{http.StatusMovedPermanently, http.StatusFound, http.StatusTemporaryRedirect, http.StatusPermanentRedirect} {
		origin, hits := redirectPair(t, code)
		client := newAPIClient(origin, 2)
		dev := &device{token: "secret-token", ip: "10.77.0.1"}
		var out struct {
			ID string `json:"id"`
		}
		err := expect(client.json(context.Background(), http.MethodPost, "/api/v1/messages/envelopes", dev, "",
			map[string]any{"ciphertext": []byte("synthetic")}, &out, map[string]string{"X-Custom": "1"}))
		var refused statusError
		if !errors.As(err, &refused) || refused.status != code {
			t.Fatalf("redirect %d: err = %v, want statusError %d", code, err, code)
		}
		if n := hits.Load(); n != 0 {
			t.Fatalf("redirect %d: destination received %d requests", code, n)
		}
		if out.ID != "" {
			t.Fatalf("redirect %d: decoded a body from the destination", code)
		}
	}
}

// TestSyncSocketRefusesRedirects checks the websocket dial, which writes its
// own handshake: a redirect is a failed dial, not a hop to another host.
func TestSyncSocketRefusesRedirects(t *testing.T) {
	origin, hits := redirectPair(t, http.StatusFound)
	socket, err := dialSync(context.Background(), origin, &device{token: "secret-token", ip: "10.77.0.1"})
	if socket != nil {
		socket.close()
	}
	var refused statusError
	if !errors.As(err, &refused) || refused.status != http.StatusFound {
		t.Fatalf("err = %v, want statusError 302", err)
	}
	if n := hits.Load(); n != 0 {
		t.Fatalf("destination received %d requests", n)
	}
}
