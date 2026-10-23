// Deployment smoke client for scripts/smoke-deploy.sh (card T46).
//
// It drives a running Veritra server through its public API as a client
// would, with synthetic data only: random bytes stand in for ciphertext and
// for the MLS key package, which the server stores without reading. It
// prints step names and error codes only, never tokens, passwords, secrets
// or payload bytes. The state file it writes holds throwaway credentials for
// the restore check and lives in the smoke's private temporary directory.
//
// Standard library only, so it builds without a module or network:
//
//	go build -o smoke-client scripts/smoke-deploy/smoke-client.go
//
// Commands:
//
//	vapid-keys -private-out FILE          new VAPID key pair; prints the public key
//	wait -base URL [-ca FILE]              wait until /readyz answers 200
//	run -base URL -state FILE ...          first-run smoke (see runSmoke)
//	verify -base URL -state FILE [-ca F]   checks against a restored or upgraded instance
//	slow-upload -base URL -state FILE ...  an attachment upload that lasts -seconds
package main

import (
	"bufio"
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: smoke-client vapid-keys|wait|run|verify [flags]")
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "vapid-keys":
		err = vapidKeys(os.Args[2:])
	case "wait":
		err = waitReady(os.Args[2:])
	case "run":
		err = runSmoke(os.Args[2:])
	case "verify":
		err = verifyRestored(os.Args[2:])
	case "slow-upload":
		err = slowUpload(os.Args[2:])
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "smoke-client: FAIL:", err)
		os.Exit(1)
	}
}

// state is what verify needs after a restore. Test values only.
type state struct {
	Username         string `json:"username"`
	Password         string `json:"password"`
	AccountID        string `json:"account_id"`
	DeviceID         string `json:"device_id"`
	DeviceSecret     string `json:"device_secret"`
	ConversationID   string `json:"conversation_id"`
	AttachmentID     string `json:"attachment_id"`
	AttachmentSHA256 string `json:"attachment_sha256"`
	AttachmentSize   int64  `json:"attachment_size"`
	BackupSHA256     string `json:"backup_sha256"`
	BackupSize       int64  `json:"backup_size"`
}

const (
	attachmentMetadata = `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576}`
	backupMetadata     = `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"state_counter":1}`
)

func vapidKeys(args []string) error {
	fs := flag.NewFlagSet("vapid-keys", flag.ContinueOnError)
	privateOut := fs.String("private-out", "", "file for the private key (base64url)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *privateOut == "" {
		return errors.New("-private-out is required")
	}
	key, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	if err := os.WriteFile(*privateOut, []byte(b64url(key.Bytes())+"\n"), 0o600); err != nil {
		return err
	}
	fmt.Println(b64url(key.PublicKey().Bytes()))
	return nil
}

func waitReady(args []string) error {
	fs := flag.NewFlagSet("wait", flag.ContinueOnError)
	base := fs.String("base", "", "server base URL")
	ca := fs.String("ca", "", "PEM CA file for an HTTPS base URL")
	timeout := fs.Duration("timeout", 2*time.Minute, "how long to wait")
	if err := fs.Parse(args); err != nil {
		return err
	}
	c, err := newClient(*base, *ca)
	if err != nil {
		return err
	}
	deadline := time.Now().Add(*timeout)
	for {
		status, err := c.status("GET", "/readyz")
		if err == nil && status == http.StatusOK {
			fmt.Println("ok: ready", *base)
			return nil
		}
		if time.Now().After(deadline) {
			if err != nil {
				return fmt.Errorf("%s not ready: %v", *base, err)
			}
			return fmt.Errorf("%s not ready: status %d", *base, status)
		}
		time.Sleep(time.Second)
	}
}

