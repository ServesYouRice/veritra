package storage

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/domain"
)

var (
	ErrAlreadySetup        = errors.New("instance already has an owner")
	ErrInviteInvalid       = errors.New("invite is invalid, expired, revoked, or fully used")
	ErrUnauthorized        = errors.New("unauthorized")
	ErrForbidden           = errors.New("forbidden")
	ErrNotFound            = errors.New("not found")
	ErrNotMember           = errors.New("account is not a conversation member")
	ErrInvalidInput        = errors.New("invalid input")
	ErrLastOwner           = errors.New("cannot delete the last active owner")
	ErrIdempotencyConflict = errors.New("idempotency key was reused for a different message")
	ErrDeviceLinkInvalid   = errors.New("device link is invalid, expired, revoked, or already used")
	ErrDeviceLinkNotReady  = errors.New("device link is not approved yet")
	ErrStorageQuota        = errors.New("encrypted storage quota exceeded")
	ErrSyncCursorExpired   = errors.New("sync cursor is older than retained history")

	// ErrDeviceLinkVerificationFailed is returned when the approver does not
	// supply the link's verification code, so a device cannot be approved
	// without the human confirming the out-of-band code shown on both devices.
	ErrDeviceLinkVerificationFailed = errors.New("device link verification code does not match")
)

type Store struct {
	db *dbRouter
}

type dbRouter struct {
	reader *sql.DB
	writer *sql.DB
}

func (db *dbRouter) ExecContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error) {
	return db.writer.ExecContext(ctx, query, args...)
}

func (db *dbRouter) QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error) {
	return db.reader.QueryContext(ctx, query, args...)
}

func (db *dbRouter) QueryRowContext(ctx context.Context, query string, args ...interface{}) *sql.Row {
	return db.reader.QueryRowContext(ctx, query, args...)
}

func (db *dbRouter) BeginTx(ctx context.Context, opts *sql.TxOptions) (*sql.Tx, error) {
	return db.writer.BeginTx(ctx, opts)
}

func (db *dbRouter) PingContext(ctx context.Context) error {
	if err := db.writer.PingContext(ctx); err != nil {
		return err
	}
	return db.reader.PingContext(ctx)
}

func (db *dbRouter) Close() error {
	return errors.Join(db.reader.Close(), db.writer.Close())
}

func Open(ctx context.Context, cfg config.Config) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(cfg.DatabasePath), 0o700); err != nil {
		return nil, err
	}
	dsn := sqliteDSN(cfg.DatabasePath)
	writer, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	writer.SetMaxOpenConns(1)
	writer.SetMaxIdleConns(1)
	if _, err := writer.ExecContext(ctx, "PRAGMA journal_mode = WAL;"); err != nil {
		_ = writer.Close()
		return nil, err
	}

	readerConns := runtime.NumCPU()
	if readerConns < 4 {
		readerConns = 4
	}
	if readerConns > 16 {
		readerConns = 16
	}
	reader, err := sql.Open("sqlite", dsn)
	if err != nil {
		_ = writer.Close()
		return nil, err
	}
	reader.SetMaxOpenConns(readerConns)
	reader.SetMaxIdleConns(readerConns)

	// Query calls use their own pool. SQLite's WAL mode gives those reads
	// deferred transactions by default, while writes stay serialized through
	// the single writer connection.
	store := &Store{db: &dbRouter{reader: reader, writer: writer}}
	return store, nil
}

func sqliteDSN(path string) string {
	separator := "?"
	if strings.Contains(path, "?") {
		separator = "&"
	}
	return path + separator + "_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)"
}

func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) Check(ctx context.Context) error {
	return s.db.PingContext(ctx)
}

