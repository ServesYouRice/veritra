# Recovery and Backups

No admin can recover user plaintext.

The intended model is:

- client encrypts backups before upload
- server stores `BackupBlob` ciphertext and metadata only
- recovery phrase/key stays with the user
- QR device linking is preferred for adding devices
- no server-side plaintext keys

The server supports authorized upload, list, download, and deletion of client-encrypted backup blobs. Instance backup creates a versioned directory manifest containing the SQLite snapshot, referenced ciphertext blobs, checksums, and migration versions; restore validates into staging before an atomic swap with rollback.

Device linking requires an existing authenticated device to compare the verification code and approve the new device before a session is issued. An offline `reset-owner-password` command is available while the server is stopped; it revokes sessions and cannot recover message keys or plaintext.

Production OpenMLS integration, cryptographic device verification, and client backup creation/restore UX remain release blockers. The release workflow fails while the fail-closed crypto service is wired.
