package storage

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"private-messenger/server/internal/domain"
)

const deviceLinkProtocolVersion = "veritra-device-link-v1"

func (s *Store) ListCommunities(ctx context.Context, accountID string) ([]domain.Community, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT c.id, c.name, c.created_by, c.created_at
		FROM communities c
		JOIN memberships m ON m.community_id = c.id
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
		if err := rows.Scan(&community.ID, &community.Name, &community.CreatedBy, &created); err != nil {
			return nil, err
		}
		community.CreatedAt = parseTime(created)
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
	rows, err := s.db.QueryContext(ctx, `SELECT id, community_id, name, kind, created_at FROM channels WHERE community_id = ? ORDER BY created_at`, communityID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	channels := []domain.Channel{}
	for rows.Next() {
		var channel domain.Channel
		var created string
		if err := rows.Scan(&channel.ID, &channel.CommunityID, &channel.Name, &channel.Kind, &created); err != nil {
			return nil, err
		}
		channel.CreatedAt = parseTime(created)
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

func (s *Store) CreateDeviceLink(ctx context.Context, accountID, deviceID string, ttl time.Duration) (domain.DeviceLink, error) {
	if ttl <= 0 || ttl > 30*time.Minute {
		ttl = 10 * time.Minute
	}
	var existingSigningKey []byte
	if err := s.db.QueryRowContext(ctx, `SELECT signing_key FROM devices WHERE id = ? AND account_id = ? AND revoked_at IS NULL`, deviceID, accountID).Scan(&existingSigningKey); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.DeviceLink{}, ErrUnauthorized
		}
		return domain.DeviceLink{}, err
	}
	if len(existingSigningKey) != 32 {
		return domain.DeviceLink{}, ErrUnauthorized
	}
	id, err := domain.NewID("dlink")
	if err != nil {
		return domain.DeviceLink{}, err
	}
	code, err := domain.NewInviteCode()
	if err != nil {
		return domain.DeviceLink{}, err
	}
	linkNonce := make([]byte, 32)
	if _, err := rand.Read(linkNonce); err != nil {
		return domain.DeviceLink{}, err
	}
	createdAt := time.Now().UTC()
	expiresAt := createdAt.Add(ttl)
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO device_links(id, code, account_id, created_by_device_id, state, verification_code, protocol_version, link_nonce, created_at, expires_at)
		VALUES(?, ?, ?, ?, ?, '', ?, ?, ?, ?)`,
		id, code, accountID, deviceID, domain.DeviceLinkPending, deviceLinkProtocolVersion, linkNonce, formatTime(createdAt), formatTime(expiresAt))
	if err != nil {
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

func (s *Store) ClaimDeviceLink(ctx context.Context, code, deviceName string, keyPackage, signingKey, transcriptHash []byte, claimTokenHash, authSecretHash string) (domain.DeviceLink, error) {
	code = strings.TrimSpace(code)
	deviceName = strings.TrimSpace(deviceName)
	if code == "" || deviceName == "" || len(keyPackage) == 0 || len(signingKey) != 32 || len(transcriptHash) != 32 || claimTokenHash == "" || authSecretHash == "" {
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
		       dl.protocol_version, dl.link_nonce, dl.claimed_device_id, dl.claimed_signing_key, dl.claimed_transcript_hash, creator.signing_key
		FROM device_links dl JOIN devices creator ON creator.id = dl.created_by_device_id AND creator.revoked_at IS NULL
		WHERE dl.code = ? AND dl.state = ? AND dl.revoked_at IS NULL AND dl.expires_at > ?`,
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
		SET state = ?, claimed_device_name = ?, claimed_key_package = ?, claimed_signing_key = ?, claimed_transcript_hash = ?, claim_token_hash = ?, claimed_auth_secret_hash = ?, claimed_at = ?
		WHERE id = ? AND state = ? AND claimed_device_id IS NOT NULL`,
		domain.DeviceLinkClaimed, deviceName, keyPackage, signingKey, transcriptHash, claimTokenHash, authSecretHash, now, link.ID, domain.DeviceLinkPending)
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
		WHERE dl.code = ? AND dl.state = ? AND dl.claimed_device_id IS NULL
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
		       dl.protocol_version, dl.link_nonce, dl.claimed_device_id, dl.claimed_signing_key, dl.claimed_transcript_hash, creator.signing_key
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

func (s *Store) ApproveDeviceLink(ctx context.Context, linkID, accountID string, transcriptHash []byte) (domain.DeviceLink, domain.Device, error) {
	link, device, _, err := s.approveDeviceLink(ctx, linkID, accountID, transcriptHash, "")
	return link, device, err
}

func (s *Store) ApproveDeviceLinkWithSyncEvent(ctx context.Context, linkID, accountID string, transcriptHash []byte) (domain.DeviceLink, domain.Device, int64, error) {
	return s.approveDeviceLink(ctx, linkID, accountID, transcriptHash, "device.updated")
}

func (s *Store) approveDeviceLink(ctx context.Context, linkID, accountID string, transcriptHash []byte, eventType string) (domain.DeviceLink, domain.Device, int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, 0, err
	}
	defer tx.Rollback()
	var link domain.DeviceLink
	var deviceName string
	var keyPackage []byte
	var authSecretHash string
	row := tx.QueryRowContext(ctx, `
		SELECT dl.id, dl.code, dl.account_id, dl.created_by_device_id, dl.state, dl.verification_code, dl.claimed_device_name, dl.approved_device_id, dl.created_at, dl.expires_at, dl.claimed_at, dl.approved_at, dl.consumed_at, dl.revoked_at,
		       dl.protocol_version, dl.link_nonce, dl.claimed_device_id, dl.claimed_signing_key, dl.claimed_transcript_hash, creator.signing_key,
		       dl.claimed_device_name, dl.claimed_key_package, dl.claimed_auth_secret_hash
		FROM device_links dl JOIN devices creator ON creator.id = dl.created_by_device_id AND creator.revoked_at IS NULL
		WHERE dl.id = ? AND dl.account_id = ? AND dl.state = ? AND dl.revoked_at IS NULL AND dl.expires_at > ?`,
		linkID, accountID, domain.DeviceLinkClaimed, nowString())
	if err := scanDeviceLinkForApproval(row, &link, &deviceName, &keyPackage, &authSecretHash); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.DeviceLink{}, domain.Device{}, 0, ErrDeviceLinkInvalid
		}
		return domain.DeviceLink{}, domain.Device{}, 0, err
	}
	if len(transcriptHash) != 32 || subtle.ConstantTimeCompare(transcriptHash, link.TranscriptHash) != 1 {
		return domain.DeviceLink{}, domain.Device{}, 0, ErrDeviceLinkVerificationFailed
	}
	if strings.TrimSpace(deviceName) == "" || len(keyPackage) == 0 || len(link.ClaimedSigningKey) != 32 || link.ClaimedDeviceID == "" || authSecretHash == "" {
		return domain.DeviceLink{}, domain.Device{}, 0, ErrDeviceLinkInvalid
	}
	now := nowString()
	deviceID := link.ClaimedDeviceID
	if _, err := tx.ExecContext(ctx, `INSERT INTO devices(id, account_id, name, key_package, signing_key, auth_secret_hash, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)`, deviceID, accountID, deviceName, keyPackage, link.ClaimedSigningKey, authSecretHash, now); err != nil {
		return domain.DeviceLink{}, domain.Device{}, 0, err
	}
	if err := insertInitialDeviceKeyPackage(ctx, tx, deviceID, keyPackage, now); err != nil {
		return domain.DeviceLink{}, domain.Device{}, 0, err
	}
	result, err := tx.ExecContext(ctx, `UPDATE device_links SET state = ?, approved_device_id = ?, approved_at = ? WHERE id = ? AND state = ?`, domain.DeviceLinkApproved, deviceID, now, linkID, domain.DeviceLinkClaimed)
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, 0, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, 0, err
	}
	if rows == 0 {
		return domain.DeviceLink{}, domain.Device{}, 0, ErrDeviceLinkInvalid
	}
	approvedAt := parseTime(now)
	link.State = domain.DeviceLinkApproved
	link.Code = ""
	link.ApprovedDeviceID = &deviceID
	link.ApprovedAt = &approvedAt
	device := domain.Device{ID: deviceID, AccountID: accountID, Name: deviceName, KeyPackage: keyPackage, SigningKey: link.ClaimedSigningKey, CreatedAt: approvedAt}
	payload := map[string]interface{}{"device": device, "device_link_id": link.ID}
	eventID, err := insertOptionalSyncEvent(ctx, tx, eventType, &accountID, "", payload, now)
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, 0, err
	}
	if err := tx.Commit(); err != nil {
		return domain.DeviceLink{}, domain.Device{}, 0, err
	}
	return link, device, eventID, nil
}

func (s *Store) ConsumeApprovedDeviceLink(ctx context.Context, linkID, claimTokenHash, sessionTokenHash string, sessionExpiresAt time.Time) (AccountDevice, error) {
	if strings.TrimSpace(linkID) == "" || claimTokenHash == "" || sessionTokenHash == "" {
		return AccountDevice{}, ErrDeviceLinkInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return AccountDevice{}, err
	}
	defer tx.Rollback()
	var state string
	err = tx.QueryRowContext(ctx, `
		SELECT state
		FROM device_links
		WHERE id = ? AND claim_token_hash = ? AND revoked_at IS NULL AND expires_at > ?`,
		linkID, claimTokenHash, nowString()).Scan(&state)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return AccountDevice{}, ErrDeviceLinkInvalid
		}
		return AccountDevice{}, err
	}
	if state != domain.DeviceLinkApproved {
		if state == domain.DeviceLinkClaimed || state == domain.DeviceLinkPending {
			return AccountDevice{}, ErrDeviceLinkNotReady
		}
		return AccountDevice{}, ErrDeviceLinkInvalid
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
			return AccountDevice{}, ErrDeviceLinkInvalid
		}
		return AccountDevice{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at) VALUES(?, ?, ?, ?, ?)`, sessionTokenHash, linked.Account.ID, linked.Device.ID, formatTime(sessionExpiresAt), nowString()); err != nil {
		return AccountDevice{}, err
	}
	result, err := tx.ExecContext(ctx, `UPDATE device_links SET state = ?, consumed_at = ? WHERE id = ? AND state = ?`, domain.DeviceLinkConsumed, nowString(), linkID, domain.DeviceLinkApproved)
	if err != nil {
		return AccountDevice{}, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return AccountDevice{}, err
	}
	if rows == 0 {
		return AccountDevice{}, ErrDeviceLinkInvalid
	}
	if err := tx.Commit(); err != nil {
		return AccountDevice{}, err
	}
	return linked, nil
}

