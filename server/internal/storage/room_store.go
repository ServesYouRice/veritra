package storage

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"time"

	"private-messenger/server/internal/domain"
)

// B6 (docs/designs/B6-group-calls.md): rooms for group calls and voice rooms.
var (
	ErrRoomFull     = errors.New("room has the maximum number of devices")
	ErrRoomEnded    = errors.New("room has ended")
	ErrRoomNotLive  = errors.New("device is not in the room")
	ErrRoomEpochCAS = errors.New("room commit is not based on the current epoch")
)

const (
	// RoomMaxDevices is the voice-only cap (O3); clients enforce the lower
	// video cap.
	RoomMaxDevices = 50
	// RoomEndedRetention is how long an ended room's row stays.
	RoomEndedRetention = time.Hour
	// RoomMaxCommitBytes caps one commit or Welcome.
	RoomMaxCommitBytes = 96 << 10
	// RoomOfferWindow is how long a join nonce lives (design: at most 60 s).
	RoomOfferWindow = 60 * time.Second
)

type Room struct {
	ID             string     `json:"call_id"`
	ConversationID string     `json:"conversation_id"`
	SFURoom        string     `json:"-"`
	GroupID        []byte     `json:"group_id"`
	Epoch          int64      `json:"epoch"`
	CreatedAt      time.Time  `json:"created_at"`
	EndedAt        *time.Time `json:"ended_at,omitempty"`
}

type RoomParticipant struct {
	DeviceID  string    `json:"device_id"`
	AccountID string    `json:"account_id"`
	JoinedAt  time.Time `json:"joined_at"`
	// Offer fields are set while the device waits to be added to the call
	// group (B6 S5); members check the signature, the server does not.
	OfferKeyPackage []byte `json:"offer_key_package,omitempty"`
	OfferSignature  []byte `json:"offer_signature,omitempty"`
	OfferExpiresAt  int64  `json:"offer_expires_at,omitempty"`
	// OfferNonce is the join nonce the signature binds (only with an offer).
	OfferNonce string `json:"offer_nonce,omitempty"`
	InGroup    bool   `json:"in_group"`
}

type RoomJoin struct {
	Room         Room
	Identity     string
	Nonce        string
	NonceExpires time.Time
	Created      bool
	Participants []RoomParticipant
}

type RoomCommit struct {
	Epoch             int64     `json:"epoch"`
	CommitterDeviceID string    `json:"committer_device_id"`
	Commit            []byte    `json:"commit"`
	Welcome           []byte    `json:"welcome,omitempty"`
	CreatedAt         time.Time `json:"created_at"`
}

