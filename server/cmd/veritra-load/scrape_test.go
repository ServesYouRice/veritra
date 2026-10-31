package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func metricsServer(t *testing.T, status int, body string) string {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)
	return server.URL
}

func TestScrapeReportsFailures(t *testing.T) {
	good := "# TYPE veritra_go_goroutines gauge\nveritra_go_goroutines 12\nother_metric 1\n"
	values, err := scrape(context.Background(), metricsServer(t, http.StatusOK, good))
	if err != nil || len(values) != 1 || values["veritra_go_goroutines"] != 12 {
		t.Fatalf("good scrape = %v, %v", values, err)
	}
	if values, err := scrape(context.Background(), ""); values != nil || err != nil {
		t.Fatalf("no URL = %v, %v; want nil, nil", values, err)
	}
	if _, err := scrape(context.Background(), metricsServer(t, http.StatusInternalServerError, good)); err == nil {
		t.Fatal("a 500 scrape returned no error")
	}
	long := good + "veritra_padding " + strings.Repeat("9", 2<<20) + "\nveritra_late 1\n"
	if _, err := scrape(context.Background(), metricsServer(t, http.StatusOK, long)); err == nil {
		t.Fatal("a line over the scanner buffer returned no error")
	}
	closed := httptest.NewServer(http.NotFoundHandler())
	closed.Close()
	if _, err := scrape(context.Background(), closed.URL); err == nil {
		t.Fatal("an unreachable endpoint returned no error")
	}
	for _, err := range []error{errScrapeRequest, errScrapeStatus, errScrapeBody} {
		if strings.Contains(err.Error(), "127.0.0.1") || strings.Contains(err.Error(), "http") {
			t.Fatalf("scrape error %q carries a URL", err)
		}
	}
}

func TestServerSummaryOmitsDeltasWithoutBaseline(t *testing.T) {
	after := map[string]float64{
		"veritra_go_goroutines":                                             40,
		`veritra_http_responses_total{status_class="5xx"}`:                  7,
		"veritra_realtime_dropped_events_total":                             3,
		`veritra_sqlite_pool_wait_seconds_total{pool="writer"}`:             90,
		"veritra_sqlite_writer_acquire_duration_seconds_count":              1000,
		"veritra_sqlite_writer_acquire_duration_seconds_sum":                2,
		`veritra_sqlite_writer_acquire_duration_seconds_bucket{le="0.001"}`: 1000,
	}
	server, message := serverMetrics(nil, errScrapeRequest, after, nil, 60)
	if message == "" {
		t.Fatal("a failed baseline left no server_metrics_error")
	}
	if server["go_goroutines"] != 40 {
		t.Fatalf("gauges from a good end-of-window scrape were dropped: %v", server)
	}
	for key := range server {
		if strings.HasSuffix(key, "_delta") || strings.HasPrefix(key, "writer_acquire_") || key == "writer_mean_queue" {
			t.Fatalf("delta-derived %s reported without a baseline: %v", key, server)
		}
	}
	if server, message := serverMetrics(map[string]float64{}, nil, nil, errScrapeStatus, 60); server != nil || message == "" {
		t.Fatalf("failed end-of-window scrape = %v, %q", server, message)
	}

	// With two complete scrapes the deltas are as before: a counter new in
	// the window counts from zero, and a reset counts from zero too.
	before := map[string]float64{`veritra_http_responses_total{status_class="5xx"}`: 2, "veritra_realtime_dropped_events_total": 10}
	server, message = serverMetrics(before, nil, after, nil, 60)
	if message != "" {
		t.Fatalf("message = %q with two good scrapes", message)
	}
	if server["http_5xx_delta"] != 5 || server["realtime_dropped_events_delta"] != 3 || server["writer_mean_queue"] != 1.5 ||
		server["writer_acquire_count_delta"] != 1000 || server["writer_acquire_p99_le_ms"] != 1 {
		t.Fatalf("server = %v", server)
	}
}
