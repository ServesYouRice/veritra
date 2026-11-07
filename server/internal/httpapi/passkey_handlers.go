package httpapi

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/protocol/webauthncose"
	"github.com/go-webauthn/webauthn/webauthn"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/storage"
)

// Passkeys (B7, docs/designs/B7-passkeys.md). A passkey replaces the
// password at sign-in only, and only on an enrolled device: the device ID
// and secret are checked at both steps. A passkey session never carries
// recent authentication, so every withRecentAuth route stays password-only.

// PasskeyService holds the relying-party setup. A nil service means
// passkeys are off.
type PasskeyService struct {
	cfg config.PasskeyConfig
	wa  *webauthn.WebAuthn
}

// NewPasskeyService builds the service from a validated config. It returns
// nil when passkeys are off.
func NewPasskeyService(cfg config.PasskeyConfig) (*PasskeyService, error) {
	if !cfg.Enabled {
		return nil, nil
	}
	origins := []string{"https://" + cfg.RPID}
	var opaque []string
	for _, app := range cfg.AndroidApps {
		opaque = append(opaque, app.Origin())
	}
	wa, err := webauthn.New(&webauthn.Config{
		RPID:                  cfg.RPID,
		RPDisplayName:         "Veritra",
		RPOrigins:             origins,
		RPOpaqueOrigins:       opaque,
		AttestationPreference: protocol.PreferNoAttestation,
		AuthenticatorSelection: protocol.AuthenticatorSelection{
			RequireResidentKey: protocol.ResidentKeyRequired(),
			ResidentKey:        protocol.ResidentKeyRequirementRequired,
			UserVerification:   protocol.VerificationRequired,
		},
	})
	if err != nil {
		return nil, err
	}
	return &PasskeyService{cfg: cfg, wa: wa}, nil
}

var passkeyAlgorithms = []protocol.CredentialParameter{
	{Type: protocol.PublicKeyCredentialType, Algorithm: webauthncose.AlgEdDSA},
	{Type: protocol.PublicKeyCredentialType, Algorithm: webauthncose.AlgES256},
	{Type: protocol.PublicKeyCredentialType, Algorithm: webauthncose.AlgRS256},
}

type passkeyUser struct {
	handle      []byte
	name        string
	credentials []webauthn.Credential
}

func (u passkeyUser) WebAuthnID() []byte                         { return u.handle }
func (u passkeyUser) WebAuthnName() string                       { return u.name }
func (u passkeyUser) WebAuthnDisplayName() string                { return u.name }
func (u passkeyUser) WebAuthnCredentials() []webauthn.Credential { return u.credentials }

func libraryCredential(c storage.PasskeyCredential) webauthn.Credential {
	var transports []protocol.AuthenticatorTransport
	for _, t := range strings.Split(c.Transports, ",") {
		if t = strings.TrimSpace(t); t != "" {
			transports = append(transports, protocol.AuthenticatorTransport(t))
		}
	}
	return webauthn.Credential{
		ID:        c.CredentialID,
		PublicKey: c.PublicKey,
		Transport: transports,
		Flags:     webauthn.CredentialFlags{UserPresent: true, UserVerified: true, BackupEligible: c.BackupEligible, BackupState: c.BackupState},
		Authenticator: webauthn.Authenticator{
			SignCount: c.SignCount,
		},
	}
}

func libraryCredentials(list []storage.PasskeyCredential) []webauthn.Credential {
	out := make([]webauthn.Credential, 0, len(list))
	for _, c := range list {
		out = append(out, libraryCredential(c))
	}
	return out
}

// passkeysOn answers 503 passkeys_not_configured while passkeys are off.
func (a *API) passkeysOn(w http.ResponseWriter) bool {
	if a.Passkeys == nil {
		writeError(w, http.StatusServiceUnavailable, "passkeys_not_configured")
		return false
	}
	return true
}

// passkeyBackoffKeys: the passkey source key always takes failures; the
// password path's own account-device key takes them only when the device
// secret was valid, so a secret holder shares one budget across methods and
// someone without the secret cannot lock the owner out.
func (a *API) passkeyBackoffKeys(r *http.Request, deviceID string) (source string) {
	return "passkey-source-device\x00" + a.clientIP(r) + "\x00" + strings.TrimSpace(deviceID)
}

