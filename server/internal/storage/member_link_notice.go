package storage

import (
	"context"
	"database/sql"
)

// MemberLinkEventType is the sync event that tells the coordinator of a group
// that a co-member has a new device to add: one a link approval created, or
// the one a K0-R recovery enrolled, once its change-4 device-list version
// lands. It carries IDs only (the new device and its account) and names no
// conversation: the coordinator learns nothing it does not already read from
// the pending-change list and the account's device list, and its client
// simply runs a membership pass. The two cases look the same.
const MemberLinkEventType = "device.member_linked"

// maxMemberLinkNotices bounds the accounts told by one link. A coordinator
// past the bound still adds the device after the client fallback.
const maxMemberLinkNotices = 64

// MemberLinkNotice is one durable MemberLinkEventType event, addressed to the
// account whose device coordinates a group the linking account is in.
type MemberLinkNotice struct {
	AccountID string
	EventID   int64
	DeviceID  string
	// LinkedAccountID is the account that linked the device.
	LinkedAccountID string
}

// insertMemberLinkNotices records, in the link's (or the recovery version's)
// own transaction, one event for each other account whose device is the
// coordinator (lowest live MLS device id, as in ListMLSPendingChangesRead) of
// an MLS group the linking account belongs to. The linking account's own
// devices already get device.updated or device_list.updated.
func insertMemberLinkNotices(ctx context.Context, tx *sql.Tx, accountID, deviceID, now string) ([]MemberLinkNotice, error) {
	rows, err := tx.QueryContext(ctx, `
		SELECT DISTINCT cd.account_id
		FROM memberships m
		JOIN conversation_mls_groups g ON g.conversation_id = m.conversation_id
		JOIN devices cd ON cd.id = (
			SELECT MIN(r.device_id) FROM conversation_mls_devices r
			JOIN devices d ON d.id = r.device_id AND d.revoked_at IS NULL
			JOIN memberships mm ON mm.conversation_id = r.conversation_id AND mm.account_id = r.account_id
			WHERE r.conversation_id = g.conversation_id AND r.removed_after_event_id IS NULL)
		WHERE m.account_id = ?1 AND cd.account_id <> ?1
		ORDER BY cd.account_id
		LIMIT ?2`, accountID, maxMemberLinkNotices)
	if err != nil {
		return nil, err
	}
	var accounts []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		accounts = append(accounts, id)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	rows.Close()
	notices := make([]MemberLinkNotice, 0, len(accounts))
	for _, id := range accounts {
		coordinator := id
		eventID, err := insertSyncEvent(ctx, tx, MemberLinkEventType, &coordinator, "",
			map[string]string{"account_id": accountID, "device_id": deviceID}, now)
		if err != nil {
			return nil, err
		}
		notices = append(notices, MemberLinkNotice{AccountID: id, EventID: eventID, DeviceID: deviceID, LinkedAccountID: accountID})
	}
	return notices, nil
}
