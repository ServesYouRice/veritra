package httpapi_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/realtime"
)

// C7 targeted history_sync (owner answer Q3), end to end over HTTP: the
// server numbers a newcomer's join epoch as the client names it, a
// history_sync for that epoch reaches only the newcomer and its sender (in
// sync and live, the live frame without ciphertext or body), a member can
// ask whether one was delivered, a second one is refused until the
// newcomer's request reopens the epoch, and a request names only its
// sender's own join epoch.
func TestC7HistorySyncGoesToTheNewcomersOnly(t *testing.T) {
	application, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, func(c *config.Config) {
		c.CommunityLayout = true
		c.C7History = true
	})
	ownerID := accountIDFromExport(t, handler, ownerToken)
	carolToken, carolID := registerMemberWithID(t, handler, ownerToken, "carol")
	daveToken, daveID := registerMemberWithID(t, handler, ownerToken, "dave")
	status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]interface{}{})
	if status != http.StatusCreated {
		t.Fatalf("create community status=%d body=%s", status, body)
	}
	var community struct {
		ID                   string `json:"id"`
		SharedConversationID string `json:"shared_conversation_id"`
	}
	decodeLayoutBody(t, body, &community)
	shared := community.SharedConversationID
	for _, id := range []string{carolID, daveID} {
		if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/members", ownerToken, map[string]interface{}{"account_id": id, "role": "member"}); status != http.StatusOK {
			t.Fatalf("add community member status=%d body=%s", status, body)
		}
	}
	carolDevice, daveDevice := firstDeviceID(t, handler, carolToken), firstDeviceID(t, handler, daveToken)
	commits := "/api/v1/conversations/" + shared + "/mls/commits"
	if status, body := doJSON(t, handler, http.MethodPost, commits, ownerToken, map[string]interface{}{"epoch": 0, "idempotency_key": "genesis"}); status != http.StatusCreated {
		t.Fatalf("genesis status=%d body=%s", status, body)
	}
	// Carol joins at epoch 1, Dave at epoch 2: what MLS reports as the new
	// epoch of each commit, and what each Welcome puts the newcomer in.
	for epoch, added := range []struct{ account, device string }{{carolID, carolDevice}, {daveID, daveDevice}} {
		if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+shared+"/key-packages/claim", ownerToken,
			map[string]interface{}{"device_ids": []string{added.device}}); status != http.StatusOK {
			t.Fatalf("claim status=%d body=%s", status, body)
		}
		if status, body := doJSON(t, handler, http.MethodPost, commits, ownerToken, map[string]interface{}{
			"epoch": epoch, "idempotency_key": "add-" + added.device,
			"commit":  base64.StdEncoding.EncodeToString([]byte("commit-" + added.device)),
			"welcome": base64.StdEncoding.EncodeToString([]byte("welcome-" + added.device)),
			"added":   []map[string]string{{"account_id": added.account, "device_id": added.device}},
		}); status != http.StatusCreated {
			t.Fatalf("add commit status=%d body=%s", status, body)
		}
	}
	clients := map[string]*realtime.Client{}
	for id, ip := range map[string]string{ownerID: "10.0.0.1", carolID: "10.0.0.2", daveID: "10.0.0.3"} {
		client, err := application.Hub.Register(id, "dev-"+id, ip)
		if err != nil {
			t.Fatalf("register realtime client: %v", err)
		}
		t.Cleanup(client.Close)
		clients[id] = client
	}
	// A one-channel history_sync and a request, as the app sends them.
	syncBody := bytes.Repeat([]byte{9}, 768+124+700)
	requestBody := bytes.Repeat([]byte{8}, 124+256)
	send := func(token, key string, metadata map[string]interface{}, sealed []byte) (int, []byte) {
		return doJSON(t, handler, http.MethodPost, "/api/v1/messages/envelopes", token, map[string]interface{}{
			"conversation_id": shared,
			"idempotency_key": key,
			"ciphertext":      base64.StdEncoding.EncodeToString([]byte("reference")),
			"crypto_protocol": "mls10-openmls-v1",
			"crypto_metadata": metadata,
			"sealed_body":     base64.StdEncoding.EncodeToString(sealed),
		})
	}
	syncFor := func(epoch int) map[string]interface{} {
		return map[string]interface{}{"protocol_version": 1, "mls_epoch": 2, "c7_sync_for_epoch": epoch}
	}
	requestFor := func(epoch int) map[string]interface{} {
		return map[string]interface{}{"protocol_version": 1, "mls_epoch": 2, "c7_sync_request_for_epoch": epoch}
	}
	status, body = send(ownerToken, "hs-1", syncFor(2), syncBody)
	if status != http.StatusCreated {
		t.Fatalf("committer's history_sync status=%d body=%s", status, body)
	}
	var sent struct {
		ID string `json:"id"`
	}
	decodeLayoutBody(t, body, &sent)

	// Live: Dave (the newcomer) and the owner (the echo) get a frame that
	// only says to sync; Carol gets nothing.
	for id, client := range clients {
		frames := drainEnvelopeFrames(t, client)
		want := id != carolID
		if (len(frames) == 1) != want || len(frames) > 1 {
			t.Fatalf("realtime frames for %s = %d, want one: %v", id, len(frames), want)
		}
		if want && (strings.Contains(string(frames[0]), "sealed_body") || strings.Contains(string(frames[0]), base64.StdEncoding.EncodeToString([]byte("reference")))) {
			t.Fatalf("live frame for %s carries the message: %s", id, frames[0])
		}
	}
	// Sync: the same, and Dave's copy carries the body.
	for token, want := range map[string]bool{daveToken: true, ownerToken: true, carolToken: false} {
		got := syncedEnvelope(t, handler, token, sent.ID)
		if (got != nil) != want {
			t.Fatalf("sync of the history_sync = %v, want %v", got != nil, want)
		}
		if got != nil && !bytes.Equal(got, syncBody) {
			t.Fatalf("synced body %d bytes", len(got))
		}
	}
	delivered := func(token string, epoch string) bool {
		t.Helper()
		status, body := doJSON(t, handler, http.MethodGet, "/api/v1/conversations/"+shared+"/history-sync?for_epoch="+epoch, token, nil)
		var answer struct {
			Delivered bool `json:"delivered"`
		}
		if status != http.StatusOK || json.Unmarshal(body, &answer) != nil {
			t.Fatalf("history-sync status=%d body=%s", status, body)
		}
		return answer.Delivered
	}
	if !delivered(carolToken, "2") || delivered(carolToken, "1") {
		t.Fatal("delivered answers")
	}
	if status, body := doJSON(t, handler, http.MethodGet, "/api/v1/conversations/"+shared+"/history-sync?for_epoch=-1", carolToken, nil); status != http.StatusBadRequest {
		t.Fatalf("negative epoch status=%d body=%s", status, body)
	}
	// Carol's fallback for the same epoch is refused.
	if status, body := send(carolToken, "hs-carol", syncFor(2), syncBody); status != http.StatusConflict || !strings.Contains(string(body), "history_sync_delivered") {
		t.Fatalf("second history_sync status=%d body=%s", status, body)
	}
	// A request names its sender's own join epoch only.
	for token, epoch := range map[string]int{daveToken: 1, carolToken: 2} {
		if status, body := send(token, "rq-bad", requestFor(epoch), requestBody); status != http.StatusBadRequest || !strings.Contains(string(body), "invalid_history_sync_target") {
			t.Fatalf("request for another epoch status=%d body=%s", status, body)
		}
	}
	// Untagged, or tagged on a channel post, is refused.
	if status, body := send(carolToken, "untagged", map[string]interface{}{"mls_epoch": 2}, syncBody); status != http.StatusBadRequest || !strings.Contains(string(body), "invalid_history_sync_target") {
		t.Fatalf("untagged group-level status=%d body=%s", status, body)
	}
	// Dave's request reopens the epoch; Carol's fallback then passes once.
	if status, body := send(daveToken, "rq-1", requestFor(2), requestBody); status != http.StatusCreated {
		t.Fatalf("newcomer's request status=%d body=%s", status, body)
	}
	if delivered(carolToken, "2") {
		t.Fatal("a request did not reopen the epoch")
	}
	if status, body := send(carolToken, "hs-carol", syncFor(2), syncBody); status != http.StatusCreated {
		t.Fatalf("history_sync after the request status=%d body=%s", status, body)
	}
	if !delivered(ownerToken, "2") {
		t.Fatal("not delivered after the second history_sync")
	}
	// Off, the check is not found.
	_, offHandler, offOwner, _ := newTestAppWithOwnerConfig(t, func(c *config.Config) { c.CommunityLayout = true })
	if status, body := doJSON(t, offHandler, http.MethodGet, "/api/v1/conversations/"+shared+"/history-sync?for_epoch=2", offOwner, nil); status != http.StatusNotFound {
		t.Fatalf("c7 off status=%d body=%s", status, body)
	}
}

