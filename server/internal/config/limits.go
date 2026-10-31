package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Limits are the per-account admission limits (card I49/T49D). Defaults come
// from the measured tier S host in testing/evidence/T47-capacity.md; see
// docs/operations.md, "Admission limits". A zero field means "use the
// default"; InstanceStorageBytes zero means "derive from the blob volume at
// startup" (DeriveInstanceStorage).
type Limits struct {
	AccountStorageBytes     int64
	InstanceStorageBytes    int64
	AccountBlobs            int
	DevicesPerAccount       int
	ConversationMembers     int
	ConversationsPerAccount int
	// KeyPackageClaimsPerTarget is the most MLS key packages one account may
	// claim from one device of another account in a day. Claims draw down the
	// target's single-use pool (50 packages), so without it any conversation
	// member could empty it.
	KeyPackageClaimsPerTarget int
	// MLSSelfUpdateMinutes is the shortest time between two update-only MLS
	// commits (a self-update that adds and removes no one) from one device
	// in one conversation. Each accepted commit moves the group to a new
	// epoch, so without it one device could churn epochs for everyone.
	MLSSelfUpdateMinutes int
	DeliveriesPerMinute  int
	WriteBytesPerHour    int64
	// AttachmentBytes is the largest file (plaintext) one attachment may
	// hold, counting the zero padding the app adds inside the encryption
	// (it pads to at most this cap); the upload route accepts that plus the
	// chunk framing, see MaxAttachmentCiphertext.
	AttachmentBytes int64
	// SocketsPerIPv6Prefix caps the realtime sockets of all addresses in one
	// IPv6 /64 (an office or home network); one address always gets at most
	// 20.
	SocketsPerIPv6Prefix int
}

const mib = 1 << 20

// Defaults and bounds. The device bound stops at the realtime hub's ten
// sockets per account: an eleventh device could never connect.
const (
	DefaultAccountStorageMiB    = 512
	LegacyInstanceStorageMiB    = 10240 // the cap the derived default never exceeds
	DefaultAccountBlobs         = 10000
	DefaultDevicesPerAccount    = 10
	DefaultConversationMembers  = 100
	DefaultConversationsPerAcct = 1000
	// DefaultKeyPackageClaimsPerTarget is half the 50 packages a device may
	// hold: one account can take at most half the pool of a device per day,
	// which still covers setting up that many groups with it.
	DefaultKeyPackageClaimsPerTarget = 25
	MaxKeyPackageClaimsPerTarget     = 50
	// DefaultMLSSelfUpdateMinutes allows one self-update an hour per device
	// and conversation. Apps refresh after 100 sent messages or 7 days, so
	// only a device sending more than 100 messages an hour in one chat waits.
	DefaultMLSSelfUpdateMinutes  = 60
	MaxMLSSelfUpdateMinutes      = 10080 // 7 days, the apps' time trigger
	DefaultDeliveriesPerMinute   = 1000
	DefaultWriteMiBPerHour       = 64
	DefaultAttachmentMiB         = 48 // what the app encrypts at most
	MaxAttachmentMiB             = 48
	DefaultSocketsPerIPv6Prefix  = 200
	PendingDeviceLinksPerAccount = 3
)

type limitSetting struct {
	key      string
	min, max int64
	scale    int64
	set      func(*Limits, int64)
}

var limitSettings = []limitSetting{
	{"PRIVATE_MESSENGER_LIMIT_ACCOUNT_STORAGE_MIB", 16, 1 << 20, mib, func(l *Limits, v int64) { l.AccountStorageBytes = v }},
	{"PRIVATE_MESSENGER_LIMIT_INSTANCE_STORAGE_MIB", 64, 1 << 24, mib, func(l *Limits, v int64) { l.InstanceStorageBytes = v }},
	{"PRIVATE_MESSENGER_LIMIT_ACCOUNT_BLOBS", 100, 1_000_000, 1, func(l *Limits, v int64) { l.AccountBlobs = int(v) }},
	{"PRIVATE_MESSENGER_LIMIT_DEVICES_PER_ACCOUNT", 1, 10, 1, func(l *Limits, v int64) { l.DevicesPerAccount = int(v) }},
	{"PRIVATE_MESSENGER_LIMIT_CONVERSATION_MEMBERS", 2, 1000, 1, func(l *Limits, v int64) { l.ConversationMembers = int(v) }},
	{"PRIVATE_MESSENGER_LIMIT_CONVERSATIONS_PER_ACCOUNT", 10, 10_000, 1, func(l *Limits, v int64) { l.ConversationsPerAccount = int(v) }},
	{"PRIVATE_MESSENGER_LIMIT_KEY_PACKAGE_CLAIMS_PER_TARGET", 1, MaxKeyPackageClaimsPerTarget, 1, func(l *Limits, v int64) { l.KeyPackageClaimsPerTarget = int(v) }},
	{"PRIVATE_MESSENGER_LIMIT_MLS_SELF_UPDATE_MINUTES", 1, MaxMLSSelfUpdateMinutes, 1, func(l *Limits, v int64) { l.MLSSelfUpdateMinutes = int(v) }},
	{"PRIVATE_MESSENGER_LIMIT_DELIVERIES_PER_MINUTE", 60, 1_000_000, 1, func(l *Limits, v int64) { l.DeliveriesPerMinute = int(v) }},
	{"PRIVATE_MESSENGER_LIMIT_WRITE_MIB_PER_HOUR", 16, 65_536, mib, func(l *Limits, v int64) { l.WriteBytesPerHour = v }},
	{"PRIVATE_MESSENGER_LIMIT_ATTACHMENT_MIB", 1, MaxAttachmentMiB, mib, func(l *Limits, v int64) { l.AttachmentBytes = v }},
	{"PRIVATE_MESSENGER_LIMIT_SOCKETS_PER_IPV6_PREFIX", 20, 10_000, 1, func(l *Limits, v int64) { l.SocketsPerIPv6Prefix = int(v) }},
}

