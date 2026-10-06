// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use crate::json::Text;
use crate::{
    abi::Bytes,
    storage::{self, Buffer},
    versioned,
};
use serde::Deserialize;
use std::{ffi::c_char, path::PathBuf};
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Item<'a> {
    #[serde(borrow)]
    id: Option<Text<'a>>,
    #[serde(borrow)]
    r#type: Option<Text<'a>>,
    timestamp: Option<f64>,
    #[serde(borrow)]
    preview: Option<Text<'a>>,
    is_pinned: Option<bool>,
    #[serde(borrow)]
    string_data: Option<Text<'a>>,
    #[serde(borrow)]
    image_file_name: Option<Text<'a>>,
    #[serde(borrow)]
    image_content_hash: Option<Text<'a>>,
    #[serde(rename = "fileURLs", borrow)]
    file_urls: Option<Vec<Text<'a>>>,
    #[serde(borrow)]
    rtf_data: Option<Text<'a>>,
    #[serde(borrow)]
    rtf_file_name: Option<Text<'a>>,
}
#[derive(Deserialize)]
struct Group<'a> {
    #[serde(borrow)]
    id: Text<'a>,
    timestamp: f64,
    #[serde(borrow)]
    items: Vec<Item<'a>>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Archive<'a> {
    #[serde(borrow)]
    history: Vec<Item<'a>>,
    #[serde(borrow)]
    pinned_items: Vec<Item<'a>>,
    #[serde(borrow)]
    groups: Option<Vec<Group<'a>>>,
}
fn valid_base64(value: &str) -> bool {
    let bytes = value.as_bytes();
    let padding = bytes.iter().rev().take_while(|&&b| b == b'=').count();
    let data = &bytes[..bytes.len() - padding];
    if !data
        .iter()
        .all(|b| b.is_ascii_alphanumeric() || *b == b'+' || *b == b'/')
    {
        return false;
    }
    if bytes.is_empty() {
        return true;
    }
    if bytes.len() < 4 {
        return false;
    }
    match data.len() % 4 {
        0 => true,
        2 => padding >= 2,
        3 => padding >= 1,
        _ => false,
    }
}
impl Item<'_> {
    fn valid(&self) -> bool {
        // All fields are deserialized even when not used for identity, matching the native DTO codec.
        let _ = (
            &self.preview,
            &self.is_pinned,
            &self.string_data,
            &self.image_file_name,
            &self.image_content_hash,
            &self.file_urls,
            &self.rtf_file_name,
        );
        self.id.as_ref().is_none_or(|id| versioned::valid_uuid(id))
            && self.r#type.as_ref().is_none_or(|kind| {
                matches!(
                    kind.as_ref(),
                    "text" | "url" | "file" | "image" | "rtf" | "unknown"
                )
            })
            && self.timestamp.is_none_or(f64::is_finite)
            && self.rtf_data.as_ref().is_none_or(|s| valid_base64(s))
    }
}
fn validate(bytes: &[u8]) -> Result<(), u32> {
    if !crate::json::native_depth_supported(bytes) {
        return Err(2);
    }
    crate::json::with_first_wins(bytes, validate_inner).map_err(|_| 2_u32)
}
fn validate_inner(bytes: &[u8]) -> Result<(), serde_json::Error> {
    let value: Archive = serde_json::from_slice(bytes)?;
    if !value
        .history
        .iter()
        .chain(&value.pinned_items)
        .all(Item::valid)
        || value.groups.as_ref().is_some_and(|groups| {
            groups.iter().any(|g| {
                !versioned::valid_uuid(&g.id)
                    || !g.timestamp.is_finite()
                    || !g.items.iter().all(Item::valid)
            })
        })
    {
        return Err(<serde_json::Error as serde::de::Error>::custom(
            "invalid archive fields",
        ));
    }
    Ok(())
}
pub struct Store {
    path: PathBuf,
    blocked: bool,
}
impl Store {
    fn read(&mut self) -> Result<Option<Vec<u8>>, u32> {
        let result = storage::read(&self.path, false)
            .map_err(|_| 2_u32)
            .and_then(|bytes| {
                if let Some(bytes) = &bytes {
                    validate(bytes)?;
                }
                Ok(bytes)
            });
        self.blocked = result.is_err();
        result
    }
    fn write(&mut self, bytes: &[u8]) -> Result<(), u32> {
        validate(bytes).map_err(|_| 3_u32)?;
        if self.blocked {
            return Err(2);
        }
        // External updates must be checked before a replacement, including writes before initial load.
        self.read()?;
        storage::write(&self.path, bytes, false, false).map_err(|_| 3_u32)
    }
}
/// # Safety
/// Path is a readable C string. All store calls are serialized by the owner.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_create(path: *const c_char) -> *mut Store {
    let Some(path) = (unsafe { storage::path(path) }) else {
        return std::ptr::null_mut();
    };
    Box::into_raw(Box::new(Store {
        path: path.to_path_buf(),
        blocked: false,
    }))
}
/// # Safety
/// Destroy a live handle once after all calls finish.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_destroy(store: *mut Store) {
    if !store.is_null() {
        drop(unsafe { Box::from_raw(store) });
    }
}
/// # Safety
/// The handle is live and exclusively borrowed. Returned buffer owns file bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_read(store: *mut Store) -> *mut Buffer {
    let Some(store) = (unsafe { store.as_mut() }) else {
        return storage::buffer(vec![], 2);
    };
    match store.read() {
        Ok(Some(bytes)) => storage::buffer(bytes, 0),
        Ok(None) => storage::buffer(vec![], 1),
        Err(e) => storage::buffer(vec![], e),
    }
}
/// Native DTO defaulting/decoding failure also blocks this store until an explicit reload.
/// # Safety
/// Handle is live and exclusively borrowed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_block(store: *mut Store) {
    if let Some(s) = unsafe { store.as_mut() } {
        s.blocked = true;
    }
}
/// # Safety
/// Handle is live and serialized; bytes remain readable for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_write(store: *mut Store, data: Bytes) -> u32 {
    let Some(store) = (unsafe { store.as_mut() }) else {
        return 3;
    };
    let Some(bytes) = (unsafe { data.slice() }) else {
        return 3;
    };
    store.write(bytes).err().unwrap_or(0)
}
/// # Safety
/// Data remains readable for its span length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_validate(data: Bytes) -> u32 {
    let Some(bytes) = (unsafe { data.slice() }) else {
        return 2;
    };
    validate(bytes).err().unwrap_or(0)
}
