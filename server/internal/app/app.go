package app

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/httpapi"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
	"private-messenger/server/internal/uploads"
	"private-messenger/server/migrations"
)

type App struct {
	Config  config.Config
	Store   *storage.Store
	Hub     *realtime.Hub
	Blobs   *uploads.LocalStore
	limiter *rateLimiter
	metrics *httpMetrics
	Log     *slog.Logger
}

func New(ctx context.Context, cfg config.Config, logger *slog.Logger) (*App, error) {
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{}))
	}
	store, err := storage.Open(ctx, cfg)
	if err != nil {
		return nil, err
	}
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		_ = store.Close()
		return nil, err
	}
	blobs, err := uploads.NewLocalStore(cfg.StoragePath)
	if err != nil {
		_ = store.Close()
		return nil, err
	}
	limiter, err := newRateLimiter(cfg.TrustedProxies, 240, 10)
	if err != nil {
		_ = store.Close()
		return nil, err
	}
	return &App{
		Config:  cfg,
		Store:   store,
		Hub:     realtime.NewHub(),
		Blobs:   blobs,
		limiter: limiter,
		metrics: newHTTPMetrics(),
		Log:     logger,
	}, nil
}

func (a *App) Handler() http.Handler {
	mux := http.NewServeMux()
	api := &httpapi.API{Store: a.Store, Hub: a.Hub, Blobs: a.Blobs, Log: a.Log, SetupToken: a.Config.SetupToken, DefaultInstanceName: a.Config.InstanceName}
	api.Register(mux)
	return securityHeaders(a.requestLogger(a.limiter.middleware(routeTimeouts(mux))))
}

func (a *App) Serve(ctx context.Context) error {
	server := &http.Server{
		Addr:              a.Config.Addr,
		Handler:           a.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       0,
		WriteTimeout:      0,
		IdleTimeout:       120 * time.Second,
	}
	var managementServer *http.Server
	if a.Config.EnableMetrics {
		managementMux := http.NewServeMux()
		managementMux.HandleFunc("GET /metrics", a.metrics.handle)
		managementServer = &http.Server{
			Addr:              a.Config.ManagementAddr,
			Handler:           managementMux,
			ReadHeaderTimeout: 5 * time.Second,
			ReadTimeout:       10 * time.Second,
			WriteTimeout:      10 * time.Second,
			IdleTimeout:       30 * time.Second,
		}
	}
	serveCtx, cancelServe := context.WithCancel(ctx)
	defer cancelServe()
	go func() {
		<-serveCtx.Done()
		a.Hub.Drain()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
		if managementServer != nil {
			_ = managementServer.Shutdown(shutdownCtx)
		}
	}()
	go a.runRetentionSweeper(ctx)
	go a.limiter.cleanupLoop(ctx)
	a.Log.Info("server_starting", "addr", a.Config.Addr)
	errCh := make(chan error, 2)
	go func() { errCh <- server.ListenAndServe() }()
	if managementServer != nil {
		a.Log.Info("management_server_starting", "addr", a.Config.ManagementAddr)
		go func() { errCh <- managementServer.ListenAndServe() }()
	}
	err := <-errCh
	cancelServe()
	if errors.Is(err, http.ErrServerClosed) && ctx.Err() != nil {
		return nil
	}
	return err
}