func passkeyAccountDeviceKey(username, deviceID string) string {
	return "login-account-device\x00" + strings.ToLower(strings.TrimSpace(username)) + "\x00" + strings.TrimSpace(deviceID)
}

type passkeyDeviceCheck struct {
	device         storage.PasskeyDevice
	source         string
	accountDevice  string
	deviceOK       bool
	failedKeys     func() []string
	deviceIDString string
}

// checkPasskeyDevice runs the device checks both passkey sign-in steps
// share. It writes the response itself and reports false when the request
// may not go on. A wrong secret, unknown device and revoked device all get
// the same 401.
func (a *API) checkPasskeyDevice(w http.ResponseWriter, r *http.Request, deviceID, deviceSecret string) (passkeyDeviceCheck, bool) {
	check := passkeyDeviceCheck{deviceIDString: strings.TrimSpace(deviceID)}
	if check.deviceIDString == "" {
		writeError(w, http.StatusBadRequest, "device_id_required")
		return check, false
	}
	check.source = a.passkeyBackoffKeys(r, check.deviceIDString)
	if retryAfter := a.LoginBackoff.RetryAfterAny(loginBackoffNow(), check.source); retryAfter > 0 {
		writeRetryError(w, "login_backoff", retryAfter)
		return check, false
	}
	device, err := a.Store.PasskeyDeviceByID(r.Context(), check.deviceIDString)
	stored := ""
	if err == nil {
		stored = device.DeviceAuthHash
		check.device = device
	}
	// Always one constant-time comparison, against an empty hash when the
	// lookup failed.
	check.deviceOK = err == nil && stored != "" && subtle.ConstantTimeCompare([]byte(auth.HashToken(deviceSecret)), []byte(stored)) == 1
	if check.deviceOK {
		check.accountDevice = passkeyAccountDeviceKey(device.Username, check.deviceIDString)
		if retryAfter := a.LoginBackoff.RetryAfterAny(loginBackoffNow(), check.accountDevice); retryAfter > 0 {
			writeRetryError(w, "login_backoff", retryAfter)
			return check, false
		}
	}
	check.failedKeys = func() []string {
		keys := []string{check.source}
		if check.deviceOK {
			keys = append(keys, check.accountDevice)
		}
		return keys
	}
	if !check.deviceOK {
		a.passkeyFailed(w, check)
		return check, false
	}
	return check, true
}

// passkeyFailed counts a failure and answers the uniform 401.
func (a *API) passkeyFailed(w http.ResponseWriter, check passkeyDeviceCheck) {
	if retryAfter := a.LoginBackoff.FailedAny(loginBackoffNow(), check.failedKeys()...); retryAfter > 0 {
		writeRetryError(w, "login_backoff", retryAfter)
		return
	}
	writeError(w, http.StatusUnauthorized, "invalid_credentials")
}

type passkeyOptionsRequest struct {
	DeviceID     string `json:"device_id"`
	DeviceSecret string `json:"device_secret"`
}

// passkeyLoginOptions begins a sign-in ceremony. It takes no username.
func (a *API) passkeyLoginOptions(w http.ResponseWriter, r *http.Request) {
	if !a.passkeysOn(w) {
		return
	}
	var req passkeyOptionsRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	check, ok := a.checkPasskeyDevice(w, r, req.DeviceID, req.DeviceSecret)
	if !ok {
		return
	}
	accountID := check.device.AccountID
	handle, err := a.Store.PasskeyUserHandle(r.Context(), accountID, false)
	if errors.Is(err, storage.ErrNotFound) {
		writeError(w, http.StatusUnauthorized, "invalid_credentials")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "passkey_options_failed")
		return
	}
	passkeys, err := a.Store.ListPasskeys(r.Context(), accountID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "passkey_options_failed")
		return
	}
	if len(passkeys) == 0 {
		writeError(w, http.StatusUnauthorized, "invalid_credentials")
		return
	}
	user := passkeyUser{handle: handle, name: check.device.Username, credentials: libraryCredentials(passkeys)}
	assertion, session, err := a.Passkeys.wa.BeginLogin(user)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "passkey_options_failed")
		return
	}
	a.writeCeremony(w, r, http.StatusOK, storage.PasskeyCeremonyLogin, accountID, check.device.DeviceID, session, assertion.Response)
}

