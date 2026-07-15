package storage

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"private-messenger/server/internal/domain"
)

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
	var count int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices WHERE id = ? AND account_id = ? AND revoked_at IS NULL`, deviceID, accountID).Scan(&count); err != nil {
		return domain.DeviceLink{}, err
	}
	if count == 0 {
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
	verificationCode, err := domain.NewVerificationCode()
	if err != nil {
		return domain.DeviceLink{}, err
	}
	createdAt := time.Now().UTC()
	expiresAt := createdAt.Add(ttl)
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO device_links(id, code, account_id, created_by_device_id, state, verification_code, created_at, expires_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?)`,
		id, code, accountID, deviceID, domain.DeviceLinkPending, verificationCode, formatTime(createdAt), formatTime(expiresAt))
	if err != nil {
		return domain.DeviceLink{}, err
	}
	return domain.DeviceLink{
		ID:                id,
		Code:              code,
		AccountID:         accountID,
		CreatedByDeviceID: deviceID,
		State:             domain.DeviceLinkPending,
		VerificationCode:  verificationCode,
		CreatedAt:         createdAt,
		ExpiresAt:         expiresAt,
	}, nil
}

func (s *Store) ClaimDeviceLink(ctx context.Context, code, deviceName string, keyPackage, signingKey []byte, claimTokenHash, authSecretHash string) (domain.DeviceLink, error) {
	code = strings.TrimSpace(code)
	deviceName = strings.TrimSpace(deviceName)
	if code == "" || deviceName == "" || len(keyPackage) == 0 || claimTokenHash == "" || authSecretHash == "" {
		return domain.DeviceLink{}, ErrDeviceLinkInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.DeviceLink{}, err
	}
	defer tx.Rollback()
	var link domain.DeviceLink
	row := tx.QueryRowContext(ctx, `
		SELECT id, code, account_id, created_by_device_id, state, verification_code, claimed_device_name, approved_device_id, created_at, expires_at, claimed_at, approved_at, consumed_at, revoked_at
		FROM device_links
		WHERE code = ? AND state = ? AND revoked_at IS NULL AND expires_at > ?`,
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
		SET state = ?, claimed_device_name = ?, claimed_key_package = ?, claimed_signing_key = ?, claim_token_hash = ?, claimed_auth_secret_hash = ?, claimed_at = ?
		WHERE id = ? AND state = ?`,
		domain.DeviceLinkClaimed, deviceName, keyPackage, nullableBytes(signingKey), claimTokenHash, authSecretHash, now, link.ID, domain.DeviceLinkPending)
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
	link.ClaimedAt = &claimedAt
	link.Code = ""
	return link, nil
}

func (s *Store) DeviceLinkForAccount(ctx context.Context, linkID, accountID string) (domain.DeviceLink, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT id, code, account_id, created_by_device_id, state, verification_code, claimed_device_name, approved_device_id, created_at, expires_at, claimed_at, approved_at, consumed_at, revoked_at
		FROM device_links
		WHERE id = ? AND account_id = ? AND revoked_at IS NULL`, linkID, accountID)
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

func (s *Store) ApproveDeviceLink(ctx context.Context, linkID, accountID, verificationCode string) (domain.DeviceLink, domain.Device, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, err
	}
	defer tx.Rollback()
	var link domain.DeviceLink
	var deviceName string
	var keyPackage []byte
	var signingKey []byte
	var authSecretHash string
	row := tx.QueryRowContext(ctx, `
		SELECT id, code, account_id, created_by_device_id, state, verification_code, claimed_device_name, approved_device_id, created_at, expires_at, claimed_at, approved_at, consumed_at, revoked_at,
		       claimed_device_name, claimed_key_package, claimed_signing_key, claimed_auth_secret_hash
		FROM device_links
		WHERE id = ? AND account_id = ? AND state = ? AND revoked_at IS NULL AND expires_at > ?`,
		linkID, accountID, domain.DeviceLinkClaimed, nowString())
	if err := scanDeviceLinkForApproval(row, &link, &deviceName, &keyPackage, &signingKey, &authSecretHash); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.DeviceLink{}, domain.Device{}, ErrDeviceLinkInvalid
		}
		return domain.DeviceLink{}, domain.Device{}, err
	}
	// The approver must confirm the out-of-band verification code shown on both
	// devices. Without this, an authenticated user could blindly approve an
	// attacker-controlled claimed device. Constant-time compare avoids leaking
	// the code through timing.
	if subtle.ConstantTimeCompare([]byte(strings.TrimSpace(verificationCode)), []byte(link.VerificationCode)) != 1 {
		return domain.DeviceLink{}, domain.Device{}, ErrDeviceLinkVerificationFailed
	}
	if strings.TrimSpace(deviceName) == "" || len(keyPackage) == 0 || authSecretHash == "" {
		return domain.DeviceLink{}, domain.Device{}, ErrDeviceLinkInvalid
	}
	deviceID, err := domain.NewID("dev")
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, err
	}
	now := nowString()
	if _, err := tx.ExecContext(ctx, `INSERT INTO devices(id, account_id, name, key_package, signing_key, auth_secret_hash, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)`, deviceID, accountID, deviceName, keyPackage, nullableBytes(signingKey), authSecretHash, now); err != nil {
		return domain.DeviceLink{}, domain.Device{}, err
	}
	if err := insertInitialDeviceKeyPackage(ctx, tx, deviceID, keyPackage, now); err != nil {
		return domain.DeviceLink{}, domain.Device{}, err
	}
	result, err := tx.ExecContext(ctx, `UPDATE device_links SET state = ?, approved_device_id = ?, approved_at = ? WHERE id = ? AND state = ?`, domain.DeviceLinkApproved, deviceID, now, linkID, domain.DeviceLinkClaimed)
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, err
	}
	if rows == 0 {
		return domain.DeviceLink{}, domain.Device{}, ErrDeviceLinkInvalid
	}
	if err := tx.Commit(); err != nil {
		return domain.DeviceLink{}, domain.Device{}, err
	}
	approvedAt := parseTime(now)
	link.State = domain.DeviceLinkApproved
	link.Code = ""
	link.ApprovedDeviceID = &deviceID
	link.ApprovedAt = &approvedAt
	device := domain.Device{ID: deviceID, AccountID: accountID, Name: deviceName, KeyPackage: keyPackage, SigningKey: signingKey, CreatedAt: approvedAt}
	return link, device, nil
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
	if err := tx.Commit(); err != nil {
		return domain.Conversation{}, err
	}
	created, _ := time.Parse(time.RFC3339Nano, createdAt)
	return domain.Conversation{ID: id, Kind: input.Kind, Title: input.Title, CommunityID: input.CommunityID, ChannelID: input.ChannelID, CreatedBy: input.CreatedBy, RetentionSeconds: input.RetentionSeconds, CreatedAt: created}, nil
}

