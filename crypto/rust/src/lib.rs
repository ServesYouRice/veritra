//! Fail-closed native boundary for Veritra's future OpenMLS integration.
//!
//! This crate does not currently perform cryptography. The exported operation
//! entry points intentionally return [`PM_CRYPTO_UNAVAILABLE`] without reading
//! their inputs. Keeping the ABI here lets Android/iOS bindings be reviewed
//! independently without making an incomplete implementation usable.

use core::ffi::c_char;

mod ffi;
pub mod mls;

pub use ffi::{PmCryptoHandle, PmOwnedBuffer};

pub const PM_CRYPTO_UNAVAILABLE: i32 = -1;
pub const PM_CRYPTO_ABI_VERSION: u32 = 2;
pub const CRYPTO_PROTOCOL: &str = "mls10-openmls-v1";

pub const MAX_ACCOUNT_ID_BYTES: usize = 128;
pub const MAX_DEVICE_ID_BYTES: usize = 128;
pub const MIN_KEY_PACKAGE_BYTES: usize = 64;
pub const MAX_KEY_PACKAGE_BYTES: usize = 48 * 1024;

/// A borrowed byte slice crossing the C ABI.
///
/// The pointed-to memory remains owned by the caller and must remain valid for
/// the duration of a call. Current fail-closed operations never dereference it.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct PmByteSlice {
    pub data: *const u8,
    pub len: usize,
}

/// A caller-owned output buffer crossing the C ABI.
///
/// A future implementation must set `written` only after producing a complete
/// output and must never return partial cryptographic state.
#[repr(C)]
#[derive(Debug)]
pub struct PmOutputBuffer {
    pub data: *mut u8,
    pub capacity: usize,
    pub written: *mut usize,
}

/// Inputs needed to bind an MLS credential to one authenticated device.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct PmDeviceCredentialInput {
    pub account_id: PmByteSlice,
    pub device_id: PmByteSlice,
    pub signing_public_key: PmByteSlice,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BoundaryError {
    EmptyAccountId,
    AccountIdTooLong,
    EmptyDeviceId,
    DeviceIdTooLong,
    EmptySigningPublicKey,
    KeyPackageTooSmall,
    KeyPackageTooLarge,
}

/// Validated identity inputs. This is not an MLS credential and is never
/// accepted as proof of identity; OpenMLS must sign and verify the final value.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DeviceCredentialInput<'a> {
    pub account_id: &'a [u8],
    pub device_id: &'a [u8],
    pub signing_public_key: &'a [u8],
}

impl<'a> DeviceCredentialInput<'a> {
    pub fn new(
        account_id: &'a [u8],
        device_id: &'a [u8],
        signing_public_key: &'a [u8],
    ) -> Result<Self, BoundaryError> {
        if account_id.is_empty() {
            return Err(BoundaryError::EmptyAccountId);
        }
        if account_id.len() > MAX_ACCOUNT_ID_BYTES {
            return Err(BoundaryError::AccountIdTooLong);
        }
        if device_id.is_empty() {
            return Err(BoundaryError::EmptyDeviceId);
        }
        if device_id.len() > MAX_DEVICE_ID_BYTES {
            return Err(BoundaryError::DeviceIdTooLong);
        }
        if signing_public_key.is_empty() {
            return Err(BoundaryError::EmptySigningPublicKey);
        }
        Ok(Self {
            account_id,
            device_id,
            signing_public_key,
        })
    }
}

/// Size-checked, opaque key-package bytes awaiting OpenMLS verification.
///
/// Construction does not establish signature, credential, ciphersuite,
/// expiration, or single-use validity.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct UnverifiedKeyPackage<'a>(&'a [u8]);

impl<'a> UnverifiedKeyPackage<'a> {
    pub fn new(bytes: &'a [u8]) -> Result<Self, BoundaryError> {
        if bytes.len() < MIN_KEY_PACKAGE_BYTES {
            return Err(BoundaryError::KeyPackageTooSmall);
        }
        if bytes.len() > MAX_KEY_PACKAGE_BYTES {
            return Err(BoundaryError::KeyPackageTooLarge);
        }
        Ok(Self(bytes))
    }

