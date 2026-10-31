package storage

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"private-messenger/server/internal/domain"
)

func conversationIDs(conversations []domain.Conversation) []string {
	ids := make([]string, 0, len(conversations))
	for _, c := range conversations {
		ids = append(ids, c.ID)
	}
	return ids
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

type conversationPageFixture struct {
	store         *Store
	owner, reader AccountDevice
	// conversations are ordered oldest activity first.
	conversations []domain.Conversation
}

// newConversationPageFixture gives the reader count group conversations, each
// with one visible message from the owner, one second apart.
func newConversationPageFixture(t *testing.T, ctx context.Context, count int) conversationPageFixture {
	t.Helper()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	reader := registerTestMember(t, ctx, store, invite.Code, "reader")
	f := conversationPageFixture{store: store, owner: owner, reader: reader}
	base := parseTime("2026-01-01T00:00:00.000000000Z")
	for i := 0; i < count; i++ {
		conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{reader.Account.ID}})
		if err != nil {
			t.Fatal(err)
		}
		insertRawMessage(t, ctx, store, conversation.ID, owner, fmt.Sprintf("msg_page_%02d", i), formatTime(base.Add(time.Duration(i)*time.Second)))
		f.conversations = append(f.conversations, conversation)
	}
	return f
}

func TestListConversationsPageStableCursor(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(t *testing.T, ctx context.Context, f conversationPageFixture)
	}{
		{"cursor conversation gets a new message", func(t *testing.T, ctx context.Context, f conversationPageFixture) {
			insertRawMessage(t, ctx, f.store, f.conversations[3].ID, f.owner, "msg_cursor_new", formatTime(parseTime("2026-02-01T00:00:00.000000000Z")))
		}},
		{"cursor conversation loses its last message", func(t *testing.T, ctx context.Context, f conversationPageFixture) {
			if _, err := f.store.db.ExecContext(ctx, `UPDATE message_envelopes SET deleted_at = ? WHERE conversation_id = ?`, nowString(), f.conversations[3].ID); err != nil {
				t.Fatal(err)
			}
		}},
		{"requester leaves the cursor conversation", func(t *testing.T, ctx context.Context, f conversationPageFixture) {
			if _, err := f.store.db.ExecContext(ctx, `DELETE FROM memberships WHERE conversation_id = ? AND account_id = ?`, f.conversations[3].ID, f.reader.Account.ID); err != nil {
				t.Fatal(err)
			}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			f := newConversationPageFixture(t, ctx, 5)
			// conversations[4] is the newest, so a page of two ends at [3].
			page1, err := f.store.ListConversationsPageFrom(ctx, f.reader.Account.ID, 2, ConversationCursor{})
			if err != nil {
				t.Fatal(err)
			}
			if got, want := conversationIDs(page1), []string{f.conversations[4].ID, f.conversations[3].ID}; !equalStrings(got, want) {
				t.Fatalf("page 1 = %v, want %v", got, want)
			}
			last := page1[len(page1)-1]
			cursor := ConversationCursor{BeforeID: last.ID, BeforeActivity: *last.LastMessageAt}
			tc.mutate(t, ctx, f)
			var rest []string
			for pages := 0; pages < 5; pages++ {
				page, err := f.store.ListConversationsPageFrom(ctx, f.reader.Account.ID, 2, cursor)
				if err != nil {
					t.Fatalf("page after the cursor: %v", err)
				}
				if len(page) == 0 {
					break
				}
				rest = append(rest, conversationIDs(page)...)
				tail := page[len(page)-1]
				cursor = ConversationCursor{BeforeID: tail.ID, BeforeActivity: *tail.LastMessageAt}
			}
			want := []string{f.conversations[2].ID, f.conversations[1].ID, f.conversations[0].ID}
			if !equalStrings(rest, want) {
				t.Fatalf("pages after the cursor = %v, want %v (no repeats, no gaps)", rest, want)
			}
		})
	}
}

func TestListConversationsPageIDOnlyCursorFailsWhenConversationIsGone(t *testing.T) {
	ctx := context.Background()
	f := newConversationPageFixture(t, ctx, 4)
	page1, err := f.store.ListConversationsPage(ctx, f.reader.Account.ID, 2, "")
	if err != nil {
		t.Fatal(err)
	}
	cursor := page1[len(page1)-1].ID
	rest, err := f.store.ListConversationsPage(ctx, f.reader.Account.ID, 2, cursor)
	if err != nil || len(rest) != 2 {
		t.Fatalf("id-only cursor: %d conversations, err = %v, want the remaining 2", len(rest), err)
	}
	if _, err := f.store.db.ExecContext(ctx, `DELETE FROM memberships WHERE conversation_id = ? AND account_id = ?`, cursor, f.reader.Account.ID); err != nil {
		t.Fatal(err)
	}
	if page, err := f.store.ListConversationsPage(ctx, f.reader.Account.ID, 2, cursor); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("id-only cursor of a conversation the account left: %d conversations, err = %v, want %v", len(page), err, ErrInvalidInput)
	}
	if _, err := f.store.ListConversationsPageFrom(ctx, f.reader.Account.ID, 2, ConversationCursor{BeforeActivity: time.Now()}); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("activity without a conversation id: err = %v, want %v", err, ErrInvalidInput)
	}
}
