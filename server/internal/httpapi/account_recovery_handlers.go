package httpapi

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"math/big"
	"net/http"
	"strings"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
)

// K0 recovery enrollment (docs/designs/K0-recovery-enrollment.md, package
// R2): someone who lost every device gets the account back on a new device
// with the password and the recovery key (D49), after a wait while another
// device is active.

const (
	accountRecoveryPrefix = "/api/v1/account-recovery"

	// DefaultRecoveryFailureCap is D79's daily cap on right-password,
	// wrong-recovery-key claims per account (or decoy) id.
	DefaultRecoveryFailureCap = 50

	recoveryProofLabel = "veritra-k0-recovery-proof-v1"
)

// recoveryDecoyAuthKey is a valid Ed25519 public key with no known use. A
// claim for an account without a recovery key (or with no account) verifies
// against it, so every claim does the same signature work.
var recoveryDecoyAuthKey = func() ed25519.PublicKey {
	seed := sha256.Sum256([]byte("veritra-k0-recovery-decoy-auth-v1"))
	return ed25519.NewKeyFromSeed(seed[:]).Public().(ed25519.PublicKey)
}()

// recoveryClaimWorkHook, when set by a test, observes each expensive or
// stateful step of a claim, so tests can check that every failing path does
// the same work.
var recoveryClaimWorkHook func(step string)

func recoveryClaimWork(step string) {
	if recoveryClaimWorkHook != nil {
		recoveryClaimWorkHook(step)
	}
}

func (a *API) registerAccountRecoveryRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/account/recovery-key", a.withAuth(a.getRecoveryKey))
	mux.HandleFunc("PUT /api/v1/account/recovery-key", a.requireRecoveryConfigured(a.withRecentAuth(a.putRecoveryKey)))
	mux.HandleFunc("POST "+accountRecoveryPrefix+"/enrollment", a.requireRecoveryConfigured(a.reserveAccountRecovery))
	mux.HandleFunc("POST "+accountRecoveryPrefix+"/claim", a.requireRecoveryConfigured(a.claimAccountRecovery))
	mux.HandleFunc("GET "+accountRecoveryPrefix+"/{id}/status", a.requireRecoveryConfigured(a.accountRecoveryStatus))
	mux.HandleFunc("POST "+accountRecoveryPrefix+"/{id}/cancel", a.requireRecoveryConfigured(a.withRecentAuth(a.cancelAccountRecovery)))
	// Every other path under the prefix answers 503 the same way while
	// recovery is off, and 404 once it is on.
	mux.HandleFunc(accountRecoveryPrefix+"/", a.requireRecoveryConfigured(func(w http.ResponseWriter, _ *http.Request) {
		writeError(w, http.StatusNotFound, "not_found")
	}))
}

func (a *API) recoveryConfigured() bool {
	return strings.TrimSpace(a.PublicOrigin) != ""
}

// requireRecoveryConfigured answers 503 recovery_not_configured, the same
// for every account and before any other check, while the public origin is
// unset.
func (a *API) requireRecoveryConfigured(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !a.recoveryConfigured() {
			writeError(w, http.StatusServiceUnavailable, "recovery_not_configured")
			return
		}
		next(w, r)
	}
}

func (a *API) recoveryFailureCap() int {
	if a.RecoveryFailureCap > 0 {
		return a.RecoveryFailureCap
	}
	return DefaultRecoveryFailureCap
}

func (a *API) recoveryActiveWindow() time.Duration {
	if a.RecoveryActiveWindow > 0 {
		return a.RecoveryActiveWindow
	}
	return 7 * 24 * time.Hour
}

func (a *API) recoveryWait() time.Duration {
	if a.RecoveryWait > 0 {
		return a.RecoveryWait
	}
	return 7 * 24 * time.Hour
}

// recoveryProofMessage is the message the recovery key's auth key signs:
// "veritra-k0-recovery-proof-v1" | lp(challenge) | signing_key |
// SHA-256(key_package) | lp(origin), with lp a u16 big-endian length. The
// origin is always the configured public origin, never anything from the
// request, so a proof made for a relaying look-alike origin fails here.
func recoveryProofMessage(challenge, signingKey, keyPackage []byte, origin string) []byte {
	keyPackageHash := sha256.Sum256(keyPackage)
	message := []byte(recoveryProofLabel)
	message = appendLengthPrefixed(message, challenge)
	message = append(message, signingKey...)
	message = append(message, keyPackageHash[:]...)
	return appendLengthPrefixed(message, []byte(origin))
}