func (a *API) writeCeremony(w http.ResponseWriter, r *http.Request, status int, kind, accountID, deviceID string, session *webauthn.SessionData, publicKey interface{}) {
	data, err := json.Marshal(session)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "passkey_options_failed")
		return
	}
	id, err := a.Store.CreatePasskeyCeremony(r.Context(), kind, accountID, deviceID, data)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "passkey_options_failed")
		return
	}
	writeJSON(w, status, map[string]interface{}{"ceremony_id": id, "public_key": publicKey})
}

type passkeyLoginRequest struct {
	CeremonyID   string          `json:"ceremony_id"`
	DeviceID     string          `json:"device_id"`
	DeviceSecret string          `json:"device_secret"`
	Credential   json.RawMessage `json:"credential"`
}

// passkeyLogin finishes a sign-in. Every failure is the same 401.
func (a *API) passkeyLogin(w http.ResponseWriter, r *http.Request) {
	if !a.passkeysOn(w) {
		return
	}
	var req passkeyLoginRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	check, ok := a.checkPasskeyDevice(w, r, req.DeviceID, req.DeviceSecret)
	if !ok {
		return
	}
	device := check.device
	fail := func() { a.passkeyFailed(w, check) }
	ceremony, err := a.Store.PasskeyCeremonyByID(r.Context(), strings.TrimSpace(req.CeremonyID), storage.PasskeyCeremonyLogin)
	if err != nil || ceremony.DeviceID != device.DeviceID || ceremony.AccountID != device.AccountID {
		fail()
		return
	}
	var session webauthn.SessionData
	if json.Unmarshal(ceremony.SessionData, &session) != nil {
		fail()
		return
	}
	parsed, err := protocol.ParseCredentialRequestResponseBytes(req.Credential)
	if err != nil {
		fail()
		return
	}
	passkeys, err := a.Store.ListPasskeys(r.Context(), device.AccountID)
	handle, handleErr := a.Store.PasskeyUserHandle(r.Context(), device.AccountID, false)
	if err != nil || handleErr != nil {
		fail()
		return
	}
	// The credential must belong to the ceremony's account, and a user handle
	// the authenticator sends must be that account's.
	var row *storage.PasskeyCredential
	for i := range passkeys {
		if subtle.ConstantTimeCompare(passkeys[i].CredentialID, parsed.RawID) == 1 {
			row = &passkeys[i]
		}
	}
	if row == nil {
		fail()
		return
	}
	if handleBytes := parsed.Response.UserHandle; len(handleBytes) > 0 && subtle.ConstantTimeCompare(handleBytes, handle) != 1 {
		fail()
		return
	}
	user := passkeyUser{handle: handle, name: device.Username, credentials: libraryCredentials(passkeys)}
	// The library checks the challenge, origin, RP ID hash, the UP and UV
	// flags, the signature and a change in backup eligibility.
	credential, err := a.Passkeys.wa.ValidateLogin(user, session, parsed)
	if err != nil {
		fail()
		return
	}
	received := parsed.Response.AuthenticatorData.Counter
	if row.SignCount > 0 && received > 0 && received <= row.SignCount {
		a.recordAuditEvent(r.Context(), &device.AccountID, "passkey.clone_warning", map[string]string{"passkey_id": row.ID})
		fail()
		return
	}
	newCount := row.SignCount
	if received > newCount {
		newCount = received
	}
	token, tokenHash, err := auth.NewToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "token_create_failed")
		return
	}
	if passkeyBeforeSessionHook != nil {
		passkeyBeforeSessionHook()
	}
	err = a.Store.FinishPasskeyLogin(r.Context(), storage.PasskeyLoginInput{
		CeremonyID: ceremony.ID, AccountID: device.AccountID, DeviceID: device.DeviceID,
		VerifiedDeviceAuthHash: device.DeviceAuthHash, PasskeyID: row.ID,
		ReadSignCount: row.SignCount, NewSignCount: newCount,
		BackupState: credential.Flags.BackupState, TokenHash: tokenHash,
	})
	if errors.Is(err, storage.ErrUnauthorized) {
		writeError(w, http.StatusUnauthorized, "invalid_credentials")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "session_create_failed")
		return
	}
	a.LoginBackoff.SucceededAny(check.source, check.accountDevice)
	a.recordAuditEvent(r.Context(), &device.AccountID, "session.login", map[string]string{"device_id": device.DeviceID, "method": "passkey"})
	writeJSON(w, http.StatusOK, map[string]interface{}{"token": token, "account_id": device.AccountID, "device_id": device.DeviceID, "role": device.Role})
}

