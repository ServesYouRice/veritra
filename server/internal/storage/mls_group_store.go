package storage

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"sort"
	"strings"
	"time"

	"private-messenger/server/internal/domain"
)

// Card I51: MLS group membership after creation.
//
// The server cannot read commits. It orders them by epoch instead: a commit
// is accepted only when it was built on the group's current epoch, and the
// commit, its Welcomes and the roster change are stored in one transaction.
// A device whose commit loses the race drops its staged commit and retries,
// so no device merges a commit that the others never see.

var (
	// ErrMLSEpochConflict means another commit was accepted first.
	ErrMLSEpochConflict = errors.New("mls commit is not based on the current epoch")
	// ErrMLSGroupLegacy means the group predates roster tracking and cannot
	// change membership.
	ErrMLSGroupLegacy = errors.New("mls group has no recorded roster")
	// ErrMLSNotInGroup means the sender device is not an active group member.
	ErrMLSNotInGroup = errors.New("device is not in the mls group")
	// ErrMLSBundleRequired means a commit or Welcome was sent outside a
	// commit bundle for a group with a recorded roster.
	ErrMLSBundleRequired = errors.New("mls group changes must use a commit bundle")
)

const (
	maxMLSBundleChanges = 256
	maxMLSHandshake     = 4 * 1024 * 1024
)

// MLSDeviceRef names one device in a membership change.
type MLSDeviceRef struct {
	AccountID string `json:"account_id"`
	DeviceID  string `json:"device_id"`
}

type MLSCommitBundleInput struct {
	ConversationID     string
	SenderAccountID    string
	SenderDeviceID     string
	Epoch              int64
	IdempotencyKey     string
	Commit             []byte
	Welcome            []byte
	Added              []MLSDeviceRef
	Removed            []MLSDeviceRef
	RevocationDeviceID string
}

type MLSCommitBundleResult struct {
	Commit    *domain.MLSMessage
	Welcomes  []domain.MLSMessage
	Epoch     int64
	Duplicate bool
}

// MLSPendingChange lists the devices a group should add or remove.
type MLSPendingChange struct {
	ConversationID string         `json:"conversation_id"`
	Epoch          int64          `json:"epoch"`
	Add            []MLSDeviceRef `json:"add"`
	Remove         []MLSDeviceRef `json:"remove"`
	// CoordinatorDeviceID is the group device expected to commit the change
	// first, so group devices do not all race for the same epoch. Others
	// act only when the change stays pending.
	CoordinatorDeviceID string `json:"coordinator_device_id"`
}

func validMLSDeviceRefs(refs []MLSDeviceRef) bool {
	if len(refs) > maxMLSBundleChanges {
		return false
	}
	seen := make(map[string]bool, len(refs))
	for _, ref := range refs {
		if strings.TrimSpace(ref.AccountID) == "" || strings.TrimSpace(ref.DeviceID) == "" ||
			len(ref.AccountID) > 128 || len(ref.DeviceID) > 128 || seen[ref.DeviceID] {
			return false
		}
		seen[ref.DeviceID] = true
	}
	return true
}

