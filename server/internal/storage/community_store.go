package storage

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"private-messenger/server/internal/admission"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/devicelist"
	"private-messenger/server/internal/domain"
)

const deviceLinkProtocolVersion = "veritra-device-link-v2"

func (s *Store) ListCommunities(ctx context.Context, accountID string) ([]domain.Community, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT c.id, c.created_by, c.created_at, l.generation, l.shared_conversation_id
		FROM communities c
		JOIN memberships m ON m.community_id = c.id
		LEFT JOIN community_layouts l ON l.community_id = c.id AND l.state = 'active'
		WHERE m.account_id = ?
		ORDER BY c.created_at DESC`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	communities := []domain.Community{}
	for rows.Next() {
		var community domain.Community
		var created string
		var generation sql.NullInt64
		var shared sql.NullString
		if err := rows.Scan(&community.ID, &community.CreatedBy, &created, &generation, &shared); err != nil {
			return nil, err
		}
		community.CreatedAt = parseTime(created)
		if shared.Valid {
			community.LayoutVersion, community.LayoutGeneration, community.SharedConversationID = CommunityLayoutVersion, generation.Int64, &shared.String
		}
		communities = append(communities, community)
	}
	return communities, rows.Err()
}

// ListChannels returns a community's channels; the caller must be a member
// of the community.
func (s *Store) ListChannels(ctx context.Context, communityID, accountID string) ([]domain.Channel, error) {
	if _, err := s.CommunityMemberRole(ctx, communityID, accountID); err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx, listChannelsQuery, communityID, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	channels := []domain.Channel{}
	for rows.Next() {
		var channel domain.Channel
		var created string
		var routeConversation, access sql.NullString
		var generation sql.NullInt64
		if err := rows.Scan(&channel.ID, &channel.CommunityID, &channel.Kind, &created, &routeConversation, &access, &generation); err != nil {
			return nil, err
		}
		channel.CreatedAt = parseTime(created)
		if access.Valid {
			channel.Kind, channel.ConversationID = access.String, &routeConversation.String
			channel.LayoutVersion, channel.LayoutGeneration = CommunityLayoutVersion, generation.Int64
		}
		channels = append(channels, channel)
	}
	return channels, rows.Err()
}

func (s *Store) ListDevices(ctx context.Context, accountID string) ([]domain.Device, error) {
	return s.ListDevicesPage(ctx, accountID, 1000, "")
}

func (s *Store) ListDevicesPage(ctx context.Context, accountID string, limit int, afterID string) ([]domain.Device, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, account_id, name, key_package, signing_key, created_at, last_seen_at, revoked_at
		FROM devices
		WHERE account_id = ?
		  AND (? = '' OR (created_at, id) > (SELECT created_at, id FROM devices WHERE id = ? AND account_id = ?))
		ORDER BY created_at, id
		LIMIT ?`, accountID, afterID, afterID, accountID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var devices []domain.Device
	for rows.Next() {
		device, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		devices = append(devices, device)
	}
	return devices, rows.Err()
}

func (s *Store) CreateDeviceLink(ctx context.Context, accountID, deviceID string, ttl time.Duration, code string) (domain.DeviceLink, error) {
	if decoded, err := hex.DecodeString(code); err != nil || len(decoded) != 32 || code != strings.ToLower(code) {
		return domain.DeviceLink{}, ErrDeviceLinkInvalid
	}
	if ttl <= 0 || ttl > 30*time.Minute {
		ttl = 10 * time.Minute
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.DeviceLink{}, err
	}
	defer tx.Rollback()
	var existingSigningKey []byte
	if err := tx.QueryRowContext(ctx, `SELECT signing_key FROM devices WHERE id = ? AND account_id = ? AND revoked_at IS NULL`, deviceID, accountID).Scan(&existingSigningKey); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.DeviceLink{}, ErrUnauthorized
		}
		return domain.DeviceLink{}, err
	}
	if len(existingSigningKey) != 32 {
		return domain.DeviceLink{}, ErrUnauthorized
	}
	// Refuse early when the account cannot take another device, and bound
	// open links: a claimed link holds a key package but no device row yet.
	if err := s.checkDevices(ctx, tx, accountID); err != nil {
		return domain.DeviceLink{}, err
	}
	open, err := countPendingDeviceLinks(ctx, tx, accountID)
	if err != nil {
		return domain.DeviceLink{}, err
	}
	if open >= config.PendingDeviceLinksPerAccount {
		return domain.DeviceLink{}, s.refuse(admission.DeviceLinks, ErrDeviceLinkLimit)
	}
	id, err := domain.NewID("dlink")
	if err != nil {
		return domain.DeviceLink{}, err
	}
	linkNonce := make([]byte, 32)
	if _, err := rand.Read(linkNonce); err != nil {
		return domain.DeviceLink{}, err
	}
	createdAt := time.Now().UTC()
	expiresAt := createdAt.Add(ttl)
	_, err = tx.ExecContext(ctx, `
		INSERT INTO device_links(id, code, account_id, created_by_device_id, state, verification_code, protocol_version, link_nonce, created_at, expires_at)
		VALUES(?, ?, ?, ?, ?, '', ?, ?, ?, ?)`,
		id, code, accountID, deviceID, domain.DeviceLinkPending, deviceLinkProtocolVersion, linkNonce, formatTime(createdAt), formatTime(expiresAt))
	if err != nil {
		return domain.DeviceLink{}, err
	}
	if err := tx.Commit(); err != nil {
		return domain.DeviceLink{}, err
	}
	return domain.DeviceLink{
		ID:                 id,
		Code:               code,
		AccountID:          accountID,
		CreatedByDeviceID:  deviceID,
		State:              domain.DeviceLinkPending,
		ProtocolVersion:    deviceLinkProtocolVersion,
		LinkNonce:          linkNonce,
		ExistingSigningKey: existingSigningKey,
		CreatedAt:          createdAt,
		ExpiresAt:          expiresAt,
	}, nil
}

func (s *Store) ClaimDeviceLink(ctx context.Context, code, deviceName string, keyPackage, signingKey, transcriptHash, claimTag []byte, claimTokenHash, authSecretHash string) (domain.DeviceLink, error) {
	code = strings.TrimSpace(code)
	deviceName = strings.TrimSpace(deviceName)
	if code == "" || deviceName == "" || len(keyPackage) == 0 || len(signingKey) != 32 || len(transcriptHash) != 32 || len(claimTag) != 32 || claimTokenHash == "" || authSecretHash == "" {
		return domain.DeviceLink{}, ErrDeviceLinkInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.DeviceLink{}, err
	}
	defer tx.Rollback()
	var link domain.DeviceLink
	row := tx.QueryRowContext(ctx, `
		SELECT dl.id, dl.code, dl.account_id, dl.created_by_device_id, dl.state, dl.verification_code, dl.claimed_device_name, dl.approved_device_id, dl.created_at, dl.expires_at, dl.claimed_at, dl.approved_at, dl.consumed_at, dl.revoked_at,
		       dl.protocol_version, dl.link_nonce, dl.claimed_device_id, dl.claimed_signing_key, dl.claimed_transcript_hash, creator.signing_key, dl.claim_tag, dl.approval_tag
		FROM device_links dl JOIN devices creator ON creator.id = dl.created_by_device_id AND creator.revoked_at IS NULL
		WHERE dl.protocol_version = 'veritra-device-link-v2' AND dl.code = ? AND dl.state = ? AND dl.revoked_at IS NULL AND dl.expires_at > ?`,
		code, domain.DeviceLinkPending, nowString())
	if err := scanDeviceLink(row, &link); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.DeviceLink{}, ErrDeviceLinkInvalid
		}
		return domain.DeviceLink{}, err
	}
	now := nowString()
	result, err := tx.ExecContext(ctx, `
		UPDATE device_links
		SET state = ?, claimed_device_name = ?, claimed_key_package = ?, claimed_signing_key = ?, claimed_transcript_hash = ?, claim_tag = ?, claim_token_hash = ?, claimed_auth_secret_hash = ?, claimed_at = ?
		WHERE id = ? AND state = ? AND claimed_device_id IS NOT NULL`,
		domain.DeviceLinkClaimed, deviceName, keyPackage, signingKey, transcriptHash, claimTag, claimTokenHash, authSecretHash, now, link.ID, domain.DeviceLinkPending)
	if err != nil {
		return domain.DeviceLink{}, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return domain.DeviceLink{}, err
	}
	if rows == 0 {
		return domain.DeviceLink{}, ErrDeviceLinkInvalid
	}
	if err := tx.Commit(); err != nil {
		return domain.DeviceLink{}, err
	}
	claimedAt := parseTime(now)
	link.State = domain.DeviceLinkClaimed
	link.ClaimedDeviceName = &deviceName
	link.ClaimedSigningKey = append([]byte(nil), signingKey...)
	link.TranscriptHash = append([]byte(nil), transcriptHash...)
	link.ClaimTag = append([]byte(nil), claimTag...)
	link.ClaimedAt = &claimedAt
	link.Code = ""
	return link, nil
}

