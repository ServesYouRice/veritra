/// What the Windows update channel trusts (W12, docs/release-engineering.md,
/// "Update channel"). Both values are set by the owner, in a reviewed pull
/// request, once the update signing key exists. Nothing else decides whether a
/// downloaded feed is genuine.
library;

/// The signed feed: `update.json`, with its detached signature at the same
/// address plus `.sig`. GitHub serves the latest release's asset under this
/// address; the signature, not the host, is what is trusted.
const String updateFeedUrl =
    'https://github.com/ServesYouRice/veritra/releases/latest/download/update.json';

/// The update signing key's Ed25519 public key: 32 bytes as 64 lowercase hex
/// characters (`scripts/update-feed.py keygen` prints it). Empty until the
/// owner generates the key. It is a different key from the Windows
/// code-signing certificate. While it is empty, or while the app has no
/// Ed25519 verification for the feed, the update check does not contact the
/// network at all (see [UpdateService]).
const String updateFeedPublicKeyHex = '';
