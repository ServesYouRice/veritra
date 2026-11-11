package domain

import "testing"

func TestRolePermissions(t *testing.T) {
	if !CanManageInvites(RoleOwner) || !CanManageInvites(RoleAdmin) {
		t.Fatal("owner and admin should manage invites")
	}
	if CanManageInvites(RoleModerator) || CanManageInvites(RoleMember) {
		t.Fatal("moderator/member should not manage global invites")
	}
	if !CanManageMembers(RoleModerator) {
		t.Fatal("moderator should manage members in the simple v1 model")
	}
	if !CanCreateChannels(RoleOwner) || !CanCreateChannels(RoleAdmin) {
		t.Fatal("owner and admin should be allowed to create channels")
	}
	if CanCreateChannels(RoleModerator) || CanCreateChannels(RoleMember) {
		t.Fatal("moderator and member must not create channels (owner decision)")
	}
}