// runSmoke is the first-run smoke: startup, owner setup, login, attachment
// upload and download, a near-cap encrypted backup through the proxy with a
// recovery download, the WebSocket upgrade with Origin checks, a Web Push
// test wake and TURN credential issuance.
func runSmoke(args []string) error {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	base := fs.String("base", "", "server base URL (normally the TLS proxy)")
	ca := fs.String("ca", "", "PEM CA file for an HTTPS base URL")
	statePath := fs.String("state", "", "state file to write (mode 0600)")
	sensitiveOut := fs.String("sensitive-out", "", "file of label<TAB>value lines that must not appear in logs")
	turnOut := fs.String("turn-out", "", "file for the issued TURN username and credential")
	setupTokenFile := fs.String("setup-token-file", "", "file holding the setup token")
	turnSecretFile := fs.String("turn-secret-file", "", "file holding the TURN shared secret")
	turnURLs := fs.String("turn-urls", "", "comma-separated TURN URLs the server should offer")
	vapidPublic := fs.String("vapid-public", "", "VAPID public key the server should offer")
	attachmentMiB := fs.Int("attachment-mib", 8, "attachment size in MiB (server cap 50)")
	backupMiB := fs.Int("backup-mib", 96, "encrypted backup size in MiB (server cap 100)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	for name, value := range map[string]string{"-base": *base, "-state": *statePath, "-sensitive-out": *sensitiveOut,
		"-turn-out": *turnOut, "-setup-token-file": *setupTokenFile, "-turn-secret-file": *turnSecretFile,
		"-turn-urls": *turnURLs, "-vapid-public": *vapidPublic} {
		if value == "" {
			return fmt.Errorf("%s is required", name)
		}
	}
	setupToken, err := readTrimmed(*setupTokenFile)
	if err != nil {
		return err
	}
	turnSecret, err := readTrimmed(*turnSecretFile)
	if err != nil {
		return err
	}
	c, err := newClient(*base, *ca)
	if err != nil {
		return err
	}
	var sensitive [][2]string
	st := state{Username: "smoke-owner", Password: "pw-" + randomToken(24)}
	sensitive = append(sensitive, [2]string{"owner password", st.Password})

	if err := checkHealth(c); err != nil {
		return err
	}
	if c.base.Scheme == "https" {
		if err := checkEdgeHeaders(c); err != nil {
			return err
		}
	}
	var setupStatus struct {
		SetupRequired bool `json:"setup_required"`
	}
	if err := c.json("GET", "/api/v1/setup/status", nil, nil, http.StatusOK, &setupStatus); err != nil {
		return err
	}
	if !setupStatus.SetupRequired {
		return errors.New("a fresh instance reports setup as done")
	}
	pass("fresh instance requires owner setup")

	// The setup endpoints refuse a request without the token.
	if err := c.json("POST", "/api/v1/setup/owner/enrollment", nil, nil, http.StatusForbidden, nil); err != nil {
		return fmt.Errorf("setup without the token: %w", err)
	}
	setupHeader := map[string]string{"X-Veritra-Setup-Token": setupToken}
	var reservation struct {
		ID        string `json:"id"`
		Challenge []byte `json:"challenge"`
	}
	if err := c.json("POST", "/api/v1/setup/owner/enrollment", nil, setupHeader, http.StatusCreated, &reservation); err != nil {
		return err
	}
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	keyPackage := syntheticKeyPackage()
	owner := map[string]any{
		"enrollment_reservation_id": reservation.ID,
		"instance_name":             "Veritra smoke",
		"username":                  st.Username,
		"password":                  st.Password,
		"device_name":               "smoke device",
		"device_key_package":        keyPackage,
		"signing_key":               []byte(publicKey),
		"challenge_signature":       ed25519.Sign(privateKey, enrollmentProof(reservation.Challenge, publicKey, keyPackage)),
	}
	var created struct {
		Account      struct{ ID string } `json:"account"`
		Device       struct{ ID string } `json:"device"`
		Token        string              `json:"token"`
		DeviceSecret string              `json:"device_secret"`
	}
	if err := c.json("POST", "/api/v1/setup/owner", owner, setupHeader, http.StatusCreated, &created); err != nil {
		return err
	}
	st.AccountID, st.DeviceID, st.DeviceSecret = created.Account.ID, created.Device.ID, created.DeviceSecret
	// Logs carry route patterns only: no tokens and no dynamic IDs (T48A).
	sensitive = append(sensitive, [2]string{"setup session token", created.Token}, [2]string{"device secret", created.DeviceSecret},
		[2]string{"enrollment reservation ID", reservation.ID}, [2]string{"account ID", st.AccountID}, [2]string{"device ID", st.DeviceID})
	pass("owner setup with the file-mounted setup token")

	if err := c.login(&st); err != nil {
		return err
	}
	sensitive = append(sensitive, [2]string{"login session token", c.token})
	pass("password and device login")

	var conversation struct {
		ID string `json:"id"`
	}
	if err := c.json("POST", "/api/v1/conversations", map[string]any{"kind": "group"}, nil, http.StatusCreated, &conversation); err != nil {
		return err
	}
	st.ConversationID = conversation.ID

	attachment, err := c.uploadAttachment(st.ConversationID, int64(*attachmentMiB)<<20)
	if err != nil {
		return err
	}
	st.AttachmentID, st.AttachmentSHA256, st.AttachmentSize = attachment.ID, attachment.SHA256, attachment.Size
	sensitive = append(sensitive, [2]string{"conversation ID", st.ConversationID}, [2]string{"attachment ID", st.AttachmentID},
		[2]string{"attachment ciphertext prefix", attachment.prefix})
	if err := c.download("/api/v1/attachments/"+st.AttachmentID, nil, st.AttachmentSHA256, st.AttachmentSize); err != nil {
		return err
	}
	if err := c.rangeRequest("/api/v1/attachments/"+st.AttachmentID, 1024); err != nil {
		return err
	}
	pass(fmt.Sprintf("attachment upload and download (%d MiB, sha256 and range checked)", *attachmentMiB))

	recoveryToken := make([]byte, 32)
	if _, err := rand.Read(recoveryToken); err != nil {
		return err
	}
	recovery := b64url(recoveryToken)
	sensitive = append(sensitive, [2]string{"recovery token", recovery})
	backup, err := c.uploadBlob("/api/v1/backups", int64(*backupMiB)<<20, map[string]string{
		"X-Private-Messenger-Encrypted": "1",
		"X-Key-Derivation-Metadata":     backupMetadata,
		"X-Recovery-Token":              recovery,
	})
	if err != nil {
		return err
	}
	st.BackupSHA256, st.BackupSize = backup.SHA256, backup.Size
	sensitive = append(sensitive, [2]string{"backup ciphertext prefix", backup.prefix})
	recoveryClient := *c
	recoveryClient.token = ""
	if err := recoveryClient.download("/api/v1/recovery", map[string]string{"X-Recovery-Token": recovery}, st.BackupSHA256, st.BackupSize); err != nil {
		return fmt.Errorf("recovery download: %w", err)
	}
	pass(fmt.Sprintf("encrypted backup upload (%d MiB) and recovery download through the proxy", *backupMiB))

	if err := c.websocketChecks(); err != nil {
		return err
	}

	pushSensitive, err := c.pushChecks(*vapidPublic)
	if err != nil {
		return err
	}
	sensitive = append(sensitive, pushSensitive...)

	username, credential, err := c.turnChecks(turnSecret, splitList(*turnURLs), st.AccountID)
	if err != nil {
		return err
	}
	sensitive = append(sensitive, [2]string{"TURN credential", credential})
	if err := os.WriteFile(*turnOut, []byte(username+"\n"+credential+"\n"), 0o600); err != nil {
		return err
	}

	if err := writeJSON(*statePath, st); err != nil {
		return err
	}
	var lines strings.Builder
	for _, entry := range sensitive {
		if len(entry[1]) >= 8 {
			lines.WriteString(entry[0] + "\t" + entry[1] + "\n")
		}
	}
	return os.WriteFile(*sensitiveOut, []byte(lines.String()), 0o600)
}

