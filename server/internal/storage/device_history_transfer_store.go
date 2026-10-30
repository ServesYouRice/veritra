package storage

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/uploads"
)

const MaxHistoryCiphertext = 100 << 20

type HistoryTransferInput struct {
	ProtocolVersion  string `json:"protocol_version"`
	TransferID       string `json:"transfer_id"`
	ClaimRequestHash string `json:"claim_request_hash"`
	TranscriptHash   []byte `json:"transcript_hash"`
	CiphertextSHA256 string `json:"ciphertext_sha256"`
	SizeBytes        int64  `json:"size_bytes"`
	Handoff          []byte `json:"handoff"`
}

type HistoryTransfer struct {
	TransferID        string          `json:"transfer_id"`
	LinkID            string          `json:"link_id"`
	AccountID         string          `json:"account_id"`
	SourceDeviceID    string          `json:"source_device_id"`
	RecipientDeviceID string          `json:"recipient_device_id"`
	ClaimRequestHash  string          `json:"claim_request_hash"`
	TranscriptHash    []byte          `json:"transcript_hash"`
	CiphertextSHA256  string          `json:"ciphertext_sha256"`
	SizeBytes         int64           `json:"size_bytes"`
	State             string          `json:"state"`
	Handoff           []byte          `json:"handoff,omitempty"`
	CreatedAt         time.Time       `json:"created_at"`
	ExpiresAt         time.Time       `json:"expires_at"`
	TerminalAt        *time.Time      `json:"terminal_at,omitempty"`
	Ref               uploads.BlobRef `json:"-"`
	handoffHash       string
}

type HistoryAccess struct{ AccountID, DeviceID, ClaimTokenHash string }

func historyInputDigest(input HistoryTransferInput) string {
	b, _ := json.Marshal(input)
	d := sha256.Sum256(b)
	return hex.EncodeToString(d[:])
}

func validateHistoryInput(input HistoryTransferInput) bool {
	return input.ProtocolVersion == DeviceLinkV3Protocol && validV3Hash(input.TransferID) && validV3Hash(input.ClaimRequestHash) && validV3Hash(input.CiphertextSHA256) && len(input.TranscriptHash) == 32 && input.SizeBytes > 0 && input.SizeBytes <= MaxHistoryCiphertext && len(input.Handoff) > 0 && len(input.Handoff) <= 8192
}

func historyLink(ctx context.Context, q queryRower, id string, access HistoryAccess, sourceOnly bool) (deviceLinkV3Record, bool, error) {
	link, err := loadDeviceLinkV3(ctx, q, ` AND v.id=?`, id)
	if err != nil {
		return link, false, err
	}
	source := access.AccountID == link.AccountID && access.DeviceID == link.SourceDeviceID && access.ClaimTokenHash == ""
	recipient := access.AccountID == link.AccountID && access.DeviceID == link.RecipientDeviceID && access.ClaimTokenHash == ""
	if access.AccountID == "" && access.DeviceID == "" && validV3Hash(access.ClaimTokenHash) && access.ClaimTokenHash == link.claimTokenHash {
		recipient = true
	}
	if (sourceOnly && !source) || (!sourceOnly && !source && !recipient) {
		return link, false, ErrForbidden
	}
	if (link.State != domain.DeviceLinkApproved && link.State != domain.DeviceLinkConsumed) || !link.validWindow(time.Now().UTC()) {
		return link, false, ErrDeviceLinkInvalid
	}
	return link, source, nil
}

