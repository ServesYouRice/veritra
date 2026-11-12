package httpapi_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/cloudflare/circl/group"
	"github.com/cloudflare/circl/oprf"
	"github.com/cloudflare/circl/zk/dleq"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/sealedsender"
)

// L2-3 sealed sender (D122). The client half here is circl's POPRF client;
// the app uses the Rust core, and both match testing/vectors/l2-sealed-v1.json.

type sealedTestToken struct {
	Epoch  uint32
	KeyID  string
	Nonce  []byte
	Output []byte
}

// sealedConversationInfo is the issuance route's answer. Epoch is not in
// it: the app takes the day from its own clock (review M1), as sealedInfo
// does here.
type sealedConversationInfo struct {
	KeyID     string `json:"key_id"`
	PublicKey []byte `json:"public_key"`
	Eligible  bool   `json:"eligible"`
	Remaining int    `json:"remaining"`
	Epoch     uint32 `json:"-"`
}

func sealedInfo(t *testing.T, handler http.Handler, token, conversationID string) (int, sealedConversationInfo) {
	t.Helper()
	status, body := doJSON(t, handler, http.MethodGet, "/api/v1/sealed/conversations/"+conversationID, token, nil)
	var info sealedConversationInfo
	if status == http.StatusOK {
		// Exactly these members: nothing per account the server could tag
		// tokens with (review M1).
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(body, &fields); err != nil {
			t.Fatal(err)
		}
		for name := range fields {
			switch name {
			case "key_id", "public_key", "eligible", "remaining":
			default:
				t.Fatalf("issuance info has member %q: %s", name, body)
			}
		}
		if err := json.Unmarshal(body, &info); err != nil {
			t.Fatal(err)
		}
	}
	info.Epoch = sealedsender.Epoch(time.Now().UTC())
	return status, info
}

// requestSealedTokens blinds n nonces, asks the server to evaluate them and
// finalizes (checking the batch proof) as the app would.
func requestSealedTokens(t *testing.T, handler http.Handler, token, conversationID string, epoch uint32, n int) ([]sealedTestToken, int, string) {
	t.Helper()
	status, body := doJSON(t, handler, http.MethodGet, "/api/v1/sealed/key", "", nil)
	if status != http.StatusOK {
		t.Fatalf("key status=%d body=%s", status, body)
	}
	var key struct {
		Suite     string `json:"suite"`
		KeyID     string `json:"key_id"`
		PublicKey []byte `json:"public_key"`
	}
	if err := json.Unmarshal(body, &key); err != nil || key.Suite != sealedsender.Suite || sealedsender.KeyID(key.PublicKey) != key.KeyID {
		t.Fatalf("key body=%s err=%v", body, err)
	}
	var pub oprf.PublicKey
	if err := pub.UnmarshalBinary(oprf.SuiteRistretto255, key.PublicKey); err != nil {
		t.Fatal(err)
	}
	client := oprf.NewPartialObliviousClient(oprf.SuiteRistretto255, &pub)
	nonces := make([][]byte, n)
	for i := range nonces {
		nonces[i] = make([]byte, sealedsender.NonceSize)
		if _, err := rand.Read(nonces[i]); err != nil {
			t.Fatal(err)
		}
	}
	finalize, request, err := client.Blind(nonces)
	if err != nil {
		t.Fatal(err)
	}
	var blinded []byte
	for _, e := range request.Elements {
		enc, err := e.MarshalBinaryCompress()
		if err != nil {
			t.Fatal(err)
		}
		blinded = append(blinded, enc...)
	}
	status, body = doJSON(t, handler, http.MethodPost, "/api/v1/sealed/conversations/"+conversationID+"/tokens", token, map[string]interface{}{
		"epoch":   epoch,
		"blinded": base64.StdEncoding.EncodeToString(blinded),
	})
	if status != http.StatusOK {
		return nil, status, string(body)
	}
	var response struct {
		KeyID     string `json:"key_id"`
		Evaluated []byte `json:"evaluated"`
		Proof     []byte `json:"proof"`
	}
	if err := json.Unmarshal(body, &response); err != nil || response.KeyID != key.KeyID || len(response.Evaluated) != n*32 {
		t.Fatalf("tokens body=%s err=%v", body, err)
	}
	evaluation := &oprf.Evaluation{Proof: new(dleq.Proof)}
	for i := 0; i < n; i++ {
		e := group.Ristretto255.NewElement()
		if err := e.UnmarshalBinary(response.Evaluated[i*32 : (i+1)*32]); err != nil {
			t.Fatal(err)
		}
		evaluation.Elements = append(evaluation.Elements, e)
	}
	if err := evaluation.Proof.UnmarshalBinary(group.Ristretto255, response.Proof); err != nil {
		t.Fatal(err)
	}
	info, err := sealedsender.Info(conversationID, epoch)
	if err != nil {
		t.Fatal(err)
	}
	outputs, err := client.Finalize(finalize, evaluation, info)
	if err != nil {
		t.Fatalf("finalize (proof check): %v", err)
	}
	tokens := make([]sealedTestToken, n)
	for i := range tokens {
		tokens[i] = sealedTestToken{Epoch: epoch, KeyID: key.KeyID, Nonce: nonces[i], Output: outputs[i]}
	}
	return tokens, status, string(body)
}