// passkeyBeforeSessionHook, when set by a test, runs between a passkey
// verification and the writer transaction.
var passkeyBeforeSessionHook func()

func passkeyJSON(c storage.PasskeyCredential) map[string]interface{} {
	out := map[string]interface{}{
		"id": c.ID, "name": c.Name,
		"created_at": c.CreatedAt.Format(time.RFC3339),
		"synced":     c.BackupState,
	}
	if c.LastUsedAt != nil {
		out["last_used_at"] = c.LastUsedAt.Format(time.RFC3339)
	} else {
		out["last_used_at"] = nil
	}
	return out
}

func (a *API) listPasskeys(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	list, err := a.Store.ListPasskeys(r.Context(), principal.AccountID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "passkeys_list_failed")
		return
	}
	out := make([]map[string]interface{}, 0, len(list))
	for _, c := range list {
		out = append(out, passkeyJSON(c))
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"passkeys": out})
}

// passkeyRegisterOptions needs a recent password check.
func (a *API) passkeyRegisterOptions(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if !a.passkeysOn(w) {
		return
	}
	passkeys, err := a.Store.ListPasskeys(r.Context(), principal.AccountID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "passkey_options_failed")
		return
	}
	if len(passkeys) >= storage.MaxPasskeysPerAccount {
		writeError(w, http.StatusConflict, "passkey_limit")
		return
	}
	username, err := a.Store.PasskeyAccountUsername(r.Context(), principal.AccountID)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	handle, err := a.Store.PasskeyUserHandle(r.Context(), principal.AccountID, true)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "passkey_options_failed")
		return
	}
	creds := libraryCredentials(passkeys)
	user := passkeyUser{handle: handle, name: username, credentials: creds}
	creation, session, err := a.Passkeys.wa.BeginRegistration(user,
		webauthn.WithCredentialParameters(passkeyAlgorithms),
		webauthn.WithExclusions(webauthn.Credentials(creds).CredentialDescriptors()))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "passkey_options_failed")
		return
	}
	a.writeCeremony(w, r, http.StatusOK, storage.PasskeyCeremonyRegister, principal.AccountID, principal.DeviceID, session, creation.Response)
}

type passkeyRegisterRequest struct {
	CeremonyID string          `json:"ceremony_id"`
	Name       string          `json:"name"`
	Credential json.RawMessage `json:"credential"`
}

