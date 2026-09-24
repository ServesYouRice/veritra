package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"private-messenger/server/internal/app"
	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/storage"
	"private-messenger/server/internal/uploads"
	"private-messenger/server/migrations"
)

var (
	version = "dev"
	commit  = "unknown"
)

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		usage(stdout)
		return nil
	}
	command := args[0]
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	fs := flag.NewFlagSet(command, flag.ContinueOnError)
	fs.SetOutput(stderr)
	var dbPath string
	var storagePath string
	var recoveryAccount string
	var passwordFile string
	fs.StringVar(&cfg.Addr, "addr", cfg.Addr, "listen address")
	fs.StringVar(&cfg.DataDir, "data-dir", cfg.DataDir, "data directory")
	fs.StringVar(&dbPath, "db", "", "SQLite database path")
	fs.StringVar(&storagePath, "storage", "", "encrypted blob storage path")
	fs.StringVar(&recoveryAccount, "account", "", "owner username for offline recovery")
	fs.StringVar(&passwordFile, "password-file", "", "path to a file containing the new password")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	dataDirFlagSet := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "data-dir" {
			dataDirFlagSet = true
		}
	})
	if dbPath != "" {
		cfg.DatabasePath = dbPath
	} else if dataDirFlagSet && os.Getenv("PRIVATE_MESSENGER_DB_PATH") == "" {
		cfg.DatabasePath = filepath.Join(cfg.DataDir, "private-messenger.db")
	}
	if storagePath != "" {
		cfg.StoragePath = storagePath
	} else if dataDirFlagSet && os.Getenv("PRIVATE_MESSENGER_STORAGE_PATH") == "" {
		cfg.StoragePath = filepath.Join(cfg.DataDir, "blobs")
	}

	ctx := context.Background()
	switch command {
	case "serve", "init", "migrate", "doctor", "backup", "restore", "reset-owner-password":
		// A restore cut short by a crash is settled before anything opens the
		// database (card I45).
		if err := recoverInterruptedRestore(cfg, stdout); err != nil {
			return err
		}
	}
	switch command {
	case "serve":
		return serve(ctx, cfg)
	case "init":
		return initInstance(ctx, cfg, stdout)
	case "migrate":
		return migrate(ctx, cfg, stdout)
	case "doctor":
		return doctor(ctx, cfg, stdout)
	case "healthcheck":
		return healthcheck(cfg)
	case "generate-setup-token":
		return generateSetupToken(stdout)
	case "backup":
		return backup(ctx, cfg, fs.Args(), stdout)
	case "restore":
		return restore(cfg, fs.Args(), stdout)
	case "verify-backup":
		return verifyBackup(ctx, fs.Args(), stdout)
	case "reset-owner-password":
		return resetOwnerPassword(ctx, cfg, recoveryAccount, passwordFile, stdout)
	case "version":
		fmt.Fprintf(stdout, "veritra %s (%s)\n", version, commit)
		return nil
	case "help", "-h", "--help":
		usage(stdout)
		return nil
	default:
		return fmt.Errorf("unknown command %q", command)
	}
}

func generateSetupToken(stdout io.Writer) error {
	token, _, err := auth.NewToken()
	if err != nil {
		return fmt.Errorf("generate setup token: %w", err)
	}
	_, err = fmt.Fprintln(stdout, token)
	return err
}

func resetOwnerPassword(ctx context.Context, cfg config.Config, username, passwordFile string, stdout io.Writer) error {
	if strings.TrimSpace(username) == "" || strings.TrimSpace(passwordFile) == "" {
		return errors.New("reset-owner-password requires --account and --password-file")
	}
	info, err := os.Stat(passwordFile)
	if err != nil {
		return err
	}
	if info.Mode().Perm()&0o077 != 0 {
		return errors.New("password file must not be readable by group or others")
	}
	raw, err := os.ReadFile(passwordFile)
	if err != nil {
		return err
	}
	if len(raw) > 1024 {
		return errors.New("password file is too large")
	}
	password := strings.TrimRight(string(raw), "\r\n")
	cost := cfg.PasswordCost
	if cost == 0 {
		cost = auth.DefaultBcryptCost
	}
	hash, err := auth.HashPasswordWithCost(password, cost)
	if err != nil {
		return fmt.Errorf("new password rejected: %w", err)
	}
	probeCtx, cancel := context.WithTimeout(ctx, time.Second)
	err = storage.ProbeDatabaseExclusive(probeCtx, cfg.DatabasePath)
	cancel()
	if err != nil {
		return fmt.Errorf("database appears in use; stop the server before recovery: %w", err)
	}
	store, err := storage.Open(ctx, cfg)
	if err != nil {
		return err
	}
	defer store.Close()
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		return err
	}
	if err := store.ResetOwnerPassword(ctx, username, hash); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "owner password reset; all existing sessions were revoked")
	return nil
}