func (s *Store) ReserveDeviceLinkEnrollment(ctx context.Context, code string) (EnrollmentReservation, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return EnrollmentReservation{}, err
	}
	defer tx.Rollback()
	var linkID, accountID, existingDeviceID, protocolVersion string
	var linkNonce, existingSigningKey []byte
	err = tx.QueryRowContext(ctx, `
		SELECT dl.id, dl.account_id, dl.created_by_device_id, dl.protocol_version, dl.link_nonce, creator.signing_key
		FROM device_links dl JOIN devices creator ON creator.id = dl.created_by_device_id AND creator.revoked_at IS NULL
		WHERE dl.protocol_version = 'veritra-device-link-v2' AND dl.code = ? AND dl.state = ? AND dl.claimed_device_id IS NULL
		  AND dl.revoked_at IS NULL AND dl.expires_at > ?`,
		strings.TrimSpace(code), domain.DeviceLinkPending, nowString()).Scan(&linkID, &accountID, &existingDeviceID, &protocolVersion, &linkNonce, &existingSigningKey)
	if errors.Is(err, sql.ErrNoRows) {
		return EnrollmentReservation{}, ErrDeviceLinkInvalid
	}
	if err != nil {
		return EnrollmentReservation{}, err
	}
	deviceID, err := domain.NewID("dev")
	if err != nil {
		return EnrollmentReservation{}, err
	}
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return EnrollmentReservation{}, err
	}
	challenge := encodeEnrollmentChallenge(linkID, accountID, deviceID, nonce)
	result, err := tx.ExecContext(ctx, `
		UPDATE device_links SET claimed_device_id = ?, claim_challenge = ?
		WHERE id = ? AND state = ? AND claimed_device_id IS NULL`,
		deviceID, challenge, linkID, domain.DeviceLinkPending)
	if err != nil {
		return EnrollmentReservation{}, err
	}
	if rows, _ := result.RowsAffected(); rows != 1 {
		return EnrollmentReservation{}, ErrDeviceLinkInvalid
	}
	if err := tx.Commit(); err != nil {
		return EnrollmentReservation{}, err
	}
	return EnrollmentReservation{
		ID: linkID, Kind: "device_link", AccountID: accountID,
		DeviceID: deviceID, Challenge: challenge,
		ProtocolVersion: protocolVersion, LinkNonce: linkNonce,
		ExistingDeviceID: existingDeviceID, ExistingSigningKey: existingSigningKey,
	}, nil
}

func (s *Store) DeviceLinkEnrollment(ctx context.Context, code, linkID string) (EnrollmentReservation, error) {
	var reservation EnrollmentReservation
	var expiresAt string
	err := s.db.QueryRowContext(ctx, `
		SELECT id, account_id, claimed_device_id, claim_challenge, expires_at
		FROM device_links
		WHERE id = ? AND code = ? AND state = ? AND claimed_device_id IS NOT NULL
		  AND claim_challenge IS NOT NULL AND revoked_at IS NULL AND expires_at > ?`,
		strings.TrimSpace(linkID), strings.TrimSpace(code), domain.DeviceLinkPending,
		nowString()).Scan(
		&reservation.ID, &reservation.AccountID, &reservation.DeviceID,
		&reservation.Challenge, &expiresAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return EnrollmentReservation{}, ErrDeviceLinkInvalid
	}
	if err != nil {
		return EnrollmentReservation{}, err
	}
	reservation.Kind = "device_link"
	reservation.ExpiresAt = parseTime(expiresAt)
	return reservation, nil
}

func (s *Store) DeviceLinkForAccount(ctx context.Context, linkID, accountID string) (domain.DeviceLink, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT dl.id, dl.code, dl.account_id, dl.created_by_device_id, dl.state, dl.verification_code, dl.claimed_device_name, dl.approved_device_id, dl.created_at, dl.expires_at, dl.claimed_at, dl.approved_at, dl.consumed_at, dl.revoked_at,
		       dl.protocol_version, dl.link_nonce, dl.claimed_device_id, dl.claimed_signing_key, dl.claimed_transcript_hash, creator.signing_key, dl.claim_tag, dl.approval_tag
		FROM device_links dl JOIN devices creator ON creator.id = dl.created_by_device_id
		WHERE dl.id = ? AND dl.account_id = ? AND dl.revoked_at IS NULL`, linkID, accountID)
	var link domain.DeviceLink
	if err := scanDeviceLink(row, &link); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.DeviceLink{}, ErrNotFound
		}
		return domain.DeviceLink{}, err
	}
	link.Code = ""
	return link, nil
}

func (s *Store) ApproveDeviceLink(ctx context.Context, linkID, accountID string, transcriptHash, approvalTag []byte) (domain.DeviceLink, domain.Device, error) {
	link, device, _, _, _, err := s.approveDeviceLink(ctx, linkID, accountID, "", transcriptHash, approvalTag, nil, "")
	return link, device, err
}

func (s *Store) ApproveDeviceLinkWithSyncEvent(ctx context.Context, linkID, accountID string, transcriptHash, approvalTag []byte) (domain.DeviceLink, domain.Device, int64, []MemberLinkNotice, error) {
	link, device, eventID, notices, _, err := s.approveDeviceLink(ctx, linkID, accountID, "", transcriptHash, approvalTag, nil, "device.updated")
	return link, device, eventID, notices, err
}

// ApproveDeviceLinkWithDeviceList is ApproveDeviceLinkWithSyncEvent that also
// stores the change-2 version the approving device signed (statement), in the
// same transaction as the new device. When the account has a list a version is
// required: without it the new device would be unlisted.
func (s *Store) ApproveDeviceLinkWithDeviceList(ctx context.Context, linkID, accountID, approverDeviceID string, transcriptHash, approvalTag, statement []byte) (domain.DeviceLink, domain.Device, int64, []MemberLinkNotice, *DeviceListResult, error) {
	return s.approveDeviceLink(ctx, linkID, accountID, approverDeviceID, transcriptHash, approvalTag, statement, "device.updated")
}

func (s *Store) approveDeviceLink(ctx context.Context, linkID, accountID, approverDeviceID string, transcriptHash, approvalTag, statement []byte, eventType string) (domain.DeviceLink, domain.Device, int64, []MemberLinkNotice, *DeviceListResult, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, 0, nil, nil, err
	}
	defer tx.Rollback()
	var link domain.DeviceLink
	var deviceName string
	var keyPackage []byte
	var authSecretHash string
	row := tx.QueryRowContext(ctx, `
		SELECT dl.id, dl.code, dl.account_id, dl.created_by_device_id, dl.state, dl.verification_code, dl.claimed_device_name, dl.approved_device_id, dl.created_at, dl.expires_at, dl.claimed_at, dl.approved_at, dl.consumed_at, dl.revoked_at,
		       dl.protocol_version, dl.link_nonce, dl.claimed_device_id, dl.claimed_signing_key, dl.claimed_transcript_hash, creator.signing_key, dl.claim_tag, dl.approval_tag,
		       dl.claimed_device_name, dl.claimed_key_package, dl.claimed_auth_secret_hash
		FROM device_links dl JOIN devices creator ON creator.id = dl.created_by_device_id AND creator.revoked_at IS NULL
		WHERE dl.id = ? AND dl.account_id = ? AND dl.state = ? AND dl.revoked_at IS NULL AND dl.expires_at > ?`,
		linkID, accountID, domain.DeviceLinkClaimed, nowString())
	if err := scanDeviceLinkForApproval(row, &link, &deviceName, &keyPackage, &authSecretHash); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.DeviceLink{}, domain.Device{}, 0, nil, nil, ErrDeviceLinkInvalid
		}
		return domain.DeviceLink{}, domain.Device{}, 0, nil, nil, err
	}
	if link.ProtocolVersion != deviceLinkProtocolVersion || len(link.ClaimTag) != 32 || len(approvalTag) != 32 || len(transcriptHash) != 32 || subtle.ConstantTimeCompare(transcriptHash, link.TranscriptHash) != 1 {
		return domain.DeviceLink{}, domain.Device{}, 0, nil, nil, ErrDeviceLinkVerificationFailed
	}
	if strings.TrimSpace(deviceName) == "" || len(keyPackage) == 0 || len(link.ClaimedSigningKey) != 32 || link.ClaimedDeviceID == "" || authSecretHash == "" {
		return domain.DeviceLink{}, domain.Device{}, 0, nil, nil, ErrDeviceLinkInvalid
	}
	if err := s.checkDevices(ctx, tx, accountID); err != nil {
		return domain.DeviceLink{}, domain.Device{}, 0, nil, nil, err
	}
	now := nowString()
	deviceID := link.ClaimedDeviceID
	if _, err := tx.ExecContext(ctx, `INSERT INTO devices(id, account_id, name, key_package, signing_key, auth_secret_hash, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)`, deviceID, accountID, deviceName, keyPackage, link.ClaimedSigningKey, authSecretHash, now); err != nil {
		return domain.DeviceLink{}, domain.Device{}, 0, nil, nil, err
	}
	if err := insertInitialDeviceKeyPackage(ctx, tx, deviceID, keyPackage, now); err != nil {
		return domain.DeviceLink{}, domain.Device{}, 0, nil, nil, err
	}
	// The change-2 version names exactly this device and the signing key the
	// link claimed, and the approving device signed it.
	listResult, err := optionalDeviceListTx(ctx, tx, accountID, statement, DeviceListRule{
		Changes: []devicelist.Change{devicelist.ChangeAdd},
		Signer:  approverDeviceID,
		Added:   []devicelist.Entry{{DeviceID: deviceID, SigningKey: link.ClaimedSigningKey}},
	}, true, now)
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, 0, nil, nil, err
	}
	result, err := tx.ExecContext(ctx, `UPDATE device_links SET state = ?, approved_device_id = ?, approved_at = ?, approval_tag = ? WHERE id = ? AND state = ?`, domain.DeviceLinkApproved, deviceID, now, approvalTag, linkID, domain.DeviceLinkClaimed)
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, 0, nil, nil, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, 0, nil, nil, err
	}
	if rows == 0 {
		return domain.DeviceLink{}, domain.Device{}, 0, nil, nil, ErrDeviceLinkInvalid
	}
	approvedAt := parseTime(now)
	link.State = domain.DeviceLinkApproved
	link.ApprovalTag = append([]byte(nil), approvalTag...)
	link.Code = ""
	link.ApprovedDeviceID = &deviceID
	link.ApprovedAt = &approvedAt
	device := domain.Device{ID: deviceID, AccountID: accountID, Name: deviceName, KeyPackage: keyPackage, SigningKey: link.ClaimedSigningKey, CreatedAt: approvedAt}
	payload := map[string]interface{}{"device": device, "device_link_id": link.ID}
	eventID, err := insertOptionalSyncEvent(ctx, tx, eventType, &accountID, "", payload, now)
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, 0, nil, nil, err
	}
	// Only the route that publishes device.updated (eventType set) tells
	// coordinators; ApproveDeviceLink is the event-less variant.
	var notices []MemberLinkNotice
	if eventType != "" {
		notices, err = insertMemberLinkNotices(ctx, tx, accountID, deviceID, now)
		if err != nil {
			return domain.DeviceLink{}, domain.Device{}, 0, nil, nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return domain.DeviceLink{}, domain.Device{}, 0, nil, nil, err
	}
	return link, device, eventID, notices, listResult, nil
}

// ConsumedDeviceLink is what consuming an approved link returns: the linked
// account and device, and the claimed transcript hash and approval tag read in
// the same transaction that creates the session.
type ConsumedDeviceLink struct {
	AccountDevice
	TranscriptHash []byte
	ApprovalTag    []byte
}

func (s *Store) ConsumeApprovedDeviceLink(ctx context.Context, linkID, claimTokenHash, sessionTokenHash string, sessionExpiresAt time.Time) (ConsumedDeviceLink, error) {
	if strings.TrimSpace(linkID) == "" || claimTokenHash == "" || sessionTokenHash == "" {
		return ConsumedDeviceLink{}, ErrDeviceLinkInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return ConsumedDeviceLink{}, err
	}
	defer tx.Rollback()
	var state string
	var transcriptHash, approvalTag []byte
	err = tx.QueryRowContext(ctx, `
		SELECT state, claimed_transcript_hash, approval_tag
		FROM device_links
		WHERE id = ? AND claim_token_hash = ? AND revoked_at IS NULL AND expires_at > ?`,
		linkID, claimTokenHash, nowString()).Scan(&state, &transcriptHash, &approvalTag)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ConsumedDeviceLink{}, ErrDeviceLinkInvalid
		}
		return ConsumedDeviceLink{}, err
	}
	if state != domain.DeviceLinkApproved {
		if state == domain.DeviceLinkClaimed || state == domain.DeviceLinkPending {
			return ConsumedDeviceLink{}, ErrDeviceLinkNotReady
		}
		return ConsumedDeviceLink{}, ErrDeviceLinkInvalid
	}
	if len(transcriptHash) != 32 || len(approvalTag) != 32 {
		return ConsumedDeviceLink{}, ErrDeviceLinkInvalid
	}
	row := tx.QueryRowContext(ctx, `
		SELECT a.id, a.username, a.email, a.role, a.status, a.created_at, a.deleted_at,
		       d.id, d.account_id, d.name, d.key_package, d.signing_key, d.created_at, d.last_seen_at, d.revoked_at
		FROM device_links dl
		JOIN accounts a ON a.id = dl.account_id
		JOIN devices d ON d.id = dl.approved_device_id
		WHERE dl.id = ? AND dl.claim_token_hash = ? AND dl.state = ? AND a.deleted_at IS NULL AND d.revoked_at IS NULL`,
		linkID, claimTokenHash, domain.DeviceLinkApproved)
	linked, err := scanAccountDevice(row)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ConsumedDeviceLink{}, ErrDeviceLinkInvalid
		}
		return ConsumedDeviceLink{}, err
	}
	createdAt := nowString()
	sessionExpiry, absoluteExpiry := s.sessionLifetime(parseTime(createdAt), sessionExpiresAt)
	if _, err := tx.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at, recent_auth_at, last_used_at, absolute_expires_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`, sessionTokenHash, linked.Account.ID, linked.Device.ID, sessionExpiry, createdAt, createdAt, createdAt, absoluteExpiry); err != nil {
		return ConsumedDeviceLink{}, err
	}
	result, err := tx.ExecContext(ctx, `UPDATE device_links SET state = ?, consumed_at = ? WHERE id = ? AND state = ?`, domain.DeviceLinkConsumed, nowString(), linkID, domain.DeviceLinkApproved)
	if err != nil {
		return ConsumedDeviceLink{}, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return ConsumedDeviceLink{}, err
	}
	if rows == 0 {
		return ConsumedDeviceLink{}, ErrDeviceLinkInvalid
	}
	if err := tx.Commit(); err != nil {
		return ConsumedDeviceLink{}, err
	}
	return ConsumedDeviceLink{AccountDevice: linked, TranscriptHash: transcriptHash, ApprovalTag: approvalTag}, nil
}

