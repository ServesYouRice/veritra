package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
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
	case "backup":
		return backup(ctx, cfg, fs.Args(), stdout)
	case "restore":
		return restore(cfg, fs.Args(), stdout)
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
	hash, err := auth.HashPassword(password)
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

func backup(ctx context.Context, cfg config.Config, args []string, stdout io.Writer) error {
	out := filepath.Join(cfg.DataDir, "backups", "veritra-"+time.Now().UTC().Format("20060102T150405Z"))
	if len(args) > 0 {
		out = args[0]
	}
	if _, err := os.Stat(out); err == nil {
		return errors.New("backup destination already exists")
	} else if !os.IsNotExist(err) {
		return err
	}
	stage := out + ".tmp"
	if err := os.MkdirAll(filepath.Join(stage, "blobs"), 0o700); err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	store, err := storage.Open(ctx, cfg)
	if err != nil {
		return err
	}
	defer store.Close()
	databasePath := filepath.Join(stage, "database.db")
	if err := store.BackupTo(ctx, databasePath); err != nil {
		return err
	}
	if err := os.Chmod(databasePath, 0o600); err != nil {
		return err
	}
	references, migrations, err := storage.ListDatabaseBlobReferences(ctx, databasePath)
	if err != nil {
		return err
	}
	manifest := instanceBackupManifest{Version: "v1", CreatedAt: time.Now().UTC(), DatabaseFile: "database.db", Migrations: migrations, InstanceName: cfg.InstanceName}
	manifest.DatabaseSHA256, _, err = fileSHA256(databasePath)
	if err != nil {
		return err
	}
	for _, reference := range references {
		source := filepath.Join(cfg.StoragePath, filepath.Base(reference.StorageKey))
		destination := filepath.Join(stage, "blobs", filepath.Base(reference.StorageKey))
		if err := copyFile(source, destination, 0o600); err != nil {
			return fmt.Errorf("copy encrypted blob %s: %w", reference.StorageKey, err)
		}
		actualSHA, actualSize, err := fileSHA256(destination)
		if err != nil {
			return err
		}
		if actualSize != reference.SizeBytes || (reference.SHA256 != "" && !strings.EqualFold(actualSHA, reference.SHA256)) {
			return fmt.Errorf("encrypted blob %s failed size/checksum verification", reference.StorageKey)
		}
		manifest.Blobs = append(manifest.Blobs, backupManifestBlob{StorageKey: reference.StorageKey, SHA256: actualSHA, SizeBytes: actualSize})
	}
	manifestBytes, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	manifestFile := filepath.Join(stage, "manifest.json")
	if err := os.WriteFile(manifestFile, append(manifestBytes, '\n'), 0o600); err != nil {
		return err
	}
	if err := os.Rename(stage, out); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "instance backup written: %s\n", out)
	return nil
}

type instanceBackupManifest struct {
	Version        string               `json:"version"`
	CreatedAt      time.Time            `json:"created_at"`
	InstanceName   string               `json:"instance_name"`
	DatabaseFile   string               `json:"database_file"`
	DatabaseSHA256 string               `json:"database_sha256"`
	Migrations     []string             `json:"migrations"`
	Blobs          []backupManifestBlob `json:"blobs"`
}

type backupManifestBlob struct {
	StorageKey string `json:"storage_key"`
	SHA256     string `json:"sha256"`
	SizeBytes  int64  `json:"size_bytes"`
}

func fileSHA256(path string) (string, int64, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer file.Close()
	hash := sha256.New()
	size, err := io.Copy(hash, file)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(hash.Sum(nil)), size, nil
}