func routeTimeouts(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/sync/ws" {
			next.ServeHTTP(w, r)
			return
		}
		deadline := 30 * time.Second
		if r.URL.Path == "/api/v1/attachments" || r.URL.Path == "/api/v1/backups" {
			deadline = 15 * time.Minute
		} else if r.URL.Path == "/api/v1/account/export" {
			deadline = 5 * time.Minute
		}
		controller := http.NewResponseController(w)
		until := time.Now().Add(deadline)
		_ = controller.SetReadDeadline(until)
		_ = controller.SetWriteDeadline(until)
		ctx, cancel := context.WithTimeout(r.Context(), deadline)
		defer cancel()
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// runRetentionSweeper periodically prunes expired message envelopes plus
// sync_events and audit_events older than the retention window. The event
// window is 30 days by default and can be overridden via
// PRIVATE_MESSENGER_SYNC_EVENT_RETENTION_DAYS.
func (a *App) runRetentionSweeper(ctx context.Context) {
	retention := 30 * 24 * time.Hour
	if raw := os.Getenv("PRIVATE_MESSENGER_SYNC_EVENT_RETENTION_DAYS"); raw != "" {
		if days, err := strconv.Atoi(raw); err == nil && days > 0 {
			retention = time.Duration(days) * 24 * time.Hour
		}
	}
	ticker := time.NewTicker(6 * time.Hour)
	defer ticker.Stop()
	sweep := func() {
		removed, storageKeys, err := a.Store.PruneExpiredContent(ctx, time.Now().UTC())
		if err != nil {
			a.Log.Warn("expired_message_prune_failed", "err", err)
		} else if removed > 0 {
			a.Log.Info("expired_messages_pruned", "removed", removed)
		}
		for _, storageKey := range storageKeys {
			if err := a.Blobs.Delete(ctx, storageKey); err != nil {
				a.Log.Warn("expired_attachment_blob_cleanup_failed", "err", err)
			}
		}
		if removed, err := a.Store.PruneCallSessions(ctx, time.Now().UTC()); err != nil {
			a.Log.Warn("call_session_prune_failed", "err", err)
		} else if removed > 0 {
			a.Log.Info("call_sessions_pruned", "removed", removed)
		}
		if removed, err := a.Store.PruneOperationalRows(ctx, time.Now().UTC()); err != nil {
			a.Log.Warn("operational_row_prune_failed", "err", err)
		} else if removed > 0 {
			a.Log.Info("operational_rows_pruned", "removed", removed)
		}
		cutoff := time.Now().UTC().Add(-retention)
		if removed, err := a.Store.PruneSyncEvents(ctx, cutoff); err != nil {
			a.Log.Warn("sync_event_prune_failed", "err", err)
		} else if removed > 0 {
			a.Log.Info("sync_events_pruned", "removed", removed)
		}
		if removed, err := a.Store.PruneAuditEvents(ctx, cutoff); err != nil {
			a.Log.Warn("audit_event_prune_failed", "err", err)
		} else if removed > 0 {
			a.Log.Info("audit_events_pruned", "removed", removed)
		}
	}
	sweep()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			sweep()
		}
	}
}

func (a *App) Close() error {
	return a.Store.Close()
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Cross-Origin-Resource-Policy", "same-origin")
		h.Set("Permissions-Policy", "geolocation=(), microphone=(), camera=(), payment=()")
		if strings.HasPrefix(r.URL.Path, "/api/v1/") && r.URL.Path != "/api/v1/health" {
			h.Set("Cache-Control", "no-store, private")
			h.Set("Pragma", "no-cache")
		}
		if r.TLS != nil {
			h.Set("Strict-Transport-Security", "max-age=63072000; includeSubDomains")
		}
		if strings.HasPrefix(r.URL.Path, "/setup") {
			h.Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		}
		next.ServeHTTP(w, r)
	})
}

func (a *App) requestLogger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		requestID := newRequestID()
		w.Header().Set("X-Request-ID", requestID)
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		a.metrics.record(rec.status)
		a.Log.Info("http_request",
			"request_id", requestID,
			"method", r.Method,
			"route", routeClass(r.URL.Path),
			"status", rec.status,
			"duration_ms", time.Since(start).Milliseconds(),
		)
	})
}

type httpMetrics struct {
	mu          sync.Mutex
	total       int64
	statusClass map[string]int64
}

func newHTTPMetrics() *httpMetrics {
	return &httpMetrics{statusClass: map[string]int64{}}
}

func (m *httpMetrics) record(status int) {
	class := strconv.Itoa(status/100) + "xx"
	m.mu.Lock()
	m.total++
	m.statusClass[class]++
	m.mu.Unlock()
}

func (m *httpMetrics) handle(w http.ResponseWriter, r *http.Request) {
	m.mu.Lock()
	total := m.total
	classes := make(map[string]int64, len(m.statusClass))
	for class, count := range m.statusClass {
		classes[class] = count
	}
	m.mu.Unlock()

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = fmt.Fprint(w, "# TYPE veritra_http_requests_total counter\n")
	_, _ = fmt.Fprintf(w, "veritra_http_requests_total %d\n", total)
	_, _ = fmt.Fprint(w, "# TYPE veritra_http_responses_total counter\n")
	for _, class := range []string{"1xx", "2xx", "3xx", "4xx", "5xx"} {
		_, _ = fmt.Fprintf(w, "veritra_http_responses_total{status_class=%q} %d\n", class, classes[class])
	}
}

func newRequestID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "request-id-unavailable"
	}
	return hex.EncodeToString(b[:])
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (r *statusRecorder) Unwrap() http.ResponseWriter {
	return r.ResponseWriter
}

func (r *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	hijacker, ok := r.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, errors.New("hijacking unsupported")
	}
	r.status = http.StatusSwitchingProtocols
	return hijacker.Hijack()
}

