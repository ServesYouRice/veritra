package domain

import (
	"testing"
	"time"
)

func TestCanModerate(t *testing.T) {
	cases := []struct {
		actor, target string
		self, want    bool
	}{
		{RoleOwner, RoleAdmin, false, true},
		{RoleAdmin, RoleModerator, false, true},
		{RoleModerator, RoleMember, false, true},
		{RoleModerator, RoleModerator, false, false},
		{RoleAdmin, RoleOwner, false, false},
		{RoleMember, RoleMember, false, false},
		{RoleOwner, RoleMember, true, false},
		{RoleOwner, "bogus", false, false},
	}
	for _, c := range cases {
		if got := CanModerate(c.actor, c.target, c.self); got != c.want {
			t.Errorf("CanModerate(%s,%s,%v)=%v want %v", c.actor, c.target, c.self, got, c.want)
		}
	}
	if !CanDeleteOthersMessage(RoleModerator, RoleMember) || CanDeleteOthersMessage(RoleMember, RoleMember) {
		t.Error("CanDeleteOthersMessage follows CanModerate")
	}
}

func TestTimeoutAndSlowMode(t *testing.T) {
	now := time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)
	if ValidTimeout(0) || !ValidTimeout(time.Hour) || ValidTimeout(MaxTimeout+1) {
		t.Error("ValidTimeout bounds")
	}
	if ValidSlowMode(-1) || !ValidSlowMode(0) || ValidSlowMode(MaxSlowMode+1) {
		t.Error("ValidSlowMode bounds")
	}
	end := now.Add(time.Minute)
	if !TimedOut(&end, now) || TimedOut(&end, end) || TimedOut(nil, now) {
		t.Error("TimedOut")
	}
	last := now.Add(-10 * time.Second)
	if w := SlowModeWait(RoleMember, 30*time.Second, &last, now); w != 20*time.Second {
		t.Errorf("wait=%v", w)
	}
	if SlowModeWait(RoleModerator, 30*time.Second, &last, now) != 0 ||
		SlowModeWait(RoleMember, 0, &last, now) != 0 ||
		SlowModeWait(RoleMember, 30*time.Second, nil, now) != 0 ||
		SlowModeWait(RoleMember, 5*time.Second, &last, now) != 0 {
		t.Error("exemptions")
	}
}