func sealedPostBody(conversationID string, token sealedTestToken, key string, ciphertext []byte, commit []byte) map[string]interface{} {
	body := map[string]interface{}{
		"conversation_id": conversationID,
		"token": map[string]interface{}{
			"key_id": token.KeyID,
			"epoch":  token.Epoch,
			"nonce":  base64.StdEncoding.EncodeToString(token.Nonce),
			"output": base64.StdEncoding.EncodeToString(token.Output),
		},
		"idempotency_key": key,
		"ciphertext":      base64.StdEncoding.EncodeToString(ciphertext),
		"crypto_protocol": "mls10-openmls-v1",
		"crypto_metadata": map[string]interface{}{
			"protocol_version": 1,
			"group_id":         conversationID,
			"content_type":     "application",
			"payload_version":  1,
			"mls_epoch":        2,
		},
	}
	if commit != nil {
		body["frank_commit"] = base64.StdEncoding.EncodeToString(commit)
	}
	return body
}

func postSealed(t *testing.T, handler http.Handler, body map[string]interface{}) (int, []byte) {
	t.Helper()
	return doJSON(t, handler, http.MethodPost, "/api/v1/sealed/messages", "", body)
}

func sealedHandler(t *testing.T, mutate func(*config.Config)) (http.Handler, string, string, func() int64) {
	t.Helper()
	application, handler, ownerToken, dbPath := newTestAppWithOwnerConfig(t, func(cfg *config.Config) {
		cfg.SealedSender = true
		if mutate != nil {
			mutate(cfg)
		}
	})
	prune := func() int64 {
		removed, _, err := application.Store.PruneExpiredContent(context.Background(), time.Now().UTC())
		if err != nil {
			t.Fatal(err)
		}
		return removed
	}
	return handler, ownerToken, dbPath, prune
}

// sealedReaders reads sync with the sealed opt-in as each device's app
// would, which records the device for the issuance gate.
func sealedReaders(t *testing.T, handler http.Handler, tokens ...string) {
	t.Helper()
	for _, token := range tokens {
		if status, body := doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0&limit=1&sealed=1", token, nil); status != http.StatusOK {
			t.Fatalf("sealed reader status=%d body=%s", status, body)
		}
	}
}

const sealedKey1 = "sealed-key-000000000000001"

func TestSealedSenderIsOffByDefault(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	conversationID := createConversation(t, handler, ownerToken)
	for _, probe := range []struct{ method, path, token string }{
		{http.MethodGet, "/api/v1/sealed/key", ""},
		{http.MethodGet, "/api/v1/sealed/conversations/" + conversationID, ownerToken},
		{http.MethodPost, "/api/v1/sealed/conversations/" + conversationID + "/tokens", ownerToken},
		{http.MethodPost, "/api/v1/sealed/messages", ""},
	} {
		if status, body := doJSON(t, handler, probe.method, probe.path, probe.token, map[string]interface{}{}); status != http.StatusNotFound {
			t.Fatalf("%s %s status=%d body=%s", probe.method, probe.path, status, body)
		}
	}
}