func appendLengthPrefixed(output, value []byte) []byte {
	var size [2]byte
	binary.BigEndian.PutUint16(size[:], uint16(len(value)))
	output = append(output, size[:]...)
	return append(output, value...)
}

// recoveryBackoffKeys are both derived from the reservation's account id,
// never a username in the body. The source key takes every failure; the
// account key is checked and counted only for a caller whose recovery proof
// verified.
func (a *API) recoveryBackoffKeys(r *http.Request, accountID string) (source, account string) {
	return "recovery-source\x00" + a.clientIP(r) + "\x00" + accountID, "recovery-account\x00" + accountID
}

func (a *API) reserveAccountRecovery(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username string `json:"username"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if !validUsername(req.Username) {
		writeError(w, http.StatusBadRequest, "invalid_identity")
		return
	}
	reservation, err := a.Store.ReserveRecoveryEnrollment(r.Context(), req.Username)
	if errors.Is(err, storage.ErrRecoveryUnavailable) {
		writeError(w, http.StatusServiceUnavailable, "recovery_not_configured")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "enrollment_reservation_failed")
		return
	}
	writeJSON(w, http.StatusCreated, enrollmentReservationResponse(reservation))
}

type recoveryClaimRequest struct {
	EnrollmentReservationID string `json:"enrollment_reservation_id"`
	Password                string `json:"password"`
	DeviceName              string `json:"device_name"`
	DeviceKeyPackage        []byte `json:"device_key_package"`
	SigningKey              []byte `json:"signing_key"`
	ChallengeSignature      []byte `json:"challenge_signature"`
	RecoverySignature       []byte `json:"recovery_signature"`
}

// claimAccountRecovery checks a recovery claim. The account is only ever the
// reservation's account_id. Unknown, suspended and deleted accounts (decoy
// ids), accounts without a recovery key, a wrong password and a wrong
// recovery key all do the same work and get the same 401.
func (a *API) claimAccountRecovery(w http.ResponseWriter, r *http.Request) {
	var req recoveryClaimRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	// Cheap shape checks and the device's own proof over public data come
	// before any hashing slot, as in register.
	if !validDisplayName(req.DeviceName) {
		writeError(w, http.StatusBadRequest, "invalid_device_name")
		return
	}
	if isReservedNonProductionKeyPackage(req.DeviceKeyPackage) {
		writeError(w, http.StatusBadRequest, "non_production_device_key_package")
		return
	}
	if len(req.DeviceKeyPackage) < 64 || len(req.DeviceKeyPackage) > 48<<10 {
		writeError(w, http.StatusBadRequest, "invalid_device_key_package")
		return
	}
	if len(req.SigningKey) != ed25519.PublicKeySize || len(req.ChallengeSignature) != ed25519.SignatureSize || len(req.RecoverySignature) != ed25519.SignatureSize {
		writeError(w, http.StatusBadRequest, "invalid_enrollment")
		return
	}
	reservation, err := a.Store.RecoveryReservation(r.Context(), req.EnrollmentReservationID)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_enrollment")
		return
	}
	if !ed25519.Verify(ed25519.PublicKey(req.SigningKey), enrollmentProofMessage(reservation.Challenge, req.SigningKey, req.DeviceKeyPackage), req.ChallengeSignature) {
		writeError(w, http.StatusBadRequest, "invalid_enrollment")
		return
	}
	sourceKey, accountKey := a.recoveryBackoffKeys(r, reservation.AccountID)
	if retryAfter := a.LoginBackoff.RetryAfterAny(loginBackoffNow(), sourceKey); retryAfter > 0 {
		writeRetryError(w, "recovery_backoff", retryAfter)
		return
	}
	record, lookupErr := a.Store.RecoveryClaimRecord(r.Context(), reservation.AccountID)
	if lookupErr != nil && !errors.Is(lookupErr, storage.ErrUnauthorized) {
		writeError(w, http.StatusInternalServerError, "recovery_claim_failed")
		return
	}
	exists := lookupErr == nil
	storedHash := ""
	authKey := recoveryDecoyAuthKey
	hasKey := exists && len(record.AuthPublicKey) == ed25519.PublicKeySize
	if exists {
		storedHash = record.PasswordHash
	}
	if hasKey {
		authKey = ed25519.PublicKey(record.AuthPublicKey)
	}
	// The claim never rehashes: a legacy hash upgrades at the next login.
	recoveryClaimWork("password")
	check, err := a.passwordService().Verify(r.Context(), auth.Anonymous, storedHash, req.Password)
	if err != nil {
		writePasswordHashFailure(w, err)
		return
	}
	recoveryClaimWork("recovery_signature")
	signatureOK := ed25519.Verify(authKey, recoveryProofMessage(reservation.Challenge, req.SigningKey, req.DeviceKeyPackage, a.PublicOrigin), req.RecoverySignature)
	passwordOK := exists && check.OK
	rkOK := hasKey && signatureOK
	if rkOK {
		if retryAfter := a.LoginBackoff.RetryAfterAny(loginBackoffNow(), accountKey); retryAfter > 0 {
			writeRetryError(w, "recovery_backoff", retryAfter)
			return
		}
	}
	// D79: every claim that got this far writes the counter, so all paths
	// cost the same; only right-password-wrong-key counts.
	recoveryClaimWork("attempt")
	attempt, err := a.Store.RecordRecoveryAttempt(r.Context(), reservation.AccountID, passwordOK && !rkOK, a.recoveryFailureCap(), time.Now().UTC())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "recovery_claim_failed")
		return
	}
	if attempt.LeakEventID != 0 {
		a.publishCommittedEvent(r.Context(), []string{reservation.AccountID}, realtime.Event{Version: "v1", Type: "account.password_leak_suspected", ID: attempt.LeakEventID, Payload: map[string]string{"day": time.Now().UTC().Format("2006-01-02")}, CreatedAt: time.Now().UTC()})
	}
	capped := attempt.Failures > a.recoveryFailureCap()
	if !passwordOK || !rkOK || capped {
		failedKeys := []string{sourceKey}
		if rkOK {
			failedKeys = append(failedKeys, accountKey)
		}
		if retryAfter := a.LoginBackoff.FailedAny(loginBackoffNow(), failedKeys...); retryAfter > 0 {
			writeRetryError(w, "recovery_backoff", retryAfter)
			return
		}
		writeError(w, http.StatusUnauthorized, "invalid_credentials")
		return
	}
	claimToken, claimTokenHash, err := auth.NewToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "claim_token_create_failed")
		return
	}
	deviceSecret, deviceAuthHash, err := auth.NewToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "device_secret_create_failed")
		return
	}
	claimed, err := a.Store.ClaimRecovery(r.Context(), storage.RecoveryClaimInput{
		ReservationID:        reservation.ID,
		AccountID:            reservation.AccountID,
		DeviceName:           req.DeviceName,
		KeyPackage:           req.DeviceKeyPackage,
		SigningKey:           req.SigningKey,
		DeviceAuthHash:       deviceAuthHash,
		ClaimTokenHash:       claimTokenHash,
		VerifiedPasswordHash: record.PasswordHash,
		VerifiedAuthKey:      record.AuthPublicKey,
		ActiveWindow:         a.recoveryActiveWindow(),
		Wait:                 a.recoveryWait(),
	})
	if err != nil {
		switch {
		case errors.Is(err, storage.ErrUnauthorized):
			// The password or recovery key changed after the checks above.
			writeError(w, http.StatusUnauthorized, "invalid_credentials")
		case errors.Is(err, storage.ErrEnrollmentInvalid):
			writeError(w, http.StatusBadRequest, "invalid_enrollment")
		default:
			writeError(w, http.StatusInternalServerError, "recovery_claim_failed")
		}
		return
	}
	a.LoginBackoff.SucceededAny(sourceKey, accountKey)
	request := claimed.Request
	now := time.Now().UTC()
	if claimed.ReplacedEventID != 0 {
		a.publishCommittedEvent(r.Context(), []string{request.AccountID}, realtime.Event{Version: "v1", Type: "account.recovery.cancelled", ID: claimed.ReplacedEventID, Payload: map[string]string{"request_id": claimed.ReplacedRequest, "reason": storage.RecoveryCancelledReplaced}, CreatedAt: now})
	}
	a.publishCommittedEvent(r.Context(), []string{request.AccountID}, realtime.Event{Version: "v1", Type: "account.recovery.pending", ID: claimed.PendingEventID, Payload: map[string]interface{}{"request_id": request.ID, "device_name": request.DeviceName, "ready_at": request.ReadyAt}, CreatedAt: now})
	a.recordAuditEvent(r.Context(), &request.AccountID, "account.recovery_requested", map[string]interface{}{"request_id": request.ID, "device_id": request.DeviceID, "waits": claimed.ActiveDeviceSeen})
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusAccepted, map[string]interface{}{
		"request_id":    request.ID,
		"claim_token":   claimToken,
		"device_secret": deviceSecret,
		"state":         request.State,
		"ready_at":      request.ReadyAt,
	})
}

// accountRecoveryStatus answers the claimant's poll. Once the request is
// ready it completes it; the session token is returned only by the call
// that completed it, and later calls answer "completed" without a token (the
// client then signs in with login and the claim's device secret).
func (a *API) accountRecoveryStatus(w http.ResponseWriter, r *http.Request) {
	claimTokenHash, ok := deviceLinkV3ClaimTokenHash(w, r)
	if !ok {
		return
	}
	sessionToken, sessionTokenHash, err := auth.NewToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "token_create_failed")
		return
	}
	completion, err := a.Store.CompleteRecovery(r.Context(), r.PathValue("id"), claimTokenHash, sessionTokenHash)
	w.Header().Set("Cache-Control", "no-store")
	switch {
	case errors.Is(err, storage.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found")
		return
	case errors.Is(err, storage.ErrRecoveryCancelled):
		writeError(w, http.StatusGone, "recovery_cancelled")
		return
	case err != nil:
		writeError(w, http.StatusInternalServerError, "recovery_status_failed")
		return
	}
	if completion.State == storage.RecoveryStateWaiting {
		writeJSON(w, http.StatusAccepted, map[string]interface{}{"state": completion.State, "ready_at": completion.ReadyAt})
		return
	}
	response := map[string]interface{}{"state": completion.State, "account": completion.Account, "device": completion.Device}
	if completion.SessionIssued {
		accountID := completion.Account.ID
		now := time.Now().UTC()
		for i, deviceID := range completion.RevokedDevices {
			a.publishCommittedEvent(r.Context(), []string{accountID}, realtime.Event{Version: "v1", Type: "device.revoked", ID: completion.RevokedEventIDs[i], Payload: map[string]string{"device_id": deviceID}, CreatedAt: now})
			a.Hub.DisconnectDevice(accountID, deviceID)
		}
		revoked := completion.RevokedDevices
		if revoked == nil {
			revoked = []string{}
		}
		a.publishCommittedEvent(r.Context(), []string{accountID}, realtime.Event{Version: "v1", Type: "account.recovered", ID: completion.RecoveredEventID, Payload: map[string]interface{}{"device_id": completion.Device.ID, "revoked": revoked}, CreatedAt: now})
		response["token"] = sessionToken
	}
	writeJSON(w, http.StatusOK, response)
}

func (a *API) cancelAccountRecovery(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	requestID := strings.TrimSpace(r.PathValue("id"))
	eventID, err := a.Store.CancelRecoveryRequest(r.Context(), principal.AccountID, requestID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	a.publishCommittedEvent(r.Context(), []string{principal.AccountID}, realtime.Event{Version: "v1", Type: "account.recovery.cancelled", ID: eventID, Payload: map[string]string{"request_id": requestID, "reason": storage.RecoveryCancelledByOwner}, CreatedAt: time.Now().UTC()})
	a.recordAuditEvent(r.Context(), &principal.AccountID, "account.recovery_cancelled", map[string]string{"request_id": requestID, "reason": storage.RecoveryCancelledByOwner, "device_id": principal.DeviceID})
	writeJSON(w, http.StatusOK, map[string]string{"state": "cancelled"})
}

func (a *API) getRecoveryKey(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	status, err := a.Store.RecoveryKeyStatus(r.Context(), principal.AccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, recoveryKeyPayload(a.recoveryConfigured(), status))
}

func recoveryKeyPayload(available bool, status storage.RecoveryKeyStatus) map[string]interface{} {
	payload := map[string]interface{}{"available": available, "configured": status.Configured}
	if status.Configured {
		payload["rk_id"] = status.RKID
		payload["set_at"] = status.SetAt
	}
	if status.Pending != nil {
		payload["pending_request"] = map[string]interface{}{
			"id":          status.Pending.ID,
			"device_name": status.Pending.DeviceName,
			"created_at":  status.Pending.CreatedAt,
			"ready_at":    status.Pending.ReadyAt,
		}
	}
	return payload
}

func (a *API) putRecoveryKey(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		RKAuthPub []byte `json:"rk_auth_pub"`
		RKID      []byte `json:"rk_id"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if !validRecoveryAuthKey(req.RKAuthPub) || len(req.RKID) != 16 {
		writeError(w, http.StatusBadRequest, "invalid_recovery_key")
		return
	}
	result, err := a.Store.SetRecoveryKey(r.Context(), principal.AccountID, req.RKAuthPub, req.RKID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	now := time.Now().UTC()
	if result.CancelledEventID != 0 {
		a.publishCommittedEvent(r.Context(), []string{principal.AccountID}, realtime.Event{Version: "v1", Type: "account.recovery.cancelled", ID: result.CancelledEventID, Payload: map[string]string{"reason": storage.RecoveryCancelledKeyChanged}, CreatedAt: now})
	}
	a.publishCommittedEvent(r.Context(), []string{principal.AccountID}, realtime.Event{Version: "v1", Type: "account.recovery_key.set", ID: result.EventID, Payload: map[string]interface{}{"rk_id": req.RKID}, CreatedAt: now})
	a.recordAuditEvent(r.Context(), &principal.AccountID, "account.recovery_key_set", map[string]string{"device_id": principal.DeviceID})
	status, err := a.Store.RecoveryKeyStatus(r.Context(), principal.AccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, recoveryKeyPayload(true, status))
}

// recoverySmallOrderKeys are the canonical encodings of the eight Ed25519
// points of small order. A signature for any message can be forged under
// them without a secret key, so none may be a recovery auth key.
var recoverySmallOrderKeys = func() [][]byte {
	hexKeys := []string{
		"0100000000000000000000000000000000000000000000000000000000000000",
		"ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
		"0000000000000000000000000000000000000000000000000000000000000000",
		"0000000000000000000000000000000000000000000000000000000000000080",
		"26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05",
		"26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85",
		"c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a",
		"c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa",
	}
	keys := make([][]byte, len(hexKeys))
	for i, value := range hexKeys {
		key, err := hex.DecodeString(value)
		if err != nil || len(key) != ed25519.PublicKeySize {
			panic("bad small-order key")
		}
		keys[i] = key
	}
	return keys
}()

var (
	ed25519FieldPrime = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 255), big.NewInt(19))
	// ed25519CurveD is -121665/121666 mod p.
	ed25519CurveD = func() *big.Int {
		d := new(big.Int).ModInverse(big.NewInt(121666), ed25519FieldPrime)
		d.Mul(d, big.NewInt(-121665))
		return d.Mod(d, ed25519FieldPrime)
	}()
)