func loadHistoryTransfer(ctx context.Context, q queryRower, id string) (HistoryTransfer, error) {
	var t HistoryTransfer
	var created, expires string
	var terminal sql.NullString
	var key sql.NullString
	err := q.QueryRowContext(ctx, `SELECT transfer_id,link_id,account_id,source_device_id,recipient_device_id,claim_request_hash,transcript_hash,ciphertext_sha256,size_bytes,state,handoff,handoff_sha256,storage_key,chunk_digests,created_at,expires_at,terminal_at FROM device_history_transfers WHERE link_id=?`, id).Scan(&t.TransferID, &t.LinkID, &t.AccountID, &t.SourceDeviceID, &t.RecipientDeviceID, &t.ClaimRequestHash, &t.TranscriptHash, &t.CiphertextSHA256, &t.SizeBytes, &t.State, &t.Handoff, &t.handoffHash, &key, &t.Ref.ChunkDigests, &created, &expires, &terminal)
	if errors.Is(err, sql.ErrNoRows) {
		return t, ErrNotFound
	}
	if err != nil {
		return t, err
	}
	t.Ref.StorageKey, t.Ref.SHA256, t.Ref.Size = key.String, t.CiphertextSHA256, t.SizeBytes
	t.CreatedAt, t.ExpiresAt, t.TerminalAt = parseTime(created), parseTime(expires), parseOptionalTime(terminal)
	return t, nil
}

func sameHistoryInput(t HistoryTransfer, input HistoryTransferInput) bool {
	d := sha256.Sum256(input.Handoff)
	return t.TransferID == input.TransferID && t.ClaimRequestHash == input.ClaimRequestHash && v3Equal(t.TranscriptHash, input.TranscriptHash) && t.CiphertextSHA256 == input.CiphertextSHA256 && t.SizeBytes == input.SizeBytes && t.handoffHash == hex.EncodeToString(d[:])
}

// CheckHistoryUpload is read-only. Exact committed retries need no second blob.
func (s *Store) CheckHistoryUpload(ctx context.Context, id string, access HistoryAccess, input HistoryTransferInput) (*HistoryTransfer, error) {
	if !validateHistoryInput(input) {
		return nil, ErrInvalidInput
	}
	link, _, err := historyLink(ctx, s.db, id, access, true)
	if err != nil {
		return nil, err
	}
	if link.ClaimRequestHash != input.ClaimRequestHash || !v3Equal(link.TranscriptHash, input.TranscriptHash) {
		return nil, ErrDeviceLinkVerificationFailed
	}
	t, err := loadHistoryTransfer(ctx, s.db, id)
	if err == nil {
		if !sameHistoryInput(t, input) {
			return nil, ErrIdempotencyConflict
		}
		t.Handoff = nil
		return &t, nil
	}
	if !errors.Is(err, ErrNotFound) {
		return nil, err
	}
	var cancelled sql.NullString
	if err := s.db.QueryRowContext(ctx, `SELECT history_cancelled_at FROM device_links_v3 WHERE id=?`, id).Scan(&cancelled); err != nil {
		return nil, err
	}
	if cancelled.Valid {
		return nil, ErrDeviceLinkInvalid
	}
	return nil, nil
}