func TestSealedPostStoresNoSenderAndSpendsItsToken(t *testing.T) {
	handler, ownerToken, dbPath, _ := sealedHandler(t, nil)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "sealedsender")
	outsiderToken, _ := registerMemberWithID(t, handler, ownerToken, "outsider")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)
	sealedReaders(t, handler, ownerToken, memberToken)

	status, info := sealedInfo(t, handler, memberToken, conversationID)
	if status != http.StatusOK || !info.Eligible || info.Remaining != 200 {
		t.Fatalf("info status=%d %+v", status, info)
	}
	if status, _ := sealedInfo(t, handler, outsiderToken, conversationID); status != http.StatusNotFound {
		t.Fatalf("outsider info status=%d", status)
	}
	tokens, status, body := requestSealedTokens(t, handler, memberToken, conversationID, info.Epoch, 3)
	if status != http.StatusOK {
		t.Fatalf("tokens status=%d body=%s", status, body)
	}
	if _, after := sealedInfo(t, handler, memberToken, conversationID); after.Remaining != 197 {
		t.Fatalf("remaining after issue %d", after.Remaining)
	}
	// An outsider gets none.
	if _, status, _ := requestSealedTokens(t, handler, outsiderToken, conversationID, info.Epoch, 1); status != http.StatusNotFound {
		t.Fatalf("outsider tokens status=%d", status)
	}

	commit := commitOf(0x5a)
	post := sealedPostBody(conversationID, tokens[0], sealedKey1, []byte("sealed ciphertext 1"), commit)
	status, response := postSealed(t, handler, post)
	if status != http.StatusCreated {
		t.Fatalf("sealed post status=%d body=%s", status, response)
	}
	var stored struct {
		ID          string `json:"id"`
		Sealed      bool   `json:"sealed"`
		FrankCommit []byte `json:"frank_commit"`
	}
	if err := json.Unmarshal(response, &stored); err != nil || !stored.Sealed || !strings.HasPrefix(stored.ID, "sealed_") || !bytes.Equal(stored.FrankCommit, commit) {
		t.Fatalf("stored body=%s", response)
	}
	if bytes.Contains(response, []byte("sender")) || bytes.Contains(response, []byte(memberID)) {
		t.Fatalf("sealed response names a sender: %s", response)
	}

	// The retry of the same post answers with the stored envelope and
	// spends nothing; the token cannot pay for another post.
	status, retry := postSealed(t, handler, post)
	if status != http.StatusOK || !bytes.Contains(retry, []byte(stored.ID)) {
		t.Fatalf("retry status=%d body=%s", status, retry)
	}
	status, response = postSealed(t, handler, sealedPostBody(conversationID, tokens[0], "sealed-key-000000000000002", []byte("another"), nil))
	if status != http.StatusConflict || !strings.Contains(string(response), "sealed_token_spent") {
		t.Fatalf("double spend status=%d body=%s", status, response)
	}
	// Another post under the stored key is a conflict, whatever the token.
	status, response = postSealed(t, handler, sealedPostBody(conversationID, tokens[1], sealedKey1, []byte("different"), commit))
	if status != http.StatusConflict || !strings.Contains(string(response), "idempotency_conflict") {
		t.Fatalf("idempotency conflict status=%d body=%s", status, response)
	}

	// Nothing in the database names the sender next to the post.
	db := openSQLite(t, dbPath)
	rows, err := db.Query(`SELECT name FROM pragma_table_info('sealed_message_envelopes')`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatal(err)
		}
		if strings.Contains(name, "sender") || strings.Contains(name, "account") || strings.Contains(name, "device") {
			t.Fatalf("sealed table has column %q", name)
		}
	}
	rows.Close()
	var payload string
	if err := db.QueryRow(`SELECT payload_json FROM sync_events WHERE event_type = 'message.sealed.created'`).Scan(&payload); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(payload, memberID) || strings.Contains(payload, "sender") {
		t.Fatalf("sync payload names the sender: %s", payload)
	}
	var spent int
	if err := db.QueryRow(`SELECT COUNT(*) FROM sealed_spent_tokens`).Scan(&spent); err != nil || spent != 1 {
		t.Fatalf("spent rows %d err=%v", spent, err)
	}

	// Every member, the sender included, gets it by sync and by id; an
	// outsider does not.
	for name, token := range map[string]string{"owner": ownerToken, "sender": memberToken} {
		status, events := doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0&limit=100&sealed=1", token, nil)
		if status != http.StatusOK || !bytes.Contains(events, []byte("message.sealed.created")) || !bytes.Contains(events, []byte(stored.ID)) {
			t.Fatalf("%s sync status=%d body=%s", name, status, events)
		}
		status, one := doJSON(t, handler, http.MethodGet, "/api/v1/messages/"+stored.ID, token, nil)
		if status != http.StatusOK || !bytes.Contains(one, []byte(`"sealed":true`)) {
			t.Fatalf("%s by id status=%d body=%s", name, status, one)
		}
	}
	if status, _ := doJSON(t, handler, http.MethodGet, "/api/v1/messages/"+stored.ID, outsiderToken, nil); status != http.StatusNotFound {
		t.Fatalf("outsider by id status=%d", status)
	}
	if status, events := doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0&limit=100&sealed=1", outsiderToken, nil); status != http.StatusOK || bytes.Contains(events, []byte(stored.ID)) {
		t.Fatalf("outsider sync status=%d body=%s", status, events)
	}
}

