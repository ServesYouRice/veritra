package httpapi

import "testing"

func TestValidUsername(t *testing.T) {
	cases := []struct {
		name     string
		username string
		want     bool
	}{
		{"typical", "owner", true},
		{"with_underscore", "owner_1", true},
		{"with_hyphen", "owner-1", true},
		{"mixed_case", "OwnerOne", true},
		{"min_length", "abc", true},
		{"max_length", "0123456789012345678901234567890a", true}, // 32 chars
		{"leading_trailing_space_trimmed", "  owner  ", true},

		{"too_short", "ab", false},
		{"too_long", "0123456789012345678901234567890ab", false}, // 33 chars
		{"empty", "", false},
		{"whitespace_only", "   ", false},
		{"space_inside", "own er", false},
		{"dot", "own.er", false},
		{"at_sign", "own@er", false},
		{"slash", "own/er", false},
		// Confusable/homoglyph impersonation guard: non-ASCII letters rejected.
		{"cyrillic_homoglyph", "аwner", false}, // Cyrillic 'а' + "wner"
		{"emoji", "owner\U0001F600", false},
		{"accented", "ownér", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := validUsername(tc.username); got != tc.want {
				t.Fatalf("validUsername(%q)=%v want %v", tc.username, got, tc.want)
			}
		})
	}
}
