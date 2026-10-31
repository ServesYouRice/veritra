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
	"runtime"
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
	fs.StringVar(&passwordFile, "password-file", "", "path to a file containing the new password; it must not be readable by group or others (not checked on Windows, where its ACL is not checked either)")
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
	case "serve", "init", "migrate", "doctor", "backup", "scheduled-backup", "restore", "reset-owner-password":
		// Every storage command works on canonical paths, so overlapping or
		// symlinked overrides are rejected and locked as one resource (I46).
		if cfg, err = cfg.ResolvePaths(); err != nil {
			return err
		}
		// A restore cut short by a crash is settled before anything opens the
		// database (card I45). Settling takes the server's locks itself, and
		// only when there is a journal, so the online commands stay lock-free.
		if err := recoverInterruptedRestore(cfg, stdout); err != nil {
			return err
		}
	}
	switch command {
	case "init", "migrate":
		// They write the database, so like serve they hold the data-directory
		// and resource locks for the whole command. verify-backup's drill
		// calls migrate() directly on its own scratch instance, unlocked.
		locks, err := acquireWriterLocks(cfg)
		if err != nil {
			return err
		}
		defer locks.Release()
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
		err := verifyBackup(ctx, cfg, fs.Args(), stdout)
		if len(fs.Args()) == 1 {
			recordStandaloneDrill(cfg, err == nil, time.Now(), stderr)
		}
		return err
	case "scheduled-backup":
		options, err := scheduledBackupOptionsFromEnv(cfg)
		if err != nil {
			return err
		}
		return scheduledBackup(ctx, cfg, options, stdout)
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
	password, err := readPasswordFile(passwordFile)
	if err != nil {
		return err
	}
	hash, err := auth.HashPasswordContext(ctx, auth.Anonymous, password)
	if err != nil {
		return fmt.Errorf("new password rejected: %w", err)
	}
	// Look for the database first: taking the locks creates the data directory
	// and their files, which a mistyped path must not leave behind.
	if _, err := os.Stat(cfg.DatabasePath); err != nil {
		return fmt.Errorf("no database to recover at %s: %w", cfg.DatabasePath, err)
	}
	server, err := acquireServerExclusion(cfg)
	if err != nil {
		return fmt.Errorf("a server appears to be running; stop the server before recovery: %w", err)
	}
	defer server.Release()
	blobs, err := lockExistingBlobStorage(cfg)
	if err != nil {
		return fmt.Errorf("a server appears to be running; stop the server before recovery: %w", err)
	}
	defer blobs.Release()
	if err := requireSettledRestore(cfg); err != nil {
		return err
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

// maxPasswordFileBytes bounds the password file reset-owner-password reads.
const maxPasswordFileBytes = 1024

// readPasswordFile reads a private, regular password file of at most
// maxPasswordFileBytes, without trailing line breaks. A FIFO or device is
// refused from its metadata, before an open could block on it, and the size
// is checked before anything is read.
func readPasswordFile(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", errors.New("password file must be a regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return "", err
	}
	if !os.SameFile(info, opened) {
		return "", errors.New("password file changed while it was opened")
	}
	if !passwordFileModeAllowed(runtime.GOOS, opened.Mode()) {
		return "", errors.New("password file must not be readable by group or others")
	}
	if opened.Size() > maxPasswordFileBytes {
		return "", errors.New("password file is too large")
	}
	raw, err := io.ReadAll(io.LimitReader(file, maxPasswordFileBytes+1))
	if err != nil {
		return "", err
	}
	if len(raw) > maxPasswordFileBytes {
		return "", errors.New("password file is too large")
	}
	return strings.TrimRight(string(raw), "\r\n"), nil
}

// passwordFileModeAllowed reports whether a password file's mode keeps it
// private. On Windows, Go derives the mode from the read-only attribute
// alone (0666 or 0444), which says nothing about who may read the file, so
// it is not checked there; the file's ACL is not checked either (bug-hunt
// Q-003).
func passwordFileModeAllowed(goos string, mode os.FileMode) bool {
	if goos == "windows" {
		return true
	}
	return mode.Perm()&0o077 == 0
}

func serve(ctx context.Context, cfg config.Config) error {
	if err := cfg.ValidateServe(); err != nil {
		return err
	}
	locks, err := acquireWriterLocks(cfg)
	if err != nil {
		return err
	}
	defer locks.Release()
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
	cfg, limitSource := app.ResolveInstanceStorage(cfg)
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
	reportStorageLimit(ctx, store, limitSource, stdout)
	fmt.Fprintln(stdout, "telemetry: disabled")
	if cfg.EnableMetrics {
		fmt.Fprintln(stdout, "local metrics: /metrics")
	} else {
		fmt.Fprintln(stdout, "local metrics: disabled")
	}
	fmt.Fprintln(stdout, "message plaintext persistence: forbidden by schema/API")
	return nil
}

// reportStorageLimit prints blob usage against the instance storage limit
// (T49D) and warns when uploads are already refused, for example after an
// upgrade lowered the default on a small volume.
func reportStorageLimit(ctx context.Context, store *storage.Store, source string, stdout io.Writer) {
	used, err := store.BlobUsageBytes(ctx)
	if err != nil {
		return
	}
	limit := store.Limits().InstanceStorageBytes
	fmt.Fprintf(stdout, "encrypted storage: %d MiB of %d MiB instance limit (%s)\n", used>>20, limit>>20, source)
	if used >= limit {
		fmt.Fprintln(stdout, "warning: stored blobs reach the instance storage limit; uploads are refused until usage falls or PRIVATE_MESSENGER_LIMIT_INSTANCE_STORAGE_MIB is raised")
	}
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
	fmt.Fprintln(w, "commands: serve, init, migrate, backup, restore, verify-backup, scheduled-backup, doctor, healthcheck, generate-setup-token, reset-owner-password, version")
}
