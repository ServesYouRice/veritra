#ifndef VERITRA_CRYPTO_H
#define VERITRA_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#define PM_CRYPTO_UNAVAILABLE (-1)
#define PM_CRYPTO_ABI_VERSION (26u)
#define PM_CRYPTO_OK (0)
#define PM_CRYPTO_INVALID_ARGUMENT (-2)
#define PM_CRYPTO_ERROR (-3)
#define PM_CRYPTO_PANIC (-4)
/* Decrypted, but the MLS sender is not the claimed account/device (ABI 5). */
#define PM_CRYPTO_SENDER_MISMATCH (-5)
/* pm_crypto_restore_begin and pm_crypto_device_migrate_v3 only (ABI 9,
 * restore split in ABI 10): the sealed state has the right magic but a
 * format version this call does not read (format 1 from OpenMLS 0.8.1, a
 * format 2/3 blob given to the restore, a format 4 root given to the
 * migration, or a newer build). The version is NOT authenticated: it may lead
 * only to a re-link/re-provision flow, never to weaker checks. Wrong key,
 * tampering, identity mismatch and corruption stay PM_CRYPTO_ERROR. */
#define PM_CRYPTO_STATE_FORMAT_UNSUPPORTED (-6)
/* ABI 9: decrypted from a retained past epoch, but the sender has left the
 * group. The ratchet has advanced: commit state, keep no content, exactly as
 * for PM_CRYPTO_SENDER_MISMATCH. */
#define PM_CRYPTO_SENDER_REMOVED (-7)
/* ABI 10, pm_crypto_device_seal_changes only: a sealed record would be over
 * its cap (D70). Nothing was sealed; *out holds u8 kind || id (1 device,
 * 2 group, 3 key package) and must be freed. Restore the committed state
 * before going on. */
#define PM_CRYPTO_RECORD_LIMIT (-8)
/* ABI 10, pm_crypto_group_join only: the Welcome names no key package this
 * device holds, or the one it names has expired (D74). Nothing was
 * consumed; the device has to be added again. */
#define PM_CRYPTO_WELCOME_KEY_PACKAGE_UNAVAILABLE (-9)
/* ABI 13 (C7), pm_crypto_c7_open and pm_crypto_group_c7_*: the key does not
 * match the sealed value's commitment. Not a data failure: try the next
 * candidate key. Nothing was decrypted. */
#define PM_CRYPTO_C7_KEY_MISMATCH (-10)
/* ABI 13 (C7): bits of the out_flags the commit calls write. */
#define PM_CRYPTO_C7_COMMIT_REMOVED (1u)      /* at least one Remove */
#define PM_CRYPTO_C7_COMMIT_ADDED (2u)        /* at least one Add */
#define PM_CRYPTO_C7_COMMIT_REMOVED_SELF (4u) /* this device was removed */
/* ABI 14 (L1, the approved-device list). A device-list statement or input is
 * not a canonical statement. Checks run in the order malformed, chain, rule,
 * signature, so a statement with one fault reports it. */
#define PM_CRYPTO_L1_MALFORMED (-11)
/* The signature does not verify under the key the rules name. */
#define PM_CRYPTO_L1_SIGNATURE (-12)
/* Wrong account, version or prev_hash, or no genesis. */
#define PM_CRYPTO_L1_CHAIN (-13)
/* The signer may not make this change, or the entries are not what the change
 * allows (also: a body this device may not sign). */
#define PM_CRYPTO_L1_RULE (-14)
/* pm_crypto_l1_sign_recovery with no entropy given and no seed held. */
#define PM_CRYPTO_L1_NO_SEED (-15)

typedef struct {
  const uint8_t *data;
  size_t len;
} PmByteSlice;

typedef struct {
  uint8_t *data;
  size_t capacity;
  size_t *written;
} PmOutputBuffer;

typedef struct {
  PmByteSlice account_id;
  PmByteSlice device_id;
  PmByteSlice signing_public_key;
} PmDeviceCredentialInput;

typedef struct PmCryptoHandle PmCryptoHandle;
typedef struct PmHistoryStream PmHistoryStream;

typedef struct {
  uint8_t *data;
  size_t len;
} PmOwnedBuffer;

uint32_t pm_crypto_abi_version(void);
int32_t pm_crypto_available(void);
const char *pm_crypto_protocol(void);

/*
 * Device handles and owned buffers are library-owned. A successful handle must
 * be destroyed exactly once. A non-empty owned buffer must be freed exactly
 * once; freeing zeroes its contents before releasing memory. Each buffer is
 * an exact-length allocation, and the library wipes any copy it drops,
 * including an output refused because its target pointer was NULL.
 *
 * These ownership and group-lifecycle primitives are available for binding
 * development, but pm_crypto_available() remains PM_CRYPTO_UNAVAILABLE until
 * enrollment, both mobile bindings, recovery, and independent review are
 * complete.
 */
int32_t pm_crypto_device_create(PmByteSlice account_id, PmByteSlice device_id,
                                PmCryptoHandle **out_handle);
/*
 * ABI 10 (D70): the sealed state is a root (the singleton, at most 16 MiB +
 * 4 KiB) and one record per owner (at most 32 MiB + 4 KiB each). A restore
 * reads the root and every stored record in one transaction, then: begin
 * (the root's generation, at least minimum_generation, must equal the
 * stored counter), add each record, and finish. Any missing, extra, stale,
 * foreign or altered record fails it. finish and abort spend the token;
 * any later use is PM_CRYPTO_INVALID_ARGUMENT.
 */
int32_t pm_crypto_restore_begin(PmByteSlice account_id, PmByteSlice device_id,
                                PmByteSlice state_key,
                                uint64_t minimum_generation,
                                PmByteSlice sealed_root, uint64_t *out_loader,
                                uint64_t *out_generation);