// RegisterHistoryUpload commits its quota reservation before a blob can exist.
func (s *Store) RegisterHistoryUpload(ctx context.Context, id string, access HistoryAccess, input HistoryTransferInput, key string) error {
	if !validateHistoryInput(input) || !domain.ValidID("blob", key) {
		return ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	link, _, err := historyLink(ctx, tx, id, access, true)
	if err != nil {
		return err
	}
	if link.ClaimRequestHash != input.ClaimRequestHash || !v3Equal(link.TranscriptHash, input.TranscriptHash) {
		return ErrDeviceLinkVerificationFailed
	}
	var blocked bool
	if err := tx.QueryRowContext(ctx, `SELECT history_cancelled_at IS NOT NULL OR EXISTS(SELECT 1 FROM device_history_transfers WHERE link_id=?) FROM device_links_v3 WHERE id=?`, id, id).Scan(&blocked); err != nil {
		return err
	}
	if blocked {
		return ErrIdempotencyConflict
	}
	if err := retireHistoryIntents(ctx, tx, `link_id=? AND expires_at<=?`, id, nowString()); err != nil {
		return err
	}
	n, err := countRows(ctx, tx, `SELECT COUNT(*) FROM device_history_upload_intents WHERE link_id=?`, id)
	if err != nil {
		return err
	}
	if n != 0 {
		return ErrIdempotencyConflict
	}
	if err := s.enforceBlobQuota(ctx, tx, link.AccountID, input.SizeBytes); err != nil {
		return err
	}
	now := time.Now().UTC()
	expiry := now.Add(10 * time.Minute)
	if link.TransferExpiresAt.Before(expiry) {
		expiry = *link.TransferExpiresAt
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO device_history_upload_intents(storage_key,link_id,account_id,transfer_id,metadata_sha256,size_bytes,created_at,expires_at) VALUES(?,?,?,?,?,?,?,?)`, key, id, link.AccountID, input.TransferID, historyInputDigest(input), input.SizeBytes, formatTime(now), formatTime(expiry))
	if err != nil {
		return err
	}
	return tx.Commit()
}

// FinalizeHistoryUpload never deletes the blob on error: an ambiguous commit
// leaves either the intent or active reference available for reconciliation.
func (s *Store) FinalizeHistoryUpload(ctx context.Context, id string, access HistoryAccess, input HistoryTransferInput, ref uploads.BlobRef) (HistoryTransfer, error) {
	if !validateHistoryInput(input) || ref.SHA256 != input.CiphertextSHA256 || ref.Size != input.SizeBytes {
		return HistoryTransfer{}, ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return HistoryTransfer{}, err
	}
	defer tx.Rollback()
	link, _, err := historyLink(ctx, tx, id, access, true)
	if err != nil {
		return HistoryTransfer{}, err
	}
	var digest string
	err = tx.QueryRowContext(ctx, `SELECT metadata_sha256 FROM device_history_upload_intents WHERE storage_key=? AND link_id=? AND expires_at>?`, ref.StorageKey, id, nowString()).Scan(&digest)
	if errors.Is(err, sql.ErrNoRows) {
		return HistoryTransfer{}, ErrDeviceLinkInvalid
	}
	if err != nil {
		return HistoryTransfer{}, err
	}
	if digest != historyInputDigest(input) {
		return HistoryTransfer{}, ErrIdempotencyConflict
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM device_history_upload_intents WHERE storage_key=?`, ref.StorageKey); err != nil {
		return HistoryTransfer{}, err
	}
	d := sha256.Sum256(input.Handoff)
	_, err = tx.ExecContext(ctx, `INSERT INTO device_history_transfers(link_id,transfer_id,account_id,source_device_id,recipient_device_id,claim_request_hash,transcript_hash,ciphertext_sha256,size_bytes,handoff,handoff_sha256,storage_key,chunk_digests,state,created_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,'active',?,?)`, id, input.TransferID, link.AccountID, link.SourceDeviceID, link.RecipientDeviceID, input.ClaimRequestHash, input.TranscriptHash, input.CiphertextSHA256, input.SizeBytes, input.Handoff, hex.EncodeToString(d[:]), ref.StorageKey, ref.ChunkDigests, nowString(), formatTime(*link.TransferExpiresAt))
	if err != nil {
		return HistoryTransfer{}, err
	}
	t, err := loadHistoryTransfer(ctx, tx, id)
	if err != nil {
		return t, err
	}
	t.Handoff = nil
	if err := tx.Commit(); err != nil {
		return HistoryTransfer{}, err
	}
	return t, nil
}

func (s *Store) AbortHistoryUpload(ctx context.Context, key string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := retireHistoryIntents(ctx, tx, `storage_key=?`, key); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) HistoryTransferForAccess(ctx context.Context, id string, access HistoryAccess, content bool) (HistoryTransfer, error) {
	_, source, err := historyLink(ctx, s.db, id, access, false)
	if err != nil {
		return HistoryTransfer{}, err
	}
	if source && content {
		return HistoryTransfer{}, ErrForbidden
	}
	t, err := loadHistoryTransfer(ctx, s.db, id)
	if err != nil {
		return t, err
	}
	if content && t.State != "active" {
		return HistoryTransfer{}, ErrDeviceLinkInvalid
	}
	if source {
		t.Handoff = nil
	}
	return t, nil
}

func (s *Store) AcknowledgeHistoryTransfer(ctx context.Context, id string, access HistoryAccess, transferID, digest string) (HistoryTransfer, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return HistoryTransfer{}, err
	}
	defer tx.Rollback()
	_, source, err := historyLink(ctx, tx, id, access, false)
	if err != nil {
		return HistoryTransfer{}, err
	}
	if source {
		return HistoryTransfer{}, ErrForbidden
	}
	t, err := loadHistoryTransfer(ctx, tx, id)
	if err != nil {
		return t, err
	}
	if t.TransferID != transferID || t.CiphertextSHA256 != digest {
		return HistoryTransfer{}, ErrIdempotencyConflict
	}
	if t.State != "acknowledged" {
		if t.State != "active" {
			return HistoryTransfer{}, ErrIdempotencyConflict
		}
		if err := retireHistoryTransfers(ctx, tx, `link_id=?`, "acknowledged", id); err != nil {
			return HistoryTransfer{}, err
		}
	}
	t, err = loadHistoryTransfer(ctx, tx, id)
	if err != nil {
		return t, err
	}
	if err := tx.Commit(); err != nil {
		return HistoryTransfer{}, err
	}
	return t, nil
}