// JoinRoom puts the device into the live room of the conversation, creating
// the room if there is none. The account must be a member who may post there
// (O8: the same C2, C4 and C5 rules as a message). Joining twice with the
// same device replaces the old seat with a fresh identity.
func (s *Store) JoinRoom(ctx context.Context, conversationID, accountID, deviceID string, now time.Time) (RoomJoin, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return RoomJoin{}, err
	}
	defer tx.Rollback()
	var role string
	if err := tx.QueryRowContext(ctx, `SELECT m.role FROM memberships m JOIN accounts a ON a.id = m.account_id AND a.status = 'active' AND a.deleted_at IS NULL WHERE m.conversation_id = ? AND m.account_id = ?`, conversationID, accountID).Scan(&role); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return RoomJoin{}, ErrNotMember
		}
		return RoomJoin{}, err
	}
	var restricted bool
	var channelID sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT c.posting_policy = 'admins' OR COALESCE(ch.kind = 'announcement', 0), c.channel_id FROM conversations c LEFT JOIN channels ch ON ch.id = c.channel_id WHERE c.id = ?`, conversationID).Scan(&restricted, &channelID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return RoomJoin{}, ErrNotFound
		}
		return RoomJoin{}, err
	}
	if restricted && !domain.CanPostRestricted(role) {
		return RoomJoin{}, ErrPostingRestricted
	}
	if err := checkNotTimedOutTx(ctx, tx, conversationID, accountID, now); err != nil {
		return RoomJoin{}, err
	}
	room, err := scanRoom(tx.QueryRowContext(ctx, `SELECT id, conversation_id, sfu_room, group_id, epoch, created_at, ended_at FROM call_rooms WHERE conversation_id = ? AND ended_at IS NULL`, conversationID))
	created := false
	switch {
	case errors.Is(err, sql.ErrNoRows):
		id, idErr := domain.NewID("room")
		if idErr != nil {
			return RoomJoin{}, idErr
		}
		sfu, idErr := domain.NewID("sfu")
		if idErr != nil {
			return RoomJoin{}, idErr
		}
		groupID := make([]byte, 32)
		if _, err := rand.Read(groupID); err != nil {
			return RoomJoin{}, err
		}
		room = Room{ID: id, ConversationID: conversationID, SFURoom: sfu, GroupID: groupID, CreatedAt: now.UTC()}
		if _, err := tx.ExecContext(ctx, `INSERT INTO call_rooms(id, conversation_id, sfu_room, group_id, epoch, created_at) VALUES(?, ?, ?, ?, 0, ?)`, room.ID, conversationID, sfu, groupID, formatTime(now)); err != nil {
			return RoomJoin{}, err
		}
		created = true
	case err != nil:
		return RoomJoin{}, err
	}
	var live, mine int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*), COALESCE(SUM(device_id = ?), 0) FROM call_room_participants WHERE room_id = ? AND left_at IS NULL`, deviceID, room.ID).Scan(&live, &mine); err != nil {
		return RoomJoin{}, err
	}
	if mine == 0 && live >= RoomMaxDevices {
		return RoomJoin{}, ErrRoomFull
	}
	if mine > 0 {
		if _, err := tx.ExecContext(ctx, `UPDATE call_room_participants SET left_at = ? WHERE room_id = ? AND device_id = ? AND left_at IS NULL`, formatTime(now), room.ID, deviceID); err != nil {
			return RoomJoin{}, err
		}
	}
	identity, err := domain.NewID("p")
	if err != nil {
		return RoomJoin{}, err
	}
	nonceID, err := domain.NewID("n")
	if err != nil {
		return RoomJoin{}, err
	}
	nonceExpires := now.Add(RoomOfferWindow)
	// The creator of a room is the call group's first member.
	if _, err := tx.ExecContext(ctx, `INSERT INTO call_room_participants(room_id, identity, device_id, account_id, joined_at, nonce, nonce_expires_at, in_group) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`, room.ID, identity, deviceID, accountID, formatTime(now), nonceID, formatTime(nonceExpires), created); err != nil {
		return RoomJoin{}, err
	}
	participants, err := roomParticipants(ctx, tx, room.ID)
	if err != nil {
		return RoomJoin{}, err
	}
	if err := tx.Commit(); err != nil {
		return RoomJoin{}, err
	}
	return RoomJoin{Room: room, Identity: identity, Nonce: nonceID, NonceExpires: nonceExpires, Created: created, Participants: participants}, nil
}

// RoomState returns the room and its live devices to a device that is in it.
func (s *Store) RoomState(ctx context.Context, roomID, deviceID string) (Room, []RoomParticipant, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Room{}, nil, err
	}
	defer tx.Rollback()
	room, err := liveRoomForDevice(ctx, tx, roomID, deviceID)
	if err != nil {
		return Room{}, nil, err
	}
	participants, err := roomParticipants(ctx, tx, roomID)
	return room, participants, err
}