func restore(cfg config.Config, args []string, stdout io.Writer) error {
	if len(args) != 1 {
		return errors.New("restore requires path to an instance backup")
	}
	src := args[0]
	info, err := os.Stat(src)
	if err != nil {
		return fmt.Errorf("backup not readable: %w", err)
	}
	var manifest *instanceBackupManifest
	if info.IsDir() {
		loaded, err := readAndValidateBackupManifest(src)
		if err != nil {
			return err
		}
		manifest = &loaded
		src = filepath.Join(src, loaded.DatabaseFile)
	}
	srcAbs, err := filepath.Abs(src)
	if err != nil {
		return err
	}
	dstAbs, err := filepath.Abs(cfg.DatabasePath)
	if err != nil {
		return err
	}
	if srcAbs == dstAbs {
		return errors.New("backup path must differ from the live database")
	}
	if err := os.MkdirAll(filepath.Dir(dstAbs), 0o700); err != nil {
		return err
	}
	stageFile, err := os.CreateTemp(filepath.Dir(dstAbs), ".veritra-restore-*.db")
	if err != nil {
		return err
	}
	stage := stageFile.Name()
	if err := stageFile.Close(); err != nil {
		return err
	}
	_ = os.Remove(stage)
	defer os.Remove(stage)
	if err := copyFile(srcAbs, stage, 0o600); err != nil {
		return fmt.Errorf("stage backup: %w", err)
	}
	if err := storage.ValidateDatabaseFile(context.Background(), stage); err != nil {
		return fmt.Errorf("backup validation failed: %w", err)
	}
	var blobStage string
	if manifest != nil {
		databaseSHA, _, err := fileSHA256(stage)
		if err != nil || !strings.EqualFold(databaseSHA, manifest.DatabaseSHA256) {
			return errors.New("backup database checksum mismatch")
		}
		references, migrations, err := storage.ListDatabaseBlobReferences(context.Background(), stage)
		if err != nil {
			return err
		}
		if strings.Join(migrations, "\x00") != strings.Join(manifest.Migrations, "\x00") || len(references) != len(manifest.Blobs) {
			return errors.New("backup manifest does not match database contents")
		}
		blobStage = cfg.StoragePath + ".restore-tmp"
		if err := os.RemoveAll(blobStage); err != nil {
			return err
		}
		if err := os.MkdirAll(blobStage, 0o700); err != nil {
			return err
		}
		defer os.RemoveAll(blobStage)
		manifestByKey := make(map[string]backupManifestBlob, len(manifest.Blobs))
		for _, blob := range manifest.Blobs {
			if blob.StorageKey == "" || filepath.Base(blob.StorageKey) != blob.StorageKey {
				return errors.New("backup manifest contains an invalid blob key")
			}
			manifestByKey[blob.StorageKey] = blob
		}
		backupRoot := filepath.Dir(src)
		for _, reference := range references {
			blob, ok := manifestByKey[reference.StorageKey]
			if !ok || blob.SizeBytes != reference.SizeBytes || (reference.SHA256 != "" && !strings.EqualFold(blob.SHA256, reference.SHA256)) {
				return fmt.Errorf("backup manifest missing or mismatches blob %s", reference.StorageKey)
			}
			source := filepath.Join(backupRoot, "blobs", blob.StorageKey)
			destination := filepath.Join(blobStage, blob.StorageKey)
			if err := copyFile(source, destination, 0o600); err != nil {
				return err
			}
			sha, size, err := fileSHA256(destination)
			if err != nil || size != blob.SizeBytes || !strings.EqualFold(sha, blob.SHA256) {
				return fmt.Errorf("backup blob %s failed checksum verification", blob.StorageKey)
			}
		}
	}
	if _, err := os.Stat(dstAbs); err == nil {
		probeCtx, cancel := context.WithTimeout(context.Background(), time.Second)
		err := storage.ProbeDatabaseExclusive(probeCtx, dstAbs)
		cancel()
		if err != nil {
			return fmt.Errorf("database appears in use; stop the server before restore: %w", err)
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	rollback := dstAbs + ".pre-restore-" + time.Now().UTC().Format("20060102T150405Z")
	blobRollback := cfg.StoragePath + ".pre-restore-" + time.Now().UTC().Format("20060102T150405Z")
	liveExists := false
	blobsExist := false
	if _, err := os.Stat(dstAbs); err == nil {
		if err := os.Rename(dstAbs, rollback); err != nil {
			return fmt.Errorf("preserve live database: %w", err)
		}
		liveExists = true
	}
	if manifest != nil {
		if _, err := os.Stat(cfg.StoragePath); err == nil {
			if err := os.Rename(cfg.StoragePath, blobRollback); err != nil {
				if liveExists {
					_ = os.Rename(rollback, dstAbs)
				}
				return fmt.Errorf("preserve live blob directory: %w", err)
			}
			blobsExist = true
		} else if !os.IsNotExist(err) {
			return err
		}
	}
	restoreRollback := func(cause error) error {
		_ = os.Remove(dstAbs)
		if manifest != nil {
			_ = os.RemoveAll(cfg.StoragePath)
			if blobsExist {
				if err := os.Rename(blobRollback, cfg.StoragePath); err != nil {
					cause = errors.Join(cause, fmt.Errorf("rollback blob directory: %w", err))
				}
			}
		}
		if liveExists {
			if err := os.Rename(rollback, dstAbs); err != nil {
				return errors.Join(cause, fmt.Errorf("rollback live database: %w", err))
			}
		}
		return cause
	}
	for _, companion := range []string{dstAbs + "-wal", dstAbs + "-shm"} {
		if err := os.Remove(companion); err != nil && !os.IsNotExist(err) {
			return restoreRollback(fmt.Errorf("remove stale SQLite companion %s: %w", companion, err))
		}
	}
	if err := os.Rename(stage, dstAbs); err != nil {
		return restoreRollback(fmt.Errorf("activate staged backup: %w", err))
	}
	if manifest != nil {
		if err := os.Rename(blobStage, cfg.StoragePath); err != nil {
			return restoreRollback(fmt.Errorf("activate staged blob directory: %w", err))
		}
	}
	if err := storage.ValidateDatabaseFile(context.Background(), dstAbs); err != nil {
		return restoreRollback(fmt.Errorf("restored database validation failed: %w", err))
	}
	fmt.Fprintf(stdout, "database restored to: %s\n", cfg.DatabasePath)
	if liveExists {
		fmt.Fprintf(stdout, "previous database preserved for rollback: %s\n", rollback)
	}
	if manifest == nil {
		fmt.Fprintln(stdout, "warning: legacy database-only restore does not include encrypted blobs")
	} else if blobsExist {
		fmt.Fprintf(stdout, "previous blob directory preserved for rollback: %s\n", blobRollback)
	}
	return nil
}

func readAndValidateBackupManifest(root string) (instanceBackupManifest, error) {
	raw, err := os.ReadFile(filepath.Join(root, "manifest.json"))
	if err != nil {
		return instanceBackupManifest{}, err
	}
	if len(raw) > 1<<20 {
		return instanceBackupManifest{}, errors.New("backup manifest is too large")
	}
	var manifest instanceBackupManifest
	if err := json.Unmarshal(raw, &manifest); err != nil {
		return instanceBackupManifest{}, fmt.Errorf("invalid backup manifest: %w", err)
	}
	if manifest.Version != "v1" || manifest.DatabaseFile != filepath.Base(manifest.DatabaseFile) || manifest.DatabaseFile == "" || len(manifest.DatabaseSHA256) != 64 {
		return instanceBackupManifest{}, errors.New("unsupported or invalid backup manifest")
	}
	return manifest, nil
}

func copyFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := out.Sync(); err != nil {
		_ = out.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}

func usage(w io.Writer) {
	fmt.Fprintln(w, "Veritra server")
	fmt.Fprintln(w, "commands: serve, init, migrate, backup, restore, doctor, healthcheck, reset-owner-password, version")
}
