package httpapi

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"private-messenger/server/internal/devicelist"
	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
)

// Account approved-device lists (L1-2, D94; docs/designs/L1-approved-device-list.md).
// The server stores and serves each account's signed chain. It cannot sign a
// version, so it cannot put a device on a list; it can still refuse, withhold
// or delay versions, which clients treat as the server denying service.
//
// Nothing here logs a statement. The audit trail and the logs carry only the
// account, the version and the change kind.

func (a *API) registerDeviceListRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/accounts/{id}/device-list", a.withAuth(a.getDeviceList))
	mux.HandleFunc("POST /api/v1/device-lists/query", a.withAuth(a.queryDeviceLists))
	mux.HandleFunc("POST /api/v1/account/device-list", a.withAuth(a.publishDeviceList))
}

// checkDeviceListField screens a statement a route accepts before the store
// sees it: it must parse. The parse already refuses a listed key or recovery
// key that is not a usable Ed25519 point (the same screen as the K0 recovery
// verification key, so a small-order key cannot become the key that signs
// change 4). An empty field is fine here; whether it is required is the
// store's call.
func checkDeviceListField(w http.ResponseWriter, statement []byte) bool {
	if len(statement) == 0 {
		return true
	}
	if _, err := devicelist.Parse(statement); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_device_list")
		return false
	}
	return true
}

// publishDeviceListEvent tells the account's own devices that a version landed,
// so they refresh and re-check their groups. Peers get no device-list event:
// they refresh before every decision, which avoids fan-out across large
// communities. A version that adds a device (link approval, recovery) also
// tells peers' group coordinators, through publishMemberLinkNotices.
func (a *API) publishDeviceListEvent(r *http.Request, accountID string, result *storage.DeviceListResult, change devicelist.Change) {
	if result == nil {
		return
	}
	a.publishCommittedEvent(r.Context(), []string{accountID}, realtime.Event{
		Version: "v1", Type: storage.DeviceListEventType, ID: result.EventID,
		Payload: map[string]uint64{"version": result.Version}, CreatedAt: time.Now().UTC(),
	})
	a.recordAuditEvent(r.Context(), &accountID, "account.device_list_updated", map[string]interface{}{"version": result.Version, "change": int(change)})
}

// publishMemberLinkNotices publishes live the D96 coordinator notices a
// committed link approval or recovery version wrote, each to its coordinator
// account only. The payload is the new device and its account, nothing else.
// Like every live event it reaches only open sockets; an app that is closed
// finds the durable event at its next catch-up. No push wake is sent.
func (a *API) publishMemberLinkNotices(ctx context.Context, notices []storage.MemberLinkNotice) {
	for _, notice := range notices {
		a.publishCommittedEvent(ctx, []string{notice.AccountID}, realtime.Event{Version: "v1", Type: storage.MemberLinkEventType, ID: notice.EventID,
			Payload: map[string]string{"account_id": notice.LinkedAccountID, "device_id": notice.DeviceID}, CreatedAt: time.Now().UTC()})
	}
}

type deviceListStatementPayload struct {
	Version   uint64    `json:"version"`
	ListHash  []byte    `json:"list_hash"`
	Statement []byte    `json:"statement"`
	CreatedAt time.Time `json:"created_at"`
}

type deviceListPagePayload struct {
	AccountID   string                       `json:"account_id"`
	HeadVersion uint64                       `json:"head_version"`
	Statements  []deviceListStatementPayload `json:"statements"`
	More        bool                         `json:"more"`
}

func deviceListPageBody(page storage.DeviceListPage) deviceListPagePayload {
	body := deviceListPagePayload{
		AccountID: page.AccountID, HeadVersion: page.HeadVersion, More: page.More,
		Statements: make([]deviceListStatementPayload, 0, len(page.Statements)),
	}
	for _, statement := range page.Statements {
		body.Statements = append(body.Statements, deviceListStatementPayload{
			Version: statement.Version, ListHash: statement.ListHash, Statement: statement.Statement, CreatedAt: statement.CreatedAt,
		})
	}
	return body
}

