package app

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/httpapi"
)

func TestRequestLoggerUsesMatchedPatternAndNeverRawPath(t *testing.T) {
	var logs bytes.Buffer
	application := &App{
		Log:     slog.New(slog.NewTextHandler(&logs, nil)),
		metrics: newHTTPMetrics(),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/recovery", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	sentinel := "AAAA_recovery_sentinel_never_log"
	request := httptest.NewRequest(http.MethodGet, "/api/v1/recovery", nil)
	request.Header.Set("X-Recovery-Token", sentinel)
	application.requestLogger(routeTimeouts(mux)).ServeHTTP(httptest.NewRecorder(), request)
	if strings.Contains(logs.String(), sentinel) {
		t.Fatalf("recovery capability appeared in application log: %s", logs.String())
	}
	if !strings.Contains(logs.String(), `route="GET /api/v1/recovery"`) {
		t.Fatalf("matched route missing from application log: %s", logs.String())
	}

	logs.Reset()
	request = httptest.NewRequest(http.MethodGet, "/api/v1/recovery/"+sentinel, nil)
	application.requestLogger(routeTimeouts(mux)).ServeHTTP(httptest.NewRecorder(), request)
	if strings.Contains(logs.String(), sentinel) || !strings.Contains(logs.String(), "route=unmatched") {
		t.Fatalf("unmatched path was not safely logged: %s", logs.String())
	}
}

func TestHTTPMetricsExposeBoundedOperationalSignals(t *testing.T) {
	metrics := newHTTPMetrics()
	limiter, err := newRateLimiter(nil, 100, 10, 5)
	if err != nil {
		t.Fatalf("new limiter: %v", err)
	}
	metrics.rateLimiter = limiter
	backoff, err := httpapi.NewLoginBackoff()
	if err != nil {
		t.Fatalf("new backoff: %v", err)
	}
	metrics.loginBackoff = backoff
	backoff.Failed("aggregate-only-test", time.Now())
	metrics.realtimeConnections = func() int { return 3 }
	metrics.retentionBacklog.Store(12)
	metrics.retentionOldestAge.Store(3600)
	metrics.push["fcm"].attempted.Store(4)
	metrics.push["fcm"].delivered.Store(3)
	metrics.record("GET /api/v1/conversations/{id}", 503, 75*time.Millisecond)

	recorder := httptest.NewRecorder()
	metrics.handle(recorder, httptest.NewRequest("GET", "/metrics", nil))
	body := recorder.Body.String()
	for _, want := range []string{
		`veritra_http_responses_total{status_class="5xx"} 1`,
		`veritra_http_route_requests_total{route="GET /api/v1/conversations/{id}"} 1`,
		`veritra_http_request_duration_seconds_bucket{route="GET /api/v1/conversations/{id}",le="0.1"} 1`,
		`veritra_realtime_connections 3`,
		`veritra_retention_backlog_rows 12`,
		`veritra_retention_oldest_age_seconds 3600`,
		`veritra_push_deliveries_total{provider="fcm",result="attempted"} 4`,
		`veritra_push_deliveries_total{provider="fcm",result="delivered"} 3`,
		`veritra_rate_limit_buckets 0`,
		`veritra_rate_limit_evictions_total 0`,
		`veritra_login_backoff_entries 1`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("metrics output missing %q:\n%s", want, body)
		}
	}
}
