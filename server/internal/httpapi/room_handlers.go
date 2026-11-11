package httpapi

import (
	"errors"
	"io"
	"net/http"
	"strconv"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
	"private-messenger/server/internal/webrtc"
)

// B6 group calls and voice rooms (docs/designs/B6-group-calls.md). The server
// hands out the room, orders the call group's commits (one per epoch) and
// mints SFU join tokens. It never sees media, keys or the real roster: the
// participants list here is the server's view, and the app shows the call
// group's MLS membership instead.

const roomTokenTTL = 5 * time.Minute

func (a *API) roomsUnavailable(w http.ResponseWriter) bool {
	if a.RoomMedia == nil {
		writeError(w, http.StatusServiceUnavailable, "rooms_unavailable")
		return true
	}
	return false
}

func (a *API) publishRoomUpdate(r *http.Request, conversationID string, room storage.Room, live int) {
	members := a.conversationMemberIDs(r.Context(), conversationID)
	if len(members) == 0 {
		return
	}
	a.Hub.Publish(members, realtime.Event{Version: "v1", Type: "room.updated", ConversationID: conversationID,
		Payload:   map[string]any{"call_id": room.ID, "epoch": room.Epoch, "participants": live, "ended": room.EndedAt != nil},
		CreatedAt: time.Now().UTC()})
}

func (a *API) roomErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, storage.ErrRoomFull):
		writeError(w, http.StatusConflict, "room_full")
	case errors.Is(err, storage.ErrRoomEnded):
		writeError(w, http.StatusGone, "room_ended")
	case errors.Is(err, storage.ErrRoomNotLive):
		writeError(w, http.StatusForbidden, "not_in_room")
	case errors.Is(err, storage.ErrRoomEpochCAS):
		writeError(w, http.StatusConflict, "room_epoch_conflict")
	default:
		handleStorageError(w, err)
	}
}

func (a *API) joinRoom(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if a.roomsUnavailable(w) {
		return
	}
	var req struct {
		ConversationID string `json:"conversation_id"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.ConversationID == "" || len(req.ConversationID) > 128 {
		writeError(w, http.StatusBadRequest, "invalid_conversation")
		return
	}
	now := time.Now().UTC()
	join, err := a.Store.JoinRoom(r.Context(), req.ConversationID, principal.AccountID, principal.DeviceID, now)
	if err != nil {
		a.roomErr(w, err)
		return
	}
	token, err := a.RoomMedia.JoinToken(join.Room.SFURoom, join.Identity, now, roomTokenTTL)
	if err != nil {
		a.warn("room_token_failed", "err", err)
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	a.publishRoomUpdate(r, req.ConversationID, join.Room, len(join.Participants))
	nonce, err := domain.NewID("n")
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"call_id": join.Room.ID, "conversation_id": join.Room.ConversationID,
		"epoch": join.Room.Epoch, "created": join.Created,
		"participants": join.Participants,
		"sfu_url":      a.RoomMedia.URL(), "sfu_token": token, "token_expires_at": now.Add(roomTokenTTL),
		"nonce": nonce, "nonce_expires_at": now.Add(60 * time.Second),
		"max_devices": storage.RoomMaxDevices,
	})
}

func (a *API) roomState(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	room, participants, err := a.Store.RoomState(r.Context(), r.PathValue("id"), principal.DeviceID)
	if err != nil {
		a.roomErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"call_id": room.ID, "conversation_id": room.ConversationID, "epoch": room.Epoch, "participants": participants})
}

func (a *API) roomCommits(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	commits, err := a.Store.RoomCommits(r.Context(), r.PathValue("id"), principal.DeviceID, after)
	if err != nil {
		a.roomErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"commits": commits})
}

// roomCommit takes one call-group commit (and its Welcome) if it is based on
// the current epoch; everything else is a 409 and the caller discards its
// staged commit.
func (a *API) roomCommit(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		ExpectedEpoch int64  `json:"expected_epoch"`
		Commit        []byte `json:"commit"`
		Welcome       []byte `json:"welcome,omitempty"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	id := r.PathValue("id")
	epoch, err := a.Store.CommitRoom(r.Context(), id, principal.DeviceID, req.ExpectedEpoch, req.Commit, req.Welcome, time.Now().UTC())
	if err != nil {
		a.roomErr(w, err)
		return
	}
	if conversationID, err := a.Store.RoomConversation(r.Context(), id); err == nil {
		a.publishRoomUpdate(r, conversationID, storage.Room{ID: id, Epoch: epoch}, -1)
	}
	writeJSON(w, http.StatusOK, map[string]any{"epoch": epoch})
}

func (a *API) leaveRoom(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	id := r.PathValue("id")
	conversationID, err := a.Store.RoomConversation(r.Context(), id)
	if err != nil {
		a.roomErr(w, err)
		return
	}
	ended, err := a.Store.LeaveRoom(r.Context(), id, principal.DeviceID, time.Now().UTC())
	if err != nil {
		a.roomErr(w, err)
		return
	}
	room := storage.Room{ID: id}
	if ended {
		t := time.Now().UTC()
		room.EndedAt = &t
	}
	a.publishRoomUpdate(r, conversationID, room, -1)
	writeJSON(w, http.StatusOK, map[string]any{"ended": ended})
}

// roomWebhook takes the SFU's signed presence events. A forged or replayed
// one is refused; a false "gone" can only cut someone off, never add anyone.
func (a *API) roomWebhook(w http.ResponseWriter, r *http.Request) {
	if a.RoomMedia == nil {
		writeError(w, http.StatusServiceUnavailable, "rooms_unavailable")
		return
	}
	defer r.Body.Close()
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64<<10))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body")
		return
	}
	event, err := a.RoomMedia.ParseWebhook(r.Header.Get("Authorization"), body, time.Now().UTC())
	if err != nil {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	now := time.Now().UTC()
	switch event.Kind {
	case "participant_left":
		err = a.Store.RoomParticipantGone(r.Context(), event.Room, event.Identity, now)
	case "room_finished":
		err = a.Store.RoomFinished(r.Context(), event.Room, now)
	}
	if err != nil {
		a.warn("room_webhook_failed", "err", err)
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

var _ webrtc.RoomMedia = webrtc.LiveKit{}