// CommitRoom stores one commit (and the Welcome that goes with it) if it is
// based on the room's current epoch. Exactly one commit per epoch wins;
// every other gets ErrRoomEpochCAS (409). The bytes are opaque.
func (s *Store) CommitRoom(ctx context.Context, roomID, deviceID string, expectedEpoch int64, commit, welcome []byte, added []string, now time.Time) (int64, error) {
	if len(commit) == 0 || len(commit) > RoomMaxCommitBytes || len(welcome) > RoomMaxCommitBytes || expectedEpoch < 0 {
		return 0, ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	if _, err := liveRoomForDevice(ctx, tx, roomID, deviceID); err != nil {
		return 0, err
	}
	res, err := tx.ExecContext(ctx, `UPDATE call_rooms SET epoch = epoch + 1 WHERE id = ? AND epoch = ? AND ended_at IS NULL`, roomID, expectedEpoch)
	if err != nil {
		return 0, err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return 0, ErrRoomEpochCAS
	}
	next := expectedEpoch + 1
	var w any
	if len(welcome) > 0 {
		w = welcome
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO call_room_commits(room_id, epoch, committer_device_id, commit_bytes, welcome_bytes, created_at) VALUES(?, ?, ?, ?, ?, ?)`, roomID, next, deviceID, commit, w, formatTime(now)); err != nil {
		return 0, err
	}
	// Bookkeeping only: the devices this commit added no longer wait. The
	// members decide who is really in the group from the commit itself.
	for _, id := range added {
		if _, err := tx.ExecContext(ctx, `UPDATE call_room_participants SET in_group = 1 WHERE room_id = ? AND device_id = ? AND left_at IS NULL`, roomID, id); err != nil {
			return 0, err
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return next, nil
}

// RoomCommits lists the commits that produced epochs above `after`.
func (s *Store) RoomCommits(ctx context.Context, roomID, deviceID string, after int64) ([]RoomCommit, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err := liveRoomForDevice(ctx, tx, roomID, deviceID); err != nil {
		return nil, err
	}
	rows, err := tx.QueryContext(ctx, `SELECT epoch, committer_device_id, commit_bytes, welcome_bytes, created_at FROM call_room_commits WHERE room_id = ? AND epoch > ? ORDER BY epoch LIMIT 200`, roomID, after)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []RoomCommit{}
	for rows.Next() {
		var c RoomCommit
		var created string
		if err := rows.Scan(&c.Epoch, &c.CommitterDeviceID, &c.Commit, &c.Welcome, &created); err != nil {
			return nil, err
		}
		c.CreatedAt = parseTime(created)
		out = append(out, c)
	}
	return out, rows.Err()
}

// LeaveRoom marks the device gone and ends the room when it was the last.
func (s *Store) LeaveRoom(ctx context.Context, roomID, deviceID string, now time.Time) (bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx, `UPDATE call_room_participants SET left_at = ? WHERE room_id = ? AND device_id = ? AND left_at IS NULL`, formatTime(now), roomID, deviceID)
	if err != nil {
		return false, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return false, ErrRoomNotLive
	}
	ended, err := endRoomIfEmpty(ctx, tx, roomID, now)
	if err != nil {
		return false, err
	}
	return ended, tx.Commit()
}

// RoomParticipantGone is the SFU webhook's effect: the participant with this
// identity in this SFU room has dropped. Unknown names are ignored.
func (s *Store) RoomParticipantGone(ctx context.Context, sfuRoom, identity string, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var roomID string
	if err := tx.QueryRowContext(ctx, `SELECT r.id FROM call_rooms r JOIN call_room_participants p ON p.room_id = r.id WHERE r.sfu_room = ? AND p.identity = ? AND p.left_at IS NULL AND r.ended_at IS NULL`, sfuRoom, identity).Scan(&roomID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE call_room_participants SET left_at = ? WHERE room_id = ? AND identity = ?`, formatTime(now), roomID, identity); err != nil {
		return err
	}
	if _, err := endRoomIfEmpty(ctx, tx, roomID, now); err != nil {
		return err
	}
	return tx.Commit()
}

// RoomFinished is the SFU webhook's room_finished: everyone is gone.
func (s *Store) RoomFinished(ctx context.Context, sfuRoom string, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `UPDATE call_room_participants SET left_at = ? WHERE left_at IS NULL AND room_id IN (SELECT id FROM call_rooms WHERE sfu_room = ? AND ended_at IS NULL)`, formatTime(now), sfuRoom); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE call_rooms SET ended_at = ? WHERE sfu_room = ? AND ended_at IS NULL`, formatTime(now), sfuRoom); err != nil {
		return err
	}
	return tx.Commit()
}

// RoomConversation names the conversation of a room (for notices).
func (s *Store) RoomConversation(ctx context.Context, roomID string) (string, error) {
	var id string
	err := s.db.QueryRowContext(ctx, `SELECT conversation_id FROM call_rooms WHERE id = ?`, roomID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return id, err
}

// PruneRooms ends a seat older than maxAge (a crashed client the SFU never
// reported), ends rooms nobody is in, and deletes rooms ended more than
// RoomEndedRetention ago, with their commits.
func (s *Store) PruneRooms(ctx context.Context, now time.Time, maxAge time.Duration) (int64, error) {
	if _, err := s.db.ExecContext(ctx, `UPDATE call_room_participants SET left_at = ? WHERE left_at IS NULL AND joined_at < ?`, formatTime(now), formatTime(now.Add(-maxAge))); err != nil {
		return 0, err
	}
	if _, err := s.db.ExecContext(ctx, `UPDATE call_rooms SET ended_at = ? WHERE ended_at IS NULL AND NOT EXISTS (SELECT 1 FROM call_room_participants p WHERE p.room_id = call_rooms.id AND p.left_at IS NULL)`, formatTime(now)); err != nil {
		return 0, err
	}
	res, err := s.db.ExecContext(ctx, `DELETE FROM call_rooms WHERE ended_at IS NOT NULL AND ended_at < ?`, formatTime(now.Add(-RoomEndedRetention)))
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func endRoomIfEmpty(ctx context.Context, tx *sql.Tx, roomID string, now time.Time) (bool, error) {
	var live int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM call_room_participants WHERE room_id = ? AND left_at IS NULL`, roomID).Scan(&live); err != nil {
		return false, err
	}
	if live > 0 {
		return false, nil
	}
	if _, err := tx.ExecContext(ctx, `UPDATE call_rooms SET ended_at = ? WHERE id = ? AND ended_at IS NULL`, formatTime(now), roomID); err != nil {
		return false, err
	}
	return true, nil
}