// verifyRestored checks an instance restored from the smoke's backup: the
// owner can still sign in, the ciphertext blobs are intact, and the
// restored instance accepts new writes.
func verifyRestored(args []string) error {
	fs := flag.NewFlagSet("verify", flag.ContinueOnError)
	base := fs.String("base", "", "server base URL")
	ca := fs.String("ca", "", "PEM CA file for an HTTPS base URL")
	statePath := fs.String("state", "", "state file written by run")
	if err := fs.Parse(args); err != nil {
		return err
	}
	raw, err := os.ReadFile(*statePath)
	if err != nil {
		return err
	}
	var st state
	if err := json.Unmarshal(raw, &st); err != nil {
		return fmt.Errorf("state file: %w", err)
	}
	c, err := newClient(*base, *ca)
	if err != nil {
		return err
	}
	if err := checkHealth(c); err != nil {
		return err
	}
	var setupStatus struct {
		SetupRequired bool   `json:"setup_required"`
		InstanceName  string `json:"instance_name"`
	}
	if err := c.json("GET", "/api/v1/setup/status", nil, nil, http.StatusOK, &setupStatus); err != nil {
		return err
	}
	if setupStatus.SetupRequired || setupStatus.InstanceName != "Veritra smoke" {
		return errors.New("restored instance lost its owner setup")
	}
	if err := c.login(&st); err != nil {
		return fmt.Errorf("login on the restored instance: %w", err)
	}
	pass("kept data: owner login")
	if err := c.download("/api/v1/attachments/"+st.AttachmentID, nil, st.AttachmentSHA256, st.AttachmentSize); err != nil {
		return fmt.Errorf("restored attachment: %w", err)
	}
	var backups struct {
		Backups []struct {
			ID     string `json:"id"`
			SHA256 string `json:"ciphertext_sha256"`
		} `json:"backups"`
	}
	if err := c.json("GET", "/api/v1/backups", nil, nil, http.StatusOK, &backups); err != nil {
		return err
	}
	backupID := ""
	for _, b := range backups.Backups {
		if strings.EqualFold(b.SHA256, st.BackupSHA256) {
			backupID = b.ID
		}
	}
	if backupID == "" {
		return errors.New("restored instance lost the encrypted backup record")
	}
	if err := c.download("/api/v1/backups/"+backupID, nil, st.BackupSHA256, st.BackupSize); err != nil {
		return fmt.Errorf("restored encrypted backup: %w", err)
	}
	pass("kept data: attachment and encrypted backup blobs intact")
	fresh, err := c.uploadAttachment(st.ConversationID, 1<<20)
	if err != nil {
		return fmt.Errorf("write on the restored instance: %w", err)
	}
	if err := c.download("/api/v1/attachments/"+fresh.ID, nil, fresh.SHA256, fresh.Size); err != nil {
		return err
	}
	pass("kept data: new SQLite and blob writes work")
	var subscriptions struct {
		Subscriptions []struct {
			Provider string `json:"provider"`
		} `json:"subscriptions"`
	}
	if err := c.json("GET", "/api/v1/push/subscriptions/me", nil, nil, http.StatusOK, &subscriptions); err != nil {
		return err
	}
	if len(subscriptions.Subscriptions) != 1 || subscriptions.Subscriptions[0].Provider != "webpush" {
		return errors.New("restored instance lost the push registration")
	}
	pass("kept data: push registration")
	return nil
}