func (s *Store) AddConversationMember(ctx context.Context, conversationID, accountID, role string) error {
	if role == "" {
		role = domain.RoleMember
	}
	id, err := domain.NewID("mbr")
	if err != nil {
		return err
	}
	// Adding an existing member must never double as a role-change operation.
	// Role changes require ManageConversationMember's actor/target rank checks.
	_, err = s.db.ExecContext(ctx, `INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(account_id, conversation_id) DO NOTHING`, id, accountID, conversationID, role, nowString())
	return err
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
	var actorRole string
	if err := tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, actorAccountID).Scan(&actorRole); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, ErrNotMember
		}
		return 0, err
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
	payload, err := json.Marshal(map[string]string{"conversation_id": conversationID, "role": role})
	if err != nil {
		return 0, err
	}
	result, err := tx.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('membership.updated', ?, ?, ?, ?)`, targetAccountID, conversationID, string(payload), createdAt)
	if err != nil {
		return 0, err
	}
	eventID, err := result.LastInsertId()
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return eventID, nil
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
			       ), 0) AS unread_count
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
		       unread_count
		FROM conversation_activity
		WHERE (? = '' OR (activity_at, id) < (
			SELECT activity_at, id FROM conversation_activity WHERE id = ?
		))
		ORDER BY activity_at DESC, id DESC
		LIMIT ?`,
		accountID, accountID, now, accountID, now, accountID, accountID, beforeID, beforeID, limit)
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
	role, err := s.ConversationMemberRole(ctx, conversationID, updatedBy)
	if err != nil {
		return domain.Conversation{}, err
	}
	if !domain.CanManageMembers(role) {
		return domain.Conversation{}, ErrForbidden
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.Conversation{}, err
	}
	defer tx.Rollback()
	now := nowString()
	if _, err := tx.ExecContext(ctx, `UPDATE conversations SET retention_seconds = ? WHERE id = ?`, nullableInt64(retentionSeconds), conversationID); err != nil {
		return domain.Conversation{}, err
	}
	if retentionSeconds == nil {
		if _, err := tx.ExecContext(ctx, `DELETE FROM disappearing_policies WHERE conversation_id = ?`, conversationID); err != nil {
			return domain.Conversation{}, err
		}
	} else {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO disappearing_policies(conversation_id, retention_seconds, updated_by, updated_at)
			VALUES(?, ?, ?, ?)
			ON CONFLICT(conversation_id) DO UPDATE SET retention_seconds = excluded.retention_seconds, updated_by = excluded.updated_by, updated_at = excluded.updated_at`,
			conversationID, *retentionSeconds, updatedBy, now); err != nil {
			return domain.Conversation{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return domain.Conversation{}, err
	}
	return s.ConversationByID(ctx, conversationID)
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
