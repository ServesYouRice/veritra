package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"private-messenger/server/internal/domain"
)

// Scoped sync reads (C1 prerequisite, docs/designs/C1-sync-isolation.md).
// They are read-only and no client uses them yet: the legacy global
// ListSyncEvents is unchanged. Each stream has its own cursor, so a failure
// in one conversation never has to hold back another.
//
// Visibility reuses the legacy predicate (syncEventVisibleTo), so the scoped
// reads cannot disagree with the global one about what a device may see.

// ListAccountSyncEvents returns the account's own events that name no
// conversation, for this device or every device, after afterID. Account
// events that carry a conversation ID (a Welcome) belong to that
// conversation's stream, not here.
func (s *Store) ListAccountSyncEvents(ctx context.Context, accountID, deviceID string, afterID int64, limit int) ([]domain.SyncEvent, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `SELECT se.id, se.event_type, se.account_id, se.conversation_id, se.payload_json, se.created_at
		FROM sync_events se
		WHERE se.account_id = ?1 AND se.conversation_id IS NULL AND se.id > ?2
		  AND (se.device_id IS NULL OR se.device_id = ?3)
		ORDER BY se.id ASC LIMIT ?4`, accountID, afterID, deviceID, limit)
	if err != nil {
		return nil, err
	}
	events, err := scanSyncEventRows(rows)
	if err != nil {
		return nil, err
	}
	if afterID > 0 {
		expired, err := s.scopedSyncCursorExpired(ctx, accountID, deviceID, "", afterID)
		if err != nil {
			return nil, err
		}
		if expired {
			return nil, ErrSyncCursorExpired
		}
	}
	return events, nil
}

// ListConversationSyncEvents returns one conversation's events after afterID
// that the device may see: shared events under the legacy visibility rules
// and the account's own events for this conversation (the Welcome). It
// returns ErrForbidden for a non-member and ErrSyncCursorExpired when
// retention pruned an event of this scope the device could have been sent.
func (s *Store) ListConversationSyncEvents(ctx context.Context, accountID, deviceID, conversationID string, afterID int64, limit int) ([]domain.SyncEvent, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil {
		return nil, err
	}
	if !member {
		return nil, ErrForbidden
	}
	// Hidden events do not count towards the page, as in the legacy merge,
	// so the query has no LIMIT and the loop stops after limit visible rows.
	rows, err := s.db.QueryContext(ctx, `SELECT CASE WHEN se.account_id IS NOT NULL THEN 1 ELSE (`+syncEventVisibleTo+`) END,
		se.id, se.event_type, se.account_id, se.conversation_id,
		CASE WHEN se.account_id IS NOT NULL OR (`+syncEventVisibleTo+`) THEN se.payload_json ELSE '' END, se.created_at
		FROM sync_events se
		WHERE se.conversation_id = ?4 AND se.id > ?2
		  AND (+se.account_id IS NULL OR (se.account_id = ?1 AND (se.device_id IS NULL OR se.device_id = ?3)))
		ORDER BY se.id ASC`, accountID, afterID, deviceID, conversationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var events []domain.SyncEvent
	candidate := &syncCandidateScanner{rows: rows}
	last := afterID
	for len(events) < limit && rows.Next() {
		event, err := scanSyncEvent(candidate)
		if err != nil {
			return nil, err
		}
		if event.ID <= last {
			return nil, fmt.Errorf("scoped sync emitted event %d after %d", event.ID, last)
		}
		last = event.ID
		if candidate.visible {
			events = append(events, event)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	if afterID > 0 {
		expired, err := s.scopedSyncCursorExpired(ctx, accountID, deviceID, conversationID, afterID)
		if err != nil {
			return nil, err
		}
		if expired {
			return nil, ErrSyncCursorExpired
		}
	}
	return events, nil
}

func scanSyncEventRows(rows *sql.Rows) ([]domain.SyncEvent, error) {
	defer rows.Close()
	var events []domain.SyncEvent
	for rows.Next() {
		event, err := scanSyncEvent(rows)
		if err != nil {
			return nil, err
		}
		events = append(events, event)
	}
	return events, rows.Err()
}

// scopedSyncCursorExpired is syncCursorExpired narrowed to one scope: the
// account scope (conversationID "") counts only the account's prune marks;
// a conversation scope counts that conversation's marks, worded as in
// syncPruneMarksExpiredQuery, plus the account marks, because those marks
// do not say which conversation a pruned Welcome belonged to (conservative:
// it can pause a conversation, never skip a gap). A cursor below the legacy
// watermark, from before the marks existed, uses the legacy global test.
func (s *Store) scopedSyncCursorExpired(ctx context.Context, accountID, deviceID, conversationID string, afterID int64) (bool, error) {
	var legacyThrough, prunedThrough int64
	err := s.db.QueryRowContext(ctx, `SELECT legacy_through, pruned_through FROM sync_prune_state WHERE id = 1`).Scan(&legacyThrough, &prunedThrough)
	known := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return false, err
	}
	if known && afterID >= prunedThrough {
		return false, nil
	}
	var expired bool
	if err := s.db.QueryRowContext(ctx, `SELECT EXISTS (
		  SELECT 1 FROM sync_prune_account_marks
		  WHERE account_id = ?1 AND device_id IN ('', ?3) AND pruned_through > ?2
		) OR EXISTS (
		  SELECT 1 FROM sync_prune_conversation_marks k
		  WHERE ?4 <> '' AND k.conversation_id = ?4 AND k.pruned_through > ?2
		    AND (k.roster_filtered = 0
		      OR NOT EXISTS (SELECT 1 FROM conversation_mls_groups jg WHERE jg.conversation_id = k.conversation_id)
		      OR EXISTS (SELECT 1 FROM conversation_mls_devices jd
		        WHERE jd.conversation_id = k.conversation_id AND jd.device_id = ?3
		          AND k.pruned_through > jd.joined_after_event_id
		          AND (jd.removed_after_event_id IS NULL
		            OR (jd.removed_after_event_id > ?2 AND jd.removed_after_event_id > jd.joined_after_event_id))))
		)`, accountID, afterID, deviceID, conversationID).Scan(&expired); err != nil {
		return false, err
	}
	if expired || (known && afterID >= legacyThrough) {
		return expired, nil
	}
	if err := s.db.QueryRowContext(ctx, legacySyncCursorExpiredQuery, accountID, afterID).Scan(&expired); err != nil {
		return false, err
	}
	return expired, nil
}