// slowUpload proves the proxy lets a transfer run past its default read
// timeout (Traefik v3: 60 s): one attachment upload paced to last -seconds.
func slowUpload(args []string) error {
	fs := flag.NewFlagSet("slow-upload", flag.ContinueOnError)
	base := fs.String("base", "", "server base URL")
	ca := fs.String("ca", "", "PEM CA file for an HTTPS base URL")
	statePath := fs.String("state", "", "state file written by run")
	mib := fs.Int("mib", 4, "attachment size in MiB")
	seconds := fs.Int("seconds", 90, "how long the upload should take")
	if err := fs.Parse(args); err != nil {
		return err
	}
	raw, err := os.ReadFile(*statePath)
	if err != nil {
		return err
	}
	var st state
	if err := json.Unmarshal(raw, &st); err != nil {
		return fmt.Errorf("state file: %w", err)
	}
	c, err := newClient(*base, *ca)
	if err != nil {
		return err
	}
	if err := c.login(&st); err != nil {
		return err
	}
	size := int64(*mib) << 20
	c.rate = float64(size) / float64(*seconds)
	started := time.Now()
	upload, err := c.uploadAttachment(st.ConversationID, size)
	elapsed := time.Since(started).Round(time.Second)
	if err != nil {
		return fmt.Errorf("upload cut off after %s: %w", elapsed, err)
	}
	c.rate = 0
	if err := c.download("/api/v1/attachments/"+upload.ID, nil, upload.SHA256, upload.Size); err != nil {
		return err
	}
	pass(fmt.Sprintf("slow upload of %d MiB took %s and completed intact", *mib, elapsed))
	return nil
}

func checkHealth(c *client) error {
	for _, path := range []string{"/livez", "/healthz", "/readyz"} {
		status, err := c.status("GET", path)
		if err != nil {
			return err
		}
		if status != http.StatusOK {
			return fmt.Errorf("GET %s: status %d", path, status)
		}
	}
	pass("livez, healthz and readyz")
	return nil
}

// checkEdgeHeaders: the TLS proxy adds HSTS (the server cannot, behind a
// proxy) and sends each security header once.
func checkEdgeHeaders(c *client) error {
	response, err := c.request("GET", "/healthz", nil, nil)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, response.Body)
	if !strings.HasPrefix(response.Header.Get("Strict-Transport-Security"), "max-age=") {
		return errors.New("the TLS proxy sends no Strict-Transport-Security header")
	}
	for _, name := range []string{"Strict-Transport-Security", "X-Content-Type-Options", "Referrer-Policy"} {
		if values := response.Header.Values(name); len(values) != 1 {
			return fmt.Errorf("%s sent %d times", name, len(values))
		}
	}
	pass("edge headers: HSTS from the proxy, each security header once")
	return nil
}