func TestSealedPostRefusesSessionsAndBadTokens(t *testing.T) {
	handler, ownerToken, _, _ := sealedHandler(t, nil)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "sealedbad")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)
	sealedReaders(t, handler, ownerToken, memberToken)
	_, info := sealedInfo(t, handler, memberToken, conversationID)
	tokens, status, body := requestSealedTokens(t, handler, memberToken, conversationID, info.Epoch, 2)
	if status != http.StatusOK {
		t.Fatalf("tokens status=%d body=%s", status, body)
	}
	good := tokens[0]

	// A session on the request fails closed, before anything is read.
	for _, header := range []string{"Authorization", "Cookie"} {
		raw, _ := json.Marshal(sealedPostBody(conversationID, good, sealedKey1, []byte("x"), nil))
		req := httptest.NewRequest(http.MethodPost, "/api/v1/sealed/messages", bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set(header, "Bearer "+memberToken)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "sealed_request_authenticated") {
			t.Fatalf("%s: status=%d body=%s", header, rec.Code, rec.Body.String())
		}
	}

	forged := good
	forged.Output = bytes.Repeat([]byte{7}, 64)
	otherConversation := createConversation(t, handler, ownerToken)
	wrongKey := good
	wrongKey.KeyID = strings.Repeat("0", 32)
	shiftedEpoch := good
	shiftedEpoch.Epoch = good.Epoch - 1
	for name, c := range map[string]struct {
		body   map[string]interface{}
		status int
		code   string
	}{
		"forged output":        {sealedPostBody(conversationID, forged, sealedKey1, []byte("x"), nil), http.StatusForbidden, "sealed_token_invalid"},
		"other conversation":   {sealedPostBody(otherConversation, good, sealedKey1, []byte("x"), nil), http.StatusForbidden, "sealed_token_invalid"},
		"unknown conversation": {sealedPostBody("conv_missing", good, sealedKey1, []byte("x"), nil), http.StatusForbidden, "sealed_token_invalid"},
		"wrong key id":         {sealedPostBody(conversationID, wrongKey, sealedKey1, []byte("x"), nil), http.StatusForbidden, "sealed_token_invalid"},
		"claimed epoch":        {sealedPostBody(conversationID, shiftedEpoch, sealedKey1, []byte("x"), nil), http.StatusForbidden, "sealed_token_invalid"},
		"short key":            {sealedPostBody(conversationID, good, "short", []byte("x"), nil), http.StatusBadRequest, "invalid_encrypted_envelope"},
	} {
		status, response := postSealed(t, handler, c.body)
		if status != c.status || !strings.Contains(string(response), c.code) {
			t.Fatalf("%s: status=%d body=%s", name, status, response)
		}
	}
	// Metadata that needs a sender (a channel, a leave notice) or names
	// another group is refused, as are fields a sealed post cannot carry.
	for name, mutate := range map[string]func(map[string]interface{}){
		"channel": func(b map[string]interface{}) { b["crypto_metadata"].(map[string]interface{})["channel_id"] = "ch_1" },
		"leave": func(b map[string]interface{}) {
			b["crypto_metadata"].(map[string]interface{})["c4_leave_notice"] = true
		},
		"other group": func(b map[string]interface{}) {
			b["crypto_metadata"].(map[string]interface{})["group_id"] = otherConversation
		},
		"no epoch": func(b map[string]interface{}) { delete(b["crypto_metadata"].(map[string]interface{}), "mls_epoch") },
	} {
		b := sealedPostBody(conversationID, good, sealedKey1, []byte("x"), nil)
		mutate(b)
		if status, response := postSealed(t, handler, b); status != http.StatusBadRequest || !strings.Contains(string(response), "invalid_crypto_metadata") {
			t.Fatalf("%s: status=%d body=%s", name, status, response)
		}
	}
	for _, field := range []string{"attachment_refs", "reply_to_id", "sealed_body"} {
		b := sealedPostBody(conversationID, good, sealedKey1, []byte("x"), nil)
		b[field] = "x"
		if status, _ := postSealed(t, handler, b); status != http.StatusBadRequest {
			t.Fatalf("%s accepted: status=%d", field, status)
		}
	}
	// None of the refusals spent the token.
	if status, response := postSealed(t, handler, sealedPostBody(conversationID, good, sealedKey1, []byte("x"), nil)); status != http.StatusCreated {
		t.Fatalf("good token after refusals status=%d body=%s", status, response)
	}
}

