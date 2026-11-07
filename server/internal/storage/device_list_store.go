package storage

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"private-messenger/server/internal/devicelist"
)

// Account approved-device lists (L1-2, D94; docs/designs/L1-approved-device-list.md).
// The server stores and serves each account's signed chain. It holds no
// signing key, so it cannot create a version; it parses and checks every
// upload with the rules clients apply, enforces monotonic versions and size
// limits, and ties each version to the request that carries it.

var (
	// ErrInvalidDeviceList is a statement that is malformed, breaks a chain
	// rule, fails its signature, or does not match the request carrying it.
	ErrInvalidDeviceList = errors.New("invalid device list")
	// ErrDeviceListConflict is a version that does not chain from the
	// account's head (a wrong version or prev_hash). A DeviceListConflictError
	// carries the head version.
	ErrDeviceListConflict = errors.New("device list version conflict")
	// ErrDeviceListRequired is a request that must carry a device list
	// version and does not (a head exists, and the action changes the list).
	ErrDeviceListRequired = errors.New("device list version required")
)

// DeviceListConflictError is ErrDeviceListConflict with the head version, so
// the caller can refresh and sign again.
type DeviceListConflictError struct{ HeadVersion uint64 }

func (e DeviceListConflictError) Error() string { return ErrDeviceListConflict.Error() }
func (e DeviceListConflictError) Is(target error) bool {
	return target == ErrDeviceListConflict
}

// DeviceListConflictHead returns the head version carried by a conflict error.
func DeviceListConflictHead(err error) (uint64, bool) {
	var conflict DeviceListConflictError
	if errors.As(err, &conflict) {
		return conflict.HeadVersion, true
	}
	return 0, false
}

const (
	// DeviceListEventType is the sync event the account's own devices get when a
	// version lands. Peers get none; they refresh before every decision.
	DeviceListEventType = "device_list.updated"

	// DeviceListPageMax is the most statements one account's read returns.
	DeviceListPageMax = 64
	// DeviceListQueryItemsMax and DeviceListQueryStatementsMax bound the batch
	// read: items in a request, statements in the answer.
	DeviceListQueryItemsMax      = 100
	DeviceListQueryStatementsMax = 256
)

// DeviceListRule ties an upload to the action of the route that carries it.
// The zero value allows nothing.
type DeviceListRule struct {
	// Changes are the change kinds the route accepts.
	Changes []devicelist.Change
	// Signer is the device that must have signed (the caller), "" for none.
	Signer string
	// Added, when non-nil, is exactly the set of pairs the version adds.
	Added []devicelist.Entry
	// Removed, when non-nil, is exactly the set of device ids the version
	// removes.
	Removed []string
	// RemovedRevoked requires every removed device to be revoked already.
	RemovedRevoked bool
	// RecoveryKeySet requires the version to carry a recovery key.
	RecoveryKeySet bool
}

func (r DeviceListRule) allows(change devicelist.Change) bool {
	for _, allowed := range r.Changes {
		if allowed == change {
			return true
		}
	}
	return false
}

// DeviceListResult is what an inserted version reports.
type DeviceListResult struct {
	Version uint64
	EventID int64
}

type deviceListHead struct {
	statement devicelist.Statement
	version   uint64
}

// deviceListHeadTx reads the account's newest version, or nil.
func deviceListHeadTx(ctx context.Context, q rowQuerier, accountID string) (*deviceListHead, error) {
	var raw []byte
	var version int64
	err := q.QueryRowContext(ctx, `SELECT version, statement FROM device_list_versions WHERE account_id = ? ORDER BY version DESC LIMIT 1`, accountID).Scan(&version, &raw)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	parsed, err := devicelist.Parse(raw)
	if err != nil {
		// Only this code writes the table, after parsing: a stored row that
		// no longer parses is corruption, not a client mistake.
		return nil, fmt.Errorf("stored device list for %s does not parse: %w", accountID, err)
	}
	return &deviceListHead{statement: parsed, version: uint64(version)}, nil
}

