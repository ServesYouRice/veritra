package storage

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"private-messenger/server/internal/admission"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/domain"
)

const DeviceLinkV3Protocol = "veritra-device-link-v3"
const deviceLinkV3TransferLifetime = 7 * 24 * time.Hour

var ErrDeviceLinkSessionUnavailable = errors.New("initial linked-device session is unavailable")

// DeviceLinkV3 contains only public, immutable enrollment context. Credential
// hashes and key-package bytes stay in the private storage record below.
type DeviceLinkV3 struct {
	ID                 string     `json:"id"`
	Code               string     `json:"code,omitempty"`
	ProtocolVersion    string     `json:"protocol_version"`
	State              string     `json:"state"`
	AccountID          string     `json:"account_id"`
	SourceDeviceID     string     `json:"created_by_device_id"`
	ServerOrigin       string     `json:"server_origin"`
	LinkNonce          []byte     `json:"link_nonce"`
	ExistingSigningKey []byte     `json:"existing_signing_key"`
	RecipientDeviceID  string     `json:"claimed_device_id,omitempty"`
	DeviceName         string     `json:"claimed_device_name,omitempty"`
	SigningKey         []byte     `json:"claimed_signing_key,omitempty"`
	TransferPublicKey  []byte     `json:"transfer_public_key,omitempty"`
	TranscriptHash     []byte     `json:"transcript_hash,omitempty"`
	ClaimTag           []byte     `json:"claim_tag,omitempty"`
	ApprovalTag        []byte     `json:"approval_tag,omitempty"`
	ClaimRequestHash   string     `json:"claim_request_hash,omitempty"`
	CreatedAt          time.Time  `json:"created_at"`
	ExpiresAt          time.Time  `json:"expires_at"`
	ClaimedAt          *time.Time `json:"claimed_at,omitempty"`
	ApprovedAt         *time.Time `json:"approved_at,omitempty"`
	TransferExpiresAt  *time.Time `json:"transfer_expires_at,omitempty"`
	CompletedAt        *time.Time `json:"completed_at,omitempty"`
}

type deviceLinkV3Record struct {
	DeviceLinkV3
	ttlSeconds           int64
	reservationRequestID string
	challenge            []byte
	keyPackage           []byte
	claimTokenHash       string
	deviceSecretHash     string
	initialSessionHash   string
}

type DeviceLinkV3ClaimInput struct {
	Code                    string `json:"code"`
	ProtocolVersion         string `json:"protocol_version"`
	ServerOrigin            string `json:"server_origin"`
	ReservationRequestID    string `json:"reservation_request_id"`
	EnrollmentReservationID string `json:"enrollment_reservation_id"`
	DeviceName              string `json:"device_name"`
	DeviceKeyPackage        []byte `json:"device_key_package"`
	SigningKey              []byte `json:"signing_key"`
	TransferPublicKey       []byte `json:"transfer_public_key"`
	TranscriptHash          []byte `json:"transcript_hash"`
	ClaimTag                []byte `json:"claim_tag"`
	ClaimTokenHash          string `json:"claim_token_hash"`
	DeviceSecretHash        string `json:"device_secret_hash"`
	InitialSessionTokenHash string `json:"initial_session_token_hash"`
	ChallengeSignature      []byte `json:"challenge_signature"`
}

type DeviceLinkV3Completion struct {
	LinkID                  string    `json:"link_id"`
	AccountID               string    `json:"account_id"`
	DeviceID                string    `json:"device_id"`
	ServerOrigin            string    `json:"server_origin"`
	ClaimRequestHash        string    `json:"claim_request_hash"`
	TranscriptHash          []byte    `json:"transcript_hash"`
	InitialSessionTokenHash string    `json:"initial_session_token_hash"`
	CompletedAt             time.Time `json:"completed_at"`
}

