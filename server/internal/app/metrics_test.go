package app

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHTTPMetricsExposeBoundedOperationalSignals(t *testing.T) {
	metrics := newHTTPMetrics()
	metrics.realtimeConnections = func() int { return 3 }
	metrics.record("GET /api/v1/conversations/{id}", 503, 75*time.Millisecond)

	recorder := httptest.NewRecorder()
	metrics.handle(recorder, httptest.NewRequest("GET", "/metrics", nil))
	body := recorder.Body.String()
	for _, want := range []string{
		`veritra_http_responses_total{status_class="5xx"} 1`,
		`veritra_http_route_requests_total{route="GET /api/v1/conversations/{id}"} 1`,
		`veritra_http_request_duration_seconds_bucket{route="GET /api/v1/conversations/{id}",le="0.1"} 1`,
		`veritra_realtime_connections 3`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("metrics output missing %q:\n%s", want, body)
		}
	}
}