func (c *client) login(st *state) error {
	var session struct {
		Token string `json:"token"`
	}
	request := map[string]string{"username": st.Username, "password": st.Password, "device_id": st.DeviceID, "device_secret": st.DeviceSecret}
	if err := c.json("POST", "/api/v1/auth/login", request, nil, http.StatusOK, &session); err != nil {
		return err
	}
	if session.Token == "" {
		return errors.New("login returned no session")
	}
	c.token = session.Token
	return nil
}

// websocketChecks proves the proxy keeps the Host header and upgrades:
// a same-origin upgrade succeeds and a foreign Origin is refused.
func (c *client) websocketChecks() error {
	origin := c.base.Scheme + "://" + c.base.Host
	status, err := c.websocket(origin)
	if err != nil {
		return err
	}
	if status != http.StatusSwitchingProtocols {
		return fmt.Errorf("same-origin WebSocket upgrade: status %d (is the Host header kept?)", status)
	}
	status, err = c.websocket("https://foreign.invalid")
	if err != nil {
		return err
	}
	if status != http.StatusForbidden {
		return fmt.Errorf("foreign-origin WebSocket upgrade: status %d, want 403", status)
	}
	pass("WebSocket upgrade through the proxy (Host kept, foreign Origin refused)")
	return nil
}