// CreateCommunity makes a community with no name: its name lives in the
// creator's encrypted info record (C3). The server never stores one.
func (s *Store) CreateCommunity(ctx context.Context, createdBy string) (domain.Community, error) {
	id, err := domain.NewID("comm")
	if err != nil {
		return domain.Community{}, err
	}
	createdAt := nowString()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.Community{}, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `INSERT INTO communities(id, created_by, created_at) VALUES(?, ?, ?)`, id, createdBy, createdAt); err != nil {
		return domain.Community{}, err
	}
	membershipID, err := domain.NewID("mbr")
	if err != nil {
		return domain.Community{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, community_id, role, created_at) VALUES(?, ?, ?, 'owner', ?)`, membershipID, createdBy, id, createdAt); err != nil {
		return domain.Community{}, err
	}
	if err := s.initCommunityLayout(ctx, tx, id, createdBy, createdAt); err != nil {
		return domain.Community{}, err
	}
	if err := tx.Commit(); err != nil {
		return domain.Community{}, err
	}
	created, _ := time.Parse(time.RFC3339Nano, createdAt)
	community := domain.Community{ID: id, CreatedBy: createdBy, CreatedAt: created}
	if layout, err := communityLayoutOf(ctx, s.db, id); err == nil && layout.active {
		community.LayoutVersion, community.LayoutGeneration, community.SharedConversationID = CommunityLayoutVersion, layout.generation, &layout.sharedConversationID
	}
	return community, nil
}

func (s *Store) CreateChannel(ctx context.Context, communityID, kind, createdBy string) (domain.Channel, error) {
	role, err := s.CommunityMemberRole(ctx, communityID, createdBy)
	if err != nil {
		return domain.Channel{}, err
	}
	if !domain.CanCreateChannels(role) {
		return domain.Channel{}, ErrForbidden
	}
	if kind == "" {
		kind = "private"
	}
	if kind != "private" && kind != "announcement" {
		return domain.Channel{}, ErrInvalidInput
	}
	id, err := domain.NewID("chan")
	if err != nil {
		return domain.Channel{}, err
	}
	createdAt := nowString()
	if _, err := s.db.ExecContext(ctx, `INSERT INTO channels(id, community_id, kind, created_at) VALUES(?, ?, ?, ?)`, id, communityID, kind, createdAt); err != nil {
		return domain.Channel{}, err
	}
	created, _ := time.Parse(time.RFC3339Nano, createdAt)
	return domain.Channel{ID: id, CommunityID: communityID, Kind: kind, CreatedAt: created}, nil
}

// CreateChannelWithConversation makes a channel (and, where the layout needs
// one, its conversation) with no name or title: both are the apps' encrypted
// info records (C3).
func (s *Store) CreateChannelWithConversation(ctx context.Context, communityID, kind, createdBy string) (domain.Channel, domain.Conversation, error) {
	// An empty kind is private in a legacy community and open in one with the
	// shared-group layout; open exists only in the latter.
	if kind != "" && kind != "private" && kind != "announcement" && kind != ChannelAccessOpen {
		return domain.Channel{}, domain.Conversation{}, ErrInvalidInput
	}
	channelID, err := domain.NewID("chan")
	if err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	conversationID, err := domain.NewID("conv")
	if err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	createdAt := nowString()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	defer tx.Rollback()
	var actorRole string
	if err := tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE community_id = ? AND account_id = ?`, communityID, createdBy).Scan(&actorRole); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.Channel{}, domain.Conversation{}, ErrNotMember
		}
		return domain.Channel{}, domain.Conversation{}, err
	}
	if !domain.CanCreateChannels(actorRole) {
		return domain.Channel{}, domain.Conversation{}, ErrForbidden
	}
	layout, err := communityLayoutOf(ctx, tx, communityID)
	if err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	if layout.active {
		if kind == "" {
			kind = ChannelAccessOpen
		}
		channel, conversation, err := s.createRoutedChannel(ctx, tx, layout, communityID, kind, createdBy, actorRole, createdAt)
		if err != nil {
			return domain.Channel{}, domain.Conversation{}, err
		}
		if err := tx.Commit(); err != nil {
			return domain.Channel{}, domain.Conversation{}, err
		}
		return channel, conversation, nil
	}
	if kind == "" {
		kind = "private"
	}
	if kind == ChannelAccessOpen {
		return domain.Channel{}, domain.Conversation{}, ErrInvalidInput
	}
	communityMembers, err := communityMemberCount(ctx, tx, communityID)
	if err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	if err := s.checkMembers(0, communityMembers); err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	if err := s.checkOwnConversations(ctx, tx, createdBy, 1); err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	rows, err := tx.QueryContext(ctx, `SELECT account_id, role FROM memberships WHERE community_id = ?`, communityID)
	if err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	type member struct{ accountID, role string }
	members := make([]member, 0)
	for rows.Next() {
		var item member
		if err := rows.Scan(&item.accountID, &item.role); err != nil {
			rows.Close()
			return domain.Channel{}, domain.Conversation{}, err
		}
		members = append(members, item)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return domain.Channel{}, domain.Conversation{}, err
	}
	if err := rows.Close(); err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	// Every community member joins the new channel, so each one needs room for
	// it, as CreateConversation requires of the members it adds. One member at
	// the limit refuses the channel rather than being left out of it.
	for _, item := range members {
		if item.accountID == createdBy {
			continue
		}
		if err := s.checkOtherConversations(ctx, tx, item.accountID, 1); err != nil {
			return domain.Channel{}, domain.Conversation{}, err
		}
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO channels(id, community_id, kind, created_at) VALUES(?, ?, ?, ?)`, channelID, communityID, kind, createdAt); err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO conversations(id, kind, title, community_id, channel_id, created_by, created_at) VALUES(?, 'community_channel', NULL, ?, ?, ?, ?)`, conversationID, communityID, channelID, createdBy, createdAt); err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	for _, item := range members {
		membershipID, err := domain.NewID("mbr")
		if err != nil {
			return domain.Channel{}, domain.Conversation{}, err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, ?, ?)`, membershipID, item.accountID, conversationID, item.role, createdAt); err != nil {
			return domain.Channel{}, domain.Conversation{}, err
		}
		payload, _ := json.Marshal(map[string]string{"conversation_id": conversationID, "role": item.role})
		if _, err := tx.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('membership.updated', ?, ?, ?, ?)`, item.accountID, conversationID, string(payload), createdAt); err != nil {
			return domain.Channel{}, domain.Conversation{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	created := parseTime(createdAt)
	channel := domain.Channel{ID: channelID, CommunityID: communityID, Kind: kind, CreatedAt: created}
	conversation := domain.Conversation{ID: conversationID, Kind: "community_channel", CommunityID: &communityID, ChannelID: &channelID, CreatedBy: createdBy, CreatedAt: created, PostingRestricted: kind == "announcement"}
	return channel, conversation, nil
}

func (s *Store) ListCommunityMembers(ctx context.Context, communityID, accountID string) ([]domain.Membership, error) {
	if _, err := s.CommunityMemberRole(ctx, communityID, accountID); err != nil {
		return nil, err
	}
	// The requester is a member (checked above), so the username join exposes
	// nothing beyond shared membership, as in ListConversationMembers.
	rows, err := s.db.QueryContext(ctx, `
		SELECT m.account_id, m.role, m.created_at, COALESCE(a.username, '')
		FROM memberships m
		LEFT JOIN accounts a ON a.id = m.account_id
		WHERE m.community_id = ?
		ORDER BY m.created_at, m.account_id`, communityID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	members := make([]domain.Membership, 0)
	for rows.Next() {
		var member domain.Membership
		var created string
		if err := rows.Scan(&member.AccountID, &member.Role, &created, &member.Username); err != nil {
			return nil, err
		}
		member.CreatedAt = parseTime(created)
		members = append(members, member)
	}
	return members, rows.Err()
}

func (s *Store) ManageCommunityMember(ctx context.Context, communityID, actorAccountID, targetAccountID, role string) ([]int64, error) {
	if !domain.ValidRole(role) {
		return nil, ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	eventIDs, err := s.manageCommunityMemberTx(ctx, tx, communityID, actorAccountID, targetAccountID, role)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return eventIDs, nil
}

// manageCommunityMemberTx is ManageCommunityMember inside the caller's
// transaction, which the caller commits. role must be valid.
func (s *Store) manageCommunityMemberTx(ctx context.Context, tx *sql.Tx, communityID, actorAccountID, targetAccountID, role string) ([]int64, error) {
	var err error
	var actorRole string
	if err := tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE community_id = ? AND account_id = ?`, communityID, actorAccountID).Scan(&actorRole); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotMember
		}
		return nil, err
	}
	// C4 (D80): one owner; anyone may step down (the owner must transfer
	// first); ownership moves only by the owner's transfer to an admin.
	if actorAccountID == targetAccountID {
		if actorRole == domain.RoleOwner || domain.RoleRank(role) >= domain.RoleRank(actorRole) {
			return nil, ErrForbidden
		}
		return s.applyCommunityRoleTx(ctx, tx, communityID, actorAccountID, role)
	}
	if !domain.CanManageMembers(actorRole) || domain.RoleRank(role) > domain.RoleRank(actorRole) {
		return nil, ErrForbidden
	}
	if role == domain.RoleOwner {
		return s.transferCommunityOwnershipTx(ctx, tx, communityID, actorAccountID, actorRole, targetAccountID)
	}
	var activeTarget int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts WHERE id = ? AND deleted_at IS NULL`, targetAccountID).Scan(&activeTarget); err != nil {
		return nil, err
	}
	if activeTarget == 0 {
		return nil, ErrNotFound
	}
	// Adding or promoting also joins the target to the community's join
	// conversations, where RemoveConversationMember cannot take it out again,
	// so a block in either direction refuses the change as it does for
	// ManageConversationMember.
	var blocked int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM account_blocks WHERE (blocker_account_id = ? AND blocked_account_id = ?) OR (blocker_account_id = ? AND blocked_account_id = ?)`, actorAccountID, targetAccountID, targetAccountID, actorAccountID).Scan(&blocked); err != nil {
		return nil, err
	}
	if blocked > 0 {
		return nil, ErrForbidden
	}
	var currentRole string
	err = tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE community_id = ? AND account_id = ?`, communityID, targetAccountID).Scan(&currentRole)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	if err == nil && domain.RoleRank(currentRole) >= domain.RoleRank(actorRole) {
		return nil, ErrForbidden
	}
	if errors.Is(err, sql.ErrNoRows) {
		if err := s.checkNewCommunityMember(ctx, tx, communityID, targetAccountID); err != nil {
			return nil, err
		}
		if err := cancelPendingJoinRequestsTx(ctx, tx, MembershipTarget{Kind: domain.InviteTargetCommunity, ID: communityID}, targetAccountID); err != nil {
			return nil, err
		}
	}
	return s.applyCommunityRoleTx(ctx, tx, communityID, targetAccountID, role)
}

// transferCommunityOwnershipTx moves a community's ownership from the acting
// owner to a current admin of the community; the old owner becomes an admin.
func (s *Store) transferCommunityOwnershipTx(ctx context.Context, tx *sql.Tx, communityID, ownerAccountID, ownerRole, targetAccountID string) ([]int64, error) {
	if ownerRole != domain.RoleOwner {
		return nil, ErrForbidden
	}
	var targetRole string
	if err := tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE community_id = ? AND account_id = ?`, communityID, targetAccountID).Scan(&targetRole); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrForbidden
		}
		return nil, err
	}
	if targetRole != domain.RoleAdmin {
		return nil, ErrForbidden
	}
	// The one-owner indexes need the old owner to step down first.
	first, err := s.applyCommunityRoleTx(ctx, tx, communityID, ownerAccountID, domain.RoleAdmin)
	if err != nil {
		return nil, err
	}
	second, err := s.applyCommunityRoleTx(ctx, tx, communityID, targetAccountID, domain.RoleOwner)
	if err != nil {
		return nil, err
	}
	// C4 server succession: asks made for the old owner's absence lapse.
	if err := markNewOwnerActiveTx(ctx, tx, successionScope{community: true, id: communityID}, targetAccountID); err != nil {
		return nil, err
	}
	return append(first, second...), nil
}

// applyCommunityRoleTx writes the target's role on its community row and on
// the community's join conversations and private channels, with an event per
// conversation. The caller has checked the change is allowed.
func (s *Store) applyCommunityRoleTx(ctx context.Context, tx *sql.Tx, communityID, targetAccountID, role string) ([]int64, error) {
	createdAt := nowString()
	membershipID, err := domain.NewID("mbr")
	if err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, community_id, role, created_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(account_id, community_id) DO UPDATE SET role = excluded.role`, membershipID, targetAccountID, communityID, role, createdAt); err != nil {
		return nil, err
	}
	conversationIDs, err := communityJoinConversationIDs(ctx, tx, communityID)
	if err != nil {
		return nil, err
	}
	eventIDs := make([]int64, 0, len(conversationIDs)+1)
	for _, conversationID := range conversationIDs {
		id, err := domain.NewID("mbr")
		if err != nil {
			return nil, err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(account_id, conversation_id) DO UPDATE SET role = excluded.role`, id, targetAccountID, conversationID, role, createdAt); err != nil {
			return nil, err
		}
		payload, _ := json.Marshal(map[string]string{"community_id": communityID, "conversation_id": conversationID, "role": role})
		result, err := tx.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('membership.updated', ?, ?, ?, ?)`, targetAccountID, conversationID, string(payload), createdAt)
		if err != nil {
			return nil, err
		}
		eventID, _ := result.LastInsertId()
		eventIDs = append(eventIDs, eventID)
	}
	// A private channel of an active layout is not part of the join set, but a
	// role change must still reach the memberships the target already has in
	// one, as the legacy loop did: a demoted admin must not stay an admin
	// there. No row is added, so this never grants access.
	privateEventIDs, err := syncPrivateChannelRoles(ctx, tx, communityID, targetAccountID, role, createdAt)
	if err != nil {
		return nil, err
	}
	eventIDs = append(eventIDs, privateEventIDs...)
	return eventIDs, nil
}

