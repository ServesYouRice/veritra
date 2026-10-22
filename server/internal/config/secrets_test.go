package config

import (
	"bytes"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const sentinelSecret = "sentinel-turn-secret-5b1f0c"

func writeSecret(t *testing.T, content string, mode os.FileMode) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadReadsSecretsFromFiles(t *testing.T) {
	t.Setenv("PRIVATE_MESSENGER_TURN_URLS", "turns://turn.example.org:5349")
	t.Setenv("PRIVATE_MESSENGER_TURN_SHARED_SECRET_FILE", writeSecret(t, sentinelSecret+"\n", 0o400))
	t.Setenv("PRIVATE_MESSENGER_VAPID_PRIVATE_KEY_FILE", writeSecret(t, "vapid-private\r\n", 0o400))
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.TURNSharedSecret != sentinelSecret {
		t.Fatalf("TURN secret was not read from its file")
	}
	if cfg.VAPIDPrivateKey != "vapid-private" {
		t.Fatalf("trailing CRLF was not trimmed")
	}
}

func TestSecretFilesKeepMultilinePEM(t *testing.T) {
	pem := "-----BEGIN PRIVATE KEY-----\nAAAA\nBBBB\n-----END PRIVATE KEY-----\n"
	t.Setenv("PRIVATE_MESSENGER_APNS_PRIVATE_KEY_FILE", writeSecret(t, pem, 0o400))
	value, err := secretEnv("PRIVATE_MESSENGER_APNS_PRIVATE_KEY")
	if err != nil {
		t.Fatal(err)
	}
	if value != strings.TrimSuffix(pem, "\n") {
		t.Fatalf("PEM body changed")
	}
}

func TestSecretFileErrorsNeverContainTheSecret(t *testing.T) {
	directory := t.TempDir()
	oversized := writeSecret(t, sentinelSecret+strings.Repeat("x", MaxSecretFileBytes), 0o400)
	cases := map[string]struct {
		direct, file, want string
	}{
		"both set":  {direct: sentinelSecret, file: writeSecret(t, sentinelSecret, 0o400), want: "both set"},
		"missing":   {file: filepath.Join(directory, "absent"), want: "open secret file"},
		"directory": {file: directory, want: "not a regular file"},
		"empty":     {file: writeSecret(t, "\n", 0o400), want: "is empty"},
		"oversized": {file: oversized, want: "exceeds"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Setenv("PRIVATE_MESSENGER_TURN_URLS", "turn://turn.example.org:3478")
			t.Setenv("PRIVATE_MESSENGER_TURN_SHARED_SECRET", tc.direct)
			t.Setenv("PRIVATE_MESSENGER_TURN_SHARED_SECRET_FILE", tc.file)
			_, err := Load()
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error=%v want %q", err, tc.want)
			}
			if !strings.Contains(err.Error(), "PRIVATE_MESSENGER_TURN_SHARED_SECRET") {
				t.Fatalf("error does not name the setting: %v", err)
			}
			if strings.Contains(err.Error(), sentinelSecret) {
				t.Fatal("error contains the secret value")
			}
		})
	}
}

func TestConfigOutputRedactsSecrets(t *testing.T) {
	cfg := Config{
		Addr:             "127.0.0.1:8080",
		SetupToken:       sentinelSecret + "-setup",
		VAPIDPrivateKey:  sentinelSecret + "-vapid",
		FCMPrivateKey:    sentinelSecret + "-fcm",
		APNsPrivateKey:   sentinelSecret + "-apns",
		TURNSharedSecret: sentinelSecret + "-turn",
	}
	var logs bytes.Buffer
	slog.New(slog.NewJSONHandler(&logs, nil)).Info("config", "cfg", cfg)
	slog.New(slog.NewTextHandler(&logs, nil)).Info("config", "cfg", &cfg)
	outputs := []string{
		fmt.Sprint(cfg), fmt.Sprintf("%v", &cfg), fmt.Sprintf("%+v", cfg),
		fmt.Sprintf("%#v", cfg), fmt.Sprintf("%s", cfg), logs.String(),
	}
	for _, output := range outputs {
		if strings.Contains(output, sentinelSecret) {
			t.Fatalf("secret in config output: %s", output)
		}
	}
	if !strings.Contains(outputs[0], "127.0.0.1:8080") || !strings.Contains(outputs[0], "[redacted]") {
		t.Fatalf("unexpected config output: %s", outputs[0])
	}
}
