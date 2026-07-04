# Recovery and Backups

No admin can recover user plaintext.

The intended model is:

- client encrypts backups before upload
- server stores `BackupBlob` ciphertext and metadata only
- recovery phrase/key stays with the user
- QR device linking is preferred for adding devices
- no server-side plaintext keys

The current MVP includes a server API for uploading client-encrypted backup blobs and a short-lived device-link flow with manual link-code entry in Flutter. Device linking requires an existing authenticated device to approve the new device before a session is issued. Backup list/download endpoints, production QR scanning/rendering, client-side cryptographic verification, encrypted backup UX, restore flows, and OpenMLS integration remain TODO.