// syncPrivateChannelRoles sets the account's role in the private-channel
// conversations of an active layout it already belongs to, and records a
// membership.updated event for each. It adds no membership.
func syncPrivateChannelRoles(ctx context.Context, tx *sql.Tx, communityID, accountID, role, at string) ([]int64, error) {
	rows, err := tx.QueryContext(ctx, `
		SELECT m.conversation_id
		FROM memberships m
		JOIN community_conversation_layouts l ON l.conversation_id = m.conversation_id
		WHERE m.account_id = ? AND l.community_id = ? AND l.purpose = 'private' AND m.role <> ?
		ORDER BY m.conversation_id`, accountID, communityID, role)
	if err != nil {
		return nil, err
	}
	var conversationIDs []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		conversationIDs = append(conversationIDs, id)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	rows.Close()
	var eventIDs []int64
	for _, conversationID := range conversationIDs {
		if _, err := tx.ExecContext(ctx, `UPDATE memberships SET role = ? WHERE account_id = ? AND conversation_id = ?`, role, accountID, conversationID); err != nil {
			return nil, err
		}
		payload, _ := json.Marshal(map[string]string{"community_id": communityID, "conversation_id": conversationID, "role": role})
		result, err := tx.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('membership.updated', ?, ?, ?, ?)`, accountID, conversationID, string(payload), at)
		if err != nil {
			return nil, err
		}
		eventID, _ := result.LastInsertId()
		eventIDs = append(eventIDs, eventID)
	}
	return eventIDs, nil
}

type CreateConversationInput struct {
	Kind             string
	Title            *string
	CommunityID      *string
	ChannelID        *string
	CreatedBy        string
	RetentionSeconds *int64
	MemberAccountIDs []string
}

func (s *Store) CreateConversation(ctx context.Context, input CreateConversationInput) (domain.Conversation, error) {
	conversation, _, err := s.CreateOrGetConversation(ctx, input)
	return conversation, err
}

// CreateOrGetConversation is CreateConversation that also reports whether
// the conversation was made now. It is false only for a DM whose pair
// already had one, which is returned instead (D67): its MLS group may
// already exist, so the caller must not build another.
func (s *Store) CreateOrGetConversation(ctx context.Context, input CreateConversationInput) (domain.Conversation, bool, error) {
	if len(input.MemberAccountIDs) > 100 || !domain.ValidID("acct", input.CreatedBy) {
		return domain.Conversation{}, false, ErrInvalidInput
	}
	normalizedMembers := make([]string, 0, len(input.MemberAccountIDs))
	seenMembers := map[string]struct{}{input.CreatedBy: {}}
	for _, accountID := range input.MemberAccountIDs {
		accountID = strings.TrimSpace(accountID)
		if !domain.ValidID("acct", accountID) {
			return domain.Conversation{}, false, ErrInvalidInput
		}
		if _, exists := seenMembers[accountID]; exists {
			continue
		}
		seenMembers[accountID] = struct{}{}
		normalizedMembers = append(normalizedMembers, accountID)
	}
	input.MemberAccountIDs = normalizedMembers
	if input.Title != nil {
		trimmed := strings.TrimSpace(*input.Title)
		if trimmed == "" || len(trimmed) > 64 {
			return domain.Conversation{}, false, ErrInvalidInput
		}
		input.Title = &trimmed
	}
	switch input.Kind {
	case "dm":
		if len(input.MemberAccountIDs) != 1 || input.Title != nil || input.CommunityID != nil || input.ChannelID != nil {
			return domain.Conversation{}, false, ErrInvalidInput
		}
	case "group":
		if input.CommunityID != nil || input.ChannelID != nil {
			return domain.Conversation{}, false, ErrInvalidInput
		}
	case "community_channel":
		// No title: a channel's name is its encrypted info record (C3).
		if input.CommunityID == nil || input.ChannelID == nil || input.Title != nil {
			return domain.Conversation{}, false, ErrInvalidInput
		}
	default:
		return domain.Conversation{}, false, ErrInvalidInput
	}
	id, err := domain.NewID("conv")
	if err != nil {
		return domain.Conversation{}, false, err
	}
	createdAt := nowString()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.Conversation{}, false, err
	}
	defer tx.Rollback()
	// A community-channel conversation must point at a channel the creator may
	// actually use: the creator has to belong to the community and the channel
	// must belong to that same community. Validated inside the transaction so it
	// is authoritative and consistent with the insert below.
	if input.Kind == "community_channel" {
		var memberCount int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE account_id = ? AND community_id = ?`, input.CreatedBy, *input.CommunityID).Scan(&memberCount); err != nil {
			return domain.Conversation{}, false, err
		}
		if memberCount == 0 {
			return domain.Conversation{}, false, ErrForbidden
		}
		var channelCommunity string
		if err := tx.QueryRowContext(ctx, `SELECT community_id FROM channels WHERE id = ?`, *input.ChannelID).Scan(&channelCommunity); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return domain.Conversation{}, false, ErrNotFound
			}
			return domain.Conversation{}, false, err
		}
		if channelCommunity != *input.CommunityID {
			return domain.Conversation{}, false, ErrForbidden
		}
		// A community with the shared-group layout creates its conversations
		// itself; one made here would be a second, unrouted group.
		layout, err := communityLayoutOf(ctx, tx, *input.CommunityID)
		if err != nil {
			return domain.Conversation{}, false, err
		}
		if layout.active {
			return domain.Conversation{}, false, ErrForbidden
		}
	}
	for _, accountID := range input.MemberAccountIDs {
		var blocked int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM account_blocks WHERE (blocker_account_id = ? AND blocked_account_id = ?) OR (blocker_account_id = ? AND blocked_account_id = ?)`, input.CreatedBy, accountID, accountID, input.CreatedBy).Scan(&blocked); err != nil {
			return domain.Conversation{}, false, err
		}
		if blocked > 0 {
			return domain.Conversation{}, false, ErrForbidden
		}
		var active int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts WHERE id = ? AND deleted_at IS NULL`, accountID).Scan(&active); err != nil {
			return domain.Conversation{}, false, err
		}
		if active == 0 {
			return domain.Conversation{}, false, ErrNotFound
		}
		if input.Kind == "community_channel" {
			var communityMember int
			if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE community_id = ? AND account_id = ?`, *input.CommunityID, accountID).Scan(&communityMember); err != nil {
				return domain.Conversation{}, false, err
			}
			if communityMember == 0 {
				return domain.Conversation{}, false, ErrForbidden
			}
		}
	}
	var dmLow, dmHigh string
	if input.Kind == "dm" {
		dmLow, dmHigh = dmAccountPair(input.CreatedBy, input.MemberAccountIDs[0])
		var existingID string
		err := tx.QueryRowContext(ctx, `SELECT conversation_id FROM dm_conversation_pairs WHERE account_id_low = ? AND account_id_high = ?`, dmLow, dmHigh).Scan(&existingID)
		if err == nil {
			conversation, err := scanConversation(tx.QueryRowContext(ctx, `SELECT id, kind, title, community_id, channel_id, created_by, retention_seconds, created_at FROM conversations WHERE id = ?`, existingID))
			if err != nil {
				return domain.Conversation{}, false, err
			}
			return conversation, false, nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return domain.Conversation{}, false, err
		}
	}
	if err := s.checkMembers(0, 1+len(input.MemberAccountIDs)); err != nil {
		return domain.Conversation{}, false, err
	}
	if err := s.checkOwnConversations(ctx, tx, input.CreatedBy, 1); err != nil {
		return domain.Conversation{}, false, err
	}
	for _, accountID := range input.MemberAccountIDs {
		if err := s.checkOtherConversations(ctx, tx, accountID, 1); err != nil {
			return domain.Conversation{}, false, err
		}
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO conversations(id, kind, title, community_id, channel_id, created_by, retention_seconds, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`, id, input.Kind, nullableString(input.Title), nullableString(input.CommunityID), nullableString(input.ChannelID), input.CreatedBy, nullableInt64(input.RetentionSeconds), createdAt); err != nil {
		return domain.Conversation{}, false, err
	}
	membershipID, err := domain.NewID("mbr")
	if err != nil {
		return domain.Conversation{}, false, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, 'owner', ?)`, membershipID, input.CreatedBy, id, createdAt); err != nil {
		return domain.Conversation{}, false, err
	}
	// Initial members are added in the same transaction so a mid-loop failure
	// cannot leave a half-populated conversation (the whole create rolls back).
	for _, accountID := range input.MemberAccountIDs {
		memberRowID, err := domain.NewID("mbr")
		if err != nil {
			return domain.Conversation{}, false, err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(account_id, conversation_id) DO NOTHING`, memberRowID, accountID, id, domain.RoleMember, createdAt); err != nil {
			return domain.Conversation{}, false, err
		}
		payload, err := json.Marshal(map[string]string{"conversation_id": id, "role": domain.RoleMember})
		if err != nil {
			return domain.Conversation{}, false, err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('membership.updated', ?, ?, ?, ?)`, accountID, id, string(payload), createdAt); err != nil {
			return domain.Conversation{}, false, err
		}
	}
	if input.Kind == "dm" {
		result, err := tx.ExecContext(ctx, `INSERT INTO dm_conversation_pairs(account_id_low, account_id_high, conversation_id) VALUES(?, ?, ?) ON CONFLICT(account_id_low, account_id_high) DO NOTHING`, dmLow, dmHigh, id)
		if err != nil {
			return domain.Conversation{}, false, err
		}
		inserted, err := result.RowsAffected()
		if err != nil {
			return domain.Conversation{}, false, err
		}
		if inserted != 1 {
			return domain.Conversation{}, false, ErrIdempotencyConflict
		}
	}
	if err := tx.Commit(); err != nil {
		return domain.Conversation{}, false, err
	}
	created, _ := time.Parse(time.RFC3339Nano, createdAt)
	return domain.Conversation{ID: id, Kind: input.Kind, Title: input.Title, CommunityID: input.CommunityID, ChannelID: input.ChannelID, CreatedBy: input.CreatedBy, RetentionSeconds: input.RetentionSeconds, CreatedAt: created}, true, nil
}

func dmAccountPair(first, second string) (string, string) {
	if first < second {
		return first, second
	}
	return second, first
}

func (s *Store) AddConversationMember(ctx context.Context, conversationID, accountID, role string) error {
	if role == "" {
		role = domain.RoleMember
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var kind string
	if err := tx.QueryRowContext(ctx, `SELECT kind FROM conversations WHERE id = ?`, conversationID).Scan(&kind); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	if kind == "dm" {
		return ErrForbidden
	}
	var existing int
	if existing, err = countRows(ctx, tx, `SELECT COUNT(*) FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, accountID); err != nil {
		return err
	}
	if existing == 0 {
		if err := s.checkNewConversationMember(ctx, tx, conversationID, accountID); err != nil {
			return err
		}
	}
	id, err := domain.NewID("mbr")
	if err != nil {
		return err
	}
	// Adding an existing member must never double as a role-change operation.
	// Role changes require ManageConversationMember's actor/target rank checks.
	if _, err = tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(account_id, conversation_id) DO NOTHING`, id, accountID, conversationID, role, nowString()); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) ManageConversationMember(ctx context.Context, conversationID, actorAccountID, targetAccountID, role string) (int64, error) {
	if role == "" {
		role = domain.RoleMember
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	eventID, err := s.manageConversationMemberTx(ctx, tx, conversationID, actorAccountID, targetAccountID, role)
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return eventID, nil
}

// manageConversationMemberTx is ManageConversationMember inside the caller's
// transaction, which the caller commits. role must not be empty.
func (s *Store) manageConversationMemberTx(ctx context.Context, tx *sql.Tx, conversationID, actorAccountID, targetAccountID, role string) (int64, error) {
	var err error
	var actorRole, conversationKind string
	var conversationCommunityID sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT m.role, c.kind, c.community_id FROM memberships m JOIN conversations c ON c.id = m.conversation_id WHERE m.conversation_id = ? AND m.account_id = ?`, conversationID, actorAccountID).Scan(&actorRole, &conversationKind, &conversationCommunityID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, ErrNotMember
		}
		return 0, err
	}
	if conversationKind == "dm" {
		return 0, ErrForbidden
	}
	// The shared conversation's roster is the community's roster.
	if shared, err := isSharedConversation(ctx, tx, conversationID); err != nil {
		return 0, err
	} else if shared {
		return 0, ErrForbidden
	}
	if actorAccountID == targetAccountID {
		return s.stepDownConversationMemberTx(ctx, tx, conversationID, actorAccountID, actorRole, role)
	}
	if !domain.CanManageMembers(actorRole) || domain.RoleRank(role) > domain.RoleRank(actorRole) {
		return 0, ErrForbidden
	}
	// D80: a group has one owner and ownership only moves by the owner's
	// transfer to a current admin (see transferConversationOwnershipTx).
	if role == domain.RoleOwner {
		return s.transferConversationOwnershipTx(ctx, tx, conversationID, actorAccountID, actorRole, targetAccountID)
	}
	var activeTarget int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts WHERE id = ? AND deleted_at IS NULL`, targetAccountID).Scan(&activeTarget); err != nil {
		return 0, err
	}
	if activeTarget == 0 {
		return 0, ErrNotFound
	}
	var blocked int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM account_blocks WHERE (blocker_account_id = ? AND blocked_account_id = ?) OR (blocker_account_id = ? AND blocked_account_id = ?)`, actorAccountID, targetAccountID, targetAccountID, actorAccountID).Scan(&blocked); err != nil {
		return 0, err
	}
	if blocked > 0 {
		return 0, ErrForbidden
	}
	var currentRole string
	err = tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, targetAccountID).Scan(&currentRole)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}
	if err == nil && domain.RoleRank(currentRole) >= domain.RoleRank(actorRole) {
		return 0, ErrForbidden
	}
	if errors.Is(err, sql.ErrNoRows) {
		// A channel belongs to its community: only a member of that community
		// may join it, the rule CreateConversation applies to initial members.
		// A channel without a community cannot be checked, so it refuses.
		if conversationKind == "community_channel" {
			if !conversationCommunityID.Valid {
				return 0, ErrForbidden
			}
			var communityMember int
			if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE community_id = ? AND account_id = ?`, conversationCommunityID.String, targetAccountID).Scan(&communityMember); err != nil {
				return 0, err
			}
			if communityMember == 0 {
				return 0, ErrForbidden
			}
		}
		if err := s.checkNewConversationMember(ctx, tx, conversationID, targetAccountID); err != nil {
			return 0, err
		}
		if err := cancelPendingJoinRequestsTx(ctx, tx, MembershipTarget{Kind: domain.InviteTargetGroup, ID: conversationID}, targetAccountID); err != nil {
			return 0, err
		}
	}
	id, err := domain.NewID("mbr")
	if err != nil {
		return 0, err
	}
	createdAt := nowString()
	if _, err := tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(account_id, conversation_id) DO UPDATE SET role = excluded.role`, id, targetAccountID, conversationID, role, createdAt); err != nil {
		return 0, err
	}
	payload := map[string]string{"conversation_id": conversationID, "account_id": targetAccountID, "role": role, "mls_coordination": "pending"}
	eventID, err := insertSyncEvent(ctx, tx, "membership.updated", nil, conversationID, payload, createdAt)
	if err != nil {
		return 0, err
	}
	return eventID, nil
}