// CreateMLSCommitBundle stores one commit with its Welcomes and roster
// change, or records the creator of a new group when there is nothing to
// commit yet.
func (s *Store) CreateMLSCommitBundle(ctx context.Context, input MLSCommitBundleInput) (MLSCommitBundleResult, error) {
	input.ConversationID = strings.TrimSpace(input.ConversationID)
	input.IdempotencyKey = strings.TrimSpace(input.IdempotencyKey)
	input.RevocationDeviceID = strings.TrimSpace(input.RevocationDeviceID)
	hasCommit := len(input.Commit) > 0
	if input.ConversationID == "" || input.SenderAccountID == "" || input.SenderDeviceID == "" ||
		input.Epoch < 0 || input.IdempotencyKey == "" || len(input.IdempotencyKey) > 96 ||
		len(input.Commit) > maxMLSHandshake || len(input.Welcome) > maxMLSHandshake ||
		!validMLSDeviceRefs(input.Added) || !validMLSDeviceRefs(input.Removed) ||
		(len(input.Added) > 0) != (len(input.Welcome) > 0) ||
		(!hasCommit && (len(input.Added) > 0 || len(input.Removed) > 0 || input.Epoch != 0)) ||
		(hasCommit && len(input.Added) == 0 && len(input.Removed) == 0) {
		return MLSCommitBundleResult{}, ErrInvalidInput
	}
	for _, removed := range input.Removed {
		if removed.DeviceID == input.SenderDeviceID {
			return MLSCommitBundleResult{}, ErrInvalidInput
		}
	}
	if input.RevocationDeviceID != "" {
		listed := false
		for _, removed := range input.Removed {
			listed = listed || removed.DeviceID == input.RevocationDeviceID
		}
		if !listed {
			return MLSCommitBundleResult{}, ErrInvalidInput
		}
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return MLSCommitBundleResult{}, err
	}
	defer tx.Rollback()

	var member bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(
		SELECT 1 FROM memberships m JOIN devices d ON d.account_id = m.account_id
		WHERE m.conversation_id = ? AND m.account_id = ? AND d.id = ? AND d.revoked_at IS NULL
	)`, input.ConversationID, input.SenderAccountID, input.SenderDeviceID).Scan(&member); err != nil {
		return MLSCommitBundleResult{}, err
	}
	if !member {
		return MLSCommitBundleResult{}, ErrNotMember
	}

	if hasCommit {
		existing, err := scanMLSMessage(tx.QueryRowContext(ctx, `
			SELECT id, conversation_id, sender_account_id, sender_device_id, recipient_device_id, revocation_device_id,
			       kind, payload, idempotency_key, sync_event_id, created_at
			FROM conversation_mls_messages WHERE sender_device_id = ? AND idempotency_key = ?`,
			input.SenderDeviceID, input.IdempotencyKey))
		if err == nil {
			if existing.ConversationID != input.ConversationID || existing.Kind != "commit" ||
				!bytes.Equal(existing.Payload, input.Commit) {
				return MLSCommitBundleResult{}, ErrIdempotencyConflict
			}
			epoch, _, err := mlsGroupEpoch(ctx, tx, input.ConversationID)
			if err != nil {
				return MLSCommitBundleResult{}, err
			}
			return MLSCommitBundleResult{Commit: &existing, Epoch: epoch, Duplicate: true}, tx.Commit()
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return MLSCommitBundleResult{}, err
		}
	}

	epoch, exists, err := mlsGroupEpoch(ctx, tx, input.ConversationID)
	if err != nil {
		return MLSCommitBundleResult{}, err
	}
	now := time.Now().UTC()
	if !exists {
		// A new group. Groups created before rosters were tracked are left
		// alone rather than guessed.
		var legacy bool
		if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM conversation_mls_messages WHERE conversation_id = ?)`,
			input.ConversationID).Scan(&legacy); err != nil {
			return MLSCommitBundleResult{}, err
		}
		if legacy {
			return MLSCommitBundleResult{}, ErrMLSGroupLegacy
		}
		if input.Epoch != 0 || len(input.Removed) > 0 || input.RevocationDeviceID != "" {
			return MLSCommitBundleResult{}, ErrMLSEpochConflict
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO conversation_mls_groups(conversation_id, epoch, updated_at) VALUES(?, 0, ?)`,
			input.ConversationID, formatTime(now)); err != nil {
			return MLSCommitBundleResult{}, err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO conversation_mls_devices(conversation_id, device_id, account_id, joined_after_event_id, joined_epoch)
			VALUES(?, ?, ?, 0, 0)`, input.ConversationID, input.SenderDeviceID, input.SenderAccountID); err != nil {
			return MLSCommitBundleResult{}, err
		}
	} else {
		active, err := activeMLSDevice(ctx, tx, input.ConversationID, input.SenderDeviceID)
		if err != nil {
			return MLSCommitBundleResult{}, err
		}
		if !active {
			return MLSCommitBundleResult{}, ErrMLSNotInGroup
		}
		if !hasCommit {
			// A retried creator record: the group already exists.
			return MLSCommitBundleResult{Epoch: epoch, Duplicate: true}, tx.Commit()
		}
		if input.Epoch != epoch {
			return MLSCommitBundleResult{}, ErrMLSEpochConflict
		}
	}
	if !hasCommit {
		return MLSCommitBundleResult{Epoch: 0}, tx.Commit()
	}

	for _, added := range input.Added {
		var eligible bool
		if err := tx.QueryRowContext(ctx, `SELECT EXISTS(
			SELECT 1 FROM devices d JOIN memberships m ON m.account_id = d.account_id
			WHERE d.id = ? AND d.account_id = ? AND d.revoked_at IS NULL AND m.conversation_id = ?
		)`, added.DeviceID, added.AccountID, input.ConversationID).Scan(&eligible); err != nil {
			return MLSCommitBundleResult{}, err
		}
		active, err := activeMLSDevice(ctx, tx, input.ConversationID, added.DeviceID)
		if err != nil {
			return MLSCommitBundleResult{}, err
		}
		if !eligible || active {
			return MLSCommitBundleResult{}, ErrForbidden
		}
	}
	for _, removed := range input.Removed {
		var accountID string
		err := tx.QueryRowContext(ctx, `SELECT account_id FROM conversation_mls_devices
			WHERE conversation_id = ? AND device_id = ? AND removed_after_event_id IS NULL`,
			input.ConversationID, removed.DeviceID).Scan(&accountID)
		if errors.Is(err, sql.ErrNoRows) || (err == nil && accountID != removed.AccountID) {
			return MLSCommitBundleResult{}, ErrForbidden
		}
		if err != nil {
			return MLSCommitBundleResult{}, err
		}
	}
	if input.RevocationDeviceID != "" {
		var allowed bool
		if err := tx.QueryRowContext(ctx, `SELECT EXISTS(
			SELECT 1 FROM mls_revocations WHERE conversation_id = ? AND revoked_device_id = ?
			AND coordinator_device_id = ? AND state = 'pending')`, input.ConversationID,
			input.RevocationDeviceID, input.SenderDeviceID).Scan(&allowed); err != nil {
			return MLSCommitBundleResult{}, err
		}
		if !allowed {
			return MLSCommitBundleResult{}, ErrForbidden
		}
	}

	commit, err := insertMLSMessage(ctx, tx, mlsMessageRow{
		conversationID: input.ConversationID, senderAccountID: input.SenderAccountID,
		senderDeviceID: input.SenderDeviceID, revocationDeviceID: input.RevocationDeviceID,
		kind: "commit", payload: input.Commit, idempotencyKey: input.IdempotencyKey, createdAt: now,
	})
	if err != nil {
		return MLSCommitBundleResult{}, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE conversation_mls_groups SET epoch = epoch + 1, updated_at = ? WHERE conversation_id = ?`,
		formatTime(now), input.ConversationID); err != nil {
		return MLSCommitBundleResult{}, err
	}
	for _, removed := range input.Removed {
		if _, err := tx.ExecContext(ctx, `UPDATE conversation_mls_devices SET removed_after_event_id = ?
			WHERE conversation_id = ? AND device_id = ? AND removed_after_event_id IS NULL`,
			commit.SyncEventID, input.ConversationID, removed.DeviceID); err != nil {
			return MLSCommitBundleResult{}, err
		}
	}
	welcomes := make([]domain.MLSMessage, 0, len(input.Added))
	for _, added := range input.Added {
		// The join cursor is the commit: the new device sees everything after
		// it, starting with its Welcome, and nothing before.
		if _, err := tx.ExecContext(ctx, `INSERT INTO conversation_mls_devices(
				conversation_id, device_id, account_id, joined_after_event_id, joined_epoch, removed_after_event_id)
			VALUES(?, ?, ?, ?, ?, NULL)
			ON CONFLICT(conversation_id, device_id) DO UPDATE SET
				account_id = excluded.account_id,
				joined_after_event_id = excluded.joined_after_event_id,
				joined_epoch = excluded.joined_epoch,
				removed_after_event_id = NULL`,
			input.ConversationID, added.DeviceID, added.AccountID, commit.SyncEventID, epoch+1); err != nil {
			return MLSCommitBundleResult{}, err
		}
		welcome, err := insertMLSMessage(ctx, tx, mlsMessageRow{
			conversationID: input.ConversationID, senderAccountID: input.SenderAccountID,
			senderDeviceID: input.SenderDeviceID, recipientAccountID: added.AccountID,
			recipientDeviceID: added.DeviceID, kind: "welcome", payload: input.Welcome,
			idempotencyKey: input.IdempotencyKey + ":welcome:" + added.DeviceID, createdAt: now,
		})
		if err != nil {
			return MLSCommitBundleResult{}, err
		}
		welcomes = append(welcomes, welcome)
	}
	if input.RevocationDeviceID != "" {
		if _, err := tx.ExecContext(ctx, `UPDATE mls_revocations SET state = 'commit_submitted', commit_message_id = ?
			WHERE conversation_id = ? AND revoked_device_id = ? AND state = 'pending'`,
			commit.ID, input.ConversationID, input.RevocationDeviceID); err != nil {
			return MLSCommitBundleResult{}, err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE mls_revocation_required_devices SET confirmed_at = ?
			WHERE conversation_id = ? AND revoked_device_id = ? AND device_id = ?`,
			formatTime(now), input.ConversationID, input.RevocationDeviceID, input.SenderDeviceID); err != nil {
			return MLSCommitBundleResult{}, err
		}
		if err := completeMLSRevocationIfConfirmed(ctx, tx, input.ConversationID, input.RevocationDeviceID, now); err != nil {
			return MLSCommitBundleResult{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return MLSCommitBundleResult{}, err
	}
	return MLSCommitBundleResult{Commit: &commit, Welcomes: welcomes, Epoch: epoch + 1}, nil
}

