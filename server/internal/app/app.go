package app

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"private-messenger/server/internal/admission"
	"private-messenger/server/internal/backupstatus"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/httpapi"
	"private-messenger/server/internal/messaging"
	"private-messenger/server/internal/opmetrics"
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
	budget       *admission.Budget
	// lowDisk is set by the capacity sampler when diskLow.
	lowDisk  atomic.Bool
	inflight atomic.Int64
	// api is the handler set built by Handler; Serve waits for its delivery
	// writes before storage closes.
	api *httpapi.API
	// shutdownBudget and shutdownDrain default to ShutdownBudget and
	// ShutdownDrain; tests shorten them.
	shutdownBudget time.Duration
	shutdownDrain  time.Duration
	// retentionBudget overrides retentionTimeBudget when set; tests lengthen
	// it so slow race-instrumented runs exercise the batch ceiling.
	retentionBudget time.Duration
	// pushSendTimeout and pushRetryDelay default to pushWakeSendTimeout and
	// the jittered backoff; the capacity scenario tests shorten them.
	pushSendTimeout time.Duration
	pushRetryDelay  time.Duration
	Log             *slog.Logger
}

// Shutdown timing (card I46). The whole stop sequence fits inside
// ShutdownBudget, which stays below the supported supervisors' stop grace
// (Compose stop_grace_period and systemd TimeoutStopSec are both 30s), so a
// supervisor never kills the process while storage is still open.
//
//  1. /readyz turns unavailable and realtime sockets are drained.
//  2. In-flight HTTP requests, including uploads, get ShutdownDrain to finish.
//  3. Connections still busy are then closed; their handlers get the rest of
//     the budget to return and run blob cleanup (5s contexts).
//  4. Serve returns and the caller closes storage.
//
// Uploads and downloads keep their 15-minute route deadline in normal
// operation; a transfer that cannot finish within ShutdownDrain is cut off
// and the client retries it after restart.
const (
	ShutdownBudget = 25 * time.Second
	ShutdownDrain  = 18 * time.Second
)

func New(ctx context.Context, cfg config.Config, logger *slog.Logger) (*App, error) {
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{}))
	}
	cfg, storageSource := ResolveInstanceStorage(cfg)
	store, err := storage.Open(ctx, cfg)
	if err != nil {
		return nil, err
	}
	logLimits(logger, store.Limits(), storageSource)
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
	if cfg.Environment == "production" && cfg.SetupToken != "" {
		if err := config.ValidateSetupToken(cfg.SetupToken); err != nil {
			_ = store.Close()
			return nil, err
		}
	}
	blobs, err := uploads.NewLocalStore(cfg.StoragePath)
	if err != nil {
		_ = store.Close()
		return nil, err
	}
	clientIdentities := httpapi.NewClientIdentityResolver(cfg.TrustedProxies)
	requestLimits := rateLimitsFromConfig(cfg.RateLimits)
	limiter, err := newRateLimiter(clientIdentities, requestLimits)
	if err != nil {
		_ = store.Close()
		return nil, err
	}
	logger.Info("rate_limits",
		"address_per_minute", requestLimits.general,
		"account_per_minute", requestLimits.account,
		"signed_in_address_per_minute", requestLimits.signedIn,
		"credential_per_minute", requestLimits.auth,
		"enrollment_per_minute", requestLimits.enrollment,
	)
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
	dataDir := cfg.DataDir
	metrics.backupStatus = func() (backupstatus.Status, bool) { return backupstatus.Read(dataDir) }
	metrics.rateLimiter = limiter
	metrics.loginBackoff = loginBackoff
	metrics.pools = store.PoolStats
	metrics.writerAcquire = store.WriterAcquire
	metrics.hubStats = hub.Stats
	metrics.admission = store.AdmissionCounters()
	application := &App{
		Config:       cfg,
		Store:        store,
		Hub:          hub,
		Blobs:        blobs,
		Push:         pushProvider,
		limiter:      limiter,
		loginBackoff: loginBackoff,
		metrics:      metrics,
		budget:       newBudget(store.Limits(), store.AdmissionCounters()),
		Log:          logger,
	}
	metrics.lowDisk = application.lowDisk.Load
	application.shutdownBudget = ShutdownBudget
	application.shutdownDrain = ShutdownDrain
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
	api := &httpapi.API{Store: a.Store, Hub: a.Hub, Blobs: a.Blobs, Push: a.Push, PushProviders: pushProviders, VAPIDPublicKey: a.Config.VAPIDPublicKey, TURNURLs: a.Config.TURNURLs, TURNSharedSecret: a.Config.TURNSharedSecret, Log: a.Log, SetupToken: a.Config.SetupToken, DefaultInstanceName: a.Config.InstanceName, PasswordCost: a.Config.PasswordCost, Messages: messaging.New(a.Store), ClientIdentities: a.limiter.clientIdentities, LoginBackoff: a.loginBackoff, Ready: a.ready.Load,
		Budget: a.budget, Admission: a.Store.AdmissionCounters(), LowDisk: a.lowDisk.Load, MaxAttachmentBytes: a.Store.Limits().AttachmentBytes}
	api.Register(mux)
	a.api = api
	return a.trackInflight(securityHeaders(a.requestLogger(a.limiter.middleware(routeTimeouts(mux)))))
}

// trackInflight counts running handlers, including hijacked realtime
// sockets that http.Server.Shutdown does not wait for, so Serve can keep
// storage open until they return.
func (a *App) trackInflight(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a.inflight.Add(1)
		defer a.inflight.Add(-1)
		next.ServeHTTP(w, r)
	})
}