int32_t pm_crypto_restore_add(uint64_t loader, PmByteSlice sealed_record);
int32_t pm_crypto_restore_finish(uint64_t loader, PmCryptoHandle **out_handle,
                                 uint64_t *out_generation);
int32_t pm_crypto_restore_abort(uint64_t loader);
/*
 * ABI 10: opens a format 2/3 blob (at most 32 MiB) stored at counter for the
 * one-way migration. Inactive groups and unowned key pairs are dropped
 * (*out_dropped). Every record is pending: seal_changes at counter + 1 and
 * store the root and all records, deleting records stored beside the old
 * blob, in one compare-and-swap transaction.
 */
int32_t pm_crypto_device_migrate_v3(PmByteSlice account_id,
                                    PmByteSlice device_id,
                                    PmByteSlice state_key, uint64_t counter,
                                    PmByteSlice sealed_state,
                                    PmCryptoHandle **out_handle,
                                    uint64_t *out_dropped);
void pm_crypto_device_destroy(PmCryptoHandle *handle);
void pm_crypto_buffer_free(PmOwnedBuffer buffer);
int32_t pm_crypto_device_signing_public_key(PmCryptoHandle *handle,
                                            PmOwnedBuffer *out);
/* ABI 7: returns the 32-byte public locator. */
int32_t pm_crypto_device_link_locator(PmByteSlice secret, PmOwnedBuffer *out);
/* ABI 11 (K0 R1): the recovery key (RK). The entropy is 30 bytes; the
 * display is 52 Crockford base32 characters (upper case, no separators) of
 * entropy || 2-byte check. Decode is case-insensitive, reads O as 0 and I/L
 * as 1, ignores '-' and ' ', and refuses anything else, a wrong check or
 * non-zero padding bits with PM_CRYPTO_INVALID_ARGUMENT. Derive returns
 * rk_pub (32), rk_id (16), rk_auth_pub (32) and, since ABI 14 (L1),
 * rk_list_pub (32, the public key of the device-list recovery signer,
 * HKDF-Expand(PRK, "veritra-k0 device-list", 32) as an Ed25519 seed); no
 * private key or seed ever crosses the ABI. The proof is an Ed25519 signature (64) by the RK auth key
 * over "veritra-k0-recovery-proof-v1" | lp(challenge) | signing_key (32) |
 * SHA-256(key_package) | lp(origin), lp a u16 big-endian length; the label is
 * fixed, so this key signs nothing else. Vector:
 * testing/vectors/k0-recovery-v1.json. */
int32_t pm_crypto_recovery_key_generate(PmOwnedBuffer *out_entropy);
int32_t pm_crypto_recovery_key_encode(PmByteSlice entropy,
                                      PmOwnedBuffer *out_display);
int32_t pm_crypto_recovery_key_decode(PmByteSlice display,
                                      PmOwnedBuffer *out_entropy);
int32_t pm_crypto_recovery_key_derive(PmByteSlice entropy,
                                      PmOwnedBuffer *out_rk_pub,
                                      PmOwnedBuffer *out_rk_id,
                                      PmOwnedBuffer *out_rk_auth_pub,
                                      PmOwnedBuffer *out_rk_list_pub);
int32_t pm_crypto_recovery_proof_sign(PmByteSlice entropy,
                                      PmByteSlice challenge,
                                      PmByteSlice signing_key,
                                      PmByteSlice key_package,
                                      PmByteSlice origin,
                                      PmOwnedBuffer *out_signature);
/* ABI 12 (C6 reports, D80). The report key is a 32-byte seed the recipient
 * app keeps secret; key_public derives the X25519 public key through
 * HKDF-SHA256 (salt "veritra-c6-report-key-v1", info
 * "veritra-c6 report-hpke") and RFC 9180 DeriveKeyPair. No private key
 * crosses the ABI. Seal is RFC 9180 base mode, DHKEM(X25519, HKDF-SHA256),
 * HKDF-SHA256, AES-256-GCM, info "veritra-c6-report-v1" fixed in Rust; aad is
 * 1 to 1024 bytes and required; plaintext 1 byte to 256 KiB. Output is
 * "VRP1" || enc (32) || ciphertext. A bad or low-order public key is
 * PM_CRYPTO_INVALID_ARGUMENT; open of altered bytes, a wrong aad or a wrong
 * key is PM_CRYPTO_ERROR. frank_commit returns HMAC-SHA256(key,
 * "veritra-frank-v1" | lp(conversation_id) | lp(sender_device_id) |
 * lp(action_id) | lp(payload)), lp a u32 big-endian length; key 32 bytes,
 * ids 1 to 128 bytes, payload 1 byte to 64 KiB. On any failure *out is left
 * untouched (the caller's null/zero buffer stays null/zero); only a success
 * writes an owned buffer. Vector: testing/vectors/c6-franking-v1.json. */
int32_t pm_crypto_report_key_generate(PmOwnedBuffer *out_seed);
int32_t pm_crypto_report_key_public(PmByteSlice seed,
                                    PmOwnedBuffer *out_public);
int32_t pm_crypto_report_seal(PmByteSlice recipient_public, PmByteSlice aad,
                              PmByteSlice plaintext,
                              PmOwnedBuffer *out_sealed);
int32_t pm_crypto_report_open(PmByteSlice seed, PmByteSlice aad,
                              PmByteSlice sealed,
                              PmOwnedBuffer *out_plaintext);
int32_t pm_crypto_frank_commit(PmByteSlice key, PmByteSlice conversation_id,
                               PmByteSlice sender_device_id,
                               PmByteSlice action_id, PmByteSlice payload,
                               PmOwnedBuffer *out_commit);