func (s *Store) DeviceLinkTranscriptForClaim(ctx context.Context, linkID, claimTokenHash string) ([]byte, error) {
	var transcriptHash []byte
	err := s.db.QueryRowContext(ctx, `
		SELECT claimed_transcript_hash FROM device_links
		WHERE id = ? AND claim_token_hash = ? AND state = ? AND revoked_at IS NULL`,
		linkID, claimTokenHash, domain.DeviceLinkConsumed).Scan(&transcriptHash)
	if errors.Is(err, sql.ErrNoRows) || len(transcriptHash) != 32 {
		return nil, ErrDeviceLinkInvalid
	}
	return transcriptHash, err
}

func (s *Store) CreateCommunity(ctx context.Context, name, createdBy string) (domain.Community, error) {
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
	if _, err := tx.ExecContext(ctx, `INSERT INTO communities(id, name, created_by, created_at) VALUES(?, ?, ?, ?)`, id, strings.TrimSpace(name), createdBy, createdAt); err != nil {
		return domain.Community{}, err
	}
	membershipID, err := domain.NewID("mbr")
	if err != nil {
		return domain.Community{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, community_id, role, created_at) VALUES(?, ?, ?, 'owner', ?)`, membershipID, createdBy, id, createdAt); err != nil {
		return domain.Community{}, err
	}
	if err := tx.Commit(); err != nil {
		return domain.Community{}, err
	}
	created, _ := time.Parse(time.RFC3339Nano, createdAt)
	return domain.Community{ID: id, Name: strings.TrimSpace(name), CreatedBy: createdBy, CreatedAt: created}, nil
}

func (s *Store) CreateChannel(ctx context.Context, communityID, name, kind, createdBy string) (domain.Channel, error) {
	role, err := s.CommunityMemberRole(ctx, communityID, createdBy)
	if err != nil {
		return domain.Channel{}, err
	}
	if !domain.CanManageMembers(role) {
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
	if _, err := s.db.ExecContext(ctx, `INSERT INTO channels(id, community_id, name, kind, created_at) VALUES(?, ?, ?, ?, ?)`, id, communityID, strings.TrimSpace(name), kind, createdAt); err != nil {
		return domain.Channel{}, err
	}
	created, _ := time.Parse(time.RFC3339Nano, createdAt)
	return domain.Channel{ID: id, CommunityID: communityID, Name: strings.TrimSpace(name), Kind: kind, CreatedAt: created}, nil
}

func (s *Store) CreateChannelWithConversation(ctx context.Context, communityID, name, kind, createdBy string) (domain.Channel, domain.Conversation, error) {
	if kind == "" {
		kind = "private"
	}
	if kind != "private" && kind != "announcement" {
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
	if !domain.CanManageMembers(actorRole) {
		return domain.Channel{}, domain.Conversation{}, ErrForbidden
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO channels(id, community_id, name, kind, created_at) VALUES(?, ?, ?, ?, ?)`, channelID, communityID, strings.TrimSpace(name), kind, createdAt); err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO conversations(id, kind, title, community_id, channel_id, created_by, created_at) VALUES(?, 'community_channel', ?, ?, ?, ?, ?)`, conversationID, strings.TrimSpace(name), communityID, channelID, createdBy, createdAt); err != nil {
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
	if err := rows.Close(); err != nil {
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
	channel := domain.Channel{ID: channelID, CommunityID: communityID, Name: strings.TrimSpace(name), Kind: kind, CreatedAt: created}
	title := strings.TrimSpace(name)
	conversation := domain.Conversation{ID: conversationID, Kind: "community_channel", Title: &title, CommunityID: &communityID, ChannelID: &channelID, CreatedBy: createdBy, CreatedAt: created}
	return channel, conversation, nil
}

func (s *Store) ListCommunityMembers(ctx context.Context, communityID, accountID string) ([]domain.Membership, error) {
	if _, err := s.CommunityMemberRole(ctx, communityID, accountID); err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx, `SELECT account_id, role, created_at FROM memberships WHERE community_id = ? ORDER BY created_at, account_id`, communityID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	members := make([]domain.Membership, 0)
	for rows.Next() {
		var member domain.Membership
		var created string
		if err := rows.Scan(&member.AccountID, &member.Role, &created); err != nil {
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
	var actorRole string
	if err := tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE community_id = ? AND account_id = ?`, communityID, actorAccountID).Scan(&actorRole); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotMember
		}
		return nil, err
	}
	if !domain.CanManageMembers(actorRole) || domain.RoleRank(role) > domain.RoleRank(actorRole) {
		return nil, ErrForbidden
	}
	var activeTarget int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts WHERE id = ? AND deleted_at IS NULL`, targetAccountID).Scan(&activeTarget); err != nil {
		return nil, err
	}
	if activeTarget == 0 {
		return nil, ErrNotFound
	}
	var currentRole string
	err = tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE community_id = ? AND account_id = ?`, communityID, targetAccountID).Scan(&currentRole)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	if err == nil && domain.RoleRank(currentRole) >= domain.RoleRank(actorRole) {
		return nil, ErrForbidden
	}
	createdAt := nowString()
	membershipID, err := domain.NewID("mbr")
	if err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, community_id, role, created_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(account_id, community_id) DO UPDATE SET role = excluded.role`, membershipID, targetAccountID, communityID, role, createdAt); err != nil {
		return nil, err
	}
	rows, err := tx.QueryContext(ctx, `SELECT id FROM conversations WHERE community_id = ? AND kind = 'community_channel'`, communityID)
	if err != nil {
		return nil, err
	}
	conversationIDs := make([]string, 0)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		conversationIDs = append(conversationIDs, id)
	}
	if err := rows.Close(); err != nil {
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
	if err := tx.Commit(); err != nil {
		return nil, err
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
	if len(input.MemberAccountIDs) > 100 || !domain.ValidID("acct", input.CreatedBy) {
		return domain.Conversation{}, ErrInvalidInput
	}
	normalizedMembers := make([]string, 0, len(input.MemberAccountIDs))
	seenMembers := map[string]struct{}{input.CreatedBy: {}}
	for _, accountID := range input.MemberAccountIDs {
		accountID = strings.TrimSpace(accountID)
		if !domain.ValidID("acct", accountID) {
			return domain.Conversation{}, ErrInvalidInput
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
			return domain.Conversation{}, ErrInvalidInput
		}
		input.Title = &trimmed
	}
	switch input.Kind {
	case "dm":
		if len(input.MemberAccountIDs) != 1 || input.Title != nil || input.CommunityID != nil || input.ChannelID != nil {
			return domain.Conversation{}, ErrInvalidInput
		}
	case "group":
		if input.CommunityID != nil || input.ChannelID != nil {
			return domain.Conversation{}, ErrInvalidInput
		}
	case "community_channel":
		if input.CommunityID == nil || input.ChannelID == nil {
			return domain.Conversation{}, ErrInvalidInput
		}
	default:
		return domain.Conversation{}, ErrInvalidInput
	}
	id, err := domain.NewID("conv")
	if err != nil {
		return domain.Conversation{}, err
	}
	createdAt := nowString()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.Conversation{}, err
	}
	defer tx.Rollback()
	// A community-channel conversation must point at a channel the creator may
	// actually use: the creator has to belong to the community and the channel
	// must belong to that same community. Validated inside the transaction so it
	// is authoritative and consistent with the insert below.
	if input.Kind == "community_channel" {
		var memberCount int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE account_id = ? AND community_id = ?`, input.CreatedBy, *input.CommunityID).Scan(&memberCount); err != nil {
			return domain.Conversation{}, err
		}
		if memberCount == 0 {
			return domain.Conversation{}, ErrForbidden
		}
		var channelCommunity string
		if err := tx.QueryRowContext(ctx, `SELECT community_id FROM channels WHERE id = ?`, *input.ChannelID).Scan(&channelCommunity); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return domain.Conversation{}, ErrNotFound
			}
			return domain.Conversation{}, err
		}
		if channelCommunity != *input.CommunityID {
			return domain.Conversation{}, ErrForbidden
		}
	}
	for _, accountID := range input.MemberAccountIDs {
		var blocked int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM account_blocks WHERE (blocker_account_id = ? AND blocked_account_id = ?) OR (blocker_account_id = ? AND blocked_account_id = ?)`, input.CreatedBy, accountID, accountID, input.CreatedBy).Scan(&blocked); err != nil {
			return domain.Conversation{}, err
		}
		if blocked > 0 {
			return domain.Conversation{}, ErrForbidden
		}
		var active int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts WHERE id = ? AND deleted_at IS NULL`, accountID).Scan(&active); err != nil {
			return domain.Conversation{}, err
		}
		if active == 0 {
			return domain.Conversation{}, ErrNotFound
		}
		if input.Kind == "community_channel" {
			var communityMember int
			if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE community_id = ? AND account_id = ?`, *input.CommunityID, accountID).Scan(&communityMember); err != nil {
				return domain.Conversation{}, err
			}
			if communityMember == 0 {
				return domain.Conversation{}, ErrForbidden
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
				return domain.Conversation{}, err
			}
			return conversation, nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return domain.Conversation{}, err
		}
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO conversations(id, kind, title, community_id, channel_id, created_by, retention_seconds, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`, id, input.Kind, nullableString(input.Title), nullableString(input.CommunityID), nullableString(input.ChannelID), input.CreatedBy, nullableInt64(input.RetentionSeconds), createdAt); err != nil {
		return domain.Conversation{}, err
	}
	membershipID, err := domain.NewID("mbr")
	if err != nil {
		return domain.Conversation{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, 'owner', ?)`, membershipID, input.CreatedBy, id, createdAt); err != nil {
		return domain.Conversation{}, err
	}
	// Initial members are added in the same transaction so a mid-loop failure
	// cannot leave a half-populated conversation (the whole create rolls back).
	for _, accountID := range input.MemberAccountIDs {
		memberRowID, err := domain.NewID("mbr")
		if err != nil {
			return domain.Conversation{}, err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(account_id, conversation_id) DO NOTHING`, memberRowID, accountID, id, domain.RoleMember, createdAt); err != nil {
			return domain.Conversation{}, err
		}
		payload, err := json.Marshal(map[string]string{"conversation_id": id, "role": domain.RoleMember})
		if err != nil {
			return domain.Conversation{}, err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('membership.updated', ?, ?, ?, ?)`, accountID, id, string(payload), createdAt); err != nil {
			return domain.Conversation{}, err
		}
	}
	if input.Kind == "dm" {
		result, err := tx.ExecContext(ctx, `INSERT INTO dm_conversation_pairs(account_id_low, account_id_high, conversation_id) VALUES(?, ?, ?) ON CONFLICT(account_id_low, account_id_high) DO NOTHING`, dmLow, dmHigh, id)
		if err != nil {
			return domain.Conversation{}, err
		}
		inserted, err := result.RowsAffected()
		if err != nil {
			return domain.Conversation{}, err
		}
		if inserted != 1 {
			return domain.Conversation{}, ErrIdempotencyConflict
		}
	}
	if err := tx.Commit(); err != nil {
		return domain.Conversation{}, err
	}
	created, _ := time.Parse(time.RFC3339Nano, createdAt)
	return domain.Conversation{ID: id, Kind: input.Kind, Title: input.Title, CommunityID: input.CommunityID, ChannelID: input.ChannelID, CreatedBy: input.CreatedBy, RetentionSeconds: input.RetentionSeconds, CreatedAt: created}, nil
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
	var actorRole, conversationKind string
	if err := tx.QueryRowContext(ctx, `SELECT m.role, c.kind FROM memberships m JOIN conversations c ON c.id = m.conversation_id WHERE m.conversation_id = ? AND m.account_id = ?`, conversationID, actorAccountID).Scan(&actorRole, &conversationKind); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, ErrNotMember
		}
		return 0, err
	}
	if conversationKind == "dm" {
		return 0, ErrForbidden
	}
	if !domain.CanManageMembers(actorRole) || domain.RoleRank(role) > domain.RoleRank(actorRole) {
		return 0, ErrForbidden
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
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return eventID, nil
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

func (s *Store) ListConversationsPage(ctx context.Context, accountID string, limit int, beforeID string) ([]domain.Conversation, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	now := nowString()
	rows, err := s.db.QueryContext(ctx, `
		WITH conversation_activity AS (
			SELECT c.id, c.kind, c.title, c.community_id, c.channel_id,
			       c.created_by, c.retention_seconds, c.created_at,
			       m.role AS current_role, lm.last_message_at,
			       COALESCE(lm.last_message_at, c.created_at) AS activity_at,
			       COALESCE((
			           SELECT COUNT(*) FROM message_envelopes me
			           WHERE me.conversation_id = c.id
			             AND me.sender_account_id != ?
			             AND NOT EXISTS (SELECT 1 FROM account_blocks b WHERE b.blocker_account_id = ? AND b.blocked_account_id = me.sender_account_id)
			             AND me.deleted_at IS NULL
			             AND (me.expires_at IS NULL OR me.expires_at > ?)
			             AND (rr.message_id IS NULL OR me.created_at > (
			                 SELECT created_at FROM message_envelopes WHERE id = rr.message_id
			             ))
			       ), 0) AS unread_count,
			       -- DM counterpart identity. Restricted to two-account DMs
			       -- the requester is already a member of, so it reveals
			       -- nothing beyond shared membership. NULL for group and
			       -- channel conversations.
			       CASE WHEN c.kind = 'dm' THEN (
			           SELECT m2.account_id FROM memberships m2
			           WHERE m2.conversation_id = c.id AND m2.account_id != ?
			           ORDER BY m2.created_at, m2.account_id LIMIT 1
			       ) END AS peer_account_id,
			       CASE WHEN c.kind = 'dm' THEN (
			           SELECT COALESCE(a2.username, '') FROM memberships m2
			           LEFT JOIN accounts a2 ON a2.id = m2.account_id
			           WHERE m2.conversation_id = c.id AND m2.account_id != ?
			           ORDER BY m2.created_at, m2.account_id LIMIT 1
			       ) END AS peer_username
			FROM conversations c
			JOIN memberships m ON m.conversation_id = c.id
			LEFT JOIN read_receipts rr
			  ON rr.conversation_id = c.id AND rr.account_id = ?
			LEFT JOIN (
				SELECT conversation_id, MAX(created_at) AS last_message_at
				FROM message_envelopes
				WHERE deleted_at IS NULL
				  AND (expires_at IS NULL OR expires_at > ?)
				  AND NOT EXISTS (SELECT 1 FROM account_blocks b WHERE b.blocker_account_id = ? AND b.blocked_account_id = message_envelopes.sender_account_id)
				GROUP BY conversation_id
			) lm ON lm.conversation_id = c.id
			WHERE m.account_id = ?
		)
		SELECT id, kind, title, community_id, channel_id, created_by,
		       retention_seconds, created_at, current_role, last_message_at,
		       unread_count, peer_account_id, peer_username
		FROM conversation_activity
		WHERE (? = '' OR (activity_at, id) < (
			SELECT activity_at, id FROM conversation_activity WHERE id = ?
		))
		ORDER BY activity_at DESC, id DESC
		LIMIT ?`,
		accountID, accountID, now, accountID, accountID, accountID, now, accountID, accountID, beforeID, beforeID, limit)
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
	return conversations, rows.Err()
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
	return conversation, nil
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