func (s *Store) CancelHistoryTransfer(ctx context.Context, id string, access HistoryAccess) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, _, err := historyLink(ctx, tx, id, access, false); err != nil {
		return err
	}
	if err := retireHistoryIntents(ctx, tx, `link_id=?`, id); err != nil {
		return err
	}
	if err := retireHistoryTransfers(ctx, tx, `link_id=?`, "cancelled", id); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE device_links_v3 SET history_cancelled_at=COALESCE(history_cancelled_at,?) WHERE id=?`, nowString(), id); err != nil {
		return err
	}
	return tx.Commit()
}

func retireHistoryIntents(ctx context.Context, tx *sql.Tx, predicate string, args ...interface{}) error {
	rows, err := tx.QueryContext(ctx, `SELECT storage_key FROM device_history_upload_intents WHERE `+predicate, args...)
	if err != nil {
		return err
	}
	var keys []string
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			rows.Close()
			return err
		}
		keys = append(keys, key)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for _, key := range keys {
		if err := enqueueBlobDeletion(ctx, tx, key); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM device_history_upload_intents WHERE storage_key=?`, key); err != nil {
			return err
		}
	}
	return nil
}

func retireHistoryTransfers(ctx context.Context, tx *sql.Tx, predicate, state string, args ...interface{}) error {
	rows, err := tx.QueryContext(ctx, `SELECT storage_key FROM device_history_transfers WHERE state='active' AND (`+predicate+`)`, args...)
	if err != nil {
		return err
	}
	var keys []string
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			rows.Close()
			return err
		}
		keys = append(keys, key)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for _, key := range keys {
		if err := enqueueBlobDeletion(ctx, tx, key); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE device_history_transfers SET state=?,terminal_at=?,handoff=NULL,storage_key=NULL,chunk_digests=NULL WHERE storage_key=? AND state='active'`, state, nowString(), key); err != nil {
			return err
		}
	}
	return nil
}

func retireHistoryForLinks(ctx context.Context, tx *sql.Tx, predicate string, args ...interface{}) error {
	where := `link_id IN (SELECT id FROM device_links_v3 WHERE ` + predicate + `)`
	if err := retireHistoryIntents(ctx, tx, where, args...); err != nil {
		return err
	}
	return retireHistoryTransfers(ctx, tx, where, "cancelled", args...)
}