// stepDownConversationMemberTx lets an account lower its own role (C4): anyone
// may step down, nobody may step up, and the owner must transfer first.
func (s *Store) stepDownConversationMemberTx(ctx context.Context, tx *sql.Tx, conversationID, accountID, currentRole, role string) (int64, error) {
	if currentRole == domain.RoleOwner || domain.RoleRank(role) >= domain.RoleRank(currentRole) {
		return 0, ErrForbidden
	}
	createdAt := nowString()
	if _, err := tx.ExecContext(ctx, `UPDATE memberships SET role = ? WHERE conversation_id = ? AND account_id = ?`, role, conversationID, accountID); err != nil {
		return 0, err
	}
	payload := map[string]string{"conversation_id": conversationID, "account_id": accountID, "role": role, "mls_coordination": "pending"}
	return insertSyncEvent(ctx, tx, "membership.updated", nil, conversationID, payload, createdAt)
}

// transferConversationOwnershipTx moves ownership from the acting owner to a
// current admin of the group; the old owner becomes an admin (C4, D80).
func (s *Store) transferConversationOwnershipTx(ctx context.Context, tx *sql.Tx, conversationID, ownerAccountID, ownerRole, targetAccountID string) (int64, error) {
	if ownerRole != domain.RoleOwner {
		return 0, ErrForbidden
	}
	var targetRole string
	if err := tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, targetAccountID).Scan(&targetRole); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, ErrForbidden
		}
		return 0, err
	}
	if targetRole != domain.RoleAdmin {
		return 0, ErrForbidden
	}
	var activeTarget int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts WHERE id = ? AND deleted_at IS NULL`, targetAccountID).Scan(&activeTarget); err != nil {
		return 0, err
	}
	if activeTarget == 0 {
		return 0, ErrNotFound
	}
	// The unique one-owner index forbids two owners at once, so the old owner
	// steps down first.
	if _, err := tx.ExecContext(ctx, `UPDATE memberships SET role = ? WHERE conversation_id = ? AND account_id = ?`, domain.RoleAdmin, conversationID, ownerAccountID); err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE memberships SET role = ? WHERE conversation_id = ? AND account_id = ?`, domain.RoleOwner, conversationID, targetAccountID); err != nil {
		return 0, err
	}
	// C4 server succession: asks made for the old owner's absence lapse.
	if err := markNewOwnerActiveTx(ctx, tx, successionScope{id: conversationID}, targetAccountID); err != nil {
		return 0, err
	}
	createdAt := nowString()
	oldOwner := map[string]string{"conversation_id": conversationID, "account_id": ownerAccountID, "role": domain.RoleAdmin, "mls_coordination": "pending"}
	if _, err := insertSyncEvent(ctx, tx, "membership.updated", nil, conversationID, oldOwner, createdAt); err != nil {
		return 0, err
	}
	newOwner := map[string]string{"conversation_id": conversationID, "account_id": targetAccountID, "role": domain.RoleOwner, "mls_coordination": "pending"}
	return insertSyncEvent(ctx, tx, "membership.updated", nil, conversationID, newOwner, createdAt)
}