func liveRoomForDevice(ctx context.Context, tx *sql.Tx, roomID, deviceID string) (Room, error) {
	room, err := scanRoom(tx.QueryRowContext(ctx, `SELECT id, conversation_id, sfu_room, group_id, epoch, created_at, ended_at FROM call_rooms WHERE id = ?`, roomID))
	if errors.Is(err, sql.ErrNoRows) {
		return Room{}, ErrNotFound
	}
	if err != nil {
		return Room{}, err
	}
	if room.EndedAt != nil {
		return Room{}, ErrRoomEnded
	}
	var n int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM call_room_participants WHERE room_id = ? AND device_id = ? AND left_at IS NULL`, roomID, deviceID).Scan(&n); err != nil {
		return Room{}, err
	}
	if n == 0 {
		return Room{}, ErrRoomNotLive
	}
	return room, nil
}

func roomParticipants(ctx context.Context, tx *sql.Tx, roomID string) ([]RoomParticipant, error) {
	rows, err := tx.QueryContext(ctx, `SELECT device_id, account_id, joined_at, offer_key_package, offer_signature, COALESCE(offer_expires_at, 0), CASE WHEN offer_key_package IS NULL THEN '' ELSE nonce END, in_group FROM call_room_participants WHERE room_id = ? AND left_at IS NULL ORDER BY joined_at, identity`, roomID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []RoomParticipant{}
	for rows.Next() {
		var p RoomParticipant
		var joined string
		if err := rows.Scan(&p.DeviceID, &p.AccountID, &joined, &p.OfferKeyPackage, &p.OfferSignature, &p.OfferExpiresAt, &p.OfferNonce, &p.InGroup); err != nil {
			return nil, err
		}
		p.JoinedAt = parseTime(joined)
		out = append(out, p)
	}
	return out, rows.Err()
}

func scanRoom(row *sql.Row) (Room, error) {
	var r Room
	var created string
	var ended sql.NullString
	if err := row.Scan(&r.ID, &r.ConversationID, &r.SFURoom, &r.GroupID, &r.Epoch, &created, &ended); err != nil {
		return Room{}, err
	}
	r.CreatedAt = parseTime(created)
	if ended.Valid {
		t := parseTime(ended.String)
		r.EndedAt = &t
	}
	return r, nil
}

// SetRoomOffer stores the join offer of a device that waits to be added:
// the call-only KeyPackage and the signature over it. The nonce must be the
// one the join route issued, unexpired and unused. The server cannot check
// the signature (it holds no keys of the call group); every member does.
func (s *Store) SetRoomOffer(ctx context.Context, roomID, deviceID, nonce string, keyPackage, signature []byte, expiresAt int64, now time.Time) error {
	if nonce == "" || len(keyPackage) == 0 || len(keyPackage) > 48<<10 || len(signature) != 64 || expiresAt <= now.Unix() || expiresAt > now.Add(2*RoomOfferWindow).Unix() {
		return ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := liveRoomForDevice(ctx, tx, roomID, deviceID); err != nil {
		return err
	}
	res, err := tx.ExecContext(ctx, `UPDATE call_room_participants SET offer_key_package = ?, offer_signature = ?, offer_expires_at = ? WHERE room_id = ? AND device_id = ? AND left_at IS NULL AND in_group = 0 AND offer_key_package IS NULL AND nonce = ? AND nonce_expires_at > ?`, keyPackage, signature, expiresAt, roomID, deviceID, nonce, formatTime(now))
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return ErrInvalidInput
	}
	return tx.Commit()
}
