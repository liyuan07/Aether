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
fn valid_archive(value: &Archive) -> bool {
    value
        .history
        .iter()
        .chain(&value.pinned_items)
        .all(Item::valid)
        && value.groups.as_ref().is_none_or(|groups| {
            groups.iter().all(|g| {
                versioned::valid_uuid(&g.id)
                    && g.timestamp.is_finite()
                    && g.items.iter().all(Item::valid)
            })
        })
}
fn validate_inner(bytes: &[u8]) -> Result<(), serde_json::Error> {
    let value: Archive = serde_json::from_slice(bytes)?;
    if valid_archive(&value) {
        Ok(())
    } else {
        Err(<serde_json::Error as serde::de::Error>::custom(
            "invalid archive fields",
        ))
    }
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

fn own_text(text: Text<'_>) -> Text<'static> {
    Text(std::borrow::Cow::Owned(text.0.into_owned()))
}
impl Item<'_> {
    fn owned(self) -> Item<'static> {
        Item {
            id: self.id.map(own_text),
            r#type: self.r#type.map(own_text),
            timestamp: self.timestamp,
            preview: self.preview.map(own_text),
            is_pinned: self.is_pinned,
            string_data: self.string_data.map(own_text),
            image_file_name: self.image_file_name.map(own_text),
            image_content_hash: self.image_content_hash.map(own_text),
            file_urls: self
                .file_urls
                .map(|v| v.into_iter().map(own_text).collect()),
            rtf_data: self.rtf_data.map(own_text),
            rtf_file_name: self.rtf_file_name.map(own_text),
        }
    }
}
pub struct Decoded {
    value: Option<Archive<'static>>,
    status: u32,
}
fn decode(bytes: &[u8]) -> Result<Archive<'static>, u32> {
    if !crate::json::native_depth_supported(bytes) {
        return Err(2);
    }
    crate::json::with_first_wins(bytes, |bytes| {
        let value: Archive = serde_json::from_slice(bytes)?;
        if !valid_archive(&value) {
            return Err(<serde_json::Error as serde::de::Error>::custom(
                "invalid archive fields",
            ));
        }
        Ok(Archive {
            history: value.history.into_iter().map(Item::owned).collect(),
            pinned_items: value.pinned_items.into_iter().map(Item::owned).collect(),
            groups: value.groups.map(|groups| {
                groups
                    .into_iter()
                    .map(|g| Group {
                        id: own_text(g.id),
                        timestamp: g.timestamp,
                        items: g.items.into_iter().map(Item::owned).collect(),
                    })
                    .collect()
            }),
        })
    })
    .map_err(|_| 2)
}
fn empty_bytes() -> Bytes {
    Bytes {
        data: std::ptr::null(),
        length: 0,
    }
}
fn text_bytes(text: &Text<'_>) -> Bytes {
    Bytes {
        data: text.as_bytes().as_ptr(),
        length: text.len(),
    }
}
fn optional_bytes(text: &Option<Text<'_>>) -> Bytes {
    text.as_ref().map(text_bytes).unwrap_or_else(empty_bytes)
}
#[repr(C)]
pub struct ItemView {
    id: Bytes,
    preview: Bytes,
    string_data: Bytes,
    image_file_name: Bytes,
    image_content_hash: Bytes,
    rtf_data: Bytes,
    rtf_file_name: Bytes,
    timestamp: f64,
    file_count: usize,
    present: u16,
    kind: u8,
    pinned: u8,
}
impl ItemView {
    fn empty() -> Self {
        Self {
            id: empty_bytes(),
            preview: empty_bytes(),
            string_data: empty_bytes(),
            image_file_name: empty_bytes(),
            image_content_hash: empty_bytes(),
            rtf_data: empty_bytes(),
            rtf_file_name: empty_bytes(),
            timestamp: 0.0,
            file_count: 0,
            present: 0,
            kind: 5,
            pinned: 0,
        }
    }
    fn from(item: &Item<'_>) -> Self {
        let flags = [
            item.id.is_some(),
            item.timestamp.is_some(),
            item.preview.is_some(),
            item.string_data.is_some(),
            item.image_file_name.is_some(),
            item.image_content_hash.is_some(),
            item.file_urls.is_some(),
            item.rtf_data.is_some(),
            item.rtf_file_name.is_some(),
        ];
        Self {
            id: optional_bytes(&item.id),
            preview: optional_bytes(&item.preview),
            string_data: optional_bytes(&item.string_data),
            image_file_name: optional_bytes(&item.image_file_name),
            image_content_hash: optional_bytes(&item.image_content_hash),
            rtf_data: optional_bytes(&item.rtf_data),
            rtf_file_name: optional_bytes(&item.rtf_file_name),
            timestamp: item.timestamp.unwrap_or(0.0),
            file_count: item.file_urls.as_ref().map_or(0, Vec::len),
            present: flags
                .iter()
                .enumerate()
                .fold(0, |bits, (i, flag)| bits | ((*flag as u16) << i)),
            kind: match item.r#type.as_deref().unwrap_or("unknown") {
                "text" => 0,
                "url" => 1,
                "file" => 2,
                "image" => 3,
                "rtf" => 4,
                _ => 5,
            },
            pinned: item.is_pinned.unwrap_or(false) as u8,
        }
    }
}
impl Decoded {
    fn items(&self, section: u8, group: usize) -> &[Item<'static>] {
        let Some(value) = &self.value else {
            return &[];
        };
        match section {
            0 => &value.history,
            1 => &value.pinned_items,
            2 => value
                .groups
                .as_ref()
                .and_then(|g| g.get(group))
                .map_or(&[], |g| &g.items),
            _ => &[],
        }
    }
}
/// # Safety
/// Store is live and exclusively borrowed. Returned decoded owner must be destroyed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_load_decoded(store: *mut Store) -> *mut Decoded {
    let result = if let Some(store) = unsafe { store.as_mut() } {
        let result = storage::read(&store.path, false)
            .map_err(|_| 2)
            .and_then(|bytes| bytes.map(|bytes| decode(&bytes)).transpose());
        store.blocked = result.is_err();
        result
    } else {
        Err(2)
    };
    let decoded = match result {
        Ok(value) => Decoded {
            status: if value.is_some() { 0 } else { 1 },
            value,
        },
        Err(status) => Decoded {
            status,
            value: None,
        },
    };
    Box::into_raw(Box::new(decoded))
}
/// # Safety
/// Destroy a decoded owner once after all borrowed views have been copied.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_decoded_destroy(decoded: *mut Decoded) {
    if !decoded.is_null() {
        drop(unsafe { Box::from_raw(decoded) });
    }
}
/// # Safety
/// Decoded owner remains live during each accessor and all borrowed view use.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_decoded_status(decoded: *const Decoded) -> u32 {
    unsafe { decoded.as_ref() }.map_or(2, |d| d.status)
}
/// # Safety
/// Decoded owner is live for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_decoded_count(
    decoded: *const Decoded,
    section: u8,
    group: usize,
) -> usize {
    unsafe { decoded.as_ref() }.map_or(0, |d| {
        if section == 3 {
            d.value
                .as_ref()
                .and_then(|v| v.groups.as_ref())
                .map_or(0, Vec::len)
        } else {
            d.items(section, group).len()
        }
    })
}
/// # Safety
/// Decoded owner is live until the returned borrowed byte spans have been copied.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_decoded_item(
    decoded: *const Decoded,
    section: u8,
    group: usize,
    index: usize,
) -> ItemView {
    unsafe { decoded.as_ref() }
        .and_then(|d| d.items(section, group).get(index))
        .map_or_else(ItemView::empty, ItemView::from)
}
/// # Safety
/// Decoded owner is live until the returned byte span has been copied.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_decoded_url(
    decoded: *const Decoded,
    section: u8,
    group: usize,
    index: usize,
    url: usize,
) -> Bytes {
    unsafe { decoded.as_ref() }
        .and_then(|d| d.items(section, group).get(index))
        .and_then(|i| i.file_urls.as_ref())
        .and_then(|urls| urls.get(url))
        .map_or_else(empty_bytes, text_bytes)
}
/// # Safety
/// Decoded owner is live until the returned borrowed group metadata has been copied.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_decoded_group(
    decoded: *const Decoded,
    index: usize,
) -> ItemView {
    let mut view = ItemView::empty();
    if let Some(group) = unsafe { decoded.as_ref() }
        .and_then(|d| d.value.as_ref())
        .and_then(|v| v.groups.as_ref())
        .and_then(|g| g.get(index))
    {
        view.id = text_bytes(&group.id);
        view.timestamp = group.timestamp;
        view.present = 3;
    }
    view
}
/// # Safety
/// Decoded owner is live for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_decoded_has_groups(
    decoded: *const Decoded,
) -> u8 {
    unsafe { decoded.as_ref() }
        .and_then(|d| d.value.as_ref())
        .is_some_and(|v| v.groups.is_some()) as u8
}