func (s *Store) ListConversationMembers(ctx context.Context, conversationID, requesterAccountID string) ([]domain.Membership, error) {
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var authorized bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM memberships WHERE conversation_id = ? AND account_id = ?)`, conversationID, requesterAccountID).Scan(&authorized); err != nil {
		return nil, err
	}
	if !authorized {
		return nil, ErrNotMember
	}
	// The username join is scoped to a conversation the requester already
	// belongs to, so it exposes no account metadata beyond shared membership.
	rows, err := tx.QueryContext(ctx, `
		SELECT m.account_id, m.role, m.created_at, COALESCE(a.username, '')
		FROM memberships m
		LEFT JOIN accounts a ON a.id = m.account_id
		WHERE m.conversation_id = ?
		ORDER BY m.created_at, m.account_id`, conversationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	members := make([]domain.Membership, 0)
	for rows.Next() {
		var member domain.Membership
		var createdAt string
		if err := rows.Scan(&member.AccountID, &member.Role, &createdAt, &member.Username); err != nil {
			return nil, err
		}
		member.CreatedAt = parseTime(createdAt)
		members = append(members, member)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return members, nil
}

type MembershipRemovalEvents struct {
	RemainingMembersEventID int64
	RemovedMemberEventID    int64
}

func (s *Store) RemoveConversationMember(ctx context.Context, conversationID, actorAccountID, targetAccountID string) (MembershipRemovalEvents, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return MembershipRemovalEvents{}, err
	}
	defer tx.Rollback()
	var actorRole, kind string
	if err := tx.QueryRowContext(ctx, `SELECT m.role, c.kind FROM memberships m JOIN conversations c ON c.id = m.conversation_id WHERE m.conversation_id = ? AND m.account_id = ?`, conversationID, actorAccountID).Scan(&actorRole, &kind); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return MembershipRemovalEvents{}, ErrNotMember
		}
		return MembershipRemovalEvents{}, err
	}
	if kind != "group" {
		return MembershipRemovalEvents{}, ErrForbidden
	}
	var targetRole string
	if err := tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, targetAccountID).Scan(&targetRole); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return MembershipRemovalEvents{}, ErrNotFound
		}
		return MembershipRemovalEvents{}, err
	}
	if actorAccountID == targetAccountID {
		if targetRole == domain.RoleOwner {
			var owners int
			if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE conversation_id = ? AND role = ?`, conversationID, domain.RoleOwner).Scan(&owners); err != nil {
				return MembershipRemovalEvents{}, err
			}
			if owners <= 1 {
				return MembershipRemovalEvents{}, ErrLastOwner
			}
		}
	} else if !domain.CanManageMembers(actorRole) || domain.RoleRank(targetRole) >= domain.RoleRank(actorRole) {
		return MembershipRemovalEvents{}, ErrForbidden
	}
	result, err := tx.ExecContext(ctx, `DELETE FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, targetAccountID)
	if err != nil {
		return MembershipRemovalEvents{}, err
	}
	removed, err := result.RowsAffected()
	if err != nil {
		return MembershipRemovalEvents{}, err
	}
	if removed != 1 {
		return MembershipRemovalEvents{}, ErrNotFound
	}
	// Cursors of a member who is gone must not come back if they are added
	// again later.
	for _, query := range []string{
		`DELETE FROM delivery_receipts WHERE conversation_id = ? AND account_id = ?`,
		`DELETE FROM read_receipts WHERE conversation_id = ? AND account_id = ?`,
	} {
		if _, err := tx.ExecContext(ctx, query, conversationID, targetAccountID); err != nil {
			return MembershipRemovalEvents{}, err
		}
	}
	eventType := "membership.removed"
	if actorAccountID == targetAccountID {
		eventType = "membership.left"
	}
	now := nowString()
	payload := map[string]string{"conversation_id": conversationID, "account_id": targetAccountID, "mls_coordination": "pending"}
	remainingEventID, err := insertSyncEvent(ctx, tx, eventType, nil, conversationID, payload, now)
	if err != nil {
		return MembershipRemovalEvents{}, err
	}
	removedEventID, err := insertSyncEvent(ctx, tx, eventType, &targetAccountID, "", payload, now)
	if err != nil {
		return MembershipRemovalEvents{}, err
	}
	if err := tx.Commit(); err != nil {
		return MembershipRemovalEvents{}, err
	}
	return MembershipRemovalEvents{RemainingMembersEventID: remainingEventID, RemovedMemberEventID: removedEventID}, nil
}

func (s *Store) ListConversations(ctx context.Context, accountID string) ([]domain.Conversation, error) {
	return s.ListConversationsPage(ctx, accountID, 1000, "")
}

// listConversationsPageQuery lists the account's conversations by latest
// visible activity (T49A). Parameters: ?1 account, ?2 now, ?3 before-cursor
// conversation id (empty for the first page), ?4 limit.
//
// Ordering needs every membership's last visible message, so that is one
// newest-first walk of idx_messages_conversation_created per conversation,
// stopping at the first message that is not deleted, expired or from a
// blocked sender. Unread counts and DM peers are computed only for the
// conversations on the returned page.
const listConversationsPageQuery = conversationsPageHead + conversationsPageLegacyCursor + conversationsPageTail

// listConversationsPageKeysetQuery is the same page with its boundary taken
// from the (activity_at, id) pair the previous page returned: ?3 is the last
// conversation id and ?5 its activity time in stored format. Nothing is looked
// up for the boundary, so a new message, an expiry or a left conversation on
// the cursor row between requests cannot move it.
const listConversationsPageKeysetQuery = conversationsPageHead + conversationsPageKeysetCursor + conversationsPageTail

// conversationsPageLegacyCursor recomputes the boundary from the cursor
// conversation's current activity (the id-only cursor of older clients).
const conversationsPageLegacyCursor = `(?3 = '' OR (activity_at, id) < (
			SELECT activity_at, id FROM ranked WHERE id = ?3
		))`

const conversationsPageKeysetCursor = `(activity_at, id) < (?5, ?3)`

const conversationsPageHead = `
	WITH conversation_activity AS MATERIALIZED (
		SELECT c.id, c.kind, c.title, c.community_id, c.channel_id,
		       c.created_by, c.retention_seconds, c.created_at,
		       m.role AS current_role,
		       (SELECT me.created_at FROM message_envelopes me
		        WHERE me.conversation_id = c.id
		          AND me.deleted_at IS NULL
		          AND (me.expires_at IS NULL OR me.expires_at > ?2)
		          AND NOT EXISTS (SELECT 1 FROM account_blocks b WHERE b.blocker_account_id = ?1 AND b.blocked_account_id = me.sender_account_id)
		        ORDER BY me.created_at DESC LIMIT 1) AS last_message_at
		FROM memberships m
		JOIN conversations c ON c.id = m.conversation_id
		WHERE m.account_id = ?1
	), ranked AS (
		SELECT *, COALESCE(last_message_at, created_at) AS activity_at
		FROM conversation_activity
	), page AS (
		SELECT * FROM ranked
		WHERE `

const conversationsPageTail = `
		ORDER BY activity_at DESC, id DESC
		LIMIT ?4
	)
	SELECT p.id, p.kind, p.title, p.community_id, p.channel_id, p.created_by,
	       p.retention_seconds, p.created_at, p.current_role, p.last_message_at,
	       -- Unread: visible messages from others after the read receipt's
	       -- message in (created_at, id) order, the order messages are listed
	       -- in (all of them without a receipt). Split by case so the receipt
	       -- bound keeps a created_at range on the index; the id comparison
	       -- only settles messages that share the receipt message's timestamp.
	       CASE WHEN rr.message_id IS NULL THEN (
	           SELECT COUNT(*) FROM message_envelopes me
	           WHERE me.conversation_id = p.id
	             AND me.sender_account_id != ?1
	             AND NOT EXISTS (SELECT 1 FROM account_blocks b WHERE b.blocker_account_id = ?1 AND b.blocked_account_id = me.sender_account_id)
	             AND me.deleted_at IS NULL
	             AND (me.expires_at IS NULL OR me.expires_at > ?2)
	       ) ELSE (
	           SELECT COUNT(*) FROM message_envelopes me
	           WHERE me.conversation_id = p.id
	             AND me.created_at >= (SELECT created_at FROM message_envelopes WHERE id = rr.message_id)
	             AND (me.created_at > (SELECT created_at FROM message_envelopes WHERE id = rr.message_id) OR me.id > rr.message_id)
	             AND me.sender_account_id != ?1
	             AND NOT EXISTS (SELECT 1 FROM account_blocks b WHERE b.blocker_account_id = ?1 AND b.blocked_account_id = me.sender_account_id)
	             AND me.deleted_at IS NULL
	             AND (me.expires_at IS NULL OR me.expires_at > ?2)
	       ) END AS unread_count,
	       -- DM counterpart identity. Restricted to two-account DMs the
	       -- requester is already a member of, so it reveals nothing beyond
	       -- shared membership. NULL for group and channel conversations.
	       CASE WHEN p.kind = 'dm' THEN (
	           SELECT m2.account_id FROM memberships m2
	           WHERE m2.conversation_id = p.id AND m2.account_id != ?1
	           ORDER BY m2.created_at, m2.account_id LIMIT 1
	       ) END AS peer_account_id,
	       CASE WHEN p.kind = 'dm' THEN (
	           SELECT COALESCE(a2.username, '') FROM memberships m2
	           LEFT JOIN accounts a2 ON a2.id = m2.account_id
	           WHERE m2.conversation_id = p.id AND m2.account_id != ?1
	           ORDER BY m2.created_at, m2.account_id LIMIT 1
	       ) END AS peer_username
	FROM page p
	LEFT JOIN read_receipts rr ON rr.conversation_id = p.id AND rr.account_id = ?1
	ORDER BY p.activity_at DESC, p.id DESC`

// ConversationCursor is the boundary of a conversation-list page: the last
// conversation of the previous page and, when the client has it, the activity
// time that page listed it with (its last_message_at, or created_at without
// messages). With both set the boundary is fixed; with only BeforeID it is
// recomputed from that conversation's current activity.
type ConversationCursor struct {
	BeforeID       string
	BeforeActivity time.Time
}

// ListConversationsPage pages by conversation id alone; see ConversationCursor.
func (s *Store) ListConversationsPage(ctx context.Context, accountID string, limit int, beforeID string) ([]domain.Conversation, error) {
	return s.ListConversationsPageFrom(ctx, accountID, limit, ConversationCursor{BeforeID: beforeID})
}

// ListConversationsPageFrom lists one page of the account's conversations. An
// id-only cursor naming a conversation the account does not belong to has no
// boundary to take (its activity is not the account's to read), and answers an
// empty page, as it always has: the app reads that as the end of the list.
// With the activity time the page listed it with, the cursor needs no
// membership and keeps working after the account left that conversation.
func (s *Store) ListConversationsPageFrom(ctx context.Context, accountID string, limit int, cursor ConversationCursor) ([]domain.Conversation, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	query := listConversationsPageQuery
	args := []interface{}{accountID, nowString(), cursor.BeforeID, limit}
	switch {
	case cursor.BeforeID == "" && !cursor.BeforeActivity.IsZero():
		return nil, ErrInvalidInput
	case cursor.BeforeID != "" && !cursor.BeforeActivity.IsZero():
		query = listConversationsPageKeysetQuery
		args = append(args, formatTime(cursor.BeforeActivity))
	case cursor.BeforeID != "":
		member, err := s.IsConversationMember(ctx, cursor.BeforeID, accountID)
		if err != nil {
			return nil, err
		}
		if !member {
			return nil, nil
		}
	}
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var conversations []domain.Conversation
	for rows.Next() {
		conversation, err := scanConversationWithRole(rows)
		if err != nil {
			return nil, err
		}
		conversations = append(conversations, conversation)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := s.annotatePostingRestricted(ctx, conversations); err != nil {
		return nil, err
	}
	if err := annotateSharedKind(ctx, s.db, conversations); err != nil {
		return nil, err
	}
	return conversations, nil
}

func (s *Store) UpdateConversationRetention(ctx context.Context, conversationID, updatedBy string, retentionSeconds *int64) (domain.Conversation, error) {
	conversation, _, err := s.updateConversationRetention(ctx, conversationID, updatedBy, retentionSeconds, "")
	return conversation, err
}

func (s *Store) UpdateConversationRetentionWithSyncEvent(ctx context.Context, conversationID, updatedBy string, retentionSeconds *int64) (domain.Conversation, int64, error) {
	return s.updateConversationRetention(ctx, conversationID, updatedBy, retentionSeconds, "retention.updated")
}

func (s *Store) updateConversationRetention(ctx context.Context, conversationID, updatedBy string, retentionSeconds *int64, eventType string) (domain.Conversation, int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.Conversation{}, 0, err
	}
	defer tx.Rollback()
	var role string
	if err := tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, updatedBy).Scan(&role); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.Conversation{}, 0, ErrNotMember
		}
		return domain.Conversation{}, 0, err
	}
	if !domain.CanManageMembers(role) {
		return domain.Conversation{}, 0, ErrForbidden
	}
	now := nowString()
	if _, err := tx.ExecContext(ctx, `UPDATE conversations SET retention_seconds = ? WHERE id = ?`, nullableInt64(retentionSeconds), conversationID); err != nil {
		return domain.Conversation{}, 0, err
	}
	if retentionSeconds == nil {
		if _, err := tx.ExecContext(ctx, `DELETE FROM disappearing_policies WHERE conversation_id = ?`, conversationID); err != nil {
			return domain.Conversation{}, 0, err
		}
	} else {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO disappearing_policies(conversation_id, retention_seconds, updated_by, updated_at)
			VALUES(?, ?, ?, ?)
			ON CONFLICT(conversation_id) DO UPDATE SET retention_seconds = excluded.retention_seconds, updated_by = excluded.updated_by, updated_at = excluded.updated_at`,
			conversationID, *retentionSeconds, updatedBy, now); err != nil {
			return domain.Conversation{}, 0, err
		}
	}
	conversation, err := scanConversation(tx.QueryRowContext(ctx, `SELECT id, kind, title, community_id, channel_id, created_by, retention_seconds, created_at FROM conversations WHERE id = ?`, conversationID))
	if err != nil {
		return domain.Conversation{}, 0, err
	}
	one := []domain.Conversation{conversation}
	if err := annotateSharedKind(ctx, tx, one); err != nil {
		return domain.Conversation{}, 0, err
	}
	conversation = one[0]
	eventID, err := insertOptionalSyncEvent(ctx, tx, eventType, nil, conversationID, conversation, now)
	if err != nil {
		return domain.Conversation{}, 0, err
	}
	if err := tx.Commit(); err != nil {
		return domain.Conversation{}, 0, err
	}
	return conversation, eventID, nil
}