// HasDeviceList reports whether the account has published a list.
func (s *Store) HasDeviceList(ctx context.Context, accountID string) (bool, error) {
	var has bool
	err := s.db.reader.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM device_list_versions WHERE account_id = ?)`, accountID).Scan(&has)
	return has, err
}

// DeviceListHeadVersion returns the account's head version, 0 for none.
func (s *Store) DeviceListHeadVersion(ctx context.Context, accountID string) (uint64, error) {
	head, err := deviceListHeadTx(ctx, s.db.reader, accountID)
	if err != nil || head == nil {
		return 0, err
	}
	return head.version, nil
}

// genesisDeviceListRule is the rule for the change-1 version a new account's
// first device signs: exactly that device with its enrollment signing key.
func genesisDeviceListRule(deviceID string, signingKey []byte) DeviceListRule {
	return DeviceListRule{
		Changes: []devicelist.Change{devicelist.ChangeGenesis},
		Signer:  deviceID,
		Added:   []devicelist.Entry{{DeviceID: deviceID, SigningKey: signingKey}},
	}
}

// optionalDeviceListTx applies the version a route may carry. With no
// version it does nothing, except where requiredWithHead is set and the
// account has a head: an action that changes the list (a link approval, a
// recovery-key change) must then say how, so an old client cannot create an
// unlisted device or a head with no recovery key. Accounts with no head stay
// as they were before L1.
//
// It fails closed on a caller with no device: every rule here is signed by a
// device, and insertDeviceListTx skips the signer check for an empty Signer,
// so an empty one is ErrForbidden when a version is sent, and when the
// account has a head and requiredWithHead is set (a device-less caller can
// never sign the version the head requires).
func optionalDeviceListTx(ctx context.Context, tx *sql.Tx, accountID string, raw []byte, rule DeviceListRule, requiredWithHead bool, now string) (*DeviceListResult, error) {
	if rule.Signer == "" && len(raw) != 0 {
		return nil, ErrForbidden
	}
	if len(raw) == 0 {
		if !requiredWithHead {
			return nil, nil
		}
		var has bool
		if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM device_list_versions WHERE account_id = ?)`, accountID).Scan(&has); err != nil {
			return nil, err
		}
		if has {
			if rule.Signer == "" {
				return nil, ErrForbidden
			}
			return nil, ErrDeviceListRequired
		}
		return nil, nil
	}
	result, err := insertDeviceListTx(ctx, tx, accountID, raw, rule, now)
	if err != nil {
		return nil, err
	}
	return &result, nil
}

