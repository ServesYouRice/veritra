package config

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net"
	"net/url"
	"os"
	"regexp"
	"strings"
)

// PasskeyAndroidApp is one Android app that may use passkeys with this
// server: its package name and the SHA-256 fingerprint of its signing
// certificate (32 bytes).
type PasskeyAndroidApp struct {
	Package     string
	Fingerprint [32]byte
}

// Origin is the origin Android reports for the app:
// android:apk-key-hash:<base64url(SHA-256(cert))>, unpadded.
func (a PasskeyAndroidApp) Origin() string {
	return "android:apk-key-hash:" + base64.RawURLEncoding.EncodeToString(a.Fingerprint[:])
}

// FingerprintText is the colon-separated upper-case form assetlinks.json uses.
func (a PasskeyAndroidApp) FingerprintText() string {
	parts := make([]string, len(a.Fingerprint))
	for i, b := range a.Fingerprint {
		parts[i] = strings.ToUpper(hex.EncodeToString([]byte{b}))
	}
	return strings.Join(parts, ":")
}

// PasskeyConfig is the operator's passkey setting (B7, docs/designs/B7-passkeys.md).
type PasskeyConfig struct {
	Enabled bool
	// RPID is the host of the public origin, never a Host header.
	RPID        string
	Origin      string
	AndroidApps []PasskeyAndroidApp
	AppleAppIDs []string
}

var (
	androidPackagePattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$`)
	appleAppIDPattern     = regexp.MustCompile(`^[A-Z0-9]{10}\.[A-Za-z0-9][A-Za-z0-9.\-]*$`)
	maxPasskeyApps        = 20
)

func loadPasskeys(cfg *Config) error {
	mode := strings.ToLower(strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_PASSKEYS")))
	switch mode {
	case "", "off":
		return nil
	case "on":
	default:
		return fmt.Errorf("PRIVATE_MESSENGER_PASSKEYS must be off or on")
	}
	passkeys, err := ParsePasskeys(cfg.PublicOrigin, os.Getenv("PRIVATE_MESSENGER_PASSKEY_ANDROID_APPS"), os.Getenv("PRIVATE_MESSENGER_PASSKEY_APPLE_APP_IDS"))
	if err != nil {
		return err
	}
	cfg.Passkeys = passkeys
	return nil
}

// ParsePasskeys validates a passkey-on setup. The public origin must be a
// valid https origin with a DNS host name that has a dot and no port: iOS
// and Windows authenticators report https://<rpid> with no port, so a port
// would make every assertion fail.
func ParsePasskeys(origin, androidApps, appleAppIDs string) (PasskeyConfig, error) {
	if origin == "" || !ValidPublicOrigin(origin) {
		return PasskeyConfig{}, fmt.Errorf("PRIVATE_MESSENGER_PASSKEYS=on needs a valid PRIVATE_MESSENGER_PUBLIC_ORIGIN")
	}
	u, err := url.Parse(origin)
	if err != nil || u.Scheme != "https" {
		return PasskeyConfig{}, fmt.Errorf("PRIVATE_MESSENGER_PASSKEYS=on needs an https PRIVATE_MESSENGER_PUBLIC_ORIGIN")
	}
	if u.Port() != "" {
		return PasskeyConfig{}, fmt.Errorf("PRIVATE_MESSENGER_PASSKEYS=on needs a PRIVATE_MESSENGER_PUBLIC_ORIGIN without a port")
	}
	host := u.Hostname()
	if net.ParseIP(host) != nil || strings.EqualFold(host, "localhost") || !strings.Contains(host, ".") || strings.HasSuffix(host, ".") {
		return PasskeyConfig{}, fmt.Errorf("PRIVATE_MESSENGER_PASSKEYS=on needs a DNS host name with a dot in PRIVATE_MESSENGER_PUBLIC_ORIGIN, not an IP address or localhost")
	}
	out := PasskeyConfig{Enabled: true, RPID: host, Origin: origin}
	seen := map[string]bool{}
	for _, entry := range splitList(androidApps) {
		pkg, fp, ok := strings.Cut(entry, ":")
		if !ok || !androidPackagePattern.MatchString(pkg) {
			return PasskeyConfig{}, fmt.Errorf("PRIVATE_MESSENGER_PASSKEY_ANDROID_APPS entries must be package:SHA256-fingerprint")
		}
		raw, err := hex.DecodeString(strings.ReplaceAll(strings.ReplaceAll(fp, ":", ""), " ", ""))
		if err != nil || len(raw) != sha256.Size {
			return PasskeyConfig{}, fmt.Errorf("PRIVATE_MESSENGER_PASSKEY_ANDROID_APPS fingerprint must be 32 hex bytes (keytool SHA256 output)")
		}
		app := PasskeyAndroidApp{Package: pkg}
		copy(app.Fingerprint[:], raw)
		key := app.Package + "\x00" + app.Origin()
		if seen[key] {
			continue
		}
		seen[key] = true
		out.AndroidApps = append(out.AndroidApps, app)
	}
	for _, id := range splitList(appleAppIDs) {
		if !appleAppIDPattern.MatchString(id) {
			return PasskeyConfig{}, fmt.Errorf("PRIVATE_MESSENGER_PASSKEY_APPLE_APP_IDS entries must be TEAMID.bundle.id")
		}
		out.AppleAppIDs = append(out.AppleAppIDs, id)
	}
	if len(out.AndroidApps) > maxPasskeyApps || len(out.AppleAppIDs) > maxPasskeyApps {
		return PasskeyConfig{}, fmt.Errorf("too many passkey app entries")
	}
	return out, nil
}

func splitList(value string) []string {
	var out []string
	for _, part := range strings.Split(value, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	return out
}