func (s *Store) ConversationByID(ctx context.Context, conversationID string) (domain.Conversation, error) {
	row := s.db.QueryRowContext(ctx, `SELECT id, kind, title, community_id, channel_id, created_by, retention_seconds, created_at FROM conversations WHERE id = ?`, conversationID)
	conversation, err := scanConversation(row)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.Conversation{}, ErrNotFound
		}
		return domain.Conversation{}, err
	}
	one := []domain.Conversation{conversation}
	if err := s.annotatePostingRestricted(ctx, one); err != nil {
		return domain.Conversation{}, err
	}
	if err := annotateSharedKind(ctx, s.db, one); err != nil {
		return domain.Conversation{}, err
	}
	return one[0], nil
}

func (s *Store) ListConversationMemberIDs(ctx context.Context, conversationID string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT account_id FROM memberships WHERE conversation_id = ?`, conversationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func (s *Store) ConversationMemberRole(ctx context.Context, conversationID, accountID string) (string, error) {
	var role string
	err := s.db.QueryRowContext(ctx, `SELECT role FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, accountID).Scan(&role)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", ErrNotMember
		}
		return "", err
	}
	return role, nil
}

func (s *Store) CommunityMemberRole(ctx context.Context, communityID, accountID string) (string, error) {
	var role string
	err := s.db.QueryRowContext(ctx, `SELECT role FROM memberships WHERE community_id = ? AND account_id = ?`, communityID, accountID).Scan(&role)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", ErrNotMember
		}
		return "", err
	}
	return role, nil
}