func (s *Store) CheckReady(ctx context.Context) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var migrations int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM schema_migrations`).Scan(&migrations); err != nil {
		return err
	}
	if migrations == 0 {
		return errors.New("database has no applied migrations")
	}
	return nil
}

func ValidateDatabaseFile(ctx context.Context, path string) error {
	db, err := sql.Open("sqlite", "file:"+filepath.ToSlash(path)+"?mode=ro&_pragma=foreign_keys(1)")
	if err != nil {
		return err
	}
	defer db.Close()
	rows, err := db.QueryContext(ctx, `PRAGMA quick_check`)
	if err != nil {
		return err
	}
	for rows.Next() {
		var result string
		if err := rows.Scan(&result); err != nil {
			rows.Close()
			return err
		}
		if result != "ok" {
			rows.Close()
			return fmt.Errorf("sqlite quick_check: %s", result)
		}
	}
	if err := rows.Close(); err != nil {
		return err
	}
	var requiredTables int
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('schema_migrations', 'instances', 'accounts', 'message_envelopes')`).Scan(&requiredTables); err != nil {
		return err
	}
	if requiredTables != 4 {
		return errors.New("backup does not contain the required Veritra schema")
	}
	foreignKeys, err := db.QueryContext(ctx, `PRAGMA foreign_key_check`)
	if err != nil {
		return err
	}
	defer foreignKeys.Close()
	if foreignKeys.Next() {
		return errors.New("backup contains foreign-key violations")
	}
	return foreignKeys.Err()
}