func (a *App) waitInflight(deadline time.Time) {
	for a.inflight.Load() > 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
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
	budget, drain := a.shutdownBudget, a.shutdownDrain
	if budget <= 0 {
		budget = ShutdownBudget
	}
	if drain <= 0 || drain > budget {
		drain = min(ShutdownDrain, budget)
	}
	serveCtx, cancelServe := context.WithCancel(ctx)
	defer cancelServe()
	var shutdownDeadline atomic.Pointer[time.Time]
	shutdownDone := make(chan struct{})
	go func() {
		defer close(shutdownDone)
		<-serveCtx.Done()
		start := time.Now()
		deadline := start.Add(budget)
		shutdownDeadline.Store(&deadline)
		a.ready.Store(false)
		a.Hub.Drain()
		drainCtx, cancel := context.WithDeadline(context.Background(), start.Add(drain))
		defer cancel()
		if err := server.Shutdown(drainCtx); err != nil {
			a.Log.Warn("shutdown_drain_incomplete", "in_flight_requests", a.inflight.Load())
			_ = server.Close()
		}
		if managementServer != nil {
			if err := managementServer.Shutdown(drainCtx); err != nil {
				_ = managementServer.Close()
			}
		}
		a.waitInflight(deadline)
	}()
	go a.runRetentionSweeper(serveCtx)
	// Always sampled: the low-disk write guard reads it.
	go a.runCapacitySampler(serveCtx)
	go a.limiter.cleanupLoop(serveCtx)
	go a.loginBackoff.CleanupLoop(serveCtx)
	wakeWorkersDone := make(chan struct{})
	go func() {
		a.runPushWakeWorkers(serveCtx)
		close(wakeWorkersDone)
	}()
	a.Log.Info("server_starting", "addr", a.Config.Addr)
	errCh := make(chan error, 2)
	go func() { errCh <- server.ListenAndServe() }()
	if managementServer != nil {
		a.Log.Info("management_server_starting", "addr", a.Config.ManagementAddr)
		go func() { errCh <- managementServer.ListenAndServe() }()
	}
	err := <-errCh
	cancelServe()
	// One deadline covers the HTTP drain and the push workers, which stop in
	// parallel; neither may push the total past the budget.
	fallback := time.Now().Add(budget)
	budgetTimer := time.NewTimer(budget)
	defer budgetTimer.Stop()
	select {
	case <-shutdownDone:
	case <-budgetTimer.C:
	}
	deadline := fallback
	if started := shutdownDeadline.Load(); started != nil {
		deadline = *started
	}
	workerWait := time.NewTimer(max(time.Until(deadline), 0))
	defer workerWait.Stop()
	select {
	case <-wakeWorkersDone:
	case <-workerWait.C:
	}
	// Delivery writes queued by the last sync pages finish (or time out)
	// before the caller closes storage.
	if a.api != nil {
		a.api.WaitDeliveryWrites(deadline)
	}
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
		if r.URL.Path == "/api/v1/attachments" || r.URL.Path == "/api/v1/backups" || r.URL.Path == "/api/v1/recovery" ||
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
		request := r.WithContext(ctx)
		// ServeMux records the matched pattern on the request it receives. Copy
		// it back so outer metrics/logging middleware cannot fall back to a raw
		// URL path merely because this timeout wrapper added a context. The
		// defer also covers a handler that aborts with a panic.
		defer func() { r.Pattern = request.Pattern }()
		next.ServeHTTP(w, request)
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
		started := time.Now()
		defer func() {
			a.metrics.retentionSweptAt.Store(time.Now().Unix())
			a.metrics.retentionSweepNanos.Store(int64(time.Since(started)))
		}()
		if cleaner, ok := a.Blobs.(uploads.TemporaryFileCleaner); ok {
			if removed, err := cleaner.CleanupTemporaryFiles(ctx, time.Now().UTC().Add(-time.Hour)); err != nil {
				a.Log.Warn("temporary_blob_cleanup_failed", "err", err)
			} else if removed > 0 {
				a.Log.Info("temporary_blobs_cleaned", "removed", removed)
			}
		}
		a.drainExpiredContent(ctx, time.Now().UTC())
		a.reconcileBlobDeletions(ctx)
		a.drainRetention(ctx, "call_sessions", func() (int64, error) {
			return a.Store.PruneCallSessions(ctx, time.Now().UTC())
		})
		a.drainRetention(ctx, "operational_rows", func() (int64, error) {
			return a.Store.PruneOperationalRows(ctx, time.Now().UTC())
		})
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
		a.updateRetentionMetrics(ctx, time.Now().UTC())
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

const (
	retentionBatchSize  = int64(500)
	retentionMaxBatches = 64
	retentionTimeBudget = 10 * time.Second
)

func (a *App) drainExpiredContent(ctx context.Context, now time.Time) {
	started := time.Now()
	var total int64
	for batch := 0; batch < retentionMaxBatches && time.Since(started) < a.retentionTimeLimit(); batch++ {
		if ctx.Err() != nil {
			return
		}
		removed, storageKeys, err := a.Store.PruneExpiredContent(ctx, now)
		if err != nil {
			a.Log.Warn("expired_message_prune_failed", "err", err)
			return
		}
		total += removed
		if removed < retentionBatchSize && int64(len(storageKeys)) < retentionBatchSize {
			break
		}
		if !retentionYield(ctx) {
			return
		}
	}
	if total > 0 {
		a.Log.Info("expired_messages_pruned", "removed", total)
	}
}

func (a *App) drainRetention(ctx context.Context, name string, prune func() (int64, error)) {
	started := time.Now()
	var total int64
	for batch := 0; batch < retentionMaxBatches && time.Since(started) < a.retentionTimeLimit(); batch++ {
		if ctx.Err() != nil {
			return
		}
		removed, err := prune()
		if err != nil {
			a.Log.Warn("retention_prune_failed", "class", name, "err", err)
			return
		}
		total += removed
		if removed < retentionBatchSize {
			break
		}
		if !retentionYield(ctx) {
			return
		}
	}
	if total > 0 {
		a.Log.Info("retention_rows_pruned", "class", name, "removed", total)
	}
}

func (a *App) retentionTimeLimit() time.Duration {
	if a.retentionBudget > 0 {
		return a.retentionBudget
	}
	return retentionTimeBudget
}

func retentionYield(ctx context.Context) bool {
	timer := time.NewTimer(2 * time.Millisecond)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

const (
	pushWakePollInterval = 500 * time.Millisecond
	pushWakeBatchSize    = 64
	pushWakeConcurrency  = 8
	pushWakeLease        = 30 * time.Second
	pushWakeSendTimeout  = 10 * time.Second
)

func (a *App) runPushWakeWorkers(ctx context.Context) {
	if a.Push == nil || a.Store == nil {
		return
	}
	var workers sync.WaitGroup
	for _, provider := range pushMetricProviders {
		provider := provider
		workers.Add(1)
		go func() {
			defer workers.Done()
			a.runPushWakeProvider(ctx, provider)
		}()
	}
	workers.Wait()
}

func (a *App) runPushWakeProvider(ctx context.Context, provider string) {
	ticker := time.NewTicker(pushWakePollInterval)
	defer ticker.Stop()
	for {
		processed := a.drainPushWakeBatch(ctx, provider)
		if ctx.Err() != nil {
			return
		}
		if processed {
			continue
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (a *App) drainPushWakeBatch(ctx context.Context, provider string) bool {
	jobs, abandoned, err := a.Store.ClaimPushWakeJobs(ctx, provider, pushWakeBatchSize, time.Now().UTC(), pushWakeLease)
	metric := a.metrics.push[provider]
	if err != nil {
		if ctx.Err() == nil {
			a.Log.Warn("push_wake_claim_failed", "provider", provider, "err", err)
		}
		return false
	}
	if abandoned > 0 {
		metric.abandoned.Add(abandoned)
	}
	if len(jobs) == 0 {
		a.updatePushWakeMetrics(ctx)
		return abandoned > 0
	}
	jobQueue := make(chan storage.PushWakeJob)
	workerCount := len(jobs)
	if workerCount > pushWakeConcurrency {
		workerCount = pushWakeConcurrency
	}
	var workers sync.WaitGroup
	workers.Add(workerCount)
	for i := 0; i < workerCount; i++ {
		go func() {
			defer workers.Done()
			for job := range jobQueue {
				a.deliverPushWake(ctx, metric, job)
			}
		}()
	}
	for _, job := range jobs {
		select {
		case jobQueue <- job:
		case <-ctx.Done():
			close(jobQueue)
			workers.Wait()
			return true
		}
	}
	close(jobQueue)
	workers.Wait()
	a.updatePushWakeMetrics(ctx)
	return true
}

func (a *App) deliverPushWake(ctx context.Context, metric *pushDeliveryMetrics, job storage.PushWakeJob) {
	freshJob, refreshErr := a.Store.RefreshPushWakeJob(ctx, job, time.Now().UTC())
	if refreshErr != nil {
		if errors.Is(refreshErr, storage.ErrNotFound) {
			dropCtx, dropCancel := context.WithTimeout(ctx, 2*time.Second)
			_ = a.Store.DropPushWakeJob(dropCtx, job)
			dropCancel()
			metric.abandoned.Add(1)
			return
		}
		if errors.Is(refreshErr, context.Canceled) && ctx.Err() != nil {
			return
		}
		metric.failed.Add(1)
		a.Log.Warn("push_wake_refresh_failed", "provider", job.Provider, "err", refreshErr)
		nextAttempt := time.Now().UTC().Add(a.retryDelay(job.Attempts))
		retryCtx, retryCancel := context.WithTimeout(ctx, 2*time.Second)
		_ = a.Store.RetryPushWakeJob(retryCtx, job, nextAttempt, time.Now().UTC())
		retryCancel()
		return
	}
	job = freshJob
	metric.attempted.Add(1)
	sendTimeout := a.pushSendTimeout
	if sendTimeout <= 0 {
		sendTimeout = pushWakeSendTimeout
	}
	sendCtx, cancel := context.WithTimeout(ctx, sendTimeout)
	sendStarted := time.Now()
	err := a.Push.SendEncryptedEventAvailable(sendCtx, push.Notification{
		NotificationMode: job.NotificationMode,
		Provider:         job.Provider,
		Endpoint:         job.Endpoint,
		PublicKey:        job.PublicKey,
		AuthSecret:       job.AuthSecret,
	})
	metric.sendDuration.Observe(time.Since(sendStarted))
	if err != nil && ctx.Err() == nil && errors.Is(sendCtx.Err(), context.DeadlineExceeded) {
		metric.timeouts.Add(1)
	}
	cancel()
	if err == nil {
		// The provider accepted the wake, so it counts as delivered even if
		// the job cannot be removed. The job then stays leased and is sent
		// again after the lease; a repeated generic wake only makes the
		// device sync once more.
		metric.delivered.Add(1)
		completionCtx, completionCancel := context.WithTimeout(ctx, 2*time.Second)
		completeErr := a.Store.CompletePushWakeJob(completionCtx, job)
		completionCancel()
		if completeErr != nil {
			a.Log.Warn("push_wake_completion_failed", "provider", job.Provider, "err", completeErr)
		}
		return
	}
	if errors.Is(err, push.ErrSubscriptionGone) || errors.Is(err, push.ErrInvalidTarget) {
		retireCtx, retireCancel := context.WithTimeout(ctx, 2*time.Second)
		retireErr := a.Store.RetirePushWakeSubscription(retireCtx, job)
		retireCancel()
		if retireErr != nil {
			// The job stays leased and is tried again after the lease, so
			// it is not abandoned yet; the retry retires it.
			metric.failed.Add(1)
			a.Log.Warn("push_wake_retire_failed", "provider", job.Provider, "err", retireErr)
			return
		}
		metric.abandoned.Add(1)
		return
	}
	if errors.Is(err, context.Canceled) && ctx.Err() != nil {
		return
	}
	metric.failed.Add(1)
	nextAttempt := time.Now().UTC().Add(a.retryDelay(job.Attempts))
	retryCtx, retryCancel := context.WithTimeout(ctx, 2*time.Second)
	retryErr := a.Store.RetryPushWakeJob(retryCtx, job, nextAttempt, time.Now().UTC())
	retryCancel()
	if retryErr != nil {
		a.Log.Warn("push_wake_retry_record_failed", "provider", job.Provider, "err", retryErr)
	}
}

func (a *App) retryDelay(attempts int) time.Duration {
	if a.pushRetryDelay > 0 {
		return a.pushRetryDelay
	}
	return pushWakeRetryDelay(attempts)
}

func pushWakeRetryDelay(attempts int) time.Duration {
	if attempts < 1 {
		attempts = 1
	}
	delay := 5 * time.Second
	for i := 1; i < attempts && delay < 5*time.Minute; i++ {
		delay *= 2
		if delay > 5*time.Minute {
			delay = 5 * time.Minute
		}
	}
	jitterLimit := delay / 5
	if jitterLimit <= 0 {
		return delay
	}
	var randomByte [1]byte
	if _, err := rand.Read(randomByte[:]); err != nil {
		return delay
	}
	return delay + time.Duration(int64(jitterLimit)*int64(randomByte[0])/255)
}

func (a *App) updatePushWakeMetrics(ctx context.Context) {
	// On shutdown the read would only fail; the gauge keeps its last value.
	if ctx.Err() != nil {
		return
	}
	backlog, err := a.Store.PushWakeBacklog(ctx, time.Now().UTC())
	if err != nil {
		a.Log.Warn("push_wake_backlog_read_failed", "err", err)
		return
	}
	for _, provider := range pushMetricProviders {
		a.metrics.push[provider].backlog.Store(0)
		a.metrics.push[provider].oldestQueuedAt.Store(0)
	}
	for _, item := range backlog {
		if metric := a.metrics.push[item.Provider]; metric != nil {
			metric.backlog.Store(item.Rows)
			if !item.OldestCreatedAt.IsZero() {
				metric.oldestQueuedAt.Store(item.OldestCreatedAt.Unix())
			}
		}
	}
}

func (a *App) updateRetentionMetrics(ctx context.Context, now time.Time) {
	backlog, err := a.Store.RetentionBacklog(ctx, now)
	if err != nil {
		a.Log.Warn("retention_backlog_read_failed", "err", err)
		return
	}
	a.metrics.retentionBacklog.Store(backlog.Rows)
	a.metrics.retentionOldestAge.Store(backlog.OldestAgeSecond)
}

func (a *App) reconcileBlobDeletions(ctx context.Context) {
	started := time.Now()
	failed := 0
	for batch := 0; batch < retentionMaxBatches && time.Since(started) < a.retentionTimeLimit(); batch++ {
		storageKeys, err := a.Store.PendingBlobDeletions(ctx, 500)
		if err != nil {
			a.Log.Warn("blob_cleanup_queue_read_failed")
			return
		}
		if len(storageKeys) == 0 {
			break
		}
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
		if int64(len(storageKeys)) < retentionBatchSize || !retentionYield(ctx) {
			break
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
		completed := false
		// A handler that does not return normally was aborted: a download
		// stopped by a failed integrity check (panic(http.ErrAbortHandler)),
		// or a panic net/http recovers. It still gets its log line and
		// metrics. Nothing is recovered here, so the panic keeps its value
		// and stack and net/http still breaks the connection.
		defer func() {
			if completed {
				return
			}
			status := rec.status
			if !rec.wroteHeader {
				status = 0 // no status line reached the client
			}
			a.metrics.aborted.Add(1)
			a.logRequest(r, requestID, status, start, "outcome", "aborted")
		}()
		next.ServeHTTP(rec, r)
		completed = true
		a.logRequest(r, requestID, rec.status, start)
	})
}

// logRequest records the request's metrics and writes its log line: the
// matched route pattern, never the raw path, and no headers or body.
func (a *App) logRequest(r *http.Request, requestID string, status int, start time.Time, extra ...any) {
	elapsed := time.Since(start)
	a.metrics.record(r.Pattern, status, elapsed)
	a.Log.Info("http_request", append([]any{
		"request_id", requestID,
		"method", r.Method,
		"route", requestRoute(r.Pattern),
		"status", status,
		"duration_ms", elapsed.Milliseconds(),
	}, extra...)...)
}

type httpMetrics struct {
	total               atomic.Int64
	active              atomic.Int64
	aborted             atomic.Int64
	statusClass         [6]atomic.Int64
	routes              sync.Map
	realtimeConnections func() int
	backupStatus        func() (backupstatus.Status, bool)
	retentionBacklog    atomic.Int64
	retentionOldestAge  atomic.Int64
	push                map[string]*pushDeliveryMetrics
	rateLimiter         *rateLimiter
	loginBackoff        *httpapi.LoginBackoff

	// Capacity signals (card I47); see capacity_metrics.go.
	startedAt           time.Time
	pools               func() (writer, reader sql.DBStats)
	writerAcquire       func() opmetrics.Snapshot
	hubStats            func() realtime.HubStats
	capacity            capacityMetrics
	retentionSweptAt    atomic.Int64
	retentionSweepNanos atomic.Int64
	admission           *admission.Counters
	lowDisk             func() bool
}

type pushDeliveryMetrics struct {
	attempted atomic.Int64
	delivered atomic.Int64
	failed    atomic.Int64
	abandoned atomic.Int64
	backlog   atomic.Int64
	timeouts  atomic.Int64
	// oldestQueuedAt is the unix time the oldest live job was queued, 0
	// when there is none. A timestamp keeps aging in PromQL (time() - x)
	// even if a stuck worker stops refreshing it.
	oldestQueuedAt atomic.Int64
	sendDuration   *opmetrics.Histogram
}

type routeMetrics struct {
	total          atomic.Int64
	durationMicros atomic.Int64
	latency        [len(latencyBounds) + 1]atomic.Int64
}

var latencyBounds = [...]time.Duration{
	10 * time.Millisecond,
	50 * time.Millisecond,
	100 * time.Millisecond,
	250 * time.Millisecond,
	500 * time.Millisecond,
	time.Second,
	5 * time.Second,
}

func newHTTPMetrics() *httpMetrics {
	metrics := &httpMetrics{push: make(map[string]*pushDeliveryMetrics, 3), startedAt: time.Now()}
	for _, provider := range pushMetricProviders {
		metrics.push[provider] = &pushDeliveryMetrics{sendDuration: newPushSendHistogram()}
	}
	return metrics
}

var pushMetricProviders = [...]string{"apns", "fcm", "webpush"}

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
	// Requests whose handler stopped without returning, such as a download
	// cut off by a failed integrity check. They are also in the counts
	// above, with the status they had sent (none: no status class).
	_, _ = fmt.Fprint(w, "# TYPE veritra_http_aborted_requests_total counter\n")
	_, _ = fmt.Fprintf(w, "veritra_http_aborted_requests_total %d\n", m.aborted.Load())
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
	if m.backupStatus != nil {
		// Times and counts only: no path, destination or error text.
		status, recorded := m.backupStatus()
		var lastSuccess, age int64 = 0, -1
		if recorded && status.LastSuccessAt != nil {
			lastSuccess = status.LastSuccessAt.Unix()
			age = int64(time.Since(*status.LastSuccessAt).Seconds())
		}
		_, _ = fmt.Fprint(w, "# TYPE veritra_backup_last_success_timestamp_seconds gauge\n")
		_, _ = fmt.Fprintf(w, "veritra_backup_last_success_timestamp_seconds %d\n", lastSuccess)
		_, _ = fmt.Fprint(w, "# TYPE veritra_backup_last_success_age_seconds gauge\n")
		_, _ = fmt.Fprintf(w, "veritra_backup_last_success_age_seconds %d\n", age)
		_, _ = fmt.Fprint(w, "# TYPE veritra_backup_consecutive_failures gauge\n")
		_, _ = fmt.Fprintf(w, "veritra_backup_consecutive_failures %d\n", status.ConsecutiveFailures)
		var lastAttempt, lastDrill, drillPassed int64
		if recorded && !status.LastAttemptAt.IsZero() {
			lastAttempt = status.LastAttemptAt.Unix()
		}
		if recorded && status.LastDrillAt != nil {
			lastDrill = status.LastDrillAt.Unix()
			if status.LastDrillPassed {
				drillPassed = 1
			}
		}
		_, _ = fmt.Fprint(w, "# TYPE veritra_backup_last_attempt_timestamp_seconds gauge\n")
		_, _ = fmt.Fprintf(w, "veritra_backup_last_attempt_timestamp_seconds %d\n", lastAttempt)
		// The drill timestamp is 0 until a drill is recorded; success is 1
		// only when the last recorded drill passed.
		_, _ = fmt.Fprint(w, "# TYPE veritra_backup_last_restore_drill_timestamp_seconds gauge\n")
		_, _ = fmt.Fprintf(w, "veritra_backup_last_restore_drill_timestamp_seconds %d\n", lastDrill)
		_, _ = fmt.Fprint(w, "# TYPE veritra_backup_last_restore_drill_success gauge\n")
		_, _ = fmt.Fprintf(w, "veritra_backup_last_restore_drill_success %d\n", drillPassed)
	}
	if m.realtimeConnections != nil {
		_, _ = fmt.Fprint(w, "# TYPE veritra_realtime_connections gauge\n")
		_, _ = fmt.Fprintf(w, "veritra_realtime_connections %d\n", m.realtimeConnections())
	}
	_, _ = fmt.Fprint(w, "# TYPE veritra_retention_backlog_rows gauge\n")
	_, _ = fmt.Fprintf(w, "veritra_retention_backlog_rows %d\n", m.retentionBacklog.Load())
	_, _ = fmt.Fprint(w, "# TYPE veritra_retention_oldest_age_seconds gauge\n")
	_, _ = fmt.Fprintf(w, "veritra_retention_oldest_age_seconds %d\n", m.retentionOldestAge.Load())
	_, _ = fmt.Fprint(w, "# TYPE veritra_push_deliveries_total counter\n")
	_, _ = fmt.Fprint(w, "# TYPE veritra_push_backlog_jobs gauge\n")
	for _, provider := range pushMetricProviders {
		metrics := m.push[provider]
		if metrics == nil {
			continue
		}
		_, _ = fmt.Fprintf(w, "veritra_push_deliveries_total{provider=%q,result=\"attempted\"} %d\n", provider, metrics.attempted.Load())
		_, _ = fmt.Fprintf(w, "veritra_push_deliveries_total{provider=%q,result=\"delivered\"} %d\n", provider, metrics.delivered.Load())
		_, _ = fmt.Fprintf(w, "veritra_push_deliveries_total{provider=%q,result=\"failed\"} %d\n", provider, metrics.failed.Load())
		_, _ = fmt.Fprintf(w, "veritra_push_deliveries_total{provider=%q,result=\"abandoned\"} %d\n", provider, metrics.abandoned.Load())
		_, _ = fmt.Fprintf(w, "veritra_push_backlog_jobs{provider=%q} %d\n", provider, metrics.backlog.Load())
	}
	if m.rateLimiter != nil {
		entries, evictions := m.rateLimiter.stats()
		_, _ = fmt.Fprint(w, "# TYPE veritra_rate_limit_buckets gauge\n")
		_, _ = fmt.Fprintf(w, "veritra_rate_limit_buckets %d\n", entries)
		_, _ = fmt.Fprint(w, "# TYPE veritra_rate_limit_evictions_total counter\n")
		_, _ = fmt.Fprintf(w, "veritra_rate_limit_evictions_total %d\n", evictions)
		_, _ = fmt.Fprint(w, "# TYPE veritra_rate_limit_rejections_total counter\n")
		for i, scope := range rateLimitScopes {
			_, _ = fmt.Fprintf(w, "veritra_rate_limit_rejections_total{scope=%q} %d\n", scope, m.rateLimiter.rejections[i].Load())
		}
	}
	if m.loginBackoff != nil {
		entries, evictions := m.loginBackoff.Stats()
		_, _ = fmt.Fprint(w, "# TYPE veritra_login_backoff_entries gauge\n")
		_, _ = fmt.Fprintf(w, "veritra_login_backoff_entries %d\n", entries)
		_, _ = fmt.Fprint(w, "# TYPE veritra_login_backoff_evictions_total counter\n")
		_, _ = fmt.Fprintf(w, "veritra_login_backoff_evictions_total %d\n", evictions)
	}
	m.writeCapacityMetrics(w)
	if m.admission != nil {
		writeAdmissionMetrics(w, m.admission, m.lowDisk != nil && m.lowDisk())
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
	status      int
	wroteHeader bool
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.wroteHeader = true
	r.ResponseWriter.WriteHeader(status)
}

func (r *statusRecorder) Write(p []byte) (int, error) {
	// A body write sends an implicit 200 status line first.
	r.wroteHeader = true
	return r.ResponseWriter.Write(p)
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
	r.wroteHeader = true
	return hijacker.Hijack()
}

func (r *statusRecorder) Flush() {
	_ = r.FlushError()
}

// FlushError is what http.ResponseController calls, so a handler that needs to
// know whether a flush reached the connection (recovery progress) sees the
// error instead of the Flusher interface swallowing it.
func (r *statusRecorder) FlushError() error {
	err := http.NewResponseController(r.ResponseWriter).Flush()
	if !errors.Is(err, http.ErrNotSupported) {
		// Flushing sends the status line (an implicit 200) if none was.
		r.wroteHeader = true
	}
	return err
}

func requestRoute(pattern string) string {
	if pattern == "" {
		return "unmatched"
	}
	return pattern
}

// Request budgets per minute (docs/operations.md, "Credential abuse
// controls"). A request without a session token is charged to its client
// address's general budget. A request with one is admitted on the
// address's signed-in budget, never the general one, and settled once its
// token has been looked up: a valid session is charged to its account's
// budget at that address, a token that does not resolve to the general
// budget. So anonymous requests and stale tokens at an address cannot
// refuse its signed-in people, while token lookups stay bounded per address
// by the signed-in budget. Credential and enrollment routes always stay on
// the address budgets, whatever they carry.
type rateLimits struct {
	// general: requests per address without a session that resolves.
	general int
	// auth and enrollment: credential and enrollment routes per address.
	auth       int
	enrollment int
	// account: requests with a valid session, per account and address.
	account int
	// signedIn: requests carrying a session token, per address.
	signedIn int
}

// The credential and enrollment budgets bound guessing; they are fixed.
const (
	credentialRequestsPerMinute = 10
	enrollmentRequestsPerMinute = 5
)

func rateLimitsFromConfig(limits config.RateLimits) rateLimits {
	limits = limits.WithDefaults()
	return rateLimits{
		general:    limits.AddressPerMinute,
		auth:       credentialRequestsPerMinute,
		enrollment: enrollmentRequestsPerMinute,
		account:    limits.AccountPerMinute,
		signedIn:   limits.SignedInAddressPerMinute,
	}
}

type rateLimiter struct {
	salt             [16]byte
	clientIdentities *httpapi.ClientIdentityResolver
	limits           rateLimits
	// maxEntries bounds each bucket table; it defaults to maxRateLimitEntries
	// and tests lower it.
	maxEntries int

	mu sync.Mutex
	// buckets holds address buckets (every budget of one client address,
	// the credential and enrollment ones included); accountBuckets holds
	// account budgets at an address. They are bounded separately, so one
	// account seen from many addresses (each IPv6 /64 is one) cannot evict
	// other addresses' buckets and reset their credential budgets.
	buckets        map[string]*bucket
	accountBuckets map[string]*bucket
	// overflow and accountOverflow serve keys that arrive while the matching
	// table is full of live buckets that all used a credential budget. Each
	// is sharded by the key's network (overflowShard). They are not table
	// entries.
	overflow        [overflowShards]bucket
	accountOverflow [overflowShards]bucket
	evictions       atomic.Int64
	rejections      [len(rateLimitScopes)]atomic.Int64
}

// rateLimitScopes name the limit a rejected request hit, for metrics only.
var rateLimitScopes = [...]string{"general", "auth", "enrollment", "account", "signed_in"}

const (
	scopeGeneral = iota
	scopeAuth
	scopeEnrollment
	scopeAccount
	scopeSignedIn
)

// bucket counts one key's requests in its current minute. An address key
// uses every field; an account key (account and address) uses general.
type bucket struct {
	general    int
	auth       int
	enrollment int
	signedIn   int
	reset      time.Time
}

// maxRateLimitEntries bounds each of the two bucket tables.
const maxRateLimitEntries = 65536

const rateLimitEvictionSampleSize = 32

func newRateLimiter(clientIdentities *httpapi.ClientIdentityResolver, limits rateLimits) (*rateLimiter, error) {
	rl := &rateLimiter{
		clientIdentities: clientIdentities,
		limits:           limits,
		maxEntries:       maxRateLimitEntries,
		buckets:          map[string]*bucket{},
		accountBuckets:   map[string]*bucket{},
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
			for _, table := range []map[string]*bucket{rl.buckets, rl.accountBuckets} {
				for k, b := range table {
					if b.reset.Before(now) {
						delete(table, k)
					}
				}
			}
			rl.mu.Unlock()
		}
	}
}

// bucketLocked returns key's bucket in table for the current minute,
// starting a new one (and evicting from the same table under pressure)
// when needed. rl.mu must be held.
func (rl *rateLimiter) bucketLocked(table map[string]*bucket, overflow *[overflowShards]bucket, host, key string, now time.Time) *bucket {
	b, ok := table[key]
	if ok && !b.reset.Before(now) {
		return b
	}
	if !ok && len(table) >= rl.maxEntries && !rl.evictOneLocked(table, now) {
		// Every sampled entry is live and has used a credential or
		// enrollment budget, which must not be reset before its minute
		// ends. This key shares the overflow bucket of its network instead
		// (a /48 for IPv6, a /24 for IPv4, salted and hashed into a fixed
		// number of buckets): the cap holds, nothing is forgotten, and one
		// network that fills the table and burns its overflow bucket cannot
		// refuse clients of other networks.
		rl.evictions.Add(1)
		shared := &overflow[rl.overflowShard(host)]
		if shared.reset.Before(now) {
			*shared = bucket{reset: now.Add(time.Minute)}
		}
		return shared
	}
	b = &bucket{reset: now.Add(time.Minute)}
	table[key] = b
	return b
}

// overflowShards is how many overflow buckets each table has.
const overflowShards = 256

// overflowShard picks the overflow bucket for host (as rateLimitHost spells
// it) from its network: a /48 for IPv6, a /24 for IPv4. The salt keeps the
// assignment private to this process.
func (rl *rateLimiter) overflowShard(host string) int {
	network := host
	if prefix, err := netip.ParsePrefix(host); err == nil {
		network = netip.PrefixFrom(prefix.Addr(), 48).Masked().String()
	} else if addr, err := netip.ParseAddr(host); err == nil {
		addr = addr.Unmap()
		if addr.Is4() {
			network = netip.PrefixFrom(addr, 24).Masked().String()
		} else {
			network = netip.PrefixFrom(addr, 48).Masked().String()
		}
	}
	hasher := sha256.New()
	_, _ = hasher.Write(rl.salt[:])
	_, _ = hasher.Write([]byte("overflow\x00"))
	_, _ = hasher.Write([]byte(network))
	sum := hasher.Sum(nil)
	return int(binary.BigEndian.Uint32(sum[:4]) % overflowShards)
}

func (rl *rateLimiter) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := rateLimitHost(rl.clientIP(r))
		now := time.Now()
		class := httpapi.ClassifyRoute(r.URL.Path)
		auth := class == httpapi.CredentialRoute
		enrollment := class == httpapi.EnrollmentRoute
		// A session token on an ordinary route is admitted on the
		// address's signed-in budget alone, so requests without a session
		// there cannot refuse it; accountCharge settles it once the token
		// has been looked up. Public routes never look a token up, so one
		// there would only buy the larger budget.
		signedIn := class == httpapi.OrdinaryRoute && httpapi.HasBearerToken(r)

		rl.mu.Lock()
		b := rl.bucketLocked(rl.buckets, &rl.overflow, host, remoteHash(rl.salt[:], host), now)
		if signedIn {
			b.signedIn++
		} else {
			b.general++
		}
		if auth {
			b.auth++
		}
		if enrollment {
			b.enrollment++
		}
		scope := -1
		switch {
		case auth && b.auth > rl.limits.auth:
			scope = scopeAuth
		case enrollment && b.enrollment > rl.limits.enrollment:
			scope = scopeEnrollment
		case signedIn && b.signedIn > rl.limits.signedIn:
			scope = scopeSignedIn
		case !signedIn && b.general > rl.limits.general:
			scope = scopeGeneral
		}
		retryAfter := boundedRetryAfter(b.reset.Sub(now))
		rl.mu.Unlock()

		if scope >= 0 {
			rl.rejections[scope].Add(1)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			http.Error(w, "rate limited", http.StatusTooManyRequests)
			return
		}
		if !signedIn {
			next.ServeHTTP(w, r)
			return
		}
		charge := &accountCharge{limiter: rl, host: host}
		request := r.WithContext(httpapi.WithRequestBudget(r.Context(), charge))
		// Copy the matched pattern back for the request logger, as
		// routeTimeouts does, and settle a token the route never looked
		// up, also when the handler aborts.
		defer func() {
			r.Pattern = request.Pattern
			charge.settleUnused()
		}()
		next.ServeHTTP(w, request)
	})
}

// accountCharge is the httpapi.RequestBudget of one request with a session
// token. The middleware admitted it on the address's signed-in budget;
// the first of Authenticated, Unauthenticated or settleUnused decides
// which other budget it is charged to.
type accountCharge struct {
	limiter *rateLimiter
	host    string

	done       bool
	ok         bool
	retryAfter int
}

// Authenticated charges the request to the budget of accountID at the
// request's address.
func (c *accountCharge) Authenticated(accountID string) (bool, int) {
	rl := c.limiter
	rl.mu.Lock()
	defer rl.mu.Unlock()
	if !c.done {
		c.settleLocked(rl.accountBuckets, &rl.accountOverflow, rl.accountKey(accountID, c.host), rl.limits.account, scopeAccount)
	}
	return c.ok, c.retryAfter
}

// Unauthenticated charges a request whose token did not resolve to the
// address's general budget, as a request without a session: guessed and
// stale tokens from one address share that budget with anonymous
// requests, and once it is spent they are refused (after their lookup).
func (c *accountCharge) Unauthenticated() (bool, int) {
	rl := c.limiter
	rl.mu.Lock()
	defer rl.mu.Unlock()
	if !c.done {
		c.settleLocked(rl.buckets, &rl.overflow, remoteHash(rl.salt[:], c.host), rl.limits.general, scopeGeneral)
	}
	return c.ok, c.retryAfter
}

// settleUnused charges a request whose route never looked its token up (a
// public route, or no route) to the general budget once it has been
// served, as one without a session.
func (c *accountCharge) settleUnused() {
	rl := c.limiter
	rl.mu.Lock()
	defer rl.mu.Unlock()
	if !c.done {
		c.settleLocked(rl.buckets, &rl.overflow, remoteHash(rl.salt[:], c.host), rl.limits.general, -1)
	}
}

// settleLocked charges key's general count in table for the current minute
// against limit, counting a refusal under scope unless it is -1. rl.mu
// must be held.
func (c *accountCharge) settleLocked(table map[string]*bucket, overflow *[overflowShards]bucket, key string, limit, scope int) {
	rl := c.limiter
	now := time.Now()
	c.done = true
	b := rl.bucketLocked(table, overflow, c.host, key, now)
	b.general++
	c.ok = b.general <= limit
	c.retryAfter = boundedRetryAfter(b.reset.Sub(now))
	if !c.ok && scope >= 0 {
		rl.rejections[scope].Add(1)
	}
}

// accountKey keys an account's budget at one client address. Like address
// keys it is a salted hash, so the table holds no identifiers.
func (rl *rateLimiter) accountKey(accountID, host string) string {
	hasher := sha256.New()
	_, _ = hasher.Write(rl.salt[:])
	_, _ = hasher.Write([]byte("account\x00"))
	_, _ = hasher.Write([]byte(accountID))
	_, _ = hasher.Write([]byte{0})
	_, _ = hasher.Write([]byte(host))
	return hex.EncodeToString(hasher.Sum(nil))
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
	host = rateLimitHost(host)
	hasher := sha256.New()
	_, _ = hasher.Write(salt)
	_, _ = hasher.Write([]byte(host))
	sum := hasher.Sum(nil)
	return hex.EncodeToString(sum[:])
}

func rateLimitHost(host string) string {
	host = strings.TrimSpace(host)
	if ip := net.ParseIP(host); ip != nil {
		if ipv4 := ip.To4(); ipv4 != nil {
			return ipv4.String()
		}
		if ipv6 := ip.To16(); ipv6 != nil {
			return net.IP(ipv6).Mask(net.CIDRMask(64, 128)).String() + "/64"
		}
	}
	return host
}

// evictOneLocked makes room in a full table and reports whether it did.
// Expired buckets go first. Otherwise, of up to rateLimitEvictionSampleSize
// live buckets it evicts the least used one that has used no credential
// (auth) and no enrollment budget: those two are what bound password and
// code guessing and must not reset before their minute ends, but a bucket
// with only ordinary request counts costs its owner little to lose. If every
// sampled bucket has used a credential budget nothing is evicted and the
// caller falls back to the network's overflow bucket.
func (rl *rateLimiter) evictOneLocked(table map[string]*bucket, now time.Time) bool {
	if len(table) < rl.maxEntries {
		return true
	}
	sampled := 0
	var victim string
	victimLoad, found := 0, false
	for key, b := range table {
		if !b.reset.After(now) {
			delete(table, key)
			if len(table) < rl.maxEntries {
				return true
			}
			continue
		}
		if b.auth == 0 && b.enrollment == 0 {
			if load := b.general + b.signedIn; !found || load < victimLoad {
				victim, victimLoad, found = key, load, true
			}
		}
		sampled++
		if sampled >= rateLimitEvictionSampleSize {
			break
		}
	}
	if !found {
		return false
	}
	delete(table, victim)
	rl.evictions.Add(1)
	return true
}

// stats reports the entries of both tables together and how many times a new
// key found its table full of live buckets: veritra_rate_limit_evictions_total
// counts each, whether a bucket with no credential use was evicted to make
// room or the key was admitted through its network's overflow bucket.
func (rl *rateLimiter) stats() (entries int, evictions int64) {
	rl.mu.Lock()
	entries = len(rl.buckets) + len(rl.accountBuckets)
	rl.mu.Unlock()
	return entries, rl.evictions.Load()
}