func (c *client) websocket(origin string) (int, error) {
	key := make([]byte, 16)
	if _, err := rand.Read(key); err != nil {
		return 0, err
	}
	encodedKey := base64.StdEncoding.EncodeToString(key)
	request, err := http.NewRequest("GET", c.url("/api/v1/sync/ws"), nil)
	if err != nil {
		return 0, err
	}
	request.Header.Set("Connection", "Upgrade")
	request.Header.Set("Upgrade", "websocket")
	request.Header.Set("Sec-WebSocket-Version", "13")
	request.Header.Set("Sec-WebSocket-Key", encodedKey)
	request.Header.Set("Origin", origin)
	request.Header.Set("Authorization", "Bearer "+c.token)
	response, err := c.ws.Do(request)
	if err != nil {
		return 0, fmt.Errorf("WebSocket upgrade: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusSwitchingProtocols {
		sum := sha1.Sum([]byte(encodedKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
		if response.Header.Get("Sec-WebSocket-Accept") != base64.StdEncoding.EncodeToString(sum[:]) {
			return 0, errors.New("WebSocket upgrade: wrong Sec-WebSocket-Accept")
		}
		// A close frame (masked, code 1000), as a client must send.
		if writer, ok := response.Body.(io.Writer); ok {
			mask := []byte{1, 2, 3, 4}
			payload := []byte{0x03 ^ mask[0], 0xe8 ^ mask[1]}
			_, _ = writer.Write(append([]byte{0x88, 0x80 | 2}, append(mask, payload...)...))
		}
	}
	return response.StatusCode, nil
}

// pushChecks registers a Web Push subscription for an endpoint that cannot
// resolve (.invalid), sends the test wake and expects the provider to try
// and fail. Real delivery needs a real browser or UnifiedPush subscription
// and public egress (G24).
func (c *client) pushChecks(vapidPublic string) ([][2]string, error) {
	var config struct {
		Enabled        bool     `json:"enabled"`
		Providers      []string `json:"providers"`
		VAPIDPublicKey string   `json:"vapid_public_key"`
	}
	if err := c.json("GET", "/api/v1/push/config", nil, nil, http.StatusOK, &config); err != nil {
		return nil, err
	}
	if !config.Enabled || !contains(config.Providers, "webpush") || config.VAPIDPublicKey != vapidPublic {
		return nil, errors.New("push config does not offer the configured Web Push key")
	}
	clientKey, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	authSecret := make([]byte, 16)
	if _, err := rand.Read(authSecret); err != nil {
		return nil, err
	}
	endpoint := "https://push-smoke.invalid/wpush/" + randomToken(24)
	subscription := map[string]string{
		"provider": "webpush", "endpoint": endpoint,
		"public_key": b64url(clientKey.PublicKey().Bytes()), "auth_secret": b64url(authSecret),
	}
	plain := map[string]string{"provider": "webpush", "endpoint": "http://push-smoke.invalid/x",
		"public_key": subscription["public_key"], "auth_secret": subscription["auth_secret"]}
	if err := c.json("POST", "/api/v1/push/subscriptions", plain, nil, http.StatusBadRequest, nil); err != nil {
		return nil, fmt.Errorf("plain-HTTP push endpoint: %w", err)
	}
	if err := c.json("POST", "/api/v1/push/subscriptions", subscription, nil, http.StatusCreated, nil); err != nil {
		return nil, err
	}
	var test struct {
		Results []struct {
			Provider string `json:"provider"`
			Result   string `json:"result"`
		} `json:"results"`
	}
	if err := c.json("POST", "/api/v1/push/test", nil, nil, http.StatusOK, &test); err != nil {
		return nil, err
	}
	if len(test.Results) != 1 || test.Results[0].Provider != "webpush" || test.Results[0].Result != "failed" {
		return nil, fmt.Errorf("test wake to an unresolvable endpoint: %+v, want one webpush result \"failed\"", test.Results)
	}
	if err := c.json("POST", "/api/v1/push/test", nil, nil, http.StatusTooManyRequests, nil); err != nil {
		return nil, fmt.Errorf("second test wake within a minute: %w", err)
	}
	pass("Web Push: VAPID key from file, subscription stored, test wake attempted (result failed: endpoint is .invalid), rate limit")
	return [][2]string{{"push endpoint", strings.TrimPrefix(endpoint, "https://push-smoke.invalid/wpush/")},
		{"push public key", subscription["public_key"]}, {"push auth secret", subscription["auth_secret"]}}, nil
}

// turnChecks verifies the issued credential is the coturn REST scheme over
// the shared secret, so coturn with use-auth-secret accepts it.
func (c *client) turnChecks(secret string, wantURLs []string, accountID string) (string, string, error) {
	var config struct {
		Enabled    bool `json:"enabled"`
		ICEServers []struct {
			URLs       []string `json:"urls"`
			Username   string   `json:"username"`
			Credential string   `json:"credential"`
		} `json:"ice_servers"`
		ExpiresAt time.Time `json:"expires_at"`
	}
	if err := c.json("GET", "/api/v1/calls/config", nil, nil, http.StatusOK, &config); err != nil {
		return "", "", err
	}
	if !config.Enabled || len(config.ICEServers) != 1 {
		return "", "", errors.New("TURN is not offered")
	}
	server := config.ICEServers[0]
	if strings.Join(server.URLs, ",") != strings.Join(wantURLs, ",") {
		return "", "", fmt.Errorf("TURN URLs %q, want %q", server.URLs, wantURLs)
	}
	expiry, account, ok := strings.Cut(server.Username, ":")
	seconds, err := strconv.ParseInt(expiry, 10, 64)
	if !ok || err != nil || account != accountID {
		return "", "", errors.New("TURN username is not <expiry>:<account>")
	}
	left := time.Until(time.Unix(seconds, 0))
	if left <= 0 || left > 11*time.Minute {
		return "", "", fmt.Errorf("TURN credential lifetime %s, want about 10 minutes", left.Round(time.Second))
	}
	mac := hmac.New(sha1.New, []byte(secret))
	mac.Write([]byte(server.Username))
	if !hmac.Equal([]byte(server.Credential), []byte(base64.StdEncoding.EncodeToString(mac.Sum(nil)))) {
		return "", "", errors.New("TURN credential is not HMAC-SHA1(shared secret, username)")
	}
	pass("TURN credential issued from the file-mounted shared secret (coturn REST scheme)")
	return server.Username, server.Credential, nil
}

type client struct {
	base  *url.URL
	http  *http.Client
	ws    *http.Client
	token string
	rate  float64 // upload bytes per second; 0 means unthrottled
}

func newClient(base, caFile string) (*client, error) {
	parsed, err := url.Parse(base)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return nil, fmt.Errorf("invalid base URL %q", base)
	}
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12}
	if caFile != "" {
		pem, err := os.ReadFile(caFile)
		if err != nil {
			return nil, err
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("no certificate in %s", caFile)
		}
		tlsConfig.RootCAs = pool
	}
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	transport := &http.Transport{Proxy: nil, DialContext: dialer.DialContext, TLSClientConfig: tlsConfig,
		ForceAttemptHTTP2: true, ResponseHeaderTimeout: 2 * time.Minute}
	wsTLS := tlsConfig.Clone()
	wsTLS.NextProtos = []string{"http/1.1"}
	wsTransport := &http.Transport{Proxy: nil, DialContext: dialer.DialContext, TLSClientConfig: wsTLS,
		TLSNextProto: map[string]func(string, *tls.Conn) http.RoundTripper{}}
	return &client{
		base: parsed,
		http: &http.Client{Transport: transport, Timeout: 15 * time.Minute},
		ws:   &http.Client{Transport: wsTransport, Timeout: 30 * time.Second},
	}, nil
}

func (c *client) url(path string) string {
	return strings.TrimRight(c.base.String(), "/") + path
}

func (c *client) request(method, path string, body io.Reader, headers map[string]string) (*http.Response, error) {
	request, err := http.NewRequest(method, c.url(path), body)
	if err != nil {
		return nil, err
	}
	if c.token != "" {
		request.Header.Set("Authorization", "Bearer "+c.token)
	}
	for key, value := range headers {
		request.Header.Set(key, value)
	}
	if sized, ok := body.(interface{ Len() int64 }); ok {
		request.ContentLength = sized.Len()
	}
	return c.http.Do(request)
}

func (c *client) status(method, path string) (int, error) {
	response, err := c.request(method, path, nil, nil)
	if err != nil {
		return 0, err
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 1<<20))
	return response.StatusCode, nil
}

