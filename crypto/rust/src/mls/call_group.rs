//! B6 (ABI 28): the call-group marker, a Veritra GroupContext extension that
//! makes a group a call group and binds it to one call and one parent
//! conversation.
//!
//! Design: `docs/designs/B6-group-calls.md` ("The call group" and "Call-group
//! marker (ABI 28)"); wire rules in `docs/crypto.md`. Rust enforces:
//!
//! - every leaf advertises extension type [`CALL_EXTENSION_TYPE`] (key
//!   packages and creator leaves, through `c4::leaf_capabilities`);
//! - a call group's context is exactly the genesis list from creation:
//!   required capabilities naming the marker, then the marker
//!   `u8(1) | lp(call_id) | lp(conversation_id)`. It never changes: a
//!   GroupContextExtensions proposal is refused in any group without a C4
//!   record (`inspect_commit`), and a record group can never gain a marker
//!   (`c4::check_record_proposal` keeps every other extension byte for
//!   byte);
//! - the call join accepts a Welcome only when its context is exactly that
//!   list for the call and conversation the app asked to join; the plain
//!   join refuses any Welcome that carries a marker, so a call group only
//!   ever enters a device through the call join;
//! - the media key (`b6_media_key`) is derived only in a call group, and
//!   only for the call id its marker names.

use super::*;
use crate::b6::{decode_call_marker, encode_call_marker, CALL_EXTENSION_TYPE};

fn call_type() -> ExtensionType {
    ExtensionType::Unknown(CALL_EXTENSION_TYPE)
}

/// The genesis (and only) context extensions of a call group.
pub(super) fn genesis_extensions(
    call_id: &[u8],
    conversation_id: &[u8],
) -> Result<Extensions<GroupContext>, MlsError> {
    let marker =
        encode_call_marker(call_id, conversation_id).map_err(|_| MlsError::InvalidIdentity)?;
    Extensions::from_vec(vec![
        Extension::RequiredCapabilities(RequiredCapabilitiesExtension::new(
            &[call_type()],
            &[],
            &[],
        )),
        Extension::Unknown(CALL_EXTENSION_TYPE, UnknownExtension(marker)),
    ])
    .map_err(|_| MlsError::InvalidState)
}

/// The marker data a context carries, if any.
pub(super) fn marker_of(extensions: &Extensions<GroupContext>) -> Option<&[u8]> {
    extensions
        .unknown(CALL_EXTENSION_TYPE)
        .map(|unknown| unknown.0.as_slice())
}

/// Whether two extension lists are the same, in order, byte for byte.
fn same_extensions(a: &Extensions<GroupContext>, b: &Extensions<GroupContext>) -> bool {
    let encode = |extensions: &Extensions<GroupContext>| {
        extensions
            .iter()
            .map(|extension| extension.tls_serialize_detached().ok())
            .collect::<Option<Vec<_>>>()
    };
    match (encode(a), encode(b)) {
        (Some(a), Some(b)) => a == b,
        _ => false,
    }
}

/// The join rule for a Welcome's group context. With `expected` (the call
/// join), the context must be exactly the genesis list for that call and
/// conversation; without it (the plain join), it must carry no marker.
pub(super) fn check_joined_context(
    extensions: &Extensions<GroupContext>,
    expected: Option<(&[u8], &[u8])>,
) -> Result<(), MlsError> {
    let refused = MlsError::InvalidIdentity;
    match expected {
        None if marker_of(extensions).is_some() => Err(refused),
        None => Ok(()),
        Some((call_id, conversation_id)) => {
            let wanted = genesis_extensions(call_id, conversation_id)?;
            if same_extensions(extensions, &wanted) {
                Ok(())
            } else {
                Err(refused)
            }
        }
    }
}

/// The call id a call group is bound to. Refused (`InvalidState`) for a
/// group without a well-formed marker or that does not require it.
pub(super) fn bound_call_id(group: &MlsGroup) -> Result<&[u8], MlsError> {
    let refused = MlsError::InvalidState;
    let extensions = group.extensions();
    let required = extensions
        .required_capabilities()
        .is_some_and(|required| required.extension_types().contains(&call_type()));
    if !required {
        return Err(refused);
    }
    let marker = marker_of(extensions).ok_or(refused)?;
    let (call_id, _) = decode_call_marker(marker).map_err(|_| refused)?;
    Ok(call_id)
}

impl MlsDevice {
    /// B6 (ABI 28): creates and persists a call group bound to `call_id`
    /// and the parent `conversation_id` (each 1 to 128 bytes). The plain
    /// [`MlsDevice::create_group`] never makes one.
    pub fn create_call_group(
        &self,
        group_id: &[u8],
        call_id: &[u8],
        conversation_id: &[u8],
    ) -> Result<MlsGroup, MlsError> {
        if group_id.is_empty() || group_id.len() > MAX_ID_BYTES {
            return Err(MlsError::InvalidIdentity);
        }
        let config = group_create_config_with(Some(genesis_extensions(call_id, conversation_id)?));
        self.held.forget(group_id)?;
        self.in_group(group_id, || {
            MlsGroup::new_with_group_id(
                &self.provider,
                &self.signer,
                &config,
                GroupId::from_slice(group_id),
                self.credential.clone(),
            )
            .map_err(|_| MlsError::GroupOperation)
        })
    }

    /// B6 (ABI 28): [`MlsDevice::join_group`] for a call group. The Welcome
    /// is refused, and nothing stored, unless its context is exactly the
    /// call group's genesis list for `call_id` and `conversation_id`: the
    /// room this device asked to join.
    pub fn join_call_group(
        &self,
        expected_group_id: &[u8],
        welcome_bytes: &[u8],
        call_id: &[u8],
        conversation_id: &[u8],
    ) -> Result<MlsGroup, MlsError> {
        // Refuse malformed ids before the Welcome consumes a key package.
        genesis_extensions(call_id, conversation_id)?;
        self.join_group_checked(
            expected_group_id,
            welcome_bytes,
            Some((call_id, conversation_id)),
        )
    }
}

#[cfg(test)]
#[path = "call_group_tests.rs"]
mod tests;