/* ABI 8 control frames: PK2Q/PK2R v1, u16-BE operation, bounded64KiB.
 * See docs/designs/K2-abi8-boundary.md for exact fields and persistence rules.
 * Each success returns one owned buffer. Failure resets out to null/zero.
 * source_confirm NEVER returns approval_tag. Persist its intent/state before
 * calling source_approval_request or sending HTTP. No private key is exported.
 * Bundle stream symbols are reserved for a later complete implementation. */
int32_t pm_crypto_k2_receive_begin(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_source_accept(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_inspect(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_enrollment_proof(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_source_confirm(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_source_approval_request(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_apply_approval(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_source_posted(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_importing(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_forget(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_expire(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
/* ABI 18 (L1-3, docs/designs/L1-3-link-commitment.md): protocol
 * veritra-device-link-v4. The context carries the existing device's
 * commitment and the new device's random. reveal_sas is read-only: it
 * opens the commitment with the revealed random and returns the 8-digit
 * SAS (about 26.6 bits; with commit-then-reveal a relay gets one 10^-8
 * guess per run). source_commitment hashes this device's own id and key.
 * The v2 derivation pm_crypto_device_link_transcript_hash was removed. */
int32_t pm_crypto_k2_reveal_sas(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_source_commitment(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
/* ABI8 bounded bundle streams. One large stream process-wide. All results
 * use PK2R framing; write/read chunks max1MiB, total padded frame max64MiB.
 * Incoming read fails until receive_finish authenticates the complete bundle.
 * Device destroy invalidates/wipes the stream; destroy the stream pointer once
 * afterward too. Never persist pointers or write plaintext snapshots to disk.
 * source_finish/receive_begin_bundle include the verified transfer ID.
 * Persist ciphertext cache+exact opaque handoff+sealed state before HTTP. */
int32_t pm_crypto_k2_source_begin(PmCryptoHandle *, PmByteSlice,
    PmHistoryStream **, PmOwnedBuffer *);
int32_t pm_crypto_k2_receive_begin_bundle(PmCryptoHandle *, PmByteSlice,
    PmHistoryStream **, PmOwnedBuffer *);
int32_t pm_crypto_k2_stream_write(PmHistoryStream *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_stream_read(PmHistoryStream *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_source_finish(PmCryptoHandle *, PmHistoryStream *,
    PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_receive_finish(PmCryptoHandle *, PmHistoryStream *,
    PmByteSlice, PmOwnedBuffer *);
void pm_crypto_k2_stream_destroy(PmHistoryStream *);
/* ABI 23 (L2-1): the key package is padded to a size bucket (see
 * pm_crypto_l2_padded_size) by one extension of type 0xF0A2 whose data is
 * zero bytes, and its leaf lists 0xF0A2 in its capabilities. */
int32_t pm_crypto_device_create_key_package(PmCryptoHandle *handle,
                                            PmOwnedBuffer *out);
/* ABI 9: the only enrollment signature. It covers
 * "veritra-enrollment-proof-v1" || u16-BE len || challenge || signing key ||
 * SHA-256(key package); the raw challenge signer was removed. */
int32_t pm_crypto_device_create_enrollment_credential(
    PmCryptoHandle *handle, PmByteSlice challenge,
    PmOwnedBuffer *out_key_package, PmOwnedBuffer *out_signing_public_key,
    PmOwnedBuffer *out_challenge_signature);
/*
 * ABI 10: seals what changed since the last seal or restore at generation,
 * which must be the stored counter + 1. *out (at most 128 MiB) is
 * u32 root_len || root || u32 count || count x (u8 kind || u16 id_len || id
 * || u64 generation || u8 present || [u32 len || sealed if present]),
 * big-endian; present 0 deletes the record. Store all of it with the root
 * at generation in the same transaction as the change it records. After any
 * failure, or a store that did not commit, restore the committed state.
 */
int32_t pm_crypto_device_seal_changes(PmCryptoHandle *handle,
                                      PmByteSlice state_key,
                                      uint64_t generation, PmOwnedBuffer *out);
/* ABI 10: drops this device's state for a group the user deleted; never
 * for a removal (already dropped). *out_deleted is 1 if one was stored. */
int32_t pm_crypto_group_delete(PmCryptoHandle *handle, PmByteSlice group_id,
                               uint8_t *out_deleted);
/* ABI 10: drops key packages expired more than 24 hours before now. */
int32_t pm_crypto_device_prune_key_packages(PmCryptoHandle *handle,
                                            uint64_t now_unix_seconds,
                                            uint64_t *out_removed);
int32_t pm_crypto_group_create(PmCryptoHandle *handle, PmByteSlice group_id);
/*
 * Joins the group carried by a Welcome for expected_group_id. Applying its
 * own removal drops a device's group (ABI 10), so a re-add is a fresh join.
 * An active stored group is never replaced: PM_CRYPTO_ERROR, with the group
 * and the key package kept, until the device has processed its removal
 * commit. A Welcome for a key package this device lacks or that expired is
 * PM_CRYPTO_WELCOME_KEY_PACKAGE_UNAVAILABLE. See docs/crypto.md,
 * "Rejoining a conversation".
 */
int32_t pm_crypto_group_join(PmCryptoHandle *handle,
                             PmByteSlice expected_group_id,
                             PmByteSlice welcome);
/*
 * Deprecated, tests only. Merges its commit at once, before the server has
 * accepted it, so a commit that loses the epoch race forks this device. Not
 * used by the app; use pm_crypto_group_stage_commit, then
 * pm_crypto_group_merge_pending_commit after the server accepts it.
 */
int32_t pm_crypto_group_add_member(PmCryptoHandle *handle,
                                   PmByteSlice group_id,
                                   PmByteSlice key_package,
                                   PmByteSlice expected_account_id,
                                   PmByteSlice expected_device_id,
                                   PmOwnedBuffer *out_commit,
                                   PmOwnedBuffer *out_welcome);
/*
 * ABI 6 (card I51): one staged, unmerged commit adding and removing devices.
 * changes: version:u8(=1) add_count:u16 {kp_len:u32 kp account_len:u16
 * account device_len:u16 device}* remove_count:u16 {account_len:u16 account
 * device_len:u16 device}*, big-endian. out_welcome is empty (NULL, 0) when
 * nothing is added. Merge after the server accepts the commit; clear it
 * after a refusal.
 * An empty list (add_count 0, remove_count 0) stages a self-update: a commit
 * with an update path and no proposals that refreshes this device's leaf key
 * (2026-10-31; earlier ABI 9 builds refuse an empty list).
 * ABI 14 (L1): version 2 of the list (version:u8 = 2) puts the 32-byte
 * signature key each key package must hold after each add's device id; a key
 * package with another leaf signature key is refused (PM_CRYPTO_ERROR) and
 * nothing is staged. Version 1 stays accepted until the app sends only
 * version 2.
 */
int32_t pm_crypto_group_stage_commit(PmCryptoHandle *handle,
                                     PmByteSlice group_id, PmByteSlice changes,
                                     PmOwnedBuffer *out_commit,
                                     PmOwnedBuffer *out_welcome,
                                     uint64_t *out_epoch);
int32_t pm_crypto_group_merge_pending_commit(PmCryptoHandle *handle,
                                             PmByteSlice group_id);
int32_t pm_crypto_group_clear_pending_commit(PmCryptoHandle *handle,
                                             PmByteSlice group_id);
int32_t pm_crypto_group_epoch(PmCryptoHandle *handle, PmByteSlice group_id,
                              uint64_t *out_epoch, uint8_t *out_pending);
/* Applies a remote commit at once. Since ABI 20 it refuses (PM_CRYPTO_ERROR)
 * any commit carrying a GroupContextExtensions proposal, as do the c7 and l1
 * process calls: a role-record change is only ever merged through
 * pm_crypto_group_stage_incoming_commit and _merge_incoming_commit. */
int32_t pm_crypto_group_process_commit(PmCryptoHandle *handle,
                                       PmByteSlice group_id,
                                       PmByteSlice commit);
/*
 * Deprecated, tests only. Merges its update commit at once, before the
 * server has accepted it, so a commit that loses the epoch race forks this
 * device. Not used by the app; use pm_crypto_group_stage_commit with an
 * empty change list.
 */
int32_t pm_crypto_group_self_update(PmCryptoHandle *handle,
                                    PmByteSlice group_id,
                                    PmOwnedBuffer *out_commit);
int32_t pm_crypto_group_safety_number(PmCryptoHandle *handle,
                                      PmByteSlice group_id,
                                      PmOwnedBuffer *out_hash,
                                      PmOwnedBuffer *out_digits);
/*
 * Deprecated, tests only. Merges its removal commit at once, before the
 * server has accepted it, so a commit that loses the epoch race forks this
 * device. Not used by the app; use pm_crypto_group_stage_commit.
 */
int32_t pm_crypto_group_remove_member(
    PmCryptoHandle *handle, PmByteSlice group_id, PmByteSlice account_id,
    PmByteSlice device_id, PmOwnedBuffer *out_commit);
/*
 * Plaintext is at most 1 MiB (1048576 bytes); ciphertext accepted by decrypt
 * is at most 1 MiB + 4096 bytes. Encrypt never returns ciphertext above the
 * decrypt ceiling, so every successful encrypt can be decrypted.
 */
int32_t pm_crypto_group_encrypt(PmCryptoHandle *handle, PmByteSlice group_id,
                                PmByteSlice plaintext,
                                PmOwnedBuffer *out_ciphertext);
int32_t pm_crypto_group_decrypt(PmCryptoHandle *handle, PmByteSlice group_id,
                                PmByteSlice ciphertext,
                                PmByteSlice sender_account_id,
                                PmByteSlice sender_device_id,
                                PmOwnedBuffer *out_plaintext);
/* ABI 23 (L2-3, sealed sender; not wired into the app yet): decrypts an
 * application message and returns the sender MLS authenticated instead of
 * checking a claimed one. PM_CRYPTO_SENDER_REMOVED for a past-epoch message
 * from a sender no longer in the group; PM_CRYPTO_SENDER_MISMATCH for a
 * sender credential that is not a device identity. In both the ratchet has
 * advanced. pm_crypto_group_decrypt keeps its D25 check. */
int32_t pm_crypto_group_decrypt_sealed(PmCryptoHandle *handle,
                                       PmByteSlice group_id,
                                       PmByteSlice ciphertext,
                                       PmOwnedBuffer *out_plaintext,
                                       PmOwnedBuffer *out_sender_account_id,
                                       PmOwnedBuffer *out_sender_device_id);
/* ABI 23 (L2-1): the size bucket of a blob of `length` bytes: the next
 * multiple of 256 (at least 256) up to 4096, then the next power of two up
 * to 8 MiB. PM_CRYPTO_INVALID_ARGUMENT above 8 MiB. Staged commits that add
 * devices pad their Welcome to this bucket inside the encrypted GroupInfo
 * (extension 0xF0A2, zero bytes); joins refuse a pad that is not zeros.
 * Vector: testing/vectors/l2-padding-v1.json. */
int32_t pm_crypto_l2_padded_size(uint64_t length, uint64_t *out_padded);
/* ABI 26 (L2-3, D122): sealed sender tokens, RFC 9497 POPRF over
 * ristretto255-SHA512 (docs/crypto.md, "Sealed sender with VOPRF tokens";
 * vector testing/vectors/l2-sealed-v1.json). token_request blinds `count`
 * (1-32) fresh 32-byte nonces for the server key under info =
 * "veritra-l2-sealed-v1" || u16 len || conversation || u32 epoch;
 * out_request is count x 32 blinded elements and out_state
 * the secret client state (VLT1) the caller wipes after finalize.
 * token_finalize takes count x 32 evaluated elements || 64-byte proof,
 * checks the proof against the state's key (PM_CRYPTO_ERROR if it fails)
 * and writes count x (32-byte nonce || 64-byte output). */
int32_t pm_crypto_l2_token_request(PmByteSlice public_key,
                                   PmByteSlice conversation_id,
                                   uint32_t epoch, uint32_t count,
                                   PmOwnedBuffer *out_state,
                                   PmOwnedBuffer *out_request);
int32_t pm_crypto_l2_token_finalize(PmByteSlice state, PmByteSlice response,
                                    PmOwnedBuffer *out_tokens);
/* ABI 26 (L2-3): designated-verifier franking of a sealed message
 * (docs/crypto.md, "Franking a sealed message"; vector
 * testing/vectors/l2-frank-dv-v1.json). frank_public_key writes the
 * device's 32-byte X25519 franking key, the key its L1 entry must list
 * (change 7). frank_designate writes m x 48 bytes (kid || tag, sorted by
 * kid) for the owner report keys in owner_keys (n x 32, 1 <= n <= 16) over
 * the device's own identity and the 32-byte commit; owner keys that are
 * non-canonical, low-order or give an all-zero secret are skipped, m = 0 is
 * the empty buffer (the plain form), and a listed_key other than the
 * device's own is PM_CRYPTO_ERROR. frank_dv_verify takes the owner's report
 * seed (the pair is derived inside) and the claimed device's franking key
 * from its account's L1 list and writes 1 valid, 0 mismatch, 2 not
 * designated to this key. */
int32_t pm_crypto_l2_frank_public_key(PmCryptoHandle *handle,
                                      PmOwnedBuffer *out_key);
int32_t pm_crypto_l2_frank_designate(PmCryptoHandle *handle,
                                     PmByteSlice conversation_id,
                                     PmByteSlice commit,
                                     PmByteSlice listed_key,
                                     PmByteSlice owner_keys,
                                     PmOwnedBuffer *out_designation);
int32_t pm_crypto_l2_frank_dv_verify(PmByteSlice seed,
                                     PmByteSlice sender_frank_key,
                                     PmByteSlice conversation_id,
                                     PmByteSlice account_id,
                                     PmByteSlice device_id,
                                     PmByteSlice commit,
                                     PmByteSlice designation,
                                     uint8_t *out_result);
/* ABI 13 (C7, docs/designs/C7-channel-history.md revision 7). Nothing is
 * wired into the app, and every piece needs the independent crypto review
 * before release, the exporter use in particular. Vector:
 * testing/vectors/c7-primitives-v1.json.
 *
 * Commit calls: like pm_crypto_group_process_commit and
 * pm_crypto_group_merge_pending_commit, but they report what the commit did
 * from MLS itself, never from a server label. out_flags gets
 * PM_CRYPTO_C7_COMMIT_* bits, out_epoch the epoch the commit produces. For
 * a removal commit that keeps this device, out_root gets 32 bytes,
 * MLS-Exporter("veritra-c7-rekey-v1", lp(group_id) | u64(new_epoch), 32)
 * (lp = u16 big-endian length, integers big-endian), taken from the staged
 * or pending commit before the merge; in every other case out_root is
 * null/0. A commit that removes this device returns PM_CRYPTO_OK with
 * REMOVED and REMOVED_SELF and no root. All outputs are checked before the
 * commit is processed and are zero/null on failure. The merge variant
 * refuses (PM_CRYPTO_ERROR) a group with nothing staged. The app wipes the
 * root once it has derived per-channel keys. No other exporter output
 * leaves the core. Only the staged path reports: the older
 * pm_crypto_group_remove_member and pm_crypto_group_self_update merge at
 * once and report nothing. */
int32_t pm_crypto_group_c7_process_commit(PmCryptoHandle *handle,
                                          PmByteSlice group_id,
                                          PmByteSlice commit, uint8_t *out_flags,
                                          uint64_t *out_epoch,
                                          PmOwnedBuffer *out_root);
int32_t pm_crypto_group_c7_merge_pending_commit(PmCryptoHandle *handle,
                                                PmByteSlice group_id,
                                                uint8_t *out_flags,
                                                uint64_t *out_epoch,
                                                PmOwnedBuffer *out_root);
/* pm_crypto_group_decrypt that also writes the epoch the message was
 * encrypted in (0 on failure). Errors are the plain call's. */
int32_t pm_crypto_group_c7_decrypt(PmCryptoHandle *handle, PmByteSlice group_id,
                                   PmByteSlice ciphertext,
                                   PmByteSlice sender_account_id,
                                   PmByteSlice sender_device_id,
                                   PmOwnedBuffer *out_plaintext,
                                   uint64_t *out_epoch);
/* The 32-byte signature public key of the member device with this account
 * and device id, from the group's current tree. */
int32_t pm_crypto_group_member_signature_key(PmCryptoHandle *handle,
                                             PmByteSlice group_id,
                                             PmByteSlice account_id,
                                             PmByteSlice device_id,
                                             PmOwnedBuffer *out_key);
/* ABI 22 (B6): media key K(s,t) of the call group's current epoch for the
 * sender device account_id/device_id (leaf found from the tree) and stream slot (0 voice, 1 camera, 2 screen, 3 screen
 * audio): HKDF-SHA256(salt "veritra-b6-sender-v1", ikm MLS-Exporter(
 * "veritra-b6-media-v1", lp(call_id) | u64(epoch), 32), info u32(leaf) |
 * u8(stream)). 32 bytes out. The exporter secret never leaves the core.
 * pm_crypto_c7_sign and _verify also accept the domain "veritra-b6-join-v1". */
int32_t pm_crypto_group_b6_media_key(PmCryptoHandle *handle,
                                     PmByteSlice group_id, PmByteSlice call_id,
                                     PmByteSlice account_id,
                                     PmByteSlice device_id, uint8_t stream,
                                     PmOwnedBuffer *out_key);
/* c7_derive: HKDF-SHA256, salt = label, ikm = key (32 bytes), info 1 to 1024
 * bytes, 32 bytes out. label is one of "veritra-c7-post-v1",
 * "veritra-c7-rekey-chk-v1", "veritra-c7-slot-v1"; any other is
 * PM_CRYPTO_INVALID_ARGUMENT. chk_commit: sha256("veritra-c7-chk-v1" | key).
 * Unlike C6 franking, C7 length prefixes are u16 big-endian. */
int32_t pm_crypto_c7_derive(PmByteSlice key, PmByteSlice label,
                            PmByteSlice info, PmOwnedBuffer *out_key);
int32_t pm_crypto_c7_chk_commit(PmByteSlice key, PmOwnedBuffer *out_commit);
/* Seal: kc[32] | nonce[12] | AES-256-GCM(K_enc, nonce, plaintext, aad), K_enc
 * and kc derived from the 32-byte key with the internal labels
 * "veritra-c7-enc-v1" and "veritra-c7-kc-v1", a fresh random nonce, aad 1 to
 * 1024 bytes (required), plaintext 1 byte to 64 KiB + 64. A key may seal one
 * message only. Open checks kc first: another key is
 * PM_CRYPTO_C7_KEY_MISMATCH (nothing decrypted), altered bytes or aad under
 * the right key are PM_CRYPTO_ERROR. */
int32_t pm_crypto_c7_seal(PmByteSlice key, PmByteSlice aad,
                          PmByteSlice plaintext, PmOwnedBuffer *out_sealed);
int32_t pm_crypto_c7_open(PmByteSlice key, PmByteSlice aad, PmByteSlice sealed,
                          PmOwnedBuffer *out_plaintext);
/* Sign and verify with the credential key (Ed25519) over domain | message.
 * domain is "veritra-c7-post-sig-v1", "veritra-c7-history-v1" or
 * "veritra-invite-binding-v2" (C1 invitation binding; any other
 * is PM_CRYPTO_INVALID_ARGUMENT); Rust prepends it, so no C7 signature is an
 * MLS signature. message 1 to 4096 bytes. Verify is strict and stateless;
 * it writes 1 or 0 to out_valid and returns PM_CRYPTO_OK for either. */
int32_t pm_crypto_c7_sign(PmCryptoHandle *handle, PmByteSlice domain,
                          PmByteSlice message, PmOwnedBuffer *out_signature);
int32_t pm_crypto_c7_verify(PmByteSlice domain, PmByteSlice public_key,
                            PmByteSlice message, PmByteSlice signature,
                            uint8_t *out_valid);
/* ABI 14 (L1): the label "veritra-l1-device-list-sig-v1" is also accepted as
 * pm_crypto_c7_sign's domain, with a different meaning: message is then a
 * device-list body (VDL1, not bytes to sign). Rust parses it strictly,
 * requires this device's own account (a genesis, change 1, must list exactly
 * this device and its own key; a migration genesis, change 6, must list this
 * device with its own key; a recovery version, change 4, is refused), and
 * signs label | SHA-256(body) | 0x01 | lp(own device id) itself. Malformed is
 * PM_CRYPTO_L1_MALFORMED, a body this device may not sign
 * PM_CRYPTO_L1_RULE. The L1 label is not a pm_crypto_c7_verify domain.
 *
 * L1 approved-device list (docs/designs/L1-approved-device-list.md, step
 * L1-1; vector testing/vectors/l1-device-list-v1.json). Every integer is big
 * endian and lp(x) a u16 length then x.
 *   body      = "VDL1" | u8 1 | lp(account_id) | u64 version | [32] prev_hash
 *               | u64 created_at_ms | u8 change | u8 count (1..16) | count x
 *               (lp(device_id) | [32] signing_key) sorted by id | u8
 *               has_recovery | [32] recovery_key (when 1)
 *   statement = body | u8 signer_kind (1 device, 2 recovery key) | lp(signer
 *               device id, empty for kind 2) | [64] signature
 *   change    = 1 genesis, 2 add, 3 remove, 4 recovery, 5 recovery key,
 *               6 migration genesis
 * Both check calls take a required expected_account_id (1 to 128 bytes, the
 * account the caller asked about) and refuse a statement or chain of any other
 * account with PM_CRYPTO_L1_CHAIN, a genesis included: a valid chain of
 * another account never passes, so the caller needs no account comparison of
 * its own (and cannot forget one).
 * pm_crypto_l1_check_step checks a statement as the version after prev (prev
 * empty for a genesis); history is every pair listed before (u16 n | n x
 * (lp(device_id) | [32] key), may be empty) and carries the no-return and
 * one-key-one-device rules; pass it from the app's keys table, since prev
 * alone cannot know a device removed earlier. out_summary: u8 1 | u8 change
 * | u8 signer_kind | lp(signer id) | u64 version | [32] list_hash | [32]
 * prev_hash | u64 created_at_ms | lp(account_id) | u8 count | count x
 * (lp(device_id) | [32] key) | u8 has_recovery | [32] recovery_key (when 1).
 * pm_crypto_l1_check_chain checks a whole chain from its genesis (u16 count
 * | count x (u16 len | statement), at most 256): out_result is the head's
 * summary, [32] list_id (list_hash of version 1), u16 n and n x (lp(device_id)
 * | [32] key | u64 added_version | u64 removed_version, 0 while listed).
 * Both return PM_CRYPTO_OK or one of the PM_CRYPTO_L1_* kinds
 * (PM_CRYPTO_INVALID_ARGUMENT for a null output or a bad length). */
int32_t pm_crypto_l1_check_step(PmByteSlice expected_account_id,
                                PmByteSlice prev, PmByteSlice statement,
                                PmByteSlice history,
                                PmOwnedBuffer *out_summary);
int32_t pm_crypto_l1_check_chain(PmByteSlice expected_account_id,
                                 PmByteSlice chain, PmOwnedBuffer *out_result);
/* The recovery-derived signer (D94: the seed stays sealed on the waiting
 * phone). hold derives the device-list seed from typed 30-byte RK entropy and
 * keeps only the seed in the sealed device record (seal afterwards; an older
 * library refuses a record that holds one). hold_public writes the held
 * seed's 32-byte public key, or an empty buffer when none is held. hold_drop
 * forgets it and writes 1 or 0 (was held). sign_recovery signs change 4 and
 * returns the whole statement: entropy empty uses the held seed (dropped once
 * the statement is made), else the seed derived from the typed entropy
 * (nothing kept). body must be a change-4 body for this device's account
 * listing exactly this device with its own key, and the finished statement
 * must pass the pm_crypto_l1_check_step check against prev (the head at
 * completion, required) and history, so nothing is signed for a version the
 * chain would refuse; PM_CRYPTO_L1_NO_SEED when none is held. */
int32_t pm_crypto_l1_recovery_hold(PmCryptoHandle *handle, PmByteSlice entropy);
int32_t pm_crypto_l1_recovery_hold_public(PmCryptoHandle *handle,
                                          PmOwnedBuffer *out_public);
int32_t pm_crypto_l1_recovery_hold_drop(PmCryptoHandle *handle,
                                        uint8_t *out_was_held);
int32_t pm_crypto_l1_sign_recovery(PmCryptoHandle *handle, PmByteSlice prev,
                                   PmByteSlice history, PmByteSlice body,
                                   PmByteSlice entropy,
                                   PmOwnedBuffer *out_statement);
/* Every leaf of the group as u16 n | n x (lp(account_id) | lp(device_id) |
 * [32] signature key), in leaf order, from the current tree. */
int32_t pm_crypto_group_members(PmCryptoHandle *handle, PmByteSlice group_id,
                                PmOwnedBuffer *out_members);
/* The pm_crypto_group_c7_* commit calls with two more outputs: out_added
 * (u16 n | n x (lp(account_id) | lp(device_id) | [32] signature key), n may
 * be 0) for the leaves of the commit's Add proposals, and out_committer (the
 * same shape, one entry) for the committer, both read from the staged commit
 * and tree, never from a server label. A commit is never refused for an L1
 * reason: the app judges the pairs afterwards and holds the conversation. All
 * five outputs are checked first and are zero/null on failure. Ids are raw
 * bytes, not necessarily UTF-8 (a member can commit an Add whose credential
 * holds any 1 to 128 bytes): carry them as bytes, and never fail once
 * PM_CRYPTO_OK has come back, because the commit is already merged. Both pair
 * buffers are encoded before the merge, so OK always comes with both. */
int32_t pm_crypto_group_l1_process_commit(
    PmCryptoHandle *handle, PmByteSlice group_id, PmByteSlice commit,
    uint8_t *out_flags, uint64_t *out_epoch, PmOwnedBuffer *out_root,
    PmOwnedBuffer *out_added, PmOwnedBuffer *out_committer);
int32_t pm_crypto_group_l1_merge_pending_commit(
    PmCryptoHandle *handle, PmByteSlice group_id, uint8_t *out_flags,
    uint64_t *out_epoch, PmOwnedBuffer *out_root, PmOwnedBuffer *out_added,
    PmOwnedBuffer *out_committer);

/* ABI 20 (C4): the group role record (docs/designs/C4-custom-roles.md;
 * formats and rules in docs/crypto.md, "Group role state (C4)"). The record
 * is 1 to 256 KiB of opaque bytes in GroupContext extension 0xF0C4, which
 * every key package and creator leaf advertises and a record group requires.
 * Rust never decodes it; Dart judges every change before it is merged.
 *
 * create_with_roles: a group whose context requires 0xF0C4 and carries
 * record (the genesis). pm_crypto_group_create stays for groups with none.
 *
 * stage_commit_with_roles: pm_crypto_group_stage_commit plus one
 * GroupContextExtensions proposal rewriting the record (every other context
 * extension unchanged). changes must be version 2 (keyed adds, L1; version 1
 * is PM_CRYPTO_INVALID_ARGUMENT) and may hold no adds and no removes: then the
 * commit is the role change alone. The record must differ from the current
 * one and the group must already carry one (PM_CRYPTO_ERROR, nothing staged).
 *
 * stage_incoming_commit: processes a remote commit to its staged form,
 * checks it (one record proposal allowed), holds it in memory without
 * merging, and writes the review: u8 format=2 | u8 flags (1 removed, 2 added,
 * 4 removed self, 8 record proposal, 16 record before present, 32 record
 * after present) | u64 new_epoch | committer lp(account) lp(device) [32] key
 * | u16 n_added {lp(account) lp(device) [32] key}* | u16 n {lp(account)}*
 * roster before | u16 n {lp(account)}* roster after (both sorted by bytes,
 * distinct) | u32 len record_before | u32 len record_after (len 0 when
 * absent) | u16 n_proven {lp(account) lp(device) [32] key}* (ABI 24: the
 * removed leaves whose own leave statement in the commit's authenticated
 * data verified). lp = u16 length prefix, big-endian. Staging uses up the commit's
 * handshake ratchet step: after a discard the app restores its committed
 * state instead of sealing.
 *
 * merge_incoming_commit: merges the held commit; commit must be the staged
 * bytes and the group still on the epoch they were staged on, else
 * PM_CRYPTO_ERROR with nothing changed and the commit still held. Outputs as
 * pm_crypto_group_l1_process_commit; the C7 root is derived only here.
 *
 * discard_incoming_commit: drops the held commit; *out_was_held 1 if one was.
 *
 * role_state: u8 format=1 | u8 flags (1 record present) | u16 n
 * {lp(account)}* | u32 len record (0 when absent), for after a join or a
 * restore. */
int32_t pm_crypto_group_create_with_roles(PmCryptoHandle *handle,
                                          PmByteSlice group_id,
                                          PmByteSlice record);
int32_t pm_crypto_group_stage_commit_with_roles(
    PmCryptoHandle *handle, PmByteSlice group_id, PmByteSlice changes,
    PmByteSlice record, PmOwnedBuffer *out_commit, PmOwnedBuffer *out_welcome,
    uint64_t *out_epoch);
int32_t pm_crypto_group_stage_incoming_commit(PmCryptoHandle *handle,
                                              PmByteSlice group_id,
                                              PmByteSlice commit,
                                              PmOwnedBuffer *out_review);
int32_t pm_crypto_group_merge_incoming_commit(
    PmCryptoHandle *handle, PmByteSlice group_id, PmByteSlice commit,
    uint8_t *out_flags, uint64_t *out_epoch, PmOwnedBuffer *out_root,
    PmOwnedBuffer *out_added, PmOwnedBuffer *out_committer);
int32_t pm_crypto_group_discard_incoming_commit(PmCryptoHandle *handle,
                                                PmByteSlice group_id,
                                                uint8_t *out_was_held);
int32_t pm_crypto_group_role_state(PmCryptoHandle *handle,
                                   PmByteSlice group_id,
                                   PmOwnedBuffer *out_state);

/* ABI 24 (C4 leave proof in the commit, docs/crypto.md).
 *
 * c4_sign_leave: this device's leave statement for group_id, 70 bytes:
 * u32 leaf_index | u16 64 | Ed25519 signature, RFC 9420 SignWithLabel with
 * the leaf signature key, label "VeritraC4Leave1", over LeaveTBS = VL(group
 * id) | u32 leaf_index | the leaf's EncryptionKey (opaque<V>). Valid until
 * this leaf changes.
 *
 * stage_commit_proven: stage_commit_with_roles with record optional (len 0:
 * no record proposal) and leave_proofs, a list "VCL1" | u8 count (1..16) |
 * statements (distinct leaves; malformed: PM_CRYPTO_INVALID_ARGUMENT). The
 * statements whose leaf the commit removes and that verify against the tree
 * go into the commit's authenticated data in the same encoding; none left:
 * no AAD. */
int32_t pm_crypto_c4_sign_leave(PmCryptoHandle *handle, PmByteSlice group_id,
                                PmOwnedBuffer *out_statement);
int32_t pm_crypto_group_stage_commit_proven(
    PmCryptoHandle *handle, PmByteSlice group_id, PmByteSlice changes,
    PmByteSlice record, PmByteSlice leave_proofs, PmOwnedBuffer *out_commit,
    PmOwnedBuffer *out_welcome, uint64_t *out_epoch);

int32_t pm_crypto_attachment_encrypt_chunk(
    PmByteSlice key, PmByteSlice nonce_prefix, uint32_t chunk_index,
    PmByteSlice context, PmByteSlice plaintext, PmOwnedBuffer *out_ciphertext);
int32_t pm_crypto_attachment_decrypt_chunk(
    PmByteSlice key, PmByteSlice nonce_prefix, uint32_t chunk_index,
    PmByteSlice context, PmByteSlice ciphertext, PmOwnedBuffer *out_plaintext);

/* ABI 19 (K1): automatic backups, a VHC1 kind-1 container sealed to the
 * recovery public key (docs/designs/K1-automatic-backups.md). Seal binds
 * account_id, source_device_id (each at most 128 bytes), created_at_ms,
 * counter and the rk_id derived from rk_pub (32), pads to the K1 bucket (at
 * least 1 MiB, at most 64 MiB) and seals a fresh file key to rk_pub; payload
 * is non-empty and at most 64 MiB - 8. Peek reads the header from the first
 * 416 bytes without authenticating anything and returns account id, source
 * device id and a 41-byte meta (u64 created_at_ms, u64 counter, 16-byte
 * rk_id, u8 plaintext_version, u64 padded_size, big-endian). Open takes the
 * 30-byte recovery-key entropy, derives the private key inside Rust, and
 * refuses another account, another key, a changed byte, and (when
 * source_device_id is non-empty) another source device; it returns the
 * plaintext, the source device id and the meta. Vector:
 * testing/vectors/k1-backup-v1.json. */
int32_t pm_crypto_backup_seal(PmByteSlice account_id,
                              PmByteSlice source_device_id,
                              uint64_t created_at_ms, uint64_t counter,
                              uint32_t plaintext_version, PmByteSlice rk_pub,
                              PmByteSlice payload, PmOwnedBuffer *out_ciphertext);
int32_t pm_crypto_backup_peek(PmByteSlice prefix, PmOwnedBuffer *out_account_id,
                              PmOwnedBuffer *out_source_device_id,
                              PmOwnedBuffer *out_meta);
int32_t pm_crypto_backup_open(PmByteSlice ciphertext, PmByteSlice entropy,
                              PmByteSlice account_id,
                              PmByteSlice source_device_id,
                              PmOwnedBuffer *out_payload,
                              PmOwnedBuffer *out_source_device_id,
                              PmOwnedBuffer *out_meta);

/* These operations remain unavailable and do not read their arguments. */
int32_t pm_crypto_create_device_key_package(PmDeviceCredentialInput input,
                                            PmOutputBuffer output);
int32_t pm_crypto_encrypt(PmByteSlice conversation_id, PmByteSlice plaintext,
                          PmOutputBuffer output);
int32_t pm_crypto_decrypt(PmByteSlice conversation_id, PmByteSlice ciphertext,
                          PmOutputBuffer output);

#endif