func (r *statusRecorder) Flush() {
	if flusher, ok := r.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func routeClass(path string) string {
	switch {
	case path == "/healthz", path == "/setup":
		return path
	case strings.HasPrefix(path, "/api/v1/conversations/"):
		return "/api/v1/conversations/{id}"
	case strings.HasPrefix(path, "/api/v1/messages/"):
		return "/api/v1/messages/{id}"
	case strings.HasPrefix(path, "/api/v1/device-links/"):
		return "/api/v1/device-links/{id}"
	case strings.HasPrefix(path, "/api/v1/communities/"):
		return "/api/v1/communities/{id}"
	case strings.HasPrefix(path, "/api/v1/push/subscriptions/"):
		return "/api/v1/push/subscriptions/{id}"
	case strings.HasPrefix(path, "/api/v1/devices/"):
		return "/api/v1/devices/{id}"
	case strings.HasPrefix(path, "/api/v1/attachments/"):
		return "/api/v1/attachments/{id}"
	case strings.HasPrefix(path, "/api/v1/backups/"):
		return "/api/v1/backups/{id}"
	case strings.HasPrefix(path, "/api/v1/calls/"):
		return "/api/v1/calls/{id}"
	default:
		return path
	}
}

type rateLimiter struct {
	salt           [16]byte
	trustedProxies []*net.IPNet
	generalLimit   int
	authLimit      int

	mu      sync.Mutex
	buckets map[string]*bucket
}

type bucket struct {
	general int
	auth    int
	reset   time.Time
}

const maxRateLimitEntries = 65536

func newRateLimiter(trustedProxies []*net.IPNet, general, auth int) (*rateLimiter, error) {
	rl := &rateLimiter{
		trustedProxies: trustedProxies,
		generalLimit:   general,
		authLimit:      auth,
		buckets:        map[string]*bucket{},
	}
	if _, err := rand.Read(rl.salt[:]); err != nil {
		return nil, err
	}
	return rl, nil
}

func (rl *rateLimiter) cleanupLoop(ctx context.Context) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			rl.mu.Lock()
			for k, b := range rl.buckets {
				if b.reset.Before(now) {
					delete(rl.buckets, k)
				}
			}
			rl.mu.Unlock()
		}
	}
}

func (rl *rateLimiter) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		clientIP := rl.clientIP(r)
		key := remoteHash(rl.salt[:], clientIP)
		now := time.Now()
		auth := isAuthEndpoint(r.URL.Path)

		rl.mu.Lock()
		b, ok := rl.buckets[key]
		if !ok || b.reset.Before(now) {
			if len(rl.buckets) >= maxRateLimitEntries && !ok {
				rl.mu.Unlock()
				http.Error(w, "rate limited", http.StatusTooManyRequests)
				return
			}
			b = &bucket{reset: now.Add(time.Minute)}
			rl.buckets[key] = b
		}
		b.general++
		if auth {
			b.auth++
		}
		overGeneral := b.general > rl.generalLimit
		overAuth := auth && b.auth > rl.authLimit
		rl.mu.Unlock()

		if overGeneral || overAuth {
			http.Error(w, "rate limited", http.StatusTooManyRequests)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func isAuthEndpoint(path string) bool {
	switch path {
	case "/api/v1/setup/owner",
		"/api/v1/auth/login",
		"/api/v1/register",
		"/api/v1/device-links/claim":
		return true
	}
	return strings.HasPrefix(path, "/api/v1/device-links/") && strings.HasSuffix(path, "/claim-status")
}

func (rl *rateLimiter) clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if len(rl.trustedProxies) == 0 {
		return host
	}
	directIP := net.ParseIP(host)
	if directIP == nil || !ipInAny(directIP, rl.trustedProxies) {
		return host
	}
	xff := r.Header.Get("X-Forwarded-For")
	if xff == "" {
		if real := strings.TrimSpace(r.Header.Get("X-Real-IP")); real != "" {
			return real
		}
		return host
	}
	parts := strings.Split(xff, ",")
	for i := len(parts) - 1; i >= 0; i-- {
		candidate := strings.TrimSpace(parts[i])
		if candidate == "" {
			continue
		}
		ip := net.ParseIP(candidate)
		if ip == nil {
			continue
		}
		if !ipInAny(ip, rl.trustedProxies) {
			return candidate
		}
	}
	return strings.TrimSpace(parts[0])
}

func ipInAny(ip net.IP, cidrs []*net.IPNet) bool {
	for _, cidr := range cidrs {
		if cidr.Contains(ip) {
			return true
		}
	}
	return false
}

func remoteHash(salt []byte, host string) string {
	sum := sha256.Sum256(append(salt, []byte(host)...))
	return hex.EncodeToString(sum[:])
}