// ValidDeviceLinkV3Origin checks the exact canonical value the clients sign.
// This value is context only: it never authorizes a fetch or changes a host.
func ValidDeviceLinkV3Origin(origin string) bool {
	if origin == "" || len(origin) > 2048 || !utf8.ValidString(origin) || strings.TrimSpace(origin) != origin {
		return false
	}
	u, err := url.Parse(origin)
	if err != nil || u.Opaque != "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.ForceQuery || strings.Contains(origin, "#") || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") {
		return false
	}
	host := u.Hostname()
	if host == "" || host != strings.ToLower(host) {
		return false
	}
	if u.Scheme == "http" && host != "localhost" {
		ip := net.ParseIP(host)
		if ip == nil || !ip.IsLoopback() {
			return false
		}
	}
	canonicalHost := host
	if strings.Contains(host, ":") {
		canonicalHost = "[" + host + "]"
	}
	if port := u.Port(); port != "" {
		value, err := strconv.Atoi(port)
		if err != nil || value < 0 || value > 65535 || strconv.Itoa(value) != port || (u.Scheme == "https" && value == 443) || (u.Scheme == "http" && value == 80) {
			return false
		}
		canonicalHost += ":" + port
	}
	return origin == u.Scheme+"://"+canonicalHost
}

func validV3Hash(value string) bool {
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size && hex.EncodeToString(decoded) == value
}

func v3Equal(left, right []byte) bool {
	return len(left) == len(right) && subtle.ConstantTimeCompare(left, right) == 1
}

func validV3Name(name string) bool {
	return name != "" && len(name) <= 64 && utf8.ValidString(name) && strings.TrimSpace(name) == name
}

// DeviceLinkV3ProofMessage mirrors the frozen native proof, not JSON ordering.
// Its domain is raw; only the next eight variable-width fields use u16-BE LP.
func DeviceLinkV3ProofMessage(input DeviceLinkV3ClaimInput, reservation EnrollmentReservation) ([]byte, error) {
	if input.ProtocolVersion != DeviceLinkV3Protocol || !ValidDeviceLinkV3Origin(input.ServerOrigin) || !validV3Hash(input.Code) || !validV3Hash(input.ReservationRequestID) || !validV3Name(input.DeviceName) || len(input.DeviceKeyPackage) < 64 || len(input.DeviceKeyPackage) > 48<<10 || len(input.SigningKey) != 32 || len(input.TransferPublicKey) != 32 || len(input.TranscriptHash) != 32 || len(input.ClaimTag) != 32 || !validV3Hash(input.ClaimTokenHash) || !validV3Hash(input.DeviceSecretHash) || !validV3Hash(input.InitialSessionTokenHash) {
		return nil, ErrEnrollmentInvalid
	}
	requestID, _ := hex.DecodeString(input.ReservationRequestID)
	message := []byte("veritra-device-link-enrollment-v3")
	for _, field := range [][]byte{[]byte(input.ServerOrigin), []byte(input.Code), requestID, []byte(reservation.ID), []byte(reservation.AccountID), []byte(reservation.DeviceID), []byte(input.DeviceName), reservation.Challenge} {
		if len(field) == 0 || len(field) > 65535 {
			return nil, ErrEnrollmentInvalid
		}
		var size [2]byte
		binary.BigEndian.PutUint16(size[:], uint16(len(field)))
		message = append(message, size[:]...)
		message = append(message, field...)
	}
	packageHash := sha256.Sum256(input.DeviceKeyPackage)
	for _, field := range [][]byte{input.SigningKey, packageHash[:], input.TransferPublicKey, input.TranscriptHash, input.ClaimTag} {
		message = append(message, field...)
	}
	for _, hash := range []string{input.ClaimTokenHash, input.DeviceSecretHash, input.InitialSessionTokenHash} {
		field, _ := hex.DecodeString(hash)
		message = append(message, field...)
	}
	return message, nil
}

