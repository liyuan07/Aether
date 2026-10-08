// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use crate::json::Text;
use crate::{
    abi::Bytes,
    storage::{self, Buffer},
    versioned,
};
use serde::{Deserialize, Serialize};
use std::{ffi::c_char, path::PathBuf};
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Item<'a> {
    #[serde(borrow)]
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<Text<'a>>,
    #[serde(borrow)]
    #[serde(skip_serializing_if = "Option::is_none")]
    r#type: Option<Text<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    timestamp: Option<f64>,
    #[serde(borrow)]
    #[serde(skip_serializing_if = "Option::is_none")]
    preview: Option<Text<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    is_pinned: Option<bool>,
    #[serde(borrow)]
    #[serde(skip_serializing_if = "Option::is_none")]
    string_data: Option<Text<'a>>,
    #[serde(borrow)]
    #[serde(skip_serializing_if = "Option::is_none")]
    image_file_name: Option<Text<'a>>,
    #[serde(borrow)]
    #[serde(skip_serializing_if = "Option::is_none")]
    image_content_hash: Option<Text<'a>>,
    #[serde(rename = "fileURLs", borrow)]
    #[serde(skip_serializing_if = "Option::is_none")]
    file_urls: Option<Vec<Text<'a>>>,
    #[serde(borrow)]
    #[serde(skip_serializing_if = "Option::is_none")]
    rtf_data: Option<Text<'a>>,
    #[serde(borrow)]
    #[serde(skip_serializing_if = "Option::is_none")]
    rtf_file_name: Option<Text<'a>>,
}
#[derive(Deserialize, Serialize)]
struct Group<'a> {
    #[serde(borrow)]
    id: Text<'a>,
    timestamp: f64,
    #[serde(borrow)]
    items: Vec<Item<'a>>,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Archive<'a> {
    #[serde(borrow)]
    history: Vec<Item<'a>>,
    #[serde(borrow)]
    pinned_items: Vec<Item<'a>>,
    #[serde(borrow)]
    #[serde(skip_serializing_if = "Option::is_none")]
    groups: Option<Vec<Group<'a>>>,
}
pub(crate) fn valid_base64(value: &str) -> bool {
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
        self.read_matching(None)
    }
    fn read_matching(&mut self, validated: Option<&[u8]>) -> Result<Option<Vec<u8>>, u32> {
        let result = storage::read(&self.path, false)
            .map_err(|_| 2_u32)
            .and_then(|bytes| {
                if let Some(bytes) = &bytes {
                    // Exact bytes from a freshly validated encoder output are already known valid.
                    // Every differing external file still goes through the complete legacy validator.
                    if validated != Some(bytes.as_slice()) {
                        validate(bytes)?;
                    }
                }
                Ok(bytes)
            });
        self.blocked = result.is_err();
        result
    }
    fn write(&mut self, bytes: &[u8]) -> Result<(), u32> {
        validate(bytes).map_err(|_| 3_u32)?;
        self.write_validated(bytes)
    }
    pub(crate) fn write_validated(&mut self, bytes: &[u8]) -> Result<(), u32> {
        self.write_checked(bytes, false)
    }
    /// Called only with fully validated compact records encoded by the streaming serializer.
    pub(crate) fn write_compact(&mut self, bytes: &[u8]) -> Result<(), u32> {
        self.write_checked(bytes, true)
    }
    fn write_checked(&mut self, bytes: &[u8], skip_identical: bool) -> Result<(), u32> {
        if self.blocked {
            return Err(2);
        }
        // External updates must be checked before a replacement, including writes before initial load.
        // Preserve legacy replacement of leaf symbolic links, even if their target bytes match.
        let can_skip = skip_identical
            && std::fs::symlink_metadata(&self.path)
                .is_ok_and(|m| m.is_file() && !m.file_type().is_symlink());
        let current = self.read_matching(if can_skip { Some(bytes) } else { None })?;
        if can_skip && current.as_deref() == Some(bytes) {
            return Ok(());
        }
        // Release the prior file bytes before the write; retain only the encoded output.
        drop(current);
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

#[repr(C)]
pub struct WriteItem {
    item: ItemView,
    url_start: usize,
}
#[repr(C)]
pub struct WriteGroup {
    id: Bytes,
    timestamp: f64,
    start: usize,
    count: usize,
}
unsafe fn borrowed<'a>(bytes: Bytes) -> Result<Text<'a>, u32> {
    unsafe { bytes.text() }
        .map(|s| Text(std::borrow::Cow::Borrowed(s)))
        .ok_or(3)
}
unsafe fn borrowed_optional<'a>(
    bytes: Bytes,
    present: u16,
    bit: u16,
) -> Result<Option<Text<'a>>, u32> {
    if present & bit == 0 {
        Ok(None)
    } else {
        unsafe { borrowed(bytes) }.map(Some)
    }
}
unsafe fn span<'a, T>(ptr: *const T, count: usize) -> Result<&'a [T], u32> {
    if count == 0 {
        Ok(&[])
    } else if ptr.is_null() {
        Err(3)
    } else {
        Ok(unsafe { std::slice::from_raw_parts(ptr, count) })
    }
}
unsafe fn write_item<'a>(row: &WriteItem, urls: &[Bytes]) -> Result<Item<'a>, u32> {
    let i = &row.item;
    if i.present & 7 != 7 || i.kind > 5 {
        return Err(3);
    }
    let file_urls = if i.present & 64 != 0 {
        let end = row.url_start.checked_add(i.file_count).ok_or(3_u32)?;
        Some(
            urls.get(row.url_start..end)
                .ok_or(3_u32)?
                .iter()
                .map(|bytes| unsafe { borrowed(*bytes) })
                .collect::<Result<_, _>>()?,
        )
    } else {
        None
    };
    Ok(Item {
        id: Some(unsafe { borrowed(i.id) }?),
        r#type: Some(Text(std::borrow::Cow::Borrowed(
            ["text", "url", "file", "image", "rtf", "unknown"][i.kind as usize],
        ))),
        timestamp: Some(i.timestamp),
        preview: Some(unsafe { borrowed(i.preview) }?),
        is_pinned: Some(i.pinned != 0),
        string_data: unsafe { borrowed_optional(i.string_data, i.present, 8) }?,
        image_file_name: unsafe { borrowed_optional(i.image_file_name, i.present, 16) }?,
        image_content_hash: unsafe { borrowed_optional(i.image_content_hash, i.present, 32) }?,
        file_urls,
        rtf_data: unsafe { borrowed_optional(i.rtf_data, i.present, 128) }?,
        rtf_file_name: unsafe { borrowed_optional(i.rtf_file_name, i.present, 256) }?,
    })
}
/// # Safety
/// Store is live and exclusively borrowed. Input arrays and byte views are readable until return.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_write_records(
    store: *mut Store,
    rows: *const WriteItem,
    row_count: usize,
    history_count: usize,
    pinned_count: usize,
    urls: *const Bytes,
    url_count: usize,
    groups: *const WriteGroup,
    group_count: usize,
    has_groups: u8,
) -> u32 {
    let result = (|| -> Result<(), u32> {
        let store = unsafe { store.as_mut() }.ok_or(3_u32)?;
        let rows = unsafe { span(rows, row_count) }?;
        let urls = unsafe { span(urls, url_count) }?;
        let groups = unsafe { span(groups, group_count) }?;
        let pinned_end = history_count.checked_add(pinned_count).ok_or(3_u32)?;
        if pinned_end > rows.len()
            || (has_groups == 0 && (!groups.is_empty() || pinned_end != rows.len()))
        {
            return Err(3);
        }
        let convert = |rows: &[WriteItem]| {
            rows.iter()
                .map(|row| unsafe { write_item(row, urls) })
                .collect::<Result<Vec<_>, _>>()
        };
        let mut expected_start = pinned_end;
        let groups = if has_groups != 0 {
            Some(
                groups
                    .iter()
                    .map(|group| {
                        let end = group.start.checked_add(group.count).ok_or(3_u32)?;
                        if group.start != expected_start {
                            return Err(3);
                        }
                        expected_start = end;
                        Ok(Group {
                            id: unsafe { borrowed(group.id) }?,
                            timestamp: group.timestamp,
                            items: convert(rows.get(group.start..end).ok_or(3_u32)?)?,
                        })
                    })
                    .collect::<Result<Vec<_>, u32>>()?,
            )
        } else {
            None
        };
        if expected_start != rows.len() {
            return Err(3);
        }
        let archive = Archive {
            history: convert(&rows[..history_count])?,
            pinned_items: convert(&rows[history_count..pinned_end])?,
            groups,
        };
        if !valid_archive(&archive) {
            return Err(3);
        }
        let bytes = serde_json::to_vec(&archive).map_err(|_| 3_u32)?;
        store.write_validated(&bytes)
    })();
    result.err().unwrap_or(0)
}

