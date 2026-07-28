package app

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
)

func TestProductionSetupTokenIsRequiredOnlyUntilOwnerExists(t *testing.T) {
	ctx := context.Background()
	cfg := deploymentConfig(t)
	cfg.Environment = "production"
	if application, err := New(ctx, cfg, nil); err == nil {
		application.Close()
		t.Fatal("fresh production instance started without setup token")
	}

	cfg.Environment = "development"
	application, err := New(ctx, cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	reservation, err := application.Store.ReserveOwnerEnrollment(ctx)
	if err != nil {
		t.Fatal(err)
	}
	passwordHash, err := auth.HashPassword("owner-password-123")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := application.Store.CreateOwner(ctx, storage.CreateOwnerInput{
		EnrollmentReservationID: reservation.ID,
		InstanceName:            "Deployment Test",
		Username:                "owner",
		PasswordHash:            passwordHash,
		DeviceName:              "owner device",
		KeyPackage:              []byte("synthetic-key-package"),
	}); err != nil {
		t.Fatal(err)
	}
	if err := application.Close(); err != nil {
		t.Fatal(err)
	}

	cfg.Environment = "production"
	application, err = New(ctx, cfg, nil)
	if err != nil {
		t.Fatalf("initialized production instance required stale setup token: %v", err)
	}
	application.Close()
}

func TestReadinessFailsBeforeGracefulDrain(t *testing.T) {
	application, err := New(context.Background(), deploymentConfig(t), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer application.Close()

	request := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	recorder := httptest.NewRecorder()
	application.Handler().ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("ready status=%d", recorder.Code)
	}
	application.ready.Store(false)
	recorder = httptest.NewRecorder()
	application.Handler().ServeHTTP(recorder, request)
	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("draining readiness status=%d", recorder.Code)
	}
	live := httptest.NewRecorder()
	application.Handler().ServeHTTP(live, httptest.NewRequest(http.MethodGet, "/livez", nil))
	if live.Code != http.StatusOK {
		t.Fatalf("draining liveness status=%d", live.Code)
	}
}

func TestServeCancellationDrainsRealtimeAndStopsListener(t *testing.T) {
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
	ctx, cancel := context.WithCancel(context.Background())
	serveDone := make(chan error, 1)
	go func() { serveDone <- application.Serve(ctx) }()

	client := &http.Client{Timeout: time.Second}
	deadline := time.Now().Add(3 * time.Second)
	for {
		response, requestErr := client.Get("http://" + addr + "/readyz")
		if requestErr == nil {
			response.Body.Close()
			if response.StatusCode == http.StatusOK {
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatal("server did not become ready")
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	select {
	case err := <-serveDone:
		if err != nil {
			t.Fatalf("graceful serve returned: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("graceful shutdown timed out")
	}
	if application.ready.Load() {
		t.Fatal("application remained ready after cancellation")
	}
	if _, err := application.Hub.Register("account", "device", "127.0.0.1"); err != realtime.ErrHubDraining {
		t.Fatalf("realtime registration after shutdown error=%v", err)
	}
}

func deploymentConfig(t *testing.T) config.Config {
	t.Helper()
	dir := t.TempDir()
	return config.Config{
		Addr:          "127.0.0.1:0",
		DataDir:       dir,
		DatabasePath:  filepath.Join(dir, "private-messenger.db"),
		StoragePath:   filepath.Join(dir, "blobs"),
		InstanceName:  "Deployment Test",
		Environment:   "development",
		SyncRetention: 30 * 24 * time.Hour,
	}
}