type mlsMessageRow struct {
	conversationID     string
	senderAccountID    string
	senderDeviceID     string
	recipientAccountID string
	recipientDeviceID  string
	revocationDeviceID string
	kind               string
	payload            []byte
	idempotencyKey     string
	createdAt          time.Time
}

// insertMLSMessage stores one MLS message and its sync event. A Welcome's
// event is visible only to its recipient device.
func insertMLSMessage(ctx context.Context, tx *sql.Tx, row mlsMessageRow) (domain.MLSMessage, error) {
	id, err := domain.NewID("mls")
	if err != nil {
		return domain.MLSMessage{}, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO conversation_mls_messages(
			id, conversation_id, sender_account_id, sender_device_id, recipient_device_id,
			kind, payload, idempotency_key, created_at, revocation_device_id
		) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, row.conversationID, row.senderAccountID, row.senderDeviceID,
		nullableEmptyString(row.recipientDeviceID), row.kind, row.payload,
		row.idempotencyKey, formatTime(row.createdAt), nullableEmptyString(row.revocationDeviceID)); err != nil {
		return domain.MLSMessage{}, err
	}
	var accountID *string
	if row.recipientAccountID != "" {
		accountID = &row.recipientAccountID
	}
	eventID, err := insertSyncEvent(ctx, tx, "mls.message.created", accountID,
		row.conversationID, map[string]string{"mls_message_id": id, "kind": row.kind}, formatTime(row.createdAt))
	if err != nil {
		return domain.MLSMessage{}, err
	}
	if row.recipientDeviceID != "" {
		if _, err := tx.ExecContext(ctx, `UPDATE sync_events SET device_id = ? WHERE id = ?`, row.recipientDeviceID, eventID); err != nil {
			return domain.MLSMessage{}, err
		}
	}
	if _, err := tx.ExecContext(ctx, `UPDATE conversation_mls_messages SET sync_event_id = ? WHERE id = ?`, eventID, id); err != nil {
		return domain.MLSMessage{}, err
	}
	return domain.MLSMessage{
		ID: id, ConversationID: row.conversationID, SenderAccountID: row.senderAccountID,
		SenderDeviceID: row.senderDeviceID, RecipientDeviceID: row.recipientDeviceID,
		RevocationDeviceID: row.revocationDeviceID, Kind: row.kind, Payload: row.payload,
		IdempotencyKey: row.idempotencyKey, SyncEventID: eventID, CreatedAt: row.createdAt,
	}, nil
}