// getDeviceList serves the statements after ?after=N, at most 64. Readers are
// the account itself and accounts that share a conversation with it. Any other
// request gets the same 404 as an unknown account.
func (a *API) getDeviceList(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var after uint64
	if raw := r.URL.Query().Get("after"); raw != "" {
		parsed, err := strconv.ParseUint(raw, 10, 63)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid_after")
			return
		}
		after = parsed
	}
	pages, err := a.Store.DeviceListsAfter(r.Context(), principal.AccountID, []storage.DeviceListQueryItem{{AccountID: r.PathValue("id"), After: after}})
	if err != nil {
		handleStorageError(w, err)
		return
	}
	if len(pages) != 1 || !pages[0].Found {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, deviceListPageBody(pages[0]))
}

// queryDeviceLists is the batch read: up to 100 {account_id, after} items, at
// most 256 statements in the answer, and `more` per item. An account that is
// unknown or unreadable is {found: false}, the same for both.
func (a *API) queryDeviceLists(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		Items []struct {
			AccountID string `json:"account_id"`
			After     int64  `json:"after"`
		} `json:"items"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if len(req.Items) == 0 || len(req.Items) > storage.DeviceListQueryItemsMax {
		writeError(w, http.StatusBadRequest, "invalid_items")
		return
	}
	items := make([]storage.DeviceListQueryItem, 0, len(req.Items))
	for _, item := range req.Items {
		if item.AccountID == "" || len(item.AccountID) > devicelist.MaxIDBytes || item.After < 0 {
			writeError(w, http.StatusBadRequest, "invalid_items")
			return
		}
		items = append(items, storage.DeviceListQueryItem{AccountID: item.AccountID, After: uint64(item.After)})
	}
	pages, err := a.Store.DeviceListsAfter(r.Context(), principal.AccountID, items)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	type itemPayload struct {
		deviceListPagePayload
		Found bool `json:"found"`
	}
	out := make([]itemPayload, 0, len(pages))
	for _, page := range pages {
		if !page.Found {
			// Unknown and unreadable look the same: just the id and found=false.
			out = append(out, itemPayload{deviceListPagePayload: deviceListPagePayload{AccountID: page.AccountID, Statements: []deviceListStatementPayload{}}})
			continue
		}
		out = append(out, itemPayload{deviceListPagePayload: deviceListPageBody(page), Found: true})
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]interface{}{"items": out})
}

// publishDeviceList takes the versions that have no route of their own:
//
//   - change 6, the migration genesis, with recent auth and only while the
//     account has no list;
//   - change 3, a repair: a listed device removes listed siblings the server
//     already revoked (no recent auth, because nothing is revoked by it);
//   - change 4, recovery: the device recovery completion enrolled, while it is
//     the account's one active device, signed by the head's recovery key (no
//     recent auth: the recovery session has none).
//
// Add and recovery-key versions travel with their own routes.
func (a *API) publishDeviceList(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		DeviceList []byte `json:"device_list"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if len(req.DeviceList) == 0 {
		writeError(w, http.StatusBadRequest, "device_list_required")
		return
	}
	if !checkDeviceListField(w, req.DeviceList) {
		return
	}
	parsed, err := devicelist.Parse(req.DeviceList)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_device_list")
		return
	}
	if principal.DeviceID == "" {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	if parsed.Body.Change == devicelist.ChangeMigrationGenesis && !recentlyAuthenticated(principal) {
		writeError(w, http.StatusForbidden, "recent_auth_required")
		return
	}
	result, notices, err := a.Store.PublishDeviceList(r.Context(), principal.AccountID, principal.DeviceID, req.DeviceList)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	a.publishDeviceListEvent(r, principal.AccountID, &result, parsed.Body.Change)
	// Change 4: the recovered device is now on the head, so peers' group
	// coordinators can add it (D96, as for a link approval).
	a.publishMemberLinkNotices(r.Context(), notices)
	writeJSON(w, http.StatusOK, map[string]uint64{"version": result.Version})
}