func ProbeDatabaseExclusive(ctx context.Context, path string) error {
	db, err := sql.Open("sqlite", sqliteDSN(path))
	if err != nil {
		return err
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	if _, err := db.ExecContext(ctx, `PRAGMA busy_timeout = 250; BEGIN EXCLUSIVE`); err != nil {
		return err
	}
	_, err = db.ExecContext(ctx, `ROLLBACK`)
	return err
}

type BackupBlobReference struct {
	StorageKey string `json:"storage_key"`
	SHA256     string `json:"sha256"`
	SizeBytes  int64  `json:"size_bytes"`
}

func ListDatabaseBlobReferences(ctx context.Context, path string) ([]BackupBlobReference, []string, error) {
	db, err := sql.Open("sqlite", "file:"+filepath.ToSlash(path)+"?mode=ro&_pragma=foreign_keys(1)")
	if err != nil {
		return nil, nil, err
	}
	defer db.Close()
	rows, err := db.QueryContext(ctx, `
		SELECT storage_key, ciphertext_sha256, size_bytes FROM attachment_envelopes
		UNION ALL
		SELECT storage_key, ciphertext_sha256, size_bytes FROM backup_blobs
		ORDER BY storage_key`)
	if err != nil {
		return nil, nil, err
	}
	references := make([]BackupBlobReference, 0)
	for rows.Next() {
		var reference BackupBlobReference
		if err := rows.Scan(&reference.StorageKey, &reference.SHA256, &reference.SizeBytes); err != nil {
			rows.Close()
			return nil, nil, err
		}
		references = append(references, reference)
	}
	if err := rows.Close(); err != nil {
		return nil, nil, err
	}
	migrationsRows, err := db.QueryContext(ctx, `SELECT version FROM schema_migrations ORDER BY version`)
	if err != nil {
		return nil, nil, err
	}
	migrations := make([]string, 0)
	for migrationsRows.Next() {
		var version string
		if err := migrationsRows.Scan(&version); err != nil {
			migrationsRows.Close()
			return nil, nil, err
		}
		migrations = append(migrations, version)
	}
	if err := migrationsRows.Close(); err != nil {
		return nil, nil, err
	}
	return references, migrations, nil
}

// BackupTo writes an atomic single-file copy of the database to dest using
// SQLite's VACUUM INTO. The destination must not already exist. This holds
// a read lock for the duration of the copy but does not block writers.
func (s *Store) BackupTo(ctx context.Context, dest string) error {
	if strings.TrimSpace(dest) == "" {
		return fmt.Errorf("backup destination required")
	}
	if _, err := os.Stat(dest); err == nil {
		return fmt.Errorf("backup destination already exists: %s", dest)
	}
	// VACUUM INTO does not accept parameter binding for the filename literal,
	// so quote it. Single-quotes are the SQL string delimiter; double them
	// inside the literal to escape per SQLite syntax. The path comes from a
	// trusted operator (CLI flag), not user input.
	escaped := strings.ReplaceAll(dest, "'", "''")
	_, err := s.db.reader.ExecContext(ctx, fmt.Sprintf("VACUUM INTO '%s'", escaped))
	return err
}

func (s *Store) Migrate(ctx context.Context, migrations fs.FS) error {
	if _, err := s.db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, checksum_sha256 TEXT NOT NULL, applied_at TEXT NOT NULL)`); err != nil {
		return err
	}
	checksumColumnAdded, err := s.ensureMigrationChecksumColumn(ctx)
	if err != nil {
		return err
	}
	entries, err := fs.ReadDir(migrations, ".")
	if err != nil {
		return err
	}
	var names []string
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".sql") {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	for _, name := range names {
		sqlBytes, err := fs.ReadFile(migrations, name)
		if err != nil {
			return err
		}
		checksum := migrationChecksum(sqlBytes)
		appliedChecksum, applied, err := s.appliedMigrationChecksum(ctx, name)
		if err != nil {
			return err
		}
		if applied {
			if appliedChecksum == "" {
				if !checksumColumnAdded {
					return fmt.Errorf("migration %s has no stored checksum", name)
				}
				if _, err := s.db.ExecContext(ctx, `UPDATE schema_migrations SET checksum_sha256 = ? WHERE version = ? AND (checksum_sha256 IS NULL OR checksum_sha256 = '')`, checksum, name); err != nil {
					return err
				}
				continue
			}
			if !strings.EqualFold(appliedChecksum, checksum) {
				return fmt.Errorf("migration %s checksum mismatch: applied %s, current %s", name, appliedChecksum, checksum)
			}
			continue
		}
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, string(sqlBytes)); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("apply migration %s: %w", name, err)
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO schema_migrations(version, checksum_sha256, applied_at) VALUES(?, ?, ?)`, name, checksum, nowString()); err != nil {
			_ = tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) ensureMigrationChecksumColumn(ctx context.Context) (bool, error) {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(schema_migrations)`)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	hasChecksum := false
	for rows.Next() {
		var cid int
		var name, columnType string
		var notNull int
		var defaultValue interface{}
		var pk int
		if err := rows.Scan(&cid, &name, &columnType, &notNull, &defaultValue, &pk); err != nil {
			return false, err
		}
		if name == "checksum_sha256" {
			hasChecksum = true
		}
	}
	if err := rows.Err(); err != nil {
		return false, err
	}
	if hasChecksum {
		return false, nil
	}
	_, err = s.db.ExecContext(ctx, `ALTER TABLE schema_migrations ADD COLUMN checksum_sha256 TEXT`)
	return err == nil, err
}

func (s *Store) appliedMigrationChecksum(ctx context.Context, version string) (string, bool, error) {
	var checksum sql.NullString
	err := s.db.QueryRowContext(ctx, `SELECT checksum_sha256 FROM schema_migrations WHERE version = ?`, version).Scan(&checksum)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", false, nil
		}
		return "", false, err
	}
	if !checksum.Valid {
		return "", true, nil
	}
	return checksum.String, true, nil
}

func migrationChecksum(sqlBytes []byte) string {
	sum := sha256.Sum256(sqlBytes)
	return hex.EncodeToString(sum[:])
}

func (s *Store) SetupRequired(ctx context.Context) (bool, error) {
	var count int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts`).Scan(&count); err != nil {
		return false, err
	}
	return count == 0, nil
}

func (s *Store) InstanceName(ctx context.Context) (string, error) {
	var name string
	if err := s.db.QueryRowContext(ctx, `SELECT name FROM instances WHERE id = 1 AND setup_complete = 1`).Scan(&name); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", ErrNotFound
		}
		return "", err
	}
	return name, nil
}