type rowQuerier interface {
	QueryRowContext(context.Context, string, ...interface{}) *sql.Row
}

func mlsGroupEpoch(ctx context.Context, q rowQuerier, conversationID string) (int64, bool, error) {
	var epoch int64
	err := q.QueryRowContext(ctx, `SELECT epoch FROM conversation_mls_groups WHERE conversation_id = ?`, conversationID).Scan(&epoch)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, false, nil
	}
	return epoch, err == nil, err
}

func activeMLSDevice(ctx context.Context, q rowQuerier, conversationID, deviceID string) (bool, error) {
	var active bool
	err := q.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM conversation_mls_devices
		WHERE conversation_id = ? AND device_id = ? AND removed_after_event_id IS NULL)`,
		conversationID, deviceID).Scan(&active)
	return active, err
}

// MLSGroupEpoch reports the recorded epoch, for conflict responses.
func (s *Store) MLSGroupEpoch(ctx context.Context, conversationID string) (int64, bool, error) {
	return mlsGroupEpoch(ctx, s.db, conversationID)
}

// ListMLSPendingChanges returns, for groups the requester device belongs
// to, the member devices that are not in the group yet and the group devices
// whose account left the conversation. Revoked devices are handled by the
// revocation flow instead.
func (s *Store) ListMLSPendingChanges(ctx context.Context, accountID, deviceID string) ([]MLSPendingChange, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT g.conversation_id, g.epoch, 'add', d.account_id, d.id
		FROM conversation_mls_groups g
		JOIN conversation_mls_devices me ON me.conversation_id = g.conversation_id
			AND me.device_id = ? AND me.removed_after_event_id IS NULL
		JOIN memberships requester ON requester.conversation_id = g.conversation_id AND requester.account_id = ?
		JOIN memberships m ON m.conversation_id = g.conversation_id
		JOIN devices d ON d.account_id = m.account_id AND d.revoked_at IS NULL
		WHERE NOT EXISTS (SELECT 1 FROM conversation_mls_devices r
			WHERE r.conversation_id = g.conversation_id AND r.device_id = d.id AND r.removed_after_event_id IS NULL)
		UNION ALL
		SELECT g.conversation_id, g.epoch, 'remove', r.account_id, r.device_id
		FROM conversation_mls_groups g
		JOIN conversation_mls_devices me ON me.conversation_id = g.conversation_id
			AND me.device_id = ? AND me.removed_after_event_id IS NULL
		JOIN memberships requester ON requester.conversation_id = g.conversation_id AND requester.account_id = ?
		JOIN conversation_mls_devices r ON r.conversation_id = g.conversation_id AND r.removed_after_event_id IS NULL
		JOIN devices d ON d.id = r.device_id AND d.revoked_at IS NULL
		WHERE NOT EXISTS (SELECT 1 FROM memberships m WHERE m.conversation_id = g.conversation_id AND m.account_id = r.account_id)
		LIMIT 2000`, deviceID, accountID, deviceID, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	byConversation := map[string]*MLSPendingChange{}
	for rows.Next() {
		var conversationID, change string
		var epoch int64
		var ref MLSDeviceRef
		if err := rows.Scan(&conversationID, &epoch, &change, &ref.AccountID, &ref.DeviceID); err != nil {
			return nil, err
		}
		item := byConversation[conversationID]
		if item == nil {
			item = &MLSPendingChange{ConversationID: conversationID, Epoch: epoch, Add: []MLSDeviceRef{}, Remove: []MLSDeviceRef{}}
			byConversation[conversationID] = item
		}
		if change == "add" {
			if len(item.Add) < maxMLSBundleChanges {
				item.Add = append(item.Add, ref)
			}
		} else if len(item.Remove) < maxMLSBundleChanges {
			item.Remove = append(item.Remove, ref)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	result := make([]MLSPendingChange, 0, len(byConversation))
	for _, item := range byConversation {
		if err := s.db.QueryRowContext(ctx, `SELECT MIN(r.device_id) FROM conversation_mls_devices r
			JOIN devices d ON d.id = r.device_id AND d.revoked_at IS NULL
			JOIN memberships m ON m.conversation_id = r.conversation_id AND m.account_id = r.account_id
			WHERE r.conversation_id = ? AND r.removed_after_event_id IS NULL`,
			item.ConversationID).Scan(&item.CoordinatorDeviceID); err != nil {
			return nil, err
		}
		sort.Slice(item.Add, func(i, j int) bool { return item.Add[i].DeviceID < item.Add[j].DeviceID })
		sort.Slice(item.Remove, func(i, j int) bool { return item.Remove[i].DeviceID < item.Remove[j].DeviceID })
		result = append(result, *item)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].ConversationID < result[j].ConversationID })
	return result, nil
}