const deviceLinkV3Select = `SELECT v.id, v.code, v.account_id, v.source_device_id,
 v.server_origin, v.create_ttl_seconds, v.state, v.link_nonce,
 COALESCE(v.reservation_request_id,''), COALESCE(v.recipient_device_id,''), v.claim_challenge,
 COALESCE(v.device_name,''), v.key_package, v.signing_key, v.transfer_public_key,
 v.transcript_hash, v.claim_tag, v.approval_tag, COALESCE(v.claim_token_hash,''),
 COALESCE(v.device_secret_hash,''), COALESCE(v.initial_session_token_hash,''),
 COALESCE(v.claim_request_hash,''), v.created_at, v.expires_at, v.claimed_at,
 v.approved_at, v.transfer_expires_at, v.completed_at, source.signing_key
 FROM device_links_v3 v
 JOIN accounts a ON a.id=v.account_id AND a.status='active' AND a.deleted_at IS NULL
 JOIN devices source ON source.id=v.source_device_id AND source.account_id=v.account_id AND source.revoked_at IS NULL
 WHERE v.revoked_at IS NULL
 AND (v.state IN ('pending','claimed') OR EXISTS (
 SELECT 1 FROM devices recipient WHERE recipient.id=v.recipient_device_id
 AND recipient.account_id=v.account_id AND recipient.revoked_at IS NULL))`

func loadDeviceLinkV3(ctx context.Context, q queryRower, predicate string, args ...interface{}) (deviceLinkV3Record, error) {
	var link deviceLinkV3Record
	var created, expires string
	var claimed, approved, deadline, completed sql.NullString
	err := q.QueryRowContext(ctx, deviceLinkV3Select+predicate, args...).Scan(
		&link.ID, &link.Code, &link.AccountID, &link.SourceDeviceID, &link.ServerOrigin,
		&link.ttlSeconds, &link.State, &link.LinkNonce, &link.reservationRequestID,
		&link.RecipientDeviceID, &link.challenge, &link.DeviceName, &link.keyPackage,
		&link.SigningKey, &link.TransferPublicKey, &link.TranscriptHash, &link.ClaimTag,
		&link.ApprovalTag, &link.claimTokenHash, &link.deviceSecretHash, &link.initialSessionHash,
		&link.ClaimRequestHash, &created, &expires, &claimed, &approved, &deadline, &completed, &link.ExistingSigningKey)
	if errors.Is(err, sql.ErrNoRows) {
		return link, ErrDeviceLinkInvalid
	}
	if err != nil {
		return link, err
	}
	link.ProtocolVersion = DeviceLinkV3Protocol
	link.CreatedAt, link.ExpiresAt = parseTime(created), parseTime(expires)
	link.ClaimedAt, link.ApprovedAt = parseOptionalTime(claimed), parseOptionalTime(approved)
	link.TransferExpiresAt, link.CompletedAt = parseOptionalTime(deadline), parseOptionalTime(completed)
	return link, nil
}

func (v deviceLinkV3Record) validWindow(now time.Time) bool {
	if v.State == domain.DeviceLinkPending || v.State == domain.DeviceLinkClaimed {
		return v.ExpiresAt.After(now)
	}
	return (v.State == domain.DeviceLinkApproved || v.State == domain.DeviceLinkConsumed) && v.TransferExpiresAt != nil && v.TransferExpiresAt.After(now)
}

func (v deviceLinkV3Record) public() DeviceLinkV3 {
	result := v.DeviceLinkV3
	result.Code = ""
	return result
}