type CreateOwnerInput struct {
	InstanceName   string
	Username       string
	Email          *string
	PasswordHash   string
	DeviceName     string
	KeyPackage     []byte
	DeviceAuthHash string
	SessionHash    string
	SessionExpiry  time.Time
}

type AccountDevice struct {
	Account domain.Account `json:"account"`
	Device  domain.Device  `json:"device"`
}

func scanAccountDevice(rows scanner) (AccountDevice, error) {
	var account domain.Account
	var email, accountDeleted, accountCreated sql.NullString
	var device domain.Device
	var signing []byte
	var deviceCreated string
	var lastSeen, revoked sql.NullString
	if err := rows.Scan(
		&account.ID, &account.Username, &email, &account.Role, &account.Status, &accountCreated, &accountDeleted,
		&device.ID, &device.AccountID, &device.Name, &device.KeyPackage, &signing, &deviceCreated, &lastSeen, &revoked,
	); err != nil {
		return AccountDevice{}, err
	}
	account.Email = stringPtr(email)
	account.CreatedAt = parseTime(accountCreated.String)
	account.DeletedAt = parseOptionalTime(accountDeleted)
	device.SigningKey = signing
	device.CreatedAt = parseTime(deviceCreated)
	device.LastSeenAt = parseOptionalTime(lastSeen)
	device.RevokedAt = parseOptionalTime(revoked)
	return AccountDevice{Account: account, Device: device}, nil
}

func scanDevice(rows scanner) (domain.Device, error) {
	var device domain.Device
	var signing []byte
	var lastSeen, revoked sql.NullString
	var created string
	if err := rows.Scan(&device.ID, &device.AccountID, &device.Name, &device.KeyPackage, &signing, &created, &lastSeen, &revoked); err != nil {
		return domain.Device{}, err
	}
	device.SigningKey = signing
	device.CreatedAt = parseTime(created)
	device.LastSeenAt = parseOptionalTime(lastSeen)
	device.RevokedAt = parseOptionalTime(revoked)
	return device, nil
}

func scanDeviceLink(rows scanner, link *domain.DeviceLink) error {
	var code, createdByDeviceID, claimedDeviceName, approvedDeviceID sql.NullString
	var created, expires, claimed, approved, consumed, revoked sql.NullString
	if err := rows.Scan(&link.ID, &code, &link.AccountID, &createdByDeviceID, &link.State, &link.VerificationCode, &claimedDeviceName, &approvedDeviceID, &created, &expires, &claimed, &approved, &consumed, &revoked); err != nil {
		return err
	}
	if code.Valid {
		link.Code = code.String
	}
	if createdByDeviceID.Valid {
		link.CreatedByDeviceID = createdByDeviceID.String
	}
	link.ClaimedDeviceName = stringPtr(claimedDeviceName)
	link.ApprovedDeviceID = stringPtr(approvedDeviceID)
	link.CreatedAt = parseTime(created.String)
	link.ExpiresAt = parseTime(expires.String)
	link.ClaimedAt = parseOptionalTime(claimed)
	link.ApprovedAt = parseOptionalTime(approved)
	link.ConsumedAt = parseOptionalTime(consumed)
	link.RevokedAt = parseOptionalTime(revoked)
	return nil
}