func (a *API) passkeyRegister(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if !a.passkeysOn(w) {
		return
	}
	var req passkeyRegisterRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	name := strings.TrimSpace(req.Name)
	if name == "" || len([]rune(name)) > storage.MaxPasskeyNameLength {
		writeError(w, http.StatusBadRequest, "invalid_name")
		return
	}
	ceremony, err := a.Store.PasskeyCeremonyByID(r.Context(), strings.TrimSpace(req.CeremonyID), storage.PasskeyCeremonyRegister)
	if err != nil || ceremony.AccountID != principal.AccountID || ceremony.DeviceID != principal.DeviceID {
		writeError(w, http.StatusBadRequest, "invalid_passkey")
		return
	}
	var session webauthn.SessionData
	if json.Unmarshal(ceremony.SessionData, &session) != nil {
		writeError(w, http.StatusBadRequest, "invalid_passkey")
		return
	}
	parsed, err := protocol.ParseCredentialCreationResponseBytes(req.Credential)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_passkey")
		return
	}
	username, err := a.Store.PasskeyAccountUsername(r.Context(), principal.AccountID)
	handle, handleErr := a.Store.PasskeyUserHandle(r.Context(), principal.AccountID, false)
	if err != nil || handleErr != nil {
		writeError(w, http.StatusBadRequest, "invalid_passkey")
		return
	}
	user := passkeyUser{handle: handle, name: username}
	credential, err := a.Passkeys.wa.CreateCredential(user, session, parsed)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_passkey")
		return
	}
	algorithm, ok := coseAlgorithm(credential.PublicKey)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_passkey")
		return
	}
	transports := make([]string, 0, len(credential.Transport))
	for _, t := range credential.Transport {
		transports = append(transports, string(t))
	}
	id, err := a.Store.AddPasskey(r.Context(), storage.AddPasskeyInput{
		CeremonyID: ceremony.ID, AccountID: principal.AccountID, DeviceID: principal.DeviceID, Name: name,
		Credential: storage.PasskeyCredential{
			CredentialID: credential.ID, PublicKey: credential.PublicKey, Algorithm: algorithm,
			SignCount: credential.Authenticator.SignCount, BackupEligible: credential.Flags.BackupEligible,
			BackupState: credential.Flags.BackupState, Transports: strings.Join(transports, ","),
		},
	})
	switch {
	case errors.Is(err, storage.ErrPasskeyLimit):
		writeError(w, http.StatusConflict, "passkey_limit")
	case errors.Is(err, storage.ErrPasskeyDuplicate):
		writeError(w, http.StatusConflict, "passkey_exists")
	case errors.Is(err, storage.ErrUnauthorized):
		writeError(w, http.StatusBadRequest, "invalid_passkey")
	case err != nil:
		handleStorageError(w, err)
	default:
		writeJSON(w, http.StatusCreated, map[string]string{"id": id})
	}
}

func coseAlgorithm(key []byte) (int64, bool) {
	parsed, err := webauthncose.ParsePublicKey(key)
	if err != nil {
		return 0, false
	}
	switch k := parsed.(type) {
	case webauthncose.EC2PublicKeyData:
		return k.Algorithm, true
	case webauthncose.OKPPublicKeyData:
		return k.Algorithm, true
	case webauthncose.RSAPublicKeyData:
		return k.Algorithm, true
	}
	return 0, false
}

func (a *API) renamePasskey(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		Name string `json:"name"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if err := a.Store.RenamePasskey(r.Context(), principal.AccountID, r.PathValue("id"), req.Name); err != nil {
		if errors.Is(err, storage.ErrInvalidInput) {
			writeError(w, http.StatusBadRequest, "invalid_name")
			return
		}
		handleStorageError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) deletePasskey(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if err := a.Store.DeletePasskey(r.Context(), principal.AccountID, r.PathValue("id")); err != nil {
		handleStorageError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// assetLinks serves /.well-known/assetlinks.json for the configured
// Android apps; 404 while passkeys are off or the list is empty.
func (a *API) assetLinks(w http.ResponseWriter, r *http.Request) {
	if a.Passkeys == nil || len(a.Passkeys.cfg.AndroidApps) == 0 {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	entries := make([]map[string]interface{}, 0, len(a.Passkeys.cfg.AndroidApps))
	for _, app := range a.Passkeys.cfg.AndroidApps {
		entries = append(entries, map[string]interface{}{
			"relation": []string{"delegate_permission/common.get_login_creds"},
			"target": map[string]interface{}{
				"namespace": "android_app", "package_name": app.Package,
				"sha256_cert_fingerprints": []string{app.FingerprintText()},
			},
		})
	}
	writeJSON(w, http.StatusOK, entries)
}

// appleAssociation serves /.well-known/apple-app-site-association.
func (a *API) appleAssociation(w http.ResponseWriter, r *http.Request) {
	if a.Passkeys == nil || len(a.Passkeys.cfg.AppleAppIDs) == 0 {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"webcredentials": map[string]interface{}{"apps": a.Passkeys.cfg.AppleAppIDs}})
}

// passkeySetupStatus is the passkeys object of GET /api/v1/setup/status.
func (a *API) passkeySetupStatus() map[string]interface{} {
	return map[string]interface{}{
		"rp_id":   a.Passkeys.cfg.RPID,
		"android": len(a.Passkeys.cfg.AndroidApps) > 0,
		"apple":   len(a.Passkeys.cfg.AppleAppIDs) > 0,
	}
}
