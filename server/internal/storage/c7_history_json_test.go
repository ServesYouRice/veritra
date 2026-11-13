package storage

import (
	"encoding/json"
	"testing"
	"time"
)

// The history and former-member rows as the app parses them
// (mobile/test/c7_history_json_test.dart holds the same text): a change of
// tag here must change the app's parser too, or every imported row would
// read with no epoch and nothing would import.
const (
	c7HistoryRowJSON      = `{"message_id":"msg_1","sender_device_id":"dev_1","action_id":"act_1","channel_id":"chan_1","created_at":"2026-11-12T10:00:00.123456789Z","epoch":7,"body":"AQID"}`
	c7GroupLevelRowJSON   = `{"message_id":"msg_2","sender_device_id":"dev_1","action_id":"act_2","created_at":"2026-11-12T10:00:00Z","body":"BAU="}`
	c7FormerMemberKeyJSON = `{"device_id":"dev_9","account_id":"acct_9","signing_key":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=","revoked":true}`
)

func TestC7HistoryJSONMatchesTheAppParser(t *testing.T) {
	epoch := int64(7)
	for want, value := range map[string]interface{}{
		c7HistoryRowJSON: HistoryBody{
			MessageID: "msg_1", SenderDeviceID: "dev_1", ActionID: "act_1", ChannelID: "chan_1",
			CreatedAt: time.Date(2026, 11, 12, 10, 0, 0, 123456789, time.UTC), Epoch: &epoch, Body: []byte{1, 2, 3},
		},
		c7GroupLevelRowJSON: HistoryBody{
			MessageID: "msg_2", SenderDeviceID: "dev_1", ActionID: "act_2",
			CreatedAt: time.Date(2026, 11, 12, 10, 0, 0, 0, time.UTC), Body: []byte{4, 5},
		},
		c7FormerMemberKeyJSON: FormerMemberKey{
			DeviceID: "dev_9", AccountID: "acct_9", SigningKey: []byte{7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7}, Revoked: true,
		},
	} {
		got, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != want {
			t.Errorf("json = %s\nwant   %s", got, want)
		}
	}
}