// json sends in (if any) as JSON and decodes a want-status response into
// out. On a different status it reports only the server's error code.
func (c *client) json(method, path string, in any, headers map[string]string, want int, out any) error {
	var body io.Reader
	all := map[string]string{}
	for key, value := range headers {
		all[key] = value
	}
	if in != nil {
		raw, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(raw)
		all["Content-Type"] = "application/json"
	}
	response, err := c.request(method, path, body, all)
	if err != nil {
		return fmt.Errorf("%s %s: %w", method, path, err)
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return fmt.Errorf("%s %s: %w", method, path, err)
	}
	if response.StatusCode != want {
		return fmt.Errorf("%s %s: status %d, want %d (%s)", method, path, response.StatusCode, want, errorCode(raw))
	}
	if out != nil {
		if err := json.Unmarshal(raw, out); err != nil {
			return fmt.Errorf("%s %s: decode response: %w", method, path, err)
		}
	}
	return nil
}

type uploaded struct {
	ID     string
	SHA256 string
	Size   int64
	prefix string // base64 of the first bytes, for the log check
}

func (c *client) uploadAttachment(conversationID string, size int64) (uploaded, error) {
	return c.uploadBlob("/api/v1/attachments?conversation_id="+url.QueryEscape(conversationID), size, map[string]string{
		"X-Private-Messenger-Encrypted": "1",
		"X-Crypto-Metadata":             attachmentMetadata,
	})
}