// validRecoveryAuthKey reports whether key is a canonical encoding of an
// Ed25519 point on the curve that is not of small order. It runs only when
// an account sets its recovery key, so the big-integer check costs nothing
// that matters.
func validRecoveryAuthKey(key []byte) bool {
	if len(key) != ed25519.PublicKeySize {
		return false
	}
	for _, small := range recoverySmallOrderKeys {
		if bytes.Equal(key, small) {
			return false
		}
	}
	littleEndian := bytes.Clone(key)
	sign := littleEndian[31] >> 7
	littleEndian[31] &= 0x7f
	bigEndian := make([]byte, len(littleEndian))
	for i, b := range littleEndian {
		bigEndian[len(littleEndian)-1-i] = b
	}
	y := new(big.Int).SetBytes(bigEndian)
	if y.Cmp(ed25519FieldPrime) >= 0 {
		return false
	}
	// x^2 = (y^2 - 1) / (d*y^2 + 1) must have a square root.
	y2 := new(big.Int).Mul(y, y)
	y2.Mod(y2, ed25519FieldPrime)
	u := new(big.Int).Sub(y2, big.NewInt(1))
	u.Mod(u, ed25519FieldPrime)
	v := new(big.Int).Mul(ed25519CurveD, y2)
	v.Add(v, big.NewInt(1))
	v.Mod(v, ed25519FieldPrime)
	vInverse := new(big.Int).ModInverse(v, ed25519FieldPrime)
	if vInverse == nil {
		return false
	}
	x2 := u.Mul(u, vInverse)
	x2.Mod(x2, ed25519FieldPrime)
	x := new(big.Int).ModSqrt(x2, ed25519FieldPrime)
	if x == nil {
		return false
	}
	// x = 0 has only the positive encoding.
	return x.Sign() != 0 || sign == 0
}