#[cfg(test)]
mod compact_gate_tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::MetadataExt,
        sync::atomic::{AtomicU64, Ordering},
    };
    static ID: AtomicU64 = AtomicU64::new(0);
    #[test]
    fn exact_validated_output_skips_rewrite_but_never_bypasses_blocking() {
        let directory = std::env::temp_dir().join(format!(
            "aether-compact-gate-{}-{}",
            std::process::id(),
            ID.fetch_add(1, Ordering::Relaxed)
        ));
        let path = directory.join("history.json");
        let bytes = br#"{"history":[],"pinnedItems":[]}"#;
        validate(bytes).unwrap();
        let mut s = Store {
            path: path.clone(),
            blocked: false,
        };
        s.write_compact(bytes).unwrap();
        let inode = fs::metadata(&path).unwrap().ino();
        s.write_compact(bytes).unwrap();
        assert_eq!(fs::metadata(&path).unwrap().ino(), inode);
        fs::write(&path, b"{corrupt synthetic}").unwrap();
        assert_eq!(s.write_compact(bytes), Err(2));
        fs::write(&path, bytes).unwrap();
        assert_eq!(s.write_compact(bytes), Err(2));
        s.read().unwrap();
        s.write_compact(bytes).unwrap();
        fs::write(&path, br#"{"history":[],"pinnedItems":[],"groups":[]}"#).unwrap();
        s.write_compact(bytes).unwrap();
        assert_eq!(fs::read(&path).unwrap(), bytes);
        fs::remove_dir_all(directory).unwrap();
    }
}