func serve(ctx context.Context, cfg config.Config) error {
	if err := cfg.ValidateServe(); err != nil {
		return err
	}
	lock, err := acquireInstanceLock(cfg.DataDir)
	if err != nil {
		return err
	}
	defer lock.Release()
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	level := slog.LevelInfo
	switch cfg.LogLevel {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	}
	options := &slog.HandlerOptions{Level: level}
	var handler slog.Handler = slog.NewTextHandler(os.Stdout, options)
	if cfg.LogFormat == "json" {
		handler = slog.NewJSONHandler(os.Stdout, options)
	}
	logger := slog.New(handler)
	logger.Info("security_posture", "version", version, "commit", commit, "environment", cfg.Environment, "trusted_proxy_networks", len(cfg.TrustedProxies), "metrics_enabled", cfg.EnableMetrics, "log_format", cfg.LogFormat)
	application, err := app.New(ctx, cfg, logger)
	if err != nil {
		return err
	}
	defer application.Close()
	return application.Serve(ctx)
}

func initInstance(ctx context.Context, cfg config.Config, stdout io.Writer) error {
	if err := os.MkdirAll(cfg.DataDir, 0o700); err != nil {
		return err
	}
	if err := os.MkdirAll(cfg.StoragePath, 0o700); err != nil {
		return err
	}
	if err := migrate(ctx, cfg, io.Discard); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "initialized data directory: %s\nsetup status URL: http://localhost%s/api/v1/setup/status\n", cfg.DataDir, cfg.Addr)
	return nil
}

func migrate(ctx context.Context, cfg config.Config, stdout io.Writer) error {
	store, err := storage.Open(ctx, cfg)
	if err != nil {
		return err
	}
	defer store.Close()
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "migrations applied")
	return nil
}

func doctor(ctx context.Context, cfg config.Config, stdout io.Writer) error {
	store, err := storage.Open(ctx, cfg)
	if err != nil {
		return err
	}
	defer store.Close()
	if err := store.Check(ctx); err != nil {
		return err
	}
	if err := store.CheckReady(ctx); err != nil {
		return fmt.Errorf("database readiness: %w", err)
	}
	if err := storage.ValidateDatabaseFile(ctx, cfg.DatabasePath); err != nil {
		return fmt.Errorf("database integrity: %w", err)
	}
	blobs, err := uploads.NewLocalStore(cfg.StoragePath)
	if err != nil {
		return err
	}
	if err := blobs.Check(ctx); err != nil {
		return fmt.Errorf("blob storage readiness: %w", err)
	}
	fmt.Fprintln(stdout, "storage: ok")
	fmt.Fprintln(stdout, "telemetry: disabled")
	if cfg.EnableMetrics {
		fmt.Fprintln(stdout, "local metrics: /metrics")
	} else {
		fmt.Fprintln(stdout, "local metrics: disabled")
	}
	fmt.Fprintln(stdout, "message plaintext persistence: forbidden by schema/API")
	return nil
}

// healthcheck probes the locally running server over HTTP and exits non-zero on
// failure. It is intended as a container HEALTHCHECK: the scratch image ships
// no shell or curl, so the server binary itself performs the probe.
func healthcheck(cfg config.Config) error {
	host, port, err := net.SplitHostPort(cfg.Addr)
	if err != nil {
		return fmt.Errorf("invalid addr %q: %w", cfg.Addr, err)
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	url := "http://" + net.JoinHostPort(host, port) + "/healthz"
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("health check failed: status %d", resp.StatusCode)
	}
	return nil
}

func usage(w io.Writer) {
	fmt.Fprintln(w, "Veritra server")
	fmt.Fprintln(w, "commands: serve, init, migrate, backup, restore, verify-backup, doctor, healthcheck, generate-setup-token, reset-owner-password, version")
}
