//! L2-1 (ABI 23): size buckets for the MLS blobs a device uploads that are
//! not already padded: key packages and the GroupInfo inside a Welcome.
//!
//! The rule (`docs/crypto.md`, "L2 padding"): a length `n` is padded to the
//! next multiple of [`BLOCK`] (at least one block) while that is at most
//! [`LINEAR_LIMIT`], and to the next power of two above it, up to
//! [`MAX_PADDED`]. A blob already larger than [`MAX_PADDED`] is not padded.
//!
//! The padding is one MLS extension of type [`PAD_EXTENSION_TYPE`] whose
//! data is zero bytes. It sits inside the signed key package and inside the
//! encrypted, signed GroupInfo, so the server cannot strip it or read the
//! unpadded length from the MLS vector lengths. Receivers need not strip
//! anything: OpenMLS ignores an unknown extension in both places, which is
//! also why ABI 22 apps accept padded blobs and ABI 23 apps accept unpadded
//! ones. A pad extension whose data is not all zero, or longer than
//! [`MAX_PADDED`], is refused, so it cannot become a side channel.
//!
//! Commits and application messages need nothing here: groups use the pure
//! ciphertext wire format, so both travel as `PrivateMessage`s padded to 256
//! bytes by MLS (`padding_size`).

use openmls::prelude::{Extension, UnknownExtension};

/// MLS extension type of the pad (private-use range; C4 uses `0xF0C4`).
pub const PAD_EXTENSION_TYPE: u16 = 0xF0A2;
/// The linear bucket step.
pub const BLOCK: usize = 256;
/// The largest linear bucket; above it buckets are powers of two.
pub const LINEAR_LIMIT: usize = 4096;
/// The largest bucket (8 MiB): its base64 still fits the 12 MiB commit
/// bundle route with the commit beside it.
pub const MAX_PADDED: usize = 8 * 1024 * 1024;

/// The bucket for a blob of `n` bytes, or `None` above [`MAX_PADDED`].
pub fn bucket(n: usize) -> Option<usize> {
    if n <= LINEAR_LIMIT {
        return Some(n.div_ceil(BLOCK).max(1) * BLOCK);
    }
    let next = n.checked_next_power_of_two()?;
    (next <= MAX_PADDED).then_some(next)
}

/// The next bucket strictly above `bucket`, for when a varint length step
/// makes `bucket` itself unreachable.
pub(crate) fn next_bucket(bucket_size: usize) -> Option<usize> {
    bucket(bucket_size + 1)
}

/// Length of the QUIC-style variable-length prefix MLS writes before a
/// vector of `n` bytes (RFC 9420, section 2.1.2).
pub(crate) fn varint_len(n: usize) -> usize {
    match n {
        0..=63 => 1,
        64..=16383 => 2,
        _ => 4,
    }
}

/// A pad extension with `len` zero bytes of data.
pub(crate) fn pad_extension(len: usize) -> Extension {
    Extension::Unknown(PAD_EXTENSION_TYPE, UnknownExtension(vec![0; len]))
}

/// Whether `extension` is a pad extension that breaks the rule (non-zero
/// data, or longer than [`MAX_PADDED`]). Any other extension is not judged.
pub(crate) fn malformed_pad(extension: &Extension) -> bool {
    match extension {
        Extension::Unknown(PAD_EXTENSION_TYPE, UnknownExtension(data)) => {
            data.len() > MAX_PADDED || data.iter().any(|&byte| byte != 0)
        }
        _ => false,
    }
}

/// Serialized size of a key package whose only extension is a pad of `pad`
/// bytes, given `bare`, the size of the same key package with an empty
/// extension list (one `0x00` length byte).
pub(crate) fn key_package_size(bare: usize, pad: usize) -> usize {
    // Extension = u16 type + vector data; the list is a vector of those.
    let entry = 2 + varint_len(pad) + pad;
    bare - 1 + varint_len(entry) + entry
}

/// The pad length that brings a key package of `bare` bytes (empty
/// extension list) exactly to a bucket, or `None` when the key package is
/// already over [`MAX_PADDED`]. The first reachable bucket at or above the
/// size with an empty pad is taken.
pub(crate) fn key_package_pad(bare: usize) -> Option<usize> {
    let mut target = bucket(key_package_size(bare, 0))?;
    loop {
        // key_package_size grows by at least one per pad byte, so no pad
        // beyond target - bare can land on target.
        if let Some(pad) =
            (0..=target.saturating_sub(bare)).find(|&pad| key_package_size(bare, pad) == target)
        {
            return Some(pad);
        }
        target = next_bucket(target)?;
    }
}

#[cfg(test)]
#[path = "l2_tests.rs"]
mod tests;
