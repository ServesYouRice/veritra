# Data Model

The server data model is built around encrypted envelopes.

Core entities:

- Instance
- Account
- Device
- DeviceLink
- Invite
- Community
- Channel
- Conversation
- Membership
- Role
- MessageEnvelope
- AttachmentEnvelope
- ReactionEnvelope
- ReadReceipt
- PushSubscription
- BackupBlob
- CallSession
- AuditEvent metadata

`MessageEnvelope` includes IDs, sender account/device, conversation/channel, ciphertext, crypto protocol metadata, timestamps, edit/delete markers, delivery metadata, and attachment refs. It never includes plaintext message body fields.

`DeviceLink` tracks a short-lived one-time code, verification code, claim token hash, approval state, and the new device public key-package metadata. It never stores private device keys.