func (s *Store) CreateDeviceLinkV3(ctx context.Context, accountID, deviceID, code, origin string, ttl time.Duration) (DeviceLinkV3, error) {
	if !validV3Hash(code) || !ValidDeviceLinkV3Origin(origin) || ttl < 0 || ttl > 30*time.Minute || ttl%time.Second != 0 {
		return DeviceLinkV3{}, ErrInvalidInput
	}
	if ttl == 0 {
		ttl = 10 * time.Minute
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return DeviceLinkV3{}, err
	}
	defer tx.Rollback()
	var key []byte
	err = tx.QueryRowContext(ctx, `SELECT d.signing_key FROM devices d JOIN accounts a ON a.id=d.account_id WHERE d.id=? AND d.account_id=? AND d.revoked_at IS NULL AND a.status='active' AND a.deleted_at IS NULL`, deviceID, accountID).Scan(&key)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && len(key) != 32) {
		return DeviceLinkV3{}, ErrUnauthorized
	}
	if err != nil {
		return DeviceLinkV3{}, err
	}
	existing, err := loadDeviceLinkV3(ctx, tx, ` AND v.code=?`, code)
	if err == nil {
		if existing.AccountID != accountID || existing.SourceDeviceID != deviceID || existing.ServerOrigin != origin || existing.ttlSeconds != int64(ttl/time.Second) {
			return DeviceLinkV3{}, ErrIdempotencyConflict
		}
		if !existing.validWindow(time.Now().UTC()) {
			return DeviceLinkV3{}, ErrDeviceLinkInvalid
		}
		result := existing.public()
		result.Code = code
		return result, nil
	}
	if !errors.Is(err, ErrDeviceLinkInvalid) {
		return DeviceLinkV3{}, err
	}
	// A revoked/expired/inactive row is deliberately invisible to public
	// lookups, but its locator must not start a fresh enrollment.
	used, err := countRows(ctx, tx, `SELECT COUNT(*) FROM device_links_v3 WHERE code=?`, code)
	if err != nil {
		return DeviceLinkV3{}, err
	}
	if used != 0 {
		return DeviceLinkV3{}, ErrDeviceLinkInvalid
	}
	if err := s.checkDevices(ctx, tx, accountID); err != nil {
		return DeviceLinkV3{}, err
	}
	open, err := countPendingDeviceLinks(ctx, tx, accountID)
	if err != nil {
		return DeviceLinkV3{}, err
	}
	if open >= config.PendingDeviceLinksPerAccount {
		return DeviceLinkV3{}, s.refuse(admission.DeviceLinks, ErrDeviceLinkLimit)
	}
	id, err := domain.NewID("dlink")
	if err != nil {
		return DeviceLinkV3{}, err
	}
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return DeviceLinkV3{}, err
	}
	now := time.Now().UTC()
	expires := now.Add(ttl)
	_, err = tx.ExecContext(ctx, `INSERT INTO device_links_v3(id,code,account_id,source_device_id,server_origin,create_ttl_seconds,state,link_nonce,created_at,expires_at) VALUES(?,?,?,?,?,?,'pending',?,?,?)`, id, code, accountID, deviceID, origin, int64(ttl/time.Second), nonce, formatTime(now), formatTime(expires))
	if err != nil {
		return DeviceLinkV3{}, err
	}
	if err := tx.Commit(); err != nil {
		return DeviceLinkV3{}, err
	}
	return DeviceLinkV3{ID: id, Code: code, ProtocolVersion: DeviceLinkV3Protocol, State: domain.DeviceLinkPending, AccountID: accountID, SourceDeviceID: deviceID, ServerOrigin: origin, LinkNonce: nonce, ExistingSigningKey: key, CreatedAt: now, ExpiresAt: expires}, nil
}