// ClaimDeviceKeyPackages claims one key package for each listed device of
// a conversation member, for adding devices to an existing group. A device
// with no package left is skipped; the caller adds it later.
func (s *Store) ClaimDeviceKeyPackages(ctx context.Context, conversationID, requesterAccountID, requesterDeviceID string, deviceIDs []string) ([]domain.DeviceKeyPackage, error) {
	if len(deviceIDs) == 0 || len(deviceIDs) > maxMLSBundleChanges {
		return nil, ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	active, err := activeMLSDevice(ctx, tx, conversationID, requesterDeviceID)
	if err != nil {
		return nil, err
	}
	var member bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM memberships WHERE conversation_id = ? AND account_id = ?)`,
		conversationID, requesterAccountID).Scan(&member); err != nil {
		return nil, err
	}
	if !member {
		return nil, ErrNotMember
	}
	if !active {
		return nil, ErrMLSNotInGroup
	}
	claimedAt := time.Now().UTC()
	seen := map[string]bool{}
	result := make([]domain.DeviceKeyPackage, 0, len(deviceIDs))
	for _, deviceID := range deviceIDs {
		deviceID = strings.TrimSpace(deviceID)
		if deviceID == "" || deviceID == requesterDeviceID || seen[deviceID] {
			return nil, ErrInvalidInput
		}
		seen[deviceID] = true
		var accountID string
		err := tx.QueryRowContext(ctx, `SELECT d.account_id FROM devices d
			JOIN memberships m ON m.account_id = d.account_id AND m.conversation_id = ?
			WHERE d.id = ? AND d.revoked_at IS NULL`, conversationID, deviceID).Scan(&accountID)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrForbidden
		}
		if err != nil {
			return nil, err
		}
		var item domain.DeviceKeyPackage
		var createdAt, expiresAt string
		err = tx.QueryRowContext(ctx, `
			SELECT id, key_package, ciphersuite, created_at, expires_at
			FROM device_key_packages
			WHERE device_id = ? AND claimed_at IS NULL AND expires_at > ?
			ORDER BY created_at, id
			LIMIT 1`, deviceID, formatTime(claimedAt)).Scan(&item.ID, &item.KeyPackage, &item.Ciphersuite, &createdAt, &expiresAt)
		if errors.Is(err, sql.ErrNoRows) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE device_key_packages SET claimed_at = ?, claimed_by_device_id = ? WHERE id = ? AND claimed_at IS NULL`,
			formatTime(claimedAt), requesterDeviceID, item.ID); err != nil {
			return nil, err
		}
		item.DeviceID = deviceID
		item.AccountID = accountID
		item.CreatedAt = parseTime(createdAt)
		item.ExpiresAt = parseTime(expiresAt)
		result = append(result, item)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return result, nil
}

