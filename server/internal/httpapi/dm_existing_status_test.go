package httpapi_test

import (
	"encoding/json"
	"net/http"
	"testing"
)

// D67 (TASK-054 Q-004): creating a DM answers 201 when the server made it
// and 200 when the pair already had one, with the same body either way, so
// a client never builds a second MLS group for an existing DM.
func TestCreateDMAnswers200ForAnExistingDM(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwnerDevice(t)
	ownerID := accountIDFromExport(t, handler, ownerToken)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "dmstatusmember")

	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken, map[string]interface{}{
		"kind":               "dm",
		"member_account_ids": []string{memberID},
	})
	if status != http.StatusCreated {
		t.Fatalf("new DM status=%d body=%s", status, response)
	}
	var created map[string]interface{}
	if err := json.Unmarshal(response, &created); err != nil {
		t.Fatalf("decode new DM: %v", err)
	}

	for _, retry := range []struct {
		name, token, peer string
	}{
		{"peer", memberToken, ownerID},
		{"creator", ownerToken, memberID},
	} {
		status, response = doJSON(t, handler, http.MethodPost, "/api/v1/conversations", retry.token, map[string]interface{}{
			"kind":               "dm",
			"member_account_ids": []string{retry.peer},
		})
		if status != http.StatusOK {
			t.Fatalf("%s: existing DM status=%d body=%s", retry.name, status, response)
		}
		var existing map[string]interface{}
		if err := json.Unmarshal(response, &existing); err != nil {
			t.Fatalf("%s: decode existing DM: %v", retry.name, err)
		}
		for _, key := range []string{"id", "kind", "created_by", "created_at"} {
			if existing[key] != created[key] {
				t.Fatalf("%s: %s=%v want %v", retry.name, key, existing[key], created[key])
			}
		}
	}

	// A group is always new.
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken, map[string]interface{}{
		"kind":               "group",
		"member_account_ids": []string{memberID},
	})
	if status != http.StatusCreated {
		t.Fatalf("group status=%d body=%s", status, response)
	}
}