    pub fn as_bytes(self) -> &'a [u8] {
        self.0
    }
}

#[no_mangle]
pub extern "C" fn pm_crypto_abi_version() -> u32 {
    PM_CRYPTO_ABI_VERSION
}

#[no_mangle]
pub extern "C" fn pm_crypto_available() -> i32 {
    PM_CRYPTO_UNAVAILABLE
}

/// Returns the versioned protocol identifier as a static NUL-terminated string.
#[no_mangle]
pub extern "C" fn pm_crypto_protocol() -> *const c_char {
    c"mls10-openmls-v1".as_ptr()
}

#[no_mangle]
pub extern "C" fn pm_crypto_create_device_key_package(
    _input: PmDeviceCredentialInput,
    _output: PmOutputBuffer,
) -> i32 {
    PM_CRYPTO_UNAVAILABLE
}

#[no_mangle]
pub extern "C" fn pm_crypto_encrypt(
    _conversation_id: PmByteSlice,
    _plaintext: PmByteSlice,
    _output: PmOutputBuffer,
) -> i32 {
    PM_CRYPTO_UNAVAILABLE
}

#[no_mangle]
pub extern "C" fn pm_crypto_decrypt(
    _conversation_id: PmByteSlice,
    _ciphertext: PmByteSlice,
    _output: PmOutputBuffer,
) -> i32 {
    PM_CRYPTO_UNAVAILABLE
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::ptr;

    fn empty_slice() -> PmByteSlice {
        PmByteSlice {
            data: ptr::null(),
            len: usize::MAX,
        }
    }

    fn empty_output() -> PmOutputBuffer {
        PmOutputBuffer {
            data: ptr::null_mut(),
            capacity: usize::MAX,
            written: ptr::null_mut(),
        }
    }

    #[test]
    fn every_production_operation_fails_closed_without_reading_inputs() {
        assert_eq!(pm_crypto_available(), PM_CRYPTO_UNAVAILABLE);
        assert_eq!(
            pm_crypto_create_device_key_package(
                PmDeviceCredentialInput {
                    account_id: empty_slice(),
                    device_id: empty_slice(),
                    signing_public_key: empty_slice(),
                },
                empty_output(),
            ),
            PM_CRYPTO_UNAVAILABLE
        );
        assert_eq!(
            pm_crypto_encrypt(empty_slice(), empty_slice(), empty_output()),
            PM_CRYPTO_UNAVAILABLE
        );
        assert_eq!(
            pm_crypto_decrypt(empty_slice(), empty_slice(), empty_output()),
            PM_CRYPTO_UNAVAILABLE
        );
    }

    #[test]
    fn credential_boundary_requires_all_device_bindings() {
        assert_eq!(
            DeviceCredentialInput::new(b"", b"device", b"public-key"),
            Err(BoundaryError::EmptyAccountId)
        );
        assert_eq!(
            DeviceCredentialInput::new(b"account", b"", b"public-key"),
            Err(BoundaryError::EmptyDeviceId)
        );
        assert_eq!(
            DeviceCredentialInput::new(b"account", b"device", b""),
            Err(BoundaryError::EmptySigningPublicKey)
        );
        assert!(DeviceCredentialInput::new(b"account", b"device", b"public-key").is_ok());
    }

    #[test]
    fn key_package_boundary_matches_server_transport_limits() {
        assert_eq!(
            UnverifiedKeyPackage::new(&[0; MIN_KEY_PACKAGE_BYTES - 1]),
            Err(BoundaryError::KeyPackageTooSmall)
        );
        let minimum = [0; MIN_KEY_PACKAGE_BYTES];
        assert_eq!(
            UnverifiedKeyPackage::new(&minimum).unwrap().as_bytes(),
            minimum
        );
        assert_eq!(
            UnverifiedKeyPackage::new(&[0; MAX_KEY_PACKAGE_BYTES + 1]),
            Err(BoundaryError::KeyPackageTooLarge)
        );
    }
}
