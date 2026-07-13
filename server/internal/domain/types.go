package domain

import (
	"crypto/rand"
	"encoding/base32"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"strings"
	"time"
)

const (
	RoleOwner     = "owner"
	RoleAdmin     = "admin"
	RoleModerator = "moderator"
	RoleMember    = "member"
)

const (
	DeviceLinkPending  = "pending"
	DeviceLinkClaimed  = "claimed"
	DeviceLinkApproved = "approved"
	DeviceLinkConsumed = "consumed"
	DeviceLinkRevoked  = "revoked"
)

type Principal struct {
	AccountID    string     `json:"account_id"`
	DeviceID     string     `json:"device_id,omitempty"`
	Username     string     `json:"username"`
	Role         string     `json:"role"`
	ExpiresAt    time.Time  `json:"-"`
	RecentAuthAt *time.Time `json:"-"`
}

type Account struct {
	ID        string     `json:"id"`
	Username  string     `json:"username"`
	Email     *string    `json:"email,omitempty"`
	Role      string     `json:"role"`
	Status    string     `json:"status"`
	CreatedAt time.Time  `json:"created_at"`
	DeletedAt *time.Time `json:"deleted_at,omitempty"`
}

type Device struct {
	ID         string     `json:"id"`
	AccountID  string     `json:"account_id"`
	Name       string     `json:"name"`
	KeyPackage []byte     `json:"key_package"`
	SigningKey []byte     `json:"signing_key,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	LastSeenAt *time.Time `json:"last_seen_at,omitempty"`
	RevokedAt  *time.Time `json:"revoked_at,omitempty"`
}

type DeviceKeyPackage struct {
	ID          string    `json:"id"`
	DeviceID    string    `json:"device_id"`
	AccountID   string    `json:"account_id,omitempty"`
	KeyPackage  []byte    `json:"key_package"`
	Ciphersuite string    `json:"ciphersuite"`
	CreatedAt   time.Time `json:"created_at"`
	ExpiresAt   time.Time `json:"expires_at"`
}

type DeviceLink struct {
	ID                string     `json:"id"`
	Code              string     `json:"code,omitempty"`
	AccountID         string     `json:"account_id,omitempty"`
	CreatedByDeviceID string     `json:"created_by_device_id,omitempty"`
	State             string     `json:"state"`
	VerificationCode  string     `json:"verification_code"`
	ClaimedDeviceName *string    `json:"claimed_device_name,omitempty"`
	ApprovedDeviceID  *string    `json:"approved_device_id,omitempty"`
	CreatedAt         time.Time  `json:"created_at"`
	ExpiresAt         time.Time  `json:"expires_at"`
	ClaimedAt         *time.Time `json:"claimed_at,omitempty"`
	ApprovedAt        *time.Time `json:"approved_at,omitempty"`
	ConsumedAt        *time.Time `json:"consumed_at,omitempty"`
	RevokedAt         *time.Time `json:"revoked_at,omitempty"`
}

type Invite struct {
	ID        string     `json:"id"`
	Code      string     `json:"code"`
	CreatedBy string     `json:"created_by"`
	MaxUses   int        `json:"max_uses"`
	Uses      int        `json:"uses"`
	ExpiresAt *time.Time `json:"expires_at,omitempty"`
	CreatedAt time.Time  `json:"created_at"`
	RevokedAt *time.Time `json:"revoked_at,omitempty"`
}

type Community struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	CreatedBy string    `json:"created_by"`
	CreatedAt time.Time `json:"created_at"`
}

type Channel struct {
	ID          string    `json:"id"`
	CommunityID string    `json:"community_id"`
	Name        string    `json:"name"`
	Kind        string    `json:"kind"`
	CreatedAt   time.Time `json:"created_at"`
}

type Conversation struct {
	ID               string    `json:"id"`
	Kind             string    `json:"kind"`
	Title            *string   `json:"title,omitempty"`
	CommunityID      *string   `json:"community_id,omitempty"`
	ChannelID        *string   `json:"channel_id,omitempty"`
	CreatedBy        string    `json:"created_by"`
	RetentionSeconds *int64    `json:"retention_seconds,omitempty"`
	CreatedAt        time.Time `json:"created_at"`
	// LastMessageAt and UnreadCount are populated by ListConversations so the
	// client can order by recent activity and show unread badges. They are
	// zero/omitted on single-conversation responses (create, retention).
	LastMessageAt *time.Time `json:"last_message_at,omitempty"`
	UnreadCount   int64      `json:"unread_count,omitempty"`
	CurrentRole      string    `json:"current_role,omitempty"`
}

type Membership struct {
	AccountID string    `json:"account_id"`
	Role      string    `json:"role"`
	CreatedAt time.Time `json:"created_at"`
}

type MessageEnvelope struct {
	ID              string          `json:"id"`
	ConversationID  string          `json:"conversation_id"`
	SenderAccountID string          `json:"sender_account_id"`
	SenderDeviceID  string          `json:"sender_device_id"`
	IdempotencyKey  string          `json:"idempotency_key"`
	Ciphertext      []byte          `json:"ciphertext"`
	CryptoProtocol  string          `json:"crypto_protocol"`
	CryptoMetadata  json.RawMessage `json:"crypto_metadata"`
	AttachmentRefs  json.RawMessage `json:"attachment_refs"`
	ReplyToID       *string         `json:"reply_to_id,omitempty"`
	ThreadRootID    *string         `json:"thread_root_id,omitempty"`
	CreatedAt       time.Time       `json:"created_at"`
	EditedAt        *time.Time      `json:"edited_at,omitempty"`
	DeletedAt       *time.Time      `json:"deleted_at,omitempty"`
	ExpiresAt       *time.Time      `json:"expires_at,omitempty"`
}

type AttachmentEnvelope struct {
	ID               string          `json:"id"`
	OwnerAccountID   string          `json:"owner_account_id"`
	ConversationID   *string         `json:"conversation_id,omitempty"`
	StorageKey       string          `json:"storage_key"`
	CiphertextSHA256 string          `json:"ciphertext_sha256"`
	SizeBytes        int64           `json:"size_bytes"`
	CryptoMetadata   json.RawMessage `json:"crypto_metadata"`
	CreatedAt        time.Time       `json:"created_at"`
}

type BackupBlob struct {
	ID                    string          `json:"id"`
	AccountID             string          `json:"account_id"`
	DeviceID              *string         `json:"device_id,omitempty"`
	StorageKey            string          `json:"-"`
	CiphertextSHA256      string          `json:"ciphertext_sha256"`
	SizeBytes             int64           `json:"size_bytes"`
	KeyDerivationMetadata json.RawMessage `json:"key_derivation_metadata"`
	CreatedAt             time.Time       `json:"created_at"`
}

type Reaction struct {
	ID                 string    `json:"id"`
	MessageID          string    `json:"message_id"`
	AccountID          string    `json:"account_id"`
	ReactionCiphertext []byte    `json:"reaction_ciphertext"`
	CreatedAt          time.Time `json:"created_at"`
}

type CallSession struct {
	ID             string          `json:"id"`
	ConversationID string          `json:"conversation_id"`
	CreatedBy      string          `json:"created_by"`
	State          string          `json:"state"`
	Metadata       json.RawMessage `json:"metadata"`
	CreatedAt      time.Time       `json:"created_at"`
	EndedAt        *time.Time      `json:"ended_at,omitempty"`
	ExpiresAt      *time.Time      `json:"expires_at,omitempty"`
}

type MetadataSearchResult struct {
	Type  string `json:"type"`
	ID    string `json:"id"`
	Label string `json:"label"`
}

type SyncEvent struct {
	ID             int64           `json:"id"`
	Type           string          `json:"type"`
	AccountID      *string         `json:"account_id,omitempty"`
	ConversationID string          `json:"conversation_id,omitempty"`
	Payload        json.RawMessage `json:"payload"`
	CreatedAt      time.Time       `json:"created_at"`
}

type AccountExport struct {
	ManifestVersion string                       `json:"manifest_version"`
	Account         Account                      `json:"account"`
	Devices         []Device                     `json:"devices"`
	Conversations   []Conversation               `json:"conversations"`
	Messages        []MessageEnvelope            `json:"messages"`
	Categories      map[string][]json.RawMessage `json:"categories"`
}

func CanManageInvites(role string) bool {
	return role == RoleOwner || role == RoleAdmin
}

func CanManageMembers(role string) bool {
	return role == RoleOwner || role == RoleAdmin || role == RoleModerator
}

func RoleRank(role string) int {
	switch role {
	case RoleOwner:
		return 4
	case RoleAdmin:
		return 3
	case RoleModerator:
		return 2
	case RoleMember:
		return 1
	default:
		return 0
	}
}

func ValidRole(role string) bool {
	return RoleRank(role) > 0
}

func NewID(prefix string) (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return prefix + "_" + hex.EncodeToString(b[:]), nil
}

func ValidID(prefix, value string) bool {
	wantPrefix := prefix + "_"
	if !strings.HasPrefix(value, wantPrefix) || len(value) != len(wantPrefix)+32 {
		return false
	}
	_, err := hex.DecodeString(value[len(wantPrefix):])
	return err == nil && value == strings.ToLower(value)
}

func NewInviteCode() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return strings.TrimRight(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b), "="), nil
}

func NewVerificationCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

func NormalizeUsername(username string) string {
	return strings.ToLower(strings.TrimSpace(username))
}