// drainEnvelopeFrames returns the message.envelope.created frames queued
// for client.
func drainEnvelopeFrames(t *testing.T, client *realtime.Client) [][]byte {
	t.Helper()
	var frames [][]byte
	deadline := time.After(50 * time.Millisecond)
	for {
		select {
		case raw := <-client.Send():
			var event struct {
				Type string `json:"type"`
			}
			if err := json.Unmarshal(raw, &event); err != nil {
				t.Fatalf("decode realtime event: %v", err)
			}
			if event.Type == "message.envelope.created" {
				frames = append(frames, raw)
			}
		case <-deadline:
			return frames
		}
	}
}

// syncedEnvelope is the sealed body sync gives token's device for message
// id, or nil when sync does not serve it.
func syncedEnvelope(t *testing.T, handler http.Handler, token, id string) []byte {
	t.Helper()
	status, body := doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0&limit=200", token, nil)
	if status != http.StatusOK {
		t.Fatalf("sync status=%d body=%s", status, body)
	}
	var decoded struct {
		Events []struct {
			Type    string `json:"type"`
			Payload struct {
				MessageID string `json:"message_id"`
				Envelope  struct {
					SealedBody []byte `json:"sealed_body"`
				} `json:"envelope"`
			} `json:"payload"`
		} `json:"events"`
	}
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Fatalf("decode sync: %v", err)
	}
	for _, event := range decoded.Events {
		if event.Type == "message.envelope.created" && event.Payload.MessageID == id {
			return event.Payload.Envelope.SealedBody
		}
	}
	return nil
}
