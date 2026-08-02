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
	"sync/atomic"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/httpapi"
	"private-messenger/server/internal/messaging"
	"private-messenger/server/internal/push"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
	"private-messenger/server/internal/uploads"
	"private-messenger/server/migrations"
)

type App struct {
	Config       config.Config
	Store        *storage.Store
	Hub          *realtime.Hub
	Blobs        uploads.Store
	Push         push.Provider
	limiter      *rateLimiter
	loginBackoff *httpapi.LoginBackoff
	metrics      *httpMetrics
	ready        atomic.Bool
	Log          *slog.Logger
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
	setupRequired, err := store.SetupRequired(ctx)
	if err != nil {
		_ = store.Close()
		return nil, fmt.Errorf("check setup state: %w", err)
	}
	if cfg.Environment == "production" && setupRequired && strings.TrimSpace(cfg.SetupToken) == "" {
		_ = store.Close()
		return nil, errors.New("fresh production instance requires PRIVATE_MESSENGER_SETUP_TOKEN")
	}
	blobs, err := uploads.NewLocalStore(cfg.StoragePath)
	if err != nil {
		_ = store.Close()
		return nil, err
	}
	clientIdentities := httpapi.NewClientIdentityResolver(cfg.TrustedProxies)
	limiter, err := newRateLimiter(clientIdentities, 240, 10, 5)
	if err != nil {
		_ = store.Close()
		return nil, err
	}
	loginBackoff, err := httpapi.NewLoginBackoff()
	if err != nil {
		_ = store.Close()
		return nil, err
	}
	providers := map[string]push.Provider{}
	pushConfigured := cfg.VAPIDSubscriber != "" || cfg.VAPIDPublicKey != "" || cfg.VAPIDPrivateKey != ""
	if pushConfigured {
		provider, err := push.NewWebPushProvider(push.WebPushConfig{
			Subscriber: cfg.VAPIDSubscriber,
			PublicKey:  cfg.VAPIDPublicKey,
			PrivateKey: cfg.VAPIDPrivateKey,
		})
		if err != nil {
			_ = store.Close()
			return nil, fmt.Errorf("configure web push: %w", err)
		}
		providers["webpush"] = provider
	}
	fcmConfigured := cfg.FCMProjectID != "" || cfg.FCMClientEmail != "" || cfg.FCMPrivateKey != ""
	if fcmConfigured {
		provider, err := push.NewFCMProvider(push.FCMConfig{ProjectID: cfg.FCMProjectID,
			ClientEmail: cfg.FCMClientEmail, PrivateKey: cfg.FCMPrivateKey})
		if err != nil {
			_ = store.Close()
			return nil, fmt.Errorf("configure FCM: %w", err)
		}
		providers["fcm"] = provider
	}
	apnsConfigured := cfg.APNsTeamID != "" || cfg.APNsKeyID != "" || cfg.APNsBundleID != "" || cfg.APNsPrivateKey != ""
	if apnsConfigured {
		provider, err := push.NewAPNsProvider(push.APNsConfig{TeamID: cfg.APNsTeamID,
			KeyID: cfg.APNsKeyID, BundleID: cfg.APNsBundleID,
			PrivateKey: cfg.APNsPrivateKey, Sandbox: cfg.Environment != "production"})
		if err != nil {
			_ = store.Close()
			return nil, fmt.Errorf("configure APNs: %w", err)
		}
		providers["apns"] = provider
	}
	pushProvider := push.NewRouter(providers)
	hub := realtime.NewHub()
	metrics := newHTTPMetrics()
	metrics.realtimeConnections = hub.ConnectionCount
	application := &App{
		Config:       cfg,
		Store:        store,
		Hub:          hub,
		Blobs:        blobs,
		Push:         pushProvider,
		limiter:      limiter,
		loginBackoff: loginBackoff,
		metrics:      metrics,
		Log:          logger,
	}
	application.ready.Store(true)
	return application, nil
}

