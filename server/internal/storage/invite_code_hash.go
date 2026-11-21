package storage

import (
	"database/sql/driver"
	"fmt"
	"strings"

	"modernc.org/sqlite"

	"private-messenger/server/internal/auth"
)

// inviteCodeHashSQLFunction is the SQL name of inviteCodeHash. Migration
// 0094_hash_invite_codes.sql calls it to hash the codes stored before it, so
// it must stay registered for as long as that migration exists: SQLite
// resolves the name when it prepares the statement, even on an empty table,
// and a fresh install that cannot find it fails to start.
const inviteCodeHashSQLFunction = "veritra_invite_code_hash"

func init() {
	// Registered on the "sqlite" driver before any connection opens, so every
	// connection, including the one Migrate uses, has it.
	if err := sqlite.RegisterDeterministicScalarFunction(inviteCodeHashSQLFunction, 1, sqlInviteCodeHash); err != nil {
		panic(fmt.Sprintf("register %s: %v", inviteCodeHashSQLFunction, err))
	}
}

// inviteCodeHash is what the invites table keeps for a registration invite
// code (column code_hash): the same SHA-256 hex the server keeps for session
// tokens and device secrets (auth.HashToken). Codes are 128 random bits, so a
// fast hash is enough; nothing that reads the database or a backup can turn
// it back into a code that registers. Creation, both lookups and migration
// 0094 go through this one function so they cannot drift apart.
func inviteCodeHash(code string) string {
	return auth.HashToken(strings.TrimSpace(code))
}

// sqlInviteCodeHash is inviteCodeHash for SQL. Anything but text fails the
// statement, so a migration that meets an odd row stops instead of storing
// a hash of the wrong bytes.
func sqlInviteCodeHash(_ *sqlite.FunctionContext, args []driver.Value) (driver.Value, error) {
	if len(args) != 1 {
		return nil, fmt.Errorf("%s: want 1 argument", inviteCodeHashSQLFunction)
	}
	switch value := args[0].(type) {
	case string:
		return inviteCodeHash(value), nil
	case []byte:
		return inviteCodeHash(string(value)), nil
	default:
		return nil, fmt.Errorf("%s: invite code is not text", inviteCodeHashSQLFunction)
	}
}