func (s *Store) ReserveDeviceLinkV3(ctx context.Context, code, requestID string) (EnrollmentReservation, error) {
	if !validV3Hash(code) || !validV3Hash(requestID) {
		return EnrollmentReservation{}, ErrEnrollmentInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return EnrollmentReservation{}, err
	}
	defer tx.Rollback()
	link, err := loadDeviceLinkV3(ctx, tx, ` AND v.code=?`, code)
	if err != nil {
		return EnrollmentReservation{}, err
	}
	if !link.ExpiresAt.After(time.Now().UTC()) || (link.State != domain.DeviceLinkPending && link.State != domain.DeviceLinkClaimed) {
		return EnrollmentReservation{}, ErrDeviceLinkInvalid
	}
	if link.reservationRequestID != "" && link.reservationRequestID != requestID {
		return EnrollmentReservation{}, ErrIdempotencyConflict
	}
	if link.reservationRequestID == "" {
		link.RecipientDeviceID, err = domain.NewID("dev")
		if err != nil {
			return EnrollmentReservation{}, err
		}
		nonce := make([]byte, 32)
		if _, err := rand.Read(nonce); err != nil {
			return EnrollmentReservation{}, err
		}
		link.challenge = encodeEnrollmentChallenge(link.ID, link.AccountID, link.RecipientDeviceID, nonce)
		_, err = tx.ExecContext(ctx, `UPDATE device_links_v3 SET reservation_request_id=?, recipient_device_id=?, claim_challenge=? WHERE id=? AND reservation_request_id IS NULL`, requestID, link.RecipientDeviceID, link.challenge, link.ID)
		if err != nil {
			return EnrollmentReservation{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return EnrollmentReservation{}, err
	}
	return EnrollmentReservation{ID: link.ID, Kind: "device_link", AccountID: link.AccountID, DeviceID: link.RecipientDeviceID, Challenge: link.challenge, ExpiresAt: link.ExpiresAt, ProtocolVersion: DeviceLinkV3Protocol, LinkNonce: link.LinkNonce, ExistingDeviceID: link.SourceDeviceID, ExistingSigningKey: link.ExistingSigningKey}, nil
}

func (s *Store) ClaimDeviceLinkV3(ctx context.Context, input DeviceLinkV3ClaimInput) (DeviceLinkV3, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return DeviceLinkV3{}, err
	}
	defer tx.Rollback()
	link, err := loadDeviceLinkV3(ctx, tx, ` AND v.id=? AND v.code=?`, input.EnrollmentReservationID, input.Code)
	if err != nil {
		return DeviceLinkV3{}, err
	}
	if !link.validWindow(time.Now().UTC()) || link.reservationRequestID == "" || input.ReservationRequestID != link.reservationRequestID || input.ServerOrigin != link.ServerOrigin {
		return DeviceLinkV3{}, ErrEnrollmentInvalid
	}
	reservation := EnrollmentReservation{ID: link.ID, AccountID: link.AccountID, DeviceID: link.RecipientDeviceID, Challenge: link.challenge}
	proof, err := DeviceLinkV3ProofMessage(input, reservation)
	if err != nil || len(input.ChallengeSignature) != ed25519.SignatureSize || !ed25519.Verify(input.SigningKey, proof, input.ChallengeSignature) {
		return DeviceLinkV3{}, ErrEnrollmentInvalid
	}
	digest := sha256.Sum256(proof)
	hash := hex.EncodeToString(digest[:])
	if link.State != domain.DeviceLinkPending {
		if link.ClaimRequestHash != hash {
			return DeviceLinkV3{}, ErrIdempotencyConflict
		}
		return link.public(), nil
	}
	if input.ClaimTokenHash == input.DeviceSecretHash || input.ClaimTokenHash == input.InitialSessionTokenHash || input.DeviceSecretHash == input.InitialSessionTokenHash {
		return DeviceLinkV3{}, ErrEnrollmentInvalid
	}
	now := nowString()
	_, err = tx.ExecContext(ctx, `UPDATE device_links_v3 SET state='claimed', device_name=?, key_package=?, signing_key=?, transfer_public_key=?, transcript_hash=?, claim_tag=?, claim_token_hash=?, device_secret_hash=?, initial_session_token_hash=?, claim_request_hash=?, claimed_at=? WHERE id=? AND state='pending'`, input.DeviceName, input.DeviceKeyPackage, input.SigningKey, input.TransferPublicKey, input.TranscriptHash, input.ClaimTag, input.ClaimTokenHash, input.DeviceSecretHash, input.InitialSessionTokenHash, hash, now, link.ID)
	if err != nil {
		return DeviceLinkV3{}, err
	}
	link, err = loadDeviceLinkV3(ctx, tx, ` AND v.id=?`, link.ID)
	if err != nil {
		return DeviceLinkV3{}, err
	}
	if err := tx.Commit(); err != nil {
		return DeviceLinkV3{}, err
	}
	return link.public(), nil
}

func (s *Store) DeviceLinkV3ForSource(ctx context.Context, id, accountID, deviceID string) (DeviceLinkV3, error) {
	link, err := loadDeviceLinkV3(ctx, s.db, ` AND v.id=? AND v.account_id=? AND v.source_device_id=?`, id, accountID, deviceID)
	if err != nil {
		return DeviceLinkV3{}, err
	}
	if !link.validWindow(time.Now().UTC()) {
		return DeviceLinkV3{}, ErrDeviceLinkInvalid
	}
	return link.public(), nil
}

func (s *Store) DeviceLinkV3ForClaim(ctx context.Context, id, claimTokenHash string) (DeviceLinkV3, error) {
	if !validV3Hash(claimTokenHash) {
		return DeviceLinkV3{}, ErrDeviceLinkInvalid
	}
	link, err := loadDeviceLinkV3(ctx, s.db, ` AND v.id=? AND v.claim_token_hash=?`, id, claimTokenHash)
	if err != nil {
		return DeviceLinkV3{}, err
	}
	if !link.validWindow(time.Now().UTC()) {
		return DeviceLinkV3{}, ErrDeviceLinkInvalid
	}
	return link.public(), nil
}

func (s *Store) ApproveDeviceLinkV3(ctx context.Context, id, accountID, sourceDeviceID, requestHash string, transcriptHash, approvalTag []byte) (DeviceLinkV3, domain.Device, int64, error) {
	if !validV3Hash(requestHash) || len(transcriptHash) != 32 || len(approvalTag) != 32 {
		return DeviceLinkV3{}, domain.Device{}, 0, ErrDeviceLinkVerificationFailed
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return DeviceLinkV3{}, domain.Device{}, 0, err
	}
	defer tx.Rollback()
	link, err := loadDeviceLinkV3(ctx, tx, ` AND v.id=? AND v.account_id=? AND v.source_device_id=?`, id, accountID, sourceDeviceID)
	if err != nil {
		return DeviceLinkV3{}, domain.Device{}, 0, err
	}
	if !link.validWindow(time.Now().UTC()) {
		return DeviceLinkV3{}, domain.Device{}, 0, ErrDeviceLinkInvalid
	}
	if link.ClaimRequestHash != requestHash || !v3Equal(link.TranscriptHash, transcriptHash) {
		return DeviceLinkV3{}, domain.Device{}, 0, ErrDeviceLinkVerificationFailed
	}
	device := domain.Device{ID: link.RecipientDeviceID, AccountID: accountID, Name: link.DeviceName, KeyPackage: link.keyPackage, SigningKey: link.SigningKey}
	if link.State == domain.DeviceLinkApproved || link.State == domain.DeviceLinkConsumed {
		if !v3Equal(link.ApprovalTag, approvalTag) {
			return DeviceLinkV3{}, domain.Device{}, 0, ErrIdempotencyConflict
		}
		device.CreatedAt = *link.ApprovedAt
		return link.public(), device, 0, nil
	}
	if link.State != domain.DeviceLinkClaimed || !link.ExpiresAt.After(time.Now().UTC()) {
		return DeviceLinkV3{}, domain.Device{}, 0, ErrDeviceLinkInvalid
	}
	if err := s.checkDevices(ctx, tx, accountID); err != nil {
		return DeviceLinkV3{}, domain.Device{}, 0, err
	}
	now := time.Now().UTC()
	nowText := formatTime(now)
	_, err = tx.ExecContext(ctx, `INSERT INTO devices(id,account_id,name,key_package,signing_key,auth_secret_hash,created_at) VALUES(?,?,?,?,?,?,?)`, link.RecipientDeviceID, accountID, link.DeviceName, link.keyPackage, link.SigningKey, link.deviceSecretHash, nowText)
	if err != nil {
		return DeviceLinkV3{}, domain.Device{}, 0, err
	}
	if err := insertInitialDeviceKeyPackage(ctx, tx, link.RecipientDeviceID, link.keyPackage, nowText); err != nil {
		return DeviceLinkV3{}, domain.Device{}, 0, err
	}
	_, err = tx.ExecContext(ctx, `UPDATE device_links_v3 SET state='approved',approval_tag=?,approved_at=?,transfer_expires_at=? WHERE id=? AND state='claimed'`, approvalTag, nowText, formatTime(now.Add(deviceLinkV3TransferLifetime)), id)
	if err != nil {
		return DeviceLinkV3{}, domain.Device{}, 0, err
	}
	device.CreatedAt = now
	eventID, err := insertSyncEvent(ctx, tx, "device.updated", &accountID, "", map[string]interface{}{"device": device, "device_link_id": id}, nowText)
	if err != nil {
		return DeviceLinkV3{}, domain.Device{}, 0, err
	}
	link, err = loadDeviceLinkV3(ctx, tx, ` AND v.id=?`, id)
	if err != nil {
		return DeviceLinkV3{}, domain.Device{}, 0, err
	}
	if err := tx.Commit(); err != nil {
		return DeviceLinkV3{}, domain.Device{}, 0, err
	}
	return link.public(), device, eventID, nil
}

func (s *Store) CompleteDeviceLinkV3(ctx context.Context, id, claimTokenHash, requestHash, initialSessionHash string, transcriptHash []byte) (DeviceLinkV3Completion, []byte, error) {
	if !validV3Hash(claimTokenHash) || !validV3Hash(requestHash) || !validV3Hash(initialSessionHash) || len(transcriptHash) != 32 {
		return DeviceLinkV3Completion{}, nil, ErrDeviceLinkVerificationFailed
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return DeviceLinkV3Completion{}, nil, err
	}
	defer tx.Rollback()
	link, err := loadDeviceLinkV3(ctx, tx, ` AND v.id=? AND v.claim_token_hash=?`, id, claimTokenHash)
	if err != nil {
		return DeviceLinkV3Completion{}, nil, err
	}
	if !link.validWindow(time.Now().UTC()) {
		return DeviceLinkV3Completion{}, nil, ErrDeviceLinkInvalid
	}
	if link.ClaimRequestHash != requestHash || link.initialSessionHash != initialSessionHash || !v3Equal(link.TranscriptHash, transcriptHash) {
		return DeviceLinkV3Completion{}, nil, ErrDeviceLinkVerificationFailed
	}
	if link.State == domain.DeviceLinkClaimed {
		return DeviceLinkV3Completion{}, nil, ErrDeviceLinkNotReady
	}
	now := time.Now().UTC()
	if link.State == domain.DeviceLinkApproved {
		if !link.ExpiresAt.After(now) {
			return DeviceLinkV3Completion{}, nil, ErrDeviceLinkInvalid
		}
		idle, absolute := s.sessionLifetime(now, time.Time{})
		_, err := tx.ExecContext(ctx, `INSERT INTO sessions(token_hash,account_id,device_id,expires_at,created_at,recent_auth_at,last_used_at,absolute_expires_at) VALUES(?,?,?,?,?,?,?,?)`, initialSessionHash, link.AccountID, link.RecipientDeviceID, idle, formatTime(now), formatTime(now), formatTime(now), absolute)
		if err != nil {
			return DeviceLinkV3Completion{}, nil, err
		}
		_, err = tx.ExecContext(ctx, `UPDATE device_links_v3 SET state='consumed',completed_at=? WHERE id=? AND state='approved'`, formatTime(now), id)
		if err != nil {
			return DeviceLinkV3Completion{}, nil, err
		}
		link.CompletedAt = &now
	} else if link.State == domain.DeviceLinkConsumed {
		// Exact CURRENT row only: rotation-grace aliases must never recover a
		// replacement session, touch it, or resurrect this original session.
		var active bool
		err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM sessions s
 JOIN accounts a ON a.id=s.account_id
 JOIN devices d ON d.id=s.device_id AND d.account_id=s.account_id
 WHERE s.token_hash=? AND s.account_id=? AND s.device_id=?`+sessionValidity+`)`, initialSessionHash, link.AccountID, link.RecipientDeviceID, formatTime(now), formatTime(now), s.idleCutoff(now)).Scan(&active)
		if err != nil {
			return DeviceLinkV3Completion{}, nil, err
		}
		if !active {
			return DeviceLinkV3Completion{}, nil, ErrDeviceLinkSessionUnavailable
		}
	} else {
		return DeviceLinkV3Completion{}, nil, ErrDeviceLinkInvalid
	}
	if link.CompletedAt == nil {
		return DeviceLinkV3Completion{}, nil, ErrDeviceLinkInvalid
	}
	receipt := DeviceLinkV3Completion{LinkID: id, AccountID: link.AccountID, DeviceID: link.RecipientDeviceID, ServerOrigin: link.ServerOrigin, ClaimRequestHash: requestHash, TranscriptHash: bytes.Clone(link.TranscriptHash), InitialSessionTokenHash: initialSessionHash, CompletedAt: *link.CompletedAt}
	if err := tx.Commit(); err != nil {
		return DeviceLinkV3Completion{}, nil, err
	}
	return receipt, bytes.Clone(link.ApprovalTag), nil
}

// CancelDeviceLinkV3 is allowed only before approval creates a device. Unlink
// after that point must use the existing explicit device-revocation flow.
func (s *Store) CancelDeviceLinkV3(ctx context.Context, id, accountID, deviceID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// An exact already-cancelled retry returns success only to its creator.
	var state string
	err = tx.QueryRowContext(ctx, `SELECT v.state FROM device_links_v3 v JOIN accounts a ON a.id=v.account_id JOIN devices d ON d.id=v.source_device_id AND d.account_id=v.account_id WHERE v.id=? AND v.account_id=? AND v.source_device_id=? AND a.status='active' AND a.deleted_at IS NULL AND d.revoked_at IS NULL`, id, accountID, deviceID).Scan(&state)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrDeviceLinkInvalid
	}
	if err != nil {
		return err
	}
	if state == domain.DeviceLinkRevoked {
		return nil
	}
	if state != domain.DeviceLinkPending && state != domain.DeviceLinkClaimed {
		return ErrIdempotencyConflict
	}
	_, err = tx.ExecContext(ctx, `UPDATE device_links_v3 SET state='revoked',revoked_at=? WHERE id=? AND state IN ('pending','claimed')`, nowString(), id)
	if err != nil {
		return err
	}
	return tx.Commit()
}

func countPendingDeviceLinks(ctx context.Context, tx *sql.Tx, accountID string) (int, error) {
	now := nowString()
	return countRows(ctx, tx, `SELECT
 (SELECT COUNT(*) FROM device_links WHERE account_id=? AND state IN ('pending','claimed') AND revoked_at IS NULL AND expires_at>?) +
 (SELECT COUNT(*) FROM device_links_v3 WHERE account_id=? AND state IN ('pending','claimed') AND revoked_at IS NULL AND expires_at>?)`, accountID, now, accountID, now)
}

// Enqueue transfer ciphertext before deleting enrollment parents.
func retireDeviceLinksV3ForDevice(ctx context.Context, tx *sql.Tx, accountID, deviceID string) error {
	if err := retireHistoryForLinks(ctx, tx, `account_id=? AND (source_device_id=? OR recipient_device_id=?)`, accountID, deviceID, deviceID); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `DELETE FROM device_links_v3 WHERE account_id=? AND (source_device_id=? OR recipient_device_id=?)`, accountID, deviceID, deviceID)
	return err
}