func (s *Store) IsConversationMember(ctx context.Context, conversationID, accountID string) (bool, error) {
	var count int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, accountID).Scan(&count); err != nil {
		return false, err
	}
	return count > 0, nil
}

// cancelExpiredApprovedDeviceLinks ends every legacy device link that was
// approved but not consumed before it expired (TASK-201, D100/D114 remedy
// d). Approval created and announced the device, but ConsumeApprovedDeviceLink
// refuses an expired link, so nobody can ever get a session for it. Fail
// closed: the device is revoked like any other (sessions, v3 links, the
// device.revoked event, MLS removal from its groups), its unclaimed key
// packages are deleted so nothing can still add it, and the link is revoked.
// The change-2 device-list version stays until a listed device repairs the
// list, as for any revocation that no device signed.
func cancelExpiredApprovedDeviceLinks(ctx context.Context, tx *sql.Tx, now time.Time) error {
	rows, err := tx.QueryContext(ctx, `
		SELECT id, account_id, approved_device_id FROM device_links
		WHERE state = ? AND revoked_at IS NULL AND consumed_at IS NULL AND approved_device_id IS NOT NULL AND expires_at <= ?
		ORDER BY expires_at, id LIMIT 100`, domain.DeviceLinkApproved, formatTime(now.UTC()))
	if err != nil {
		return err
	}
	type expired struct{ linkID, accountID, deviceID string }
	var found []expired
	for rows.Next() {
		var e expired
		if err := rows.Scan(&e.linkID, &e.accountID, &e.deviceID); err != nil {
			rows.Close()
			return err
		}
		found = append(found, e)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()
	at := formatTime(now.UTC())
	for _, e := range found {
		// Claim the link first, guarded by its state: a link consumed or
		// revoked meanwhile is left alone and its device is not touched.
		result, err := tx.ExecContext(ctx, `UPDATE device_links SET state = ?, revoked_at = ? WHERE id = ? AND state = ? AND consumed_at IS NULL AND revoked_at IS NULL`, domain.DeviceLinkRevoked, at, e.linkID, domain.DeviceLinkApproved)
		if err != nil {
			return err
		}
		if n, err := result.RowsAffected(); err != nil {
			return err
		} else if n == 0 {
			continue
		}
		// A device that is already revoked got its event and MLS removal then.
		var alreadyRevoked int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices WHERE id = ? AND account_id = ? AND revoked_at IS NOT NULL`, e.deviceID, e.accountID).Scan(&alreadyRevoked); err != nil {
			return err
		}
		if alreadyRevoked == 0 {
			if _, err := revokeDeviceTx(ctx, tx, e.accountID, e.deviceID, "device.revoked", at); err != nil && !errors.Is(err, ErrNotFound) {
				return err
			}
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM device_key_packages WHERE device_id = ? AND claimed_at IS NULL`, e.deviceID); err != nil {
			return err
		}
	}
	return nil
}