// mlsJoinFilter limits a conversation's encrypted events to the devices in
// its group, from their join cursor on (card I51). Groups without a
// recorded roster are not filtered. The query binds the device ID once.
//
// An application envelope also names the epoch it was encrypted in; one from
// an epoch before the device joined is withheld even when it was stored
// later, because the device cannot decrypt it.
const mlsJoinFilterEvent = `(
	NOT EXISTS (SELECT 1 FROM conversation_mls_groups jg WHERE jg.conversation_id = se.conversation_id)
	OR EXISTS (SELECT 1 FROM conversation_mls_devices jd
		WHERE jd.conversation_id = se.conversation_id AND jd.device_id = ?
		AND se.id > jd.joined_after_event_id
		AND (jd.removed_after_event_id IS NULL OR se.id <= jd.removed_after_event_id)
		AND (se.event_type NOT LIKE 'message.envelope.%'
			OR json_type(se.payload_json, '$.envelope.crypto_metadata.mls_epoch') IS NOT 'integer'
			OR json_extract(se.payload_json, '$.envelope.crypto_metadata.mls_epoch') >= jd.joined_epoch))
)`

// mlsJoinFilterMessage is mlsJoinFilterEvent for conversation_mls_messages
// rows (alias mm), keyed by their sync event.
const mlsJoinFilterMessage = `(
	NOT EXISTS (SELECT 1 FROM conversation_mls_groups jg WHERE jg.conversation_id = mm.conversation_id)
	OR EXISTS (SELECT 1 FROM conversation_mls_devices jd
		WHERE jd.conversation_id = mm.conversation_id AND jd.device_id = ?
		AND mm.sync_event_id > jd.joined_after_event_id
		AND (jd.removed_after_event_id IS NULL OR mm.sync_event_id <= jd.removed_after_event_id))
)`