// uploadBlob streams size random bytes (standing in for ciphertext) and
// checks the server's recorded hash and size.
func (c *client) uploadBlob(path string, size int64, headers map[string]string) (uploaded, error) {
	prefix := make([]byte, 24)
	if _, err := rand.Read(prefix); err != nil {
		return uploaded{}, err
	}
	hash := sha256.New()
	var source io.Reader = io.TeeReader(io.MultiReader(bytes.NewReader(prefix), io.LimitReader(rand.Reader, size-int64(len(prefix)))), hash)
	if c.rate > 0 {
		source = &throttled{r: source, rate: c.rate, start: time.Now()}
	}
	body := &sizedReader{r: source, n: size}
	all := map[string]string{"Content-Type": "application/octet-stream"}
	for key, value := range headers {
		all[key] = value
	}
	response, err := c.request("POST", path, body, all)
	if err != nil {
		return uploaded{}, fmt.Errorf("upload %s: %w", strings.SplitN(path, "?", 2)[0], err)
	}
	defer response.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if response.StatusCode != http.StatusCreated {
		return uploaded{}, fmt.Errorf("upload %s: status %d (%s)", strings.SplitN(path, "?", 2)[0], response.StatusCode, errorCode(raw))
	}
	var result struct {
		ID     string `json:"id"`
		SHA256 string `json:"ciphertext_sha256"`
		Size   int64  `json:"size_bytes"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return uploaded{}, err
	}
	sum := hex.EncodeToString(hash.Sum(nil))
	if !strings.EqualFold(result.SHA256, sum) || result.Size != size {
		return uploaded{}, errors.New("server recorded a different hash or size than was sent")
	}
	return uploaded{ID: result.ID, SHA256: sum, Size: size, prefix: base64.StdEncoding.EncodeToString(prefix)}, nil
}

func (c *client) download(path string, headers map[string]string, wantSHA string, wantSize int64) error {
	response, err := c.request("GET", path, nil, headers)
	if err != nil {
		return fmt.Errorf("download %s: %w", routeName(path), err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		return fmt.Errorf("download %s: status %d (%s)", routeName(path), response.StatusCode, errorCode(raw))
	}
	hash := sha256.New()
	n, err := io.Copy(hash, response.Body)
	if err != nil {
		return fmt.Errorf("download %s: %w", routeName(path), err)
	}
	if n != wantSize || !strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), wantSHA) {
		return fmt.Errorf("download %s: content differs from the upload", routeName(path))
	}
	return nil
}

func (c *client) rangeRequest(path string, length int) error {
	response, err := c.request("GET", path, nil, map[string]string{"Range": fmt.Sprintf("bytes=0-%d", length-1)})
	if err != nil {
		return err
	}
	defer response.Body.Close()
	n, _ := io.Copy(io.Discard, response.Body)
	if response.StatusCode != http.StatusPartialContent || n != int64(length) {
		return fmt.Errorf("range request on %s: status %d, %d bytes", routeName(path), response.StatusCode, n)
	}
	return nil
}

// enrollmentProof mirrors the server's enrollment proof message.
func enrollmentProof(challenge, signingKey, keyPackage []byte) []byte {
	keyPackageHash := sha256.Sum256(keyPackage)
	proof := []byte("veritra-enrollment-proof-v1")
	var length [2]byte
	binary.BigEndian.PutUint16(length[:], uint16(len(challenge)))
	proof = append(proof, length[:]...)
	proof = append(proof, challenge...)
	proof = append(proof, signingKey...)
	return append(proof, keyPackageHash[:]...)
}

// syntheticKeyPackage is random bytes of a plausible size. The server stores
// it opaquely and rejects only reserved test markers.
func syntheticKeyPackage() []byte {
	for {
		value := make([]byte, 512)
		if _, err := rand.Read(value); err != nil {
			panic(err)
		}
		lower := strings.ToLower(string(value))
		if !strings.Contains(lower, "test") && !strings.Contains(lower, "placeholder") && !strings.Contains(lower, "non-production") {
			return value
		}
	}
}

// throttled paces reads to rate bytes per second, like a slow uplink.
type throttled struct {
	r     io.Reader
	rate  float64
	start time.Time
	sent  int64
}

func (t *throttled) Read(p []byte) (int, error) {
	if len(p) > 16<<10 {
		p = p[:16<<10]
	}
	n, err := t.r.Read(p)
	t.sent += int64(n)
	if wait := time.Duration(float64(t.sent)/t.rate*float64(time.Second)) - time.Since(t.start); wait > 0 {
		time.Sleep(wait)
	}
	return n, err
}

type sizedReader struct {
	r io.Reader
	n int64
}

func (s *sizedReader) Read(p []byte) (int, error) { return s.r.Read(p) }
func (s *sizedReader) Len() int64                 { return s.n }

func errorCode(raw []byte) string {
	var body struct {
		Error string `json:"error"`
	}
	if json.Unmarshal(raw, &body) == nil && body.Error != "" && len(body.Error) <= 64 {
		return body.Error
	}
	return "no error code"
}

// routeName drops IDs from a path for messages.
func routeName(path string) string {
	path = strings.SplitN(path, "?", 2)[0]
	parts := strings.Split(path, "/")
	if len(parts) > 4 {
		return strings.Join(parts[:4], "/") + "/{id}"
	}
	return path
}

func readTrimmed(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	value := strings.TrimSpace(string(raw))
	if value == "" {
		return "", fmt.Errorf("%s is empty", path)
	}
	return value, nil
}

func writeJSON(path string, value any) error {
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(raw, '\n'), 0o600)
}

func randomToken(n int) string {
	value := make([]byte, n)
	if _, err := rand.Read(value); err != nil {
		panic(err)
	}
	return b64url(value)
}

func b64url(value []byte) string { return base64.RawURLEncoding.EncodeToString(value) }

func splitList(raw string) []string {
	var out []string
	scanner := bufio.NewScanner(strings.NewReader(strings.ReplaceAll(raw, ",", "\n")))
	for scanner.Scan() {
		if value := strings.TrimSpace(scanner.Text()); value != "" {
			out = append(out, value)
		}
	}
	return out
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func pass(message string) { fmt.Println("ok:", message) }
