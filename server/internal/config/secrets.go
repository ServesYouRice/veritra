package config

import (
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
)

// MaxSecretFileBytes bounds a *_FILE secret read. The largest supported
// secret is a PEM private key, which is well under this size.
const MaxSecretFileBytes = 64 << 10

// secretEnv returns the value of a secret setting. The value comes either
// from KEY or from the file named by KEY_FILE (Compose secrets, systemd
// LoadCredential). Setting both is ambiguous and rejected. Errors name the
// variable and, for file problems, the path; never the secret.
func secretEnv(key string) (string, error) {
	direct := strings.TrimSpace(os.Getenv(key))
	path := strings.TrimSpace(os.Getenv(key + "_FILE"))
	if path == "" {
		return direct, nil
	}
	if direct != "" {
		return "", fmt.Errorf("%s and %s_FILE are both set; configure only one", key, key)
	}
	value, err := readSecretFile(path)
	if err != nil {
		return "", fmt.Errorf("%s_FILE: %w", key, err)
	}
	return value, nil
}

func readSecretFile(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("open secret file %q: %w", path, pathCause(err))
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", fmt.Errorf("stat secret file %q: %w", path, pathCause(err))
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("secret file %q is not a regular file", path)
	}
	raw, err := io.ReadAll(io.LimitReader(file, MaxSecretFileBytes+1))
	if err != nil {
		return "", fmt.Errorf("read secret file %q: %w", path, pathCause(err))
	}
	if len(raw) > MaxSecretFileBytes {
		return "", fmt.Errorf("secret file %q exceeds %d bytes", path, MaxSecretFileBytes)
	}
	value := strings.TrimSpace(strings.TrimRight(string(raw), "\r\n"))
	if value == "" {
		return "", fmt.Errorf("secret file %q is empty", path)
	}
	return value, nil
}

// pathCause strips the *os.PathError wrapper so the path is not repeated.
func pathCause(err error) error {
	var pathErr *os.PathError
	if errors.As(err, &pathErr) {
		return pathErr.Err
	}
	return err
}

func redact(value string) string {
	if value == "" {
		return ""
	}
	return "[redacted]"
}

// String keeps accidental fmt output of a Config free of secrets.
func (c Config) String() string {
	return fmt.Sprintf("Config{Addr:%q DataDir:%q DatabasePath:%q StoragePath:%q Environment:%q SetupToken:%q VAPIDPrivateKey:%q FCMPrivateKey:%q APNsPrivateKey:%q TURNSharedSecret:%q}",
		c.Addr, c.DataDir, c.DatabasePath, c.StoragePath, c.Environment,
		redact(c.SetupToken), redact(c.VAPIDPrivateKey), redact(c.FCMPrivateKey), redact(c.APNsPrivateKey), redact(c.TURNSharedSecret))
}

// GoString covers %#v, which would otherwise print every field.
func (c Config) GoString() string { return c.String() }

// LogValue keeps a Config handed to slog free of secrets.
func (c Config) LogValue() slog.Value {
	return slog.GroupValue(
		slog.String("addr", c.Addr),
		slog.String("data_dir", c.DataDir),
		slog.String("database_path", c.DatabasePath),
		slog.String("storage_path", c.StoragePath),
		slog.String("environment", c.Environment),
		slog.Bool("setup_token_set", c.SetupToken != ""),
		slog.Bool("turn_configured", c.TURNSharedSecret != ""),
	)
}