func TestSealedTokensAreBoundToTheirEpoch(t *testing.T) {
	handler, ownerToken, _, _ := sealedHandler(t, nil)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "sealedepoch")
	sealedReaders(t, handler, ownerToken, memberToken)
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)
	_, info := sealedInfo(t, handler, memberToken, conversationID)

	// Issued only for today and tomorrow.
	for _, epoch := range []uint32{info.Epoch - 1, info.Epoch + 2} {
		if _, status, body := requestSealedTokens(t, handler, memberToken, conversationID, epoch, 1); status != http.StatusBadRequest || !strings.Contains(body, "invalid_sealed_epoch") {
			t.Fatalf("epoch %d status=%d body=%s", epoch, status, body)
		}
	}
	// A token for tomorrow does not work today.
	tomorrow, status, body := requestSealedTokens(t, handler, memberToken, conversationID, info.Epoch+1, 1)
	if status != http.StatusOK {
		t.Fatalf("tomorrow status=%d body=%s", status, body)
	}
	status, response := postSealed(t, handler, sealedPostBody(conversationID, tomorrow[0], sealedKey1, []byte("x"), nil))
	if status != http.StatusConflict || !strings.Contains(string(response), "sealed_token_expired") {
		t.Fatalf("tomorrow's token today status=%d body=%s", status, response)
	}
	// Relabelled as today's, its output does not verify.
	relabelled := tomorrow[0]
	relabelled.Epoch = info.Epoch
	if status, response := postSealed(t, handler, sealedPostBody(conversationID, relabelled, sealedKey1, []byte("x"), nil)); status != http.StatusForbidden {
		t.Fatalf("relabelled status=%d body=%s", status, response)
	}
}