func scanDeviceLinkForApproval(rows scanner, link *domain.DeviceLink, deviceName *string, keyPackage *[]byte, signingKey *[]byte, authSecretHash *string) error {
	var code, createdByDeviceID, claimedDeviceName, approvedDeviceID, claimedDeviceNameForDevice sql.NullString
	var created, expires, claimed, approved, consumed, revoked sql.NullString
	if err := rows.Scan(
		&link.ID, &code, &link.AccountID, &createdByDeviceID, &link.State, &link.VerificationCode, &claimedDeviceName, &approvedDeviceID, &created, &expires, &claimed, &approved, &consumed, &revoked,
		&claimedDeviceNameForDevice, keyPackage, signingKey, authSecretHash,
	); err != nil {
		return err
	}
	if code.Valid {
		link.Code = code.String
	}
	if createdByDeviceID.Valid {
		link.CreatedByDeviceID = createdByDeviceID.String
	}
	link.ClaimedDeviceName = stringPtr(claimedDeviceName)
	link.ApprovedDeviceID = stringPtr(approvedDeviceID)
	link.CreatedAt = parseTime(created.String)
	link.ExpiresAt = parseTime(expires.String)
	link.ClaimedAt = parseOptionalTime(claimed)
	link.ApprovedAt = parseOptionalTime(approved)
	link.ConsumedAt = parseOptionalTime(consumed)
	link.RevokedAt = parseOptionalTime(revoked)
	if claimedDeviceNameForDevice.Valid {
		*deviceName = claimedDeviceNameForDevice.String
	}
	return nil
}

func scanConversation(rows scanner) (domain.Conversation, error) {
	var c domain.Conversation
	var title, communityID, channelID, created sql.NullString
	var retention sql.NullInt64
	if err := rows.Scan(&c.ID, &c.Kind, &title, &communityID, &channelID, &c.CreatedBy, &retention, &created); err != nil {
		return domain.Conversation{}, err
	}
	c.Title = stringPtr(title)
	c.CommunityID = stringPtr(communityID)
	c.ChannelID = stringPtr(channelID)
	if retention.Valid {
		c.RetentionSeconds = &retention.Int64
	}
	c.CreatedAt = parseTime(created.String)
	return c, nil
}

func scanConversationWithRole(rows scanner) (domain.Conversation, error) {
	var c domain.Conversation
	var title, communityID, channelID, created, lastMessage sql.NullString
	var retention sql.NullInt64
	var unread int64
	if err := rows.Scan(&c.ID, &c.Kind, &title, &communityID, &channelID,
		&c.CreatedBy, &retention, &created, &c.CurrentRole, &lastMessage,
		&unread); err != nil {
		return domain.Conversation{}, err
	}
	c.Title = stringPtr(title)
	c.CommunityID = stringPtr(communityID)
	c.ChannelID = stringPtr(channelID)
	if retention.Valid {
		c.RetentionSeconds = &retention.Int64
	}
	c.CreatedAt = parseTime(created.String)
	if lastMessage.Valid && lastMessage.String != "" {
		t := parseTime(lastMessage.String)
		c.LastMessageAt = &t
	}
	c.UnreadCount = unread
	return c, nil
}

func scanMessage(rows scanner) (domain.MessageEnvelope, error) {
	var msg domain.MessageEnvelope
	var cryptoMetadata, attachmentRefs string
	var replyTo, threadRoot, created, edited, deleted, expires sql.NullString
	if err := rows.Scan(&msg.ID, &msg.ConversationID, &msg.SenderAccountID, &msg.SenderDeviceID, &msg.IdempotencyKey, &msg.Ciphertext, &msg.CryptoProtocol, &cryptoMetadata, &attachmentRefs, &replyTo, &threadRoot, &created, &edited, &deleted, &expires); err != nil {
		return domain.MessageEnvelope{}, err
	}
	msg.CryptoMetadata = json.RawMessage(cryptoMetadata)
	msg.AttachmentRefs = json.RawMessage(attachmentRefs)
	msg.ReplyToID = stringPtr(replyTo)
	msg.ThreadRootID = stringPtr(threadRoot)
	msg.CreatedAt = parseTime(created.String)
	msg.EditedAt = parseOptionalTime(edited)
	msg.DeletedAt = parseOptionalTime(deleted)
	msg.ExpiresAt = parseOptionalTime(expires)
	return msg, nil
}