func (a *App) Handler() http.Handler {
	mux := http.NewServeMux()
	pushProviders := make([]string, 0, 3)
	if a.Config.VAPIDPublicKey != "" {
		pushProviders = append(pushProviders, "webpush")
	}
	if a.Config.FCMProjectID != "" {
		pushProviders = append(pushProviders, "fcm")
	}
	if a.Config.APNsTeamID != "" {
		pushProviders = append(pushProviders, "apns")
	}
	api := &httpapi.API{Store: a.Store, Hub: a.Hub, Blobs: a.Blobs, Push: a.Push, PushProviders: pushProviders, VAPIDPublicKey: a.Config.VAPIDPublicKey, TURNURLs: a.Config.TURNURLs, TURNSharedSecret: a.Config.TURNSharedSecret, Log: a.Log, SetupToken: a.Config.SetupToken, DefaultInstanceName: a.Config.InstanceName, Messages: messaging.New(a.Store), ClientIdentities: a.limiter.clientIdentities, LoginBackoff: a.loginBackoff, Ready: a.ready.Load}
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
		a.ready.Store(false)
		a.Hub.Drain()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
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
		if r.URL.Path == "/api/v1/attachments" || r.URL.Path == "/api/v1/backups" ||
			(r.Method == http.MethodGet && (strings.HasPrefix(r.URL.Path, "/api/v1/attachments/") || strings.HasPrefix(r.URL.Path, "/api/v1/backups/"))) {
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
func (a *App) runRetentionSweeper(ctx context.Context) {
	retention := a.Config.SyncRetention
	if retention <= 0 {
		retention = 30 * 24 * time.Hour
	}
	ticker := time.NewTicker(6 * time.Hour)
	defer ticker.Stop()
	sweep := func() {
		if cleaner, ok := a.Blobs.(uploads.TemporaryFileCleaner); ok {
			if removed, err := cleaner.CleanupTemporaryFiles(ctx, time.Now().UTC().Add(-time.Hour)); err != nil {
				a.Log.Warn("temporary_blob_cleanup_failed", "err", err)
			} else if removed > 0 {
				a.Log.Info("temporary_blobs_cleaned", "removed", removed)
			}
		}
		removed, _, err := a.Store.PruneExpiredContent(ctx, time.Now().UTC())
		if err != nil {
			a.Log.Warn("expired_message_prune_failed", "err", err)
		} else if removed > 0 {
			a.Log.Info("expired_messages_pruned", "removed", removed)
		}
		a.reconcileBlobDeletions(ctx)
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

func (a *App) reconcileBlobDeletions(ctx context.Context) {
	storageKeys, err := a.Store.PendingBlobDeletions(ctx, 500)
	if err != nil {
		a.Log.Warn("blob_cleanup_queue_read_failed")
		return
	}
	failed := 0
	for _, storageKey := range storageKeys {
		if err := a.Blobs.Delete(ctx, storageKey); err != nil {
			failed++
			_ = a.Store.RecordBlobDeletionFailure(ctx, storageKey)
			continue
		}
		if err := a.Store.CompleteBlobDeletion(ctx, storageKey); err != nil {
			failed++
		}
	}
	if failed > 0 {
		a.Log.Warn("blob_cleanup_incomplete", "failed_count", failed)
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
		a.metrics.active.Add(1)
		defer a.metrics.active.Add(-1)
		start := time.Now()
		requestID := newRequestID()
		w.Header().Set("X-Request-ID", requestID)
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		a.metrics.record(r.Pattern, rec.status, time.Since(start))
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
	total               atomic.Int64
	active              atomic.Int64
	statusClass         [6]atomic.Int64
	routes              sync.Map
	realtimeConnections func() int
}

type routeMetrics struct {
	total          atomic.Int64
	durationMicros atomic.Int64
	latency        [7]atomic.Int64
}

var latencyBounds = [...]time.Duration{
	10 * time.Millisecond,
	50 * time.Millisecond,
	100 * time.Millisecond,
	500 * time.Millisecond,
	time.Second,
	5 * time.Second,
}

func newHTTPMetrics() *httpMetrics {
	return &httpMetrics{}
}

func (m *httpMetrics) record(pattern string, status int, elapsed time.Duration) {
	m.total.Add(1)
	class := status / 100
	if class >= 1 && class <= 5 {
		m.statusClass[class].Add(1)
	}
	if pattern == "" {
		pattern = "unmatched"
	}
	value, _ := m.routes.LoadOrStore(pattern, &routeMetrics{})
	route := value.(*routeMetrics)
	route.total.Add(1)
	route.durationMicros.Add(elapsed.Microseconds())
	bucket := len(latencyBounds)
	for i, bound := range latencyBounds {
		if elapsed <= bound {
			bucket = i
			break
		}
	}
	for i := bucket; i < len(route.latency); i++ {
		route.latency[i].Add(1)
	}
}

func (m *httpMetrics) handle(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = fmt.Fprint(w, "# TYPE veritra_http_requests_total counter\n")
	_, _ = fmt.Fprintf(w, "veritra_http_requests_total %d\n", m.total.Load())
	_, _ = fmt.Fprint(w, "# TYPE veritra_http_active_requests gauge\n")
	_, _ = fmt.Fprintf(w, "veritra_http_active_requests %d\n", m.active.Load())
	_, _ = fmt.Fprint(w, "# TYPE veritra_http_responses_total counter\n")
	for class := 1; class <= 5; class++ {
		_, _ = fmt.Fprintf(w, "veritra_http_responses_total{status_class=%q} %d\n", strconv.Itoa(class)+"xx", m.statusClass[class].Load())
	}
	_, _ = fmt.Fprint(w, "# TYPE veritra_http_route_requests_total counter\n")
	_, _ = fmt.Fprint(w, "# TYPE veritra_http_request_duration_seconds histogram\n")
	m.routes.Range(func(key, value any) bool {
		pattern := key.(string)
		route := value.(*routeMetrics)
		_, _ = fmt.Fprintf(w, "veritra_http_route_requests_total{route=%q} %d\n", pattern, route.total.Load())
		for i, bound := range latencyBounds {
			_, _ = fmt.Fprintf(w, "veritra_http_request_duration_seconds_bucket{route=%q,le=%q} %d\n", pattern, strconv.FormatFloat(bound.Seconds(), 'f', -1, 64), route.latency[i].Load())
		}
		_, _ = fmt.Fprintf(w, "veritra_http_request_duration_seconds_bucket{route=%q,le=\"+Inf\"} %d\n", pattern, route.latency[len(latencyBounds)].Load())
		_, _ = fmt.Fprintf(w, "veritra_http_request_duration_seconds_sum{route=%q} %s\n", pattern, strconv.FormatFloat(float64(route.durationMicros.Load())/1_000_000, 'f', 6, 64))
		_, _ = fmt.Fprintf(w, "veritra_http_request_duration_seconds_count{route=%q} %d\n", pattern, route.total.Load())
		return true
	})
	if m.realtimeConnections != nil {
		_, _ = fmt.Fprint(w, "# TYPE veritra_realtime_connections gauge\n")
		_, _ = fmt.Fprintf(w, "veritra_realtime_connections %d\n", m.realtimeConnections())
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
	salt             [16]byte
	clientIdentities *httpapi.ClientIdentityResolver
	generalLimit     int
	authLimit        int
	enrollmentLimit  int

	mu      sync.Mutex
	buckets map[string]*bucket
}

type bucket struct {
	general    int
	auth       int
	enrollment int
	reset      time.Time
}

const maxRateLimitEntries = 65536

func newRateLimiter(clientIdentities *httpapi.ClientIdentityResolver, general, auth, enrollment int) (*rateLimiter, error) {
	rl := &rateLimiter{
		clientIdentities: clientIdentities,
		generalLimit:     general,
		authLimit:        auth,
		enrollmentLimit:  enrollment,
		buckets:          map[string]*bucket{},
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
		enrollment := isEnrollmentEndpoint(r.URL.Path)

		rl.mu.Lock()
		b, ok := rl.buckets[key]
		if !ok || b.reset.Before(now) {
			if len(rl.buckets) >= maxRateLimitEntries && !ok {
				rl.mu.Unlock()
				w.Header().Set("Retry-After", "60")
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
		if enrollment {
			b.enrollment++
		}
		overGeneral := b.general > rl.generalLimit
		overAuth := auth && b.auth > rl.authLimit
		overEnrollment := enrollment && b.enrollment > rl.enrollmentLimit
		retryAfter := boundedRetryAfter(b.reset.Sub(now))
		rl.mu.Unlock()

		if overGeneral || overAuth || overEnrollment {
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
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

func isEnrollmentEndpoint(path string) bool {
	return strings.HasSuffix(path, "/enrollment")
}

func (rl *rateLimiter) clientIP(r *http.Request) string {
	return rl.clientIdentities.ClientIP(r)
}

func boundedRetryAfter(duration time.Duration) int {
	seconds := int(duration.Round(time.Second) / time.Second)
	if seconds < 1 {
		return 1
	}
	if seconds > 60 {
		return 60
	}
	return seconds
}

func remoteHash(salt []byte, host string) string {
	sum := sha256.Sum256(append(salt, []byte(host)...))
	return hex.EncodeToString(sum[:])
}