// Review M1: no per-conversation counter is bound into a token (the
// server could set one per account and tag its tokens). A member's leftover
// tokens outlive a removal until their day ends; receivers refuse the
// removed sender's posts (SenderRemoved), docs/crypto.md "What still leaks".
func TestSealedTokensBindOnlyConversationAndDay(t *testing.T) {
	handler, ownerToken, dbPath, _ := sealedHandler(t, nil)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "sealedstay")
	leaverToken, leaverID := registerMemberWithID(t, handler, ownerToken, "sealedleave")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)
	addMember(t, handler, ownerToken, conversationID, leaverID)
	sealedReaders(t, handler, ownerToken, memberToken, leaverToken)
	_, info := sealedInfo(t, handler, leaverToken, conversationID)
	tokens, status, body := requestSealedTokens(t, handler, leaverToken, conversationID, info.Epoch, 2)
	if status != http.StatusOK {
		t.Fatalf("tokens status=%d body=%s", status, body)
	}
	if status, body := doJSON(t, handler, http.MethodDelete, "/api/v1/conversations/"+conversationID+"/members/"+leaverID, ownerToken, nil); status >= 300 {
		t.Fatalf("remove status=%d body=%s", status, body)
	}
	// Removed: no new tokens and no issuance info.
	if _, status, _ := requestSealedTokens(t, handler, leaverToken, conversationID, info.Epoch, 1); status != http.StatusNotFound {
		t.Fatalf("removed member issuance status=%d", status)
	}
	// Its leftover token still redeems for its day.
	if status, response := postSealed(t, handler, sealedPostBody(conversationID, tokens[0], sealedKey1, []byte("x"), nil)); status != http.StatusCreated {
		t.Fatalf("leftover post status=%d body=%s", status, response)
	}
	// The member who stayed, and a revoked device, change nothing either.
	_, after := sealedInfo(t, handler, memberToken, conversationID)
	fresh, status, body := requestSealedTokens(t, handler, memberToken, conversationID, after.Epoch, 1)
	if status != http.StatusOK {
		t.Fatalf("fresh tokens status=%d body=%s", status, body)
	}
	db := openSQLite(t, dbPath)
	if _, err := db.Exec(`UPDATE devices SET revoked_at = ? WHERE account_id = ?`, time.Now().UTC().Format(time.RFC3339Nano), leaverID); err != nil {
		t.Fatal(err)
	}
	if status, response := postSealed(t, handler, sealedPostBody(conversationID, fresh[0], "sealed-key-000000000000003", []byte("y"), nil)); status != http.StatusCreated {
		t.Fatalf("fresh post status=%d body=%s", status, response)
	}
	var tables int
	if err := db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name = 'sealed_conversation_state' OR name LIKE 'sealed_generation_%'`).Scan(&tables); err != nil || tables != 0 {
		t.Fatalf("generation objects %d err=%v", tables, err)
	}
}

func TestSealedTokensAreCappedAndOnlyForEligibleConversations(t *testing.T) {
	handler, ownerToken, dbPath, _ := sealedHandler(t, func(cfg *config.Config) { cfg.SealedTokensPerDay = 3 })
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "sealedcap")
	sealedReaders(t, handler, ownerToken, memberToken)
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)
	_, info := sealedInfo(t, handler, memberToken, conversationID)
	if info.Remaining != 3 {
		t.Fatalf("remaining %d", info.Remaining)
	}
	if _, status, body := requestSealedTokens(t, handler, memberToken, conversationID, info.Epoch, 2); status != http.StatusOK {
		t.Fatalf("first batch status=%d body=%s", status, body)
	}
	if _, status, body := requestSealedTokens(t, handler, memberToken, conversationID, info.Epoch, 2); status != http.StatusTooManyRequests || !strings.Contains(body, "sealed_token_limit") {
		t.Fatalf("over cap status=%d body=%s", status, body)
	}
	// The cap is per epoch: tomorrow has its own.
	if _, status, body := requestSealedTokens(t, handler, memberToken, conversationID, info.Epoch+1, 3); status != http.StatusOK {
		t.Fatalf("tomorrow batch status=%d body=%s", status, body)
	}
	if _, status, body := requestSealedTokens(t, handler, memberToken, conversationID, info.Epoch, 33); status != http.StatusBadRequest {
		t.Fatalf("oversized batch status=%d body=%s", status, body)
	}

	// Admins-only posting and a member under a timeout take identified
	// posts only.
	other := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, other, memberID)
	_, otherInfo := sealedInfo(t, handler, memberToken, other)
	tokens, status, body := requestSealedTokens(t, handler, memberToken, other, otherInfo.Epoch, 1)
	if status != http.StatusOK {
		t.Fatalf("other tokens status=%d body=%s", status, body)
	}
	db := openSQLite(t, dbPath)
	for name, change := range map[string][2]string{
		"admins only": {`UPDATE conversations SET posting_policy = 'admins' WHERE id = ?`, `UPDATE conversations SET posting_policy = 'everyone' WHERE id = ?`},
		"timeout": {`UPDATE memberships SET timeout_until = '2999-01-01T00:00:00.000000000Z' WHERE conversation_id = ? AND role = 'owner'`,
			`UPDATE memberships SET timeout_until = NULL WHERE conversation_id = ?`},
	} {
		if _, err := db.Exec(change[0], other); err != nil {
			t.Fatal(err)
		}
		status, state := sealedInfo(t, handler, memberToken, other)
		if status != http.StatusOK || state.Eligible {
			t.Fatalf("%s: info status=%d %+v", name, status, state)
		}
		if _, status, body := requestSealedTokens(t, handler, memberToken, other, otherInfo.Epoch, 1); status != http.StatusConflict || !strings.Contains(body, "sealed_not_eligible") {
			t.Fatalf("%s: issuance status=%d body=%s", name, status, body)
		}
		if status, response := postSealed(t, handler, sealedPostBody(other, tokens[0], sealedKey1, []byte("x"), nil)); status != http.StatusConflict || !strings.Contains(string(response), "sealed_not_eligible") {
			t.Fatalf("%s: post status=%d body=%s", name, status, response)
		}
		if _, err := db.Exec(change[1], other); err != nil {
			t.Fatal(err)
		}
	}
}

// C6 still works for a sealed message: the copy holder gets the stored
// commitment with no sender, marked sealed, and attributes the message with
// the franking signature carried in the report (docs/crypto.md).
func TestReportEnvelopeOfASealedMessage(t *testing.T) {
	handler, ownerToken, _, _ := sealedHandler(t, nil)
	ownerID := accountIDFromExport(t, handler, ownerToken)
	senderToken, senderID := registerMemberWithID(t, handler, ownerToken, "sealedreported")
	reporterToken, reporterID := registerMemberWithID(t, handler, ownerToken, "sealedreporter")
	sealedReaders(t, handler, ownerToken, senderToken, reporterToken)
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, senderID)
	addMember(t, handler, ownerToken, conversationID, reporterID)

	_, info := sealedInfo(t, handler, senderToken, conversationID)
	tokens, status, body := requestSealedTokens(t, handler, senderToken, conversationID, info.Epoch, 1)
	if status != http.StatusOK {
		t.Fatalf("tokens status=%d body=%s", status, body)
	}
	commit := commitOf(0x77)
	status, response := postSealed(t, handler, sealedPostBody(conversationID, tokens[0], sealedKey1, []byte("reported sealed"), commit))
	if status != http.StatusCreated {
		t.Fatalf("post status=%d body=%s", status, response)
	}
	var stored struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &stored); err != nil {
		t.Fatal(err)
	}

	key := bytes.Repeat([]byte{9}, 32)
	if status, body := putReportKey(t, handler, ownerToken, key); status != http.StatusOK {
		t.Fatalf("publish status=%d body=%s", status, body)
	}
	if status, body := fileReport(t, handler, reporterToken, conversationID, reportIDOne, reportCopy{InboxID: ownerID, Rev: 1, Key: key, Sealed: sealedWith(3)}); status != http.StatusCreated {
		t.Fatalf("report status=%d body=%s", status, body)
	}
	status, reports, listed := listReportsAs(t, handler, ownerToken, "inbox=instance_owner")
	if status != http.StatusOK || len(reports) != 1 {
		t.Fatalf("list status=%d body=%s", status, listed)
	}
	path := "/api/v1/reports/" + reports[0].ID + "/envelope?envelope_id=" + stored.ID
	status, response = doJSON(t, handler, http.MethodGet, path, ownerToken, nil)
	var record struct {
		EnvelopeID     string `json:"envelope_id"`
		ConversationID string `json:"conversation_id"`
		FrankCommit    []byte `json:"frank_commit"`
		Sealed         bool   `json:"sealed"`
		IdempotencyKey string `json:"idempotency_key"`
	}
	// The key ties a report to this envelope, not to a copy (review low b).
	if status != http.StatusOK || json.Unmarshal(response, &record) != nil || record.EnvelopeID != stored.ID || record.ConversationID != conversationID || !record.Sealed || !bytes.Equal(record.FrankCommit, commit) || record.IdempotencyKey == "" {
		t.Fatalf("record status=%d body=%s", status, response)
	}
	if bytes.Contains(response, []byte("sender")) || bytes.Contains(response, []byte(senderID)) {
		t.Fatalf("sealed record names a sender: %s", response)
	}
	for name, token := range map[string]string{"reporter": reporterToken, "sender": senderToken} {
		if status, _ := doJSON(t, handler, http.MethodGet, path, token, nil); status != http.StatusNotFound {
			t.Fatalf("%s status=%d", name, status)
		}
	}
}

func TestSealedEnvelopesExpireAndArePruned(t *testing.T) {
	handler, ownerToken, dbPath, prune := sealedHandler(t, nil)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "sealedexpire")
	sealedReaders(t, handler, ownerToken, memberToken)
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)
	_, info := sealedInfo(t, handler, memberToken, conversationID)
	tokens, status, body := requestSealedTokens(t, handler, memberToken, conversationID, info.Epoch, 1)
	if status != http.StatusOK {
		t.Fatalf("tokens status=%d body=%s", status, body)
	}
	ciphertext := []byte("short-lived sealed ciphertext")
	post := sealedPostBody(conversationID, tokens[0], sealedKey1, ciphertext, nil)
	post["expires_at"] = time.Now().UTC().Add(time.Hour).Format(time.RFC3339Nano)
	status, response := postSealed(t, handler, post)
	if status != http.StatusCreated {
		t.Fatalf("post status=%d body=%s", status, response)
	}
	var stored struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &stored); err != nil {
		t.Fatal(err)
	}
	db := openSQLite(t, dbPath)
	if _, err := db.Exec(`UPDATE sealed_message_envelopes SET expires_at = '2000-01-01T00:00:00.000000000Z' WHERE id = ?`, stored.ID); err != nil {
		t.Fatal(err)
	}
	// Expired but not yet pruned: proven gone (I33) and hidden from sync.
	if status, _ := doJSON(t, handler, http.MethodGet, "/api/v1/messages/"+stored.ID, ownerToken, nil); status != http.StatusGone {
		t.Fatalf("expired by id status=%d", status)
	}
	encoded := base64.StdEncoding.EncodeToString(ciphertext)
	if _, events := doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0&limit=100&sealed=1", ownerToken, nil); bytes.Contains(events, []byte(encoded)) {
		t.Fatalf("expired envelope served by sync: %s", events)
	}
	if removed := prune(); removed < 1 {
		t.Fatalf("prune removed %d", removed)
	}
	var payload string
	if err := db.QueryRow(`SELECT payload_json FROM sync_events WHERE event_type = 'message.sealed.created'`).Scan(&payload); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(payload, encoded) || !strings.Contains(payload, `"redacted":1`) {
		t.Fatalf("pruned event keeps its ciphertext: %s", payload)
	}
	var left int
	if err := db.QueryRow(`SELECT COUNT(*) FROM sealed_message_envelopes`).Scan(&left); err != nil || left != 0 {
		t.Fatalf("envelopes left %d err=%v", left, err)
	}
	// The nonce stays spent after its envelope is gone.
	if status, response := postSealed(t, handler, sealedPostBody(conversationID, tokens[0], "sealed-key-000000000000009", []byte("again"), nil)); status != http.StatusConflict || !strings.Contains(string(response), "sealed_token_spent") {
		t.Fatalf("respend after prune status=%d body=%s", status, response)
	}
	// Dead epochs are swept.
	if _, err := db.Exec(`INSERT INTO sealed_spent_tokens(key_id, epoch, nonce, message_id) VALUES(?, ?, ?, 'old')`, tokens[0].KeyID, info.Epoch-2, bytes.Repeat([]byte{1}, 32)); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE sealed_token_issuance SET epoch = ? WHERE conversation_id = ?`, info.Epoch-1, conversationID); err != nil {
		t.Fatal(err)
	}
	prune()
	var oldSpent, oldIssued int
	if err := db.QueryRow(`SELECT COUNT(*) FROM sealed_spent_tokens WHERE epoch < ?`, info.Epoch-1).Scan(&oldSpent); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`SELECT COUNT(*) FROM sealed_token_issuance WHERE epoch < ?`, info.Epoch).Scan(&oldIssued); err != nil {
		t.Fatal(err)
	}
	if oldSpent != 0 || oldIssued != 0 {
		t.Fatalf("dead token rows kept: spent=%d issued=%d", oldSpent, oldIssued)
	}
}