// insertDeviceListTx parses, checks and stores one version in the caller's
// transaction. Callers run it after the transaction's own device changes (the
// new device row, the revocation), so the checks see them.
//
// A wrong version or prev_hash is a DeviceListConflictError; everything else
// wrong is ErrInvalidDeviceList. Nothing here logs the statement.
func insertDeviceListTx(ctx context.Context, tx *sql.Tx, accountID string, raw []byte, rule DeviceListRule, now string) (DeviceListResult, error) {
	next, err := devicelist.Parse(raw)
	if err != nil {
		return DeviceListResult{}, ErrInvalidDeviceList
	}
	head, err := deviceListHeadTx(ctx, tx, accountID)
	if err != nil {
		return DeviceListResult{}, err
	}
	history, err := deviceListHistoryTx(ctx, tx, accountID)
	if err != nil {
		return DeviceListResult{}, err
	}
	if head != nil {
		history.Head = &head.statement
	}
	if err := devicelist.CheckStep(accountID, history, next); err != nil {
		if errors.Is(err, devicelist.ErrVersionGap) || errors.Is(err, devicelist.ErrPrevHash) {
			var headVersion uint64
			if head != nil {
				headVersion = head.version
			}
			return DeviceListResult{}, DeviceListConflictError{HeadVersion: headVersion}
		}
		return DeviceListResult{}, ErrInvalidDeviceList
	}
	body := next.Body
	if !rule.allows(body.Change) {
		return DeviceListResult{}, ErrInvalidDeviceList
	}
	if rule.Signer != "" && (next.SignerKind != devicelist.SignerDevice || next.SignerDeviceID != rule.Signer) {
		return DeviceListResult{}, ErrInvalidDeviceList
	}
	if rule.RecoveryKeySet && body.RecoveryKey == nil {
		return DeviceListResult{}, ErrInvalidDeviceList
	}
	var prevBody devicelist.Body
	if head != nil {
		prevBody = head.statement.Body
	}
	added := devicelist.Added(prevBody, body)
	removed := devicelist.Removed(prevBody, body)
	if rule.Added != nil && !sameEntrySet(added, rule.Added) {
		return DeviceListResult{}, ErrInvalidDeviceList
	}
	if rule.Removed != nil && !sameIDSet(removed, rule.Removed) {
		return DeviceListResult{}, ErrInvalidDeviceList
	}
	// Every listed device exists in the account, is not revoked and has the
	// same signing key.
	for _, entry := range body.Entries {
		var key []byte
		var live bool
		err := tx.QueryRowContext(ctx, `SELECT signing_key, revoked_at IS NULL FROM devices WHERE id = ? AND account_id = ?`, entry.DeviceID, accountID).Scan(&key, &live)
		if errors.Is(err, sql.ErrNoRows) {
			return DeviceListResult{}, ErrInvalidDeviceList
		}
		if err != nil {
			return DeviceListResult{}, err
		}
		if !live || !bytes.Equal(key, entry.SigningKey) {
			return DeviceListResult{}, ErrInvalidDeviceList
		}
	}
	if rule.RemovedRevoked {
		for _, deviceID := range removed {
			var revoked bool
			err := tx.QueryRowContext(ctx, `SELECT revoked_at IS NOT NULL FROM devices WHERE id = ? AND account_id = ?`, deviceID, accountID).Scan(&revoked)
			if errors.Is(err, sql.ErrNoRows) {
				// A device the server never had cannot be "already revoked".
				return DeviceListResult{}, ErrInvalidDeviceList
			}
			if err != nil {
				return DeviceListResult{}, err
			}
			if !revoked {
				return DeviceListResult{}, ErrInvalidDeviceList
			}
		}
	}
	var signer interface{}
	if next.SignerKind == devicelist.SignerDevice {
		signer = next.SignerDeviceID
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO device_list_versions(account_id, version, list_hash, statement, change, signer_device_id, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)`,
		accountID, int64(body.Version), next.Hash(), next.Raw, int(body.Change), signer, now); err != nil {
		if strings.Contains(err.Error(), "constraint failed") {
			// Lost a race for this version: the head moved.
			return DeviceListResult{}, DeviceListConflictError{HeadVersion: body.Version}
		}
		return DeviceListResult{}, err
	}
	for _, deviceID := range removed {
		if _, err := tx.ExecContext(ctx, `UPDATE device_list_devices SET removed_version = ? WHERE account_id = ? AND device_id = ? AND removed_version IS NULL`, int64(body.Version), accountID, deviceID); err != nil {
			return DeviceListResult{}, err
		}
	}
	for _, entry := range added {
		if _, err := tx.ExecContext(ctx, `INSERT INTO device_list_devices(account_id, device_id, signing_key, added_version) VALUES(?, ?, ?, ?)`, accountID, entry.DeviceID, entry.SigningKey, int64(body.Version)); err != nil {
			return DeviceListResult{}, err
		}
	}
	eventID, err := insertSyncEvent(ctx, tx, DeviceListEventType, &accountID, "", map[string]uint64{"version": body.Version}, now)
	if err != nil {
		return DeviceListResult{}, err
	}
	return DeviceListResult{Version: body.Version, EventID: eventID}, nil
}

// deviceListHistoryTx loads every pair the chain ever listed, for the
// no-return and one-key-one-device rules.
func deviceListHistoryTx(ctx context.Context, q interface {
	QueryContext(context.Context, string, ...interface{}) (*sql.Rows, error)
}, accountID string) (devicelist.History, error) {
	rows, err := q.QueryContext(ctx, `SELECT device_id, signing_key FROM device_list_devices WHERE account_id = ?`, accountID)
	if err != nil {
		return devicelist.History{}, err
	}
	defer rows.Close()
	devices := map[string]bool{}
	keys := map[string]bool{}
	for rows.Next() {
		var deviceID string
		var key []byte
		if err := rows.Scan(&deviceID, &key); err != nil {
			return devicelist.History{}, err
		}
		devices[deviceID] = true
		keys[string(key)] = true
	}
	if err := rows.Err(); err != nil {
		return devicelist.History{}, err
	}
	return devicelist.History{
		SeenDevice: func(deviceID string) bool { return devices[deviceID] },
		SeenKey:    func(key []byte) bool { return keys[string(key)] },
	}, nil
}

func sameEntrySet(got, want []devicelist.Entry) bool {
	if len(got) != len(want) {
		return false
	}
	sorted := append([]devicelist.Entry(nil), want...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].DeviceID < sorted[j].DeviceID })
	for i := range got {
		if got[i].DeviceID != sorted[i].DeviceID || !bytes.Equal(got[i].SigningKey, sorted[i].SigningKey) {
			return false
		}
	}
	return true
}

func sameIDSet(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	a := append([]string(nil), got...)
	b := append([]string(nil), want...)
	sort.Strings(a)
	sort.Strings(b)
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// PublishDeviceList stores a version on POST /account/device-list: the
// migration genesis (change 6), a repair removal (change 3 of devices the
// server already revoked) or a recovery version (change 4). Each has its own
// rule; the route's recent-auth check for change 6 is the handler's.
func (s *Store) PublishDeviceList(ctx context.Context, accountID, deviceID string, raw []byte) (DeviceListResult, error) {
	// The rules below name the caller as the signer; an empty id would skip that
	// check, and every change kind this route takes is sent from a device.
	if deviceID == "" {
		return DeviceListResult{}, ErrForbidden
	}
	parsed, err := devicelist.Parse(raw)
	if err != nil {
		return DeviceListResult{}, ErrInvalidDeviceList
	}
	now := nowString()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return DeviceListResult{}, err
	}
	defer tx.Rollback()
	var rule DeviceListRule
	switch parsed.Body.Change {
	case devicelist.ChangeMigrationGenesis:
		// Only while the account has no list; checkStep refuses a genesis on
		// a head (the version is then not head + 1).
		rule = DeviceListRule{Changes: []devicelist.Change{devicelist.ChangeMigrationGenesis}, Signer: deviceID}
	case devicelist.ChangeRemove:
		rule = DeviceListRule{Changes: []devicelist.Change{devicelist.ChangeRemove}, Signer: deviceID, RemovedRevoked: true}
	case devicelist.ChangeRecovery:
		// Only from the device recovery completion enrolled, while it is the
		// account's one active device.
		var completed bool
		if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM account_recovery_requests WHERE account_id = ? AND device_id = ? AND state = 'completed')`, accountID, deviceID).Scan(&completed); err != nil {
			return DeviceListResult{}, err
		}
		var active int
		var activeID string
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*), COALESCE(MIN(id), '') FROM devices WHERE account_id = ? AND revoked_at IS NULL`, accountID).Scan(&active, &activeID); err != nil {
			return DeviceListResult{}, err
		}
		if !completed || active != 1 || activeID != deviceID {
			return DeviceListResult{}, ErrInvalidDeviceList
		}
		if len(parsed.Body.Entries) != 1 || parsed.Body.Entries[0].DeviceID != deviceID {
			return DeviceListResult{}, ErrInvalidDeviceList
		}
		rule = DeviceListRule{Changes: []devicelist.Change{devicelist.ChangeRecovery}}
	default:
		return DeviceListResult{}, ErrInvalidDeviceList
	}
	result, err := insertDeviceListTx(ctx, tx, accountID, raw, rule, now)
	if err != nil {
		return DeviceListResult{}, err
	}
	if err := tx.Commit(); err != nil {
		return DeviceListResult{}, err
	}
	return result, nil
}

// DeviceListStatement is one stored version as the read routes return it.
type DeviceListStatement struct {
	Version   uint64
	ListHash  []byte
	Statement []byte
	CreatedAt time.Time
}

// DeviceListPage is one account's answer: Found is false for an unknown
// account and for one the requester may not read, which look the same.
type DeviceListPage struct {
	AccountID   string
	Found       bool
	HeadVersion uint64
	Statements  []DeviceListStatement
	More        bool
}

// DeviceListQueryItem asks for the versions of one account after a version.
type DeviceListQueryItem struct {
	AccountID string
	After     uint64
}

// deviceListReadable reports whether requester may read the account's list:
// the account itself, or an account that shares a conversation with it. An
// unknown or deleted account is not readable.
func deviceListReadable(ctx context.Context, q rowQuerier, requesterID, accountID string) (bool, error) {
	var readable bool
	err := q.QueryRowContext(ctx, `
		SELECT EXISTS(SELECT 1 FROM accounts WHERE id = ?1 AND deleted_at IS NULL)
		   AND (?1 = ?2 OR EXISTS(
		        SELECT 1 FROM memberships a JOIN memberships b ON b.conversation_id = a.conversation_id
		        WHERE a.account_id = ?2 AND b.account_id = ?1 AND a.conversation_id IS NOT NULL))`,
		accountID, requesterID).Scan(&readable)
	return readable, err
}

func deviceListPageTx(ctx context.Context, tx *sql.Tx, requesterID string, item DeviceListQueryItem, limit int) (DeviceListPage, error) {
	page := DeviceListPage{AccountID: item.AccountID}
	readable, err := deviceListReadable(ctx, tx, requesterID, item.AccountID)
	if err != nil {
		return page, err
	}
	if !readable {
		return page, nil
	}
	page.Found = true
	var head sql.NullInt64
	if err := tx.QueryRowContext(ctx, `SELECT MAX(version) FROM device_list_versions WHERE account_id = ?`, item.AccountID).Scan(&head); err != nil {
		return page, err
	}
	if head.Valid {
		page.HeadVersion = uint64(head.Int64)
	}
	if limit <= 0 {
		page.More = page.HeadVersion > item.After
		return page, nil
	}
	rows, err := tx.QueryContext(ctx, `SELECT version, list_hash, statement, created_at FROM device_list_versions WHERE account_id = ? AND version > ? ORDER BY version LIMIT ?`,
		item.AccountID, int64(item.After), limit+1)
	if err != nil {
		return page, err
	}
	defer rows.Close()
	for rows.Next() {
		var version int64
		var statement DeviceListStatement
		var created string
		if err := rows.Scan(&version, &statement.ListHash, &statement.Statement, &created); err != nil {
			return page, err
		}
		if len(page.Statements) == limit {
			page.More = true
			break
		}
		statement.Version = uint64(version)
		statement.CreatedAt = parseTime(created)
		page.Statements = append(page.Statements, statement)
	}
	return page, rows.Err()
}

// DeviceListsAfter answers the batch read: one page per item in request
// order, at most DeviceListPageMax statements per item and
// DeviceListQueryStatementsMax in all (an item the budget does not reach has
// More set and no statements). It is one read snapshot.
func (s *Store) DeviceListsAfter(ctx context.Context, requesterID string, items []DeviceListQueryItem) ([]DeviceListPage, error) {
	if len(items) == 0 || len(items) > DeviceListQueryItemsMax {
		return nil, ErrInvalidInput
	}
	tx, err := s.db.reader.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	budget := DeviceListQueryStatementsMax
	pages := make([]DeviceListPage, 0, len(items))
	for _, item := range items {
		limit := DeviceListPageMax
		if budget < limit {
			limit = budget
		}
		page, err := deviceListPageTx(ctx, tx, requesterID, item, limit)
		if err != nil {
			return nil, err
		}
		budget -= len(page.Statements)
		pages = append(pages, page)
	}
	return pages, nil
}

// deviceOnHeadSQL is the honest-server gate as a SQL condition: the device is
// on the head of its account's list, or the account has no list (an account
// from before L1 stays as it was). A device an L1 account's list does not name
// is never offered in pending changes, claimed, or added by a commit bundle.
// Clients do not rely on this; it keeps an honest server from handing out a
// device that no signed version approved. accountColumn and deviceColumn are
// SQL text for columns, never values.
func deviceOnHeadSQL(accountColumn, deviceColumn string) string {
	return `(NOT EXISTS (SELECT 1 FROM device_list_versions dlv WHERE dlv.account_id = ` + accountColumn + `)
		OR EXISTS (SELECT 1 FROM device_list_devices dld WHERE dld.account_id = ` + accountColumn + ` AND dld.device_id = ` + deviceColumn + ` AND dld.removed_version IS NULL))`
}

// DeviceListBlocksRecovery reports whether the account has a list whose head
// names no recovery key. Recovery claims against it are refused: the device
// recovery enrolls could not sign the version that replaces the lost ones.
// An account with no list is not blocked (it predates L1).
func (s *Store) DeviceListBlocksRecovery(ctx context.Context, accountID string) (bool, error) {
	hasHead, recoveryKey, err := s.deviceListHeadRecoveryKey(ctx, s.db.reader, accountID)
	if err != nil {
		return false, err
	}
	return hasHead && recoveryKey == nil, nil
}

// deviceListHeadRecoveryKey reports whether the account has a head and the
// recovery key that head names, nil when it names none.
func (s *Store) deviceListHeadRecoveryKey(ctx context.Context, q rowQuerier, accountID string) (hasHead bool, recoveryKey []byte, err error) {
	head, err := deviceListHeadTx(ctx, q, accountID)
	if err != nil || head == nil {
		return false, nil, err
	}
	return true, head.statement.Body.RecoveryKey, nil
}