func scanAttachment(rows scanner) (domain.AttachmentEnvelope, error) {
	var attachment domain.AttachmentEnvelope
	var conversationID sql.NullString
	var metadata, created string
	if err := rows.Scan(&attachment.ID, &attachment.OwnerAccountID, &conversationID, &attachment.StorageKey, &attachment.CiphertextSHA256, &attachment.SizeBytes, &metadata, &created); err != nil {
		return domain.AttachmentEnvelope{}, err
	}
	attachment.ConversationID = stringPtr(conversationID)
	attachment.CryptoMetadata = json.RawMessage(metadata)
	attachment.CreatedAt = parseTime(created)
	return attachment, nil
}

func scanBackup(rows scanner) (domain.BackupBlob, error) {
	var backup domain.BackupBlob
	var deviceID sql.NullString
	var metadata, created string
	if err := rows.Scan(&backup.ID, &backup.AccountID, &deviceID, &backup.StorageKey, &backup.CiphertextSHA256, &backup.SizeBytes, &metadata, &created); err != nil {
		return domain.BackupBlob{}, err
	}
	backup.DeviceID = stringPtr(deviceID)
	backup.KeyDerivationMetadata = json.RawMessage(metadata)
	backup.CreatedAt = parseTime(created)
	return backup, nil
}

func scanCall(rows scanner) (domain.CallSession, error) {
	var call domain.CallSession
	var metadata, created string
	var ended, expires sql.NullString
	if err := rows.Scan(&call.ID, &call.ConversationID, &call.CreatedBy, &call.State, &metadata, &created, &ended, &expires); err != nil {
		return domain.CallSession{}, err
	}
	call.Metadata = json.RawMessage(metadata)
	call.CreatedAt = parseTime(created)
	call.EndedAt = parseOptionalTime(ended)
	call.ExpiresAt = parseOptionalTime(expires)
	return call, nil
}

func scanSyncEvent(rows scanner) (domain.SyncEvent, error) {
	var event domain.SyncEvent
	var accountID, conversationID, created sql.NullString
	var payload string
	if err := rows.Scan(&event.ID, &event.Type, &accountID, &conversationID, &payload, &created); err != nil {
		return domain.SyncEvent{}, err
	}
	event.AccountID = stringPtr(accountID)
	if conversationID.Valid {
		event.ConversationID = conversationID.String
	}
	event.Payload = json.RawMessage(payload)
	event.CreatedAt = parseTime(created.String)
	return event, nil
}

func nullableString(value *string) sql.NullString {
	if value == nil || strings.TrimSpace(*value) == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: strings.TrimSpace(*value), Valid: true}
}

func nullableEmptyString(value string) sql.NullString {
	if strings.TrimSpace(value) == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: strings.TrimSpace(value), Valid: true}
}

func nullableTime(value *time.Time) sql.NullString {
	if value == nil {
		return sql.NullString{}
	}
	return sql.NullString{String: formatTime(value.UTC()), Valid: true}
}

func nullableInt64(value *int64) sql.NullInt64 {
	if value == nil {
		return sql.NullInt64{}
	}
	return sql.NullInt64{Int64: *value, Valid: true}
}

func nullableBytes(value []byte) interface{} {
	if len(value) == 0 {
		return nil
	}
	return value
}

func stringPtr(value sql.NullString) *string {
	if !value.Valid {
		return nil
	}
	v := value.String
	return &v
}

func parseOptionalTime(value sql.NullString) *time.Time {
	if !value.Valid {
		return nil
	}
	t := parseTime(value.String)
	return &t
}

func parseTime(value string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return time.Time{}
	}
	return t
}

func nowString() string {
	return formatTime(time.Now().UTC())
}

func formatTime(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000000000Z")
}

func escapeLike(value string) string {
	value = strings.ReplaceAll(value, `\`, `\\`)
	value = strings.ReplaceAll(value, `%`, `\%`)
	value = strings.ReplaceAll(value, `_`, `\_`)
	return value
}