func loadLimits() (Limits, error) {
	var limits Limits
	for _, setting := range limitSettings {
		raw := strings.TrimSpace(os.Getenv(setting.key))
		if raw == "" {
			continue
		}
		value, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || value < setting.min || value > setting.max {
			return Limits{}, fmt.Errorf("%s must be a whole number between %d and %d", setting.key, setting.min, setting.max)
		}
		setting.set(&limits, value*setting.scale)
	}
	if err := limits.WithDefaults().Validate(); err != nil {
		return Limits{}, err
	}
	return limits, nil
}

// WithDefaults fills every zero field except InstanceStorageBytes, which
// stays zero until DeriveInstanceStorage resolves it.
func (l Limits) WithDefaults() Limits {
	if l.AccountStorageBytes == 0 {
		l.AccountStorageBytes = DefaultAccountStorageMiB * mib
	}
	if l.AccountBlobs == 0 {
		l.AccountBlobs = DefaultAccountBlobs
	}
	if l.DevicesPerAccount == 0 {
		l.DevicesPerAccount = DefaultDevicesPerAccount
	}
	if l.ConversationMembers == 0 {
		l.ConversationMembers = DefaultConversationMembers
	}
	if l.ConversationsPerAccount == 0 {
		l.ConversationsPerAccount = DefaultConversationsPerAcct
	}
	if l.KeyPackageClaimsPerTarget == 0 {
		l.KeyPackageClaimsPerTarget = DefaultKeyPackageClaimsPerTarget
	}
	if l.MLSSelfUpdateMinutes == 0 {
		l.MLSSelfUpdateMinutes = DefaultMLSSelfUpdateMinutes
	}
	if l.DeliveriesPerMinute == 0 {
		l.DeliveriesPerMinute = DefaultDeliveriesPerMinute
	}
	if l.WriteBytesPerHour == 0 {
		l.WriteBytesPerHour = DefaultWriteMiBPerHour * mib
	}
	if l.AttachmentBytes == 0 {
		l.AttachmentBytes = DefaultAttachmentMiB * mib
	}
	if l.SocketsPerIPv6Prefix == 0 {
		l.SocketsPerIPv6Prefix = DefaultSocketsPerIPv6Prefix
	}
	return l
}

// MaxAttachmentCiphertext is the most ciphertext the upload route accepts
// for a file of at most plaintext bytes: the app seals 1 MiB chunks, each
// with a 4-byte length and a 16-byte tag (mobile attachment_crypto.dart).
func MaxAttachmentCiphertext(plaintext int64) int64 {
	chunks := (plaintext + mib - 1) / mib
	return plaintext + chunks*(4+16)
}

// Validate checks the relations between limits. A message to a full
// conversation reserves 1 + ConversationMembers deliveries, so the minute's
// budget must hold at least two such messages.
func (l Limits) Validate() error {
	if l.DeliveriesPerMinute < 2*(1+l.ConversationMembers) {
		return fmt.Errorf("PRIVATE_MESSENGER_LIMIT_DELIVERIES_PER_MINUTE must be at least twice (1 + PRIVATE_MESSENGER_LIMIT_CONVERSATION_MEMBERS), %d", 2*(1+l.ConversationMembers))
	}
	if l.InstanceStorageBytes != 0 && l.AccountStorageBytes > l.InstanceStorageBytes {
		return fmt.Errorf("PRIVATE_MESSENGER_LIMIT_ACCOUNT_STORAGE_MIB must not exceed PRIVATE_MESSENGER_LIMIT_INSTANCE_STORAGE_MIB")
	}
	return nil
}

// DeriveInstanceStorage is the default instance storage limit for a blob
// volume of volumeBytes when backupKeep scheduled backups are kept. A backup
// run copies every blob and its restore drill restores one more copy, so
// the volume must hold (keep + 3) times the live data; 10% stays free. The
// result never exceeds the former fixed 10 GiB, and is at least 64 MiB.
func DeriveInstanceStorage(volumeBytes int64, backupKeep int) int64 {
	if backupKeep < 1 {
		backupKeep = 1
	}
	derived := volumeBytes / 10 * 9 / int64(backupKeep+3)
	derived = derived / mib * mib
	return min(max(derived, 64*mib), LegacyInstanceStorageMiB*mib)
}