// Review H1: a member reads every idempotency key in the conversation, so a
// sealed post may not take the key of an identified envelope there (the
// sending device would take it for its own post), and an identified post
// may not take the key of a sealed one. Both answer idempotency_conflict.
func TestSealedAndIdentifiedKeysDoNotCross(t *testing.T) {
	handler, ownerToken, _, _ := sealedHandler(t, nil)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "sealedcross")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)
	sealedReaders(t, handler, ownerToken, memberToken)
	_, info := sealedInfo(t, handler, memberToken, conversationID)
	tokens, status, body := requestSealedTokens(t, handler, memberToken, conversationID, info.Epoch, 2)
	if status != http.StatusOK {
		t.Fatalf("tokens status=%d body=%s", status, body)
	}
	const identifiedKey = "identified-key-00000000001"
	createMessage(t, handler, ownerToken, conversationID, identifiedKey, []byte("owner ciphertext"))
	status, response := postSealed(t, handler, sealedPostBody(conversationID, tokens[0], identifiedKey, []byte("member ciphertext"), nil))
	if status != http.StatusConflict || !strings.Contains(string(response), "idempotency_conflict") {
		t.Fatalf("sealed under an identified key status=%d body=%s", status, response)
	}
	// The refused post spent nothing.
	if status, response := postSealed(t, handler, sealedPostBody(conversationID, tokens[0], sealedKey1, []byte("member ciphertext"), nil)); status != http.StatusCreated {
		t.Fatalf("post status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/messages/envelopes", ownerToken, map[string]interface{}{
		"conversation_id": conversationID,
		"idempotency_key": sealedKey1,
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("owner again")),
		"crypto_protocol": "mls10-openmls-v1",
	})
	if status != http.StatusConflict || !strings.Contains(string(response), "idempotency_conflict") {
		t.Fatalf("identified under a sealed key status=%d body=%s", status, response)
	}
}
