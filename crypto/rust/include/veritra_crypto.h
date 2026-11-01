#ifndef VERITRA_CRYPTO_H
#define VERITRA_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#define PM_CRYPTO_UNAVAILABLE (-1)
#define PM_CRYPTO_ABI_VERSION (11u)
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
 * rk_pub (32), rk_id (16) and rk_auth_pub (32); no private key or seed ever
 * crosses the ABI. The proof is an Ed25519 signature (64) by the RK auth key
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
                                      PmOwnedBuffer *out_rk_auth_pub);
int32_t pm_crypto_recovery_proof_sign(PmByteSlice entropy,
                                      PmByteSlice challenge,
                                      PmByteSlice signing_key,
                                      PmByteSlice key_package,
                                      PmByteSlice origin,
                                      PmOwnedBuffer *out_signature);
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
/* ABI 7: returns hash32, claim MAC32, approval MAC32, SAS prefix4. The SAS
 * is prefix4 (big-endian) mod 10^8: 8 digits, about 26.6 bits. The prefix
 * and both tags are MACs keyed from the 128-bit out-of-band link secret, so
 * a relay without it cannot grind keys to match; if the secret leaks, the 8
 * digits alone fall to about 10^4 key generations per side. */
int32_t pm_crypto_device_link_transcript_hash(
    PmCryptoHandle *handle, PmByteSlice protocol_version,
    PmByteSlice server_origin, PmByteSlice link_id, PmByteSlice link_secret,
    PmByteSlice peer_device_id,
    PmByteSlice peer_signing_public_key, PmByteSlice link_nonce,
    uint8_t local_is_existing_device, PmOwnedBuffer *out);
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
int32_t pm_crypto_attachment_encrypt_chunk(
    PmByteSlice key, PmByteSlice nonce_prefix, uint32_t chunk_index,
    PmByteSlice context, PmByteSlice plaintext, PmOwnedBuffer *out_ciphertext);
int32_t pm_crypto_attachment_decrypt_chunk(
    PmByteSlice key, PmByteSlice nonce_prefix, uint32_t chunk_index,
    PmByteSlice context, PmByteSlice ciphertext, PmOwnedBuffer *out_plaintext);

/* These operations remain unavailable and do not read their arguments. */
int32_t pm_crypto_create_device_key_package(PmDeviceCredentialInput input,
                                            PmOutputBuffer output);
int32_t pm_crypto_encrypt(PmByteSlice conversation_id, PmByteSlice plaintext,
                          PmOutputBuffer output);
int32_t pm_crypto_decrypt(PmByteSlice conversation_id, PmByteSlice ciphertext,
                          PmOutputBuffer output);

#endif
