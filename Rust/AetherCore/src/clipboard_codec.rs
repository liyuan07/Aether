// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Streaming clipboard serializer over compact borrowed records: no second item/URL list.
use crate::{
    abi::Bytes,
    clipboard_archive::{Store, valid_base64},
    rule_codec::Span,
};
use serde::{
    Serialize, Serializer,
    ser::{SerializeSeq, SerializeStruct},
};

#[repr(C)]
pub struct Item {
    id: Span,
    preview: Span,
    string_data: Span,
    image_file_name: Span,
    image_content_hash: Span,
    rtf_data: Span,
    rtf_file_name: Span,
    timestamp: f64,
    url_start: usize,
    file_count: usize,
    present: u16,
    kind: u8,
    pinned: u8,
}
#[repr(C)]
pub struct Group {
    id: Span,
    timestamp: f64,
    start: usize,
    count: usize,
}
struct Archive<'a> {
    rows: &'a [Item],
    urls: &'a [Span],
    groups: &'a [Group],
    bytes: &'a [u8],
    history_count: usize,
    pinned_end: usize,
    has_groups: bool,
}
fn text(span: Span, bytes: &[u8]) -> Result<&str, u32> {
    span.text(bytes).ok_or(3)
}
fn range(start: usize, count: usize, length: usize) -> Result<std::ops::Range<usize>, u32> {
    let end = start
        .checked_add(count)
        .filter(|&v| v <= length)
        .ok_or(3_u32)?;
    Ok(start..end)
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
impl Archive<'_> {
    fn validate(&self) -> Result<(), u32> {
        if self.pinned_end > self.rows.len()
            || !self.has_groups && (!self.groups.is_empty() || self.pinned_end != self.rows.len())
        {
            return Err(3);
        }
        let mut expected = self.pinned_end;
        for g in self.groups {
            if g.start != expected
                || !g.timestamp.is_finite()
                || !crate::versioned::valid_uuid(text(g.id, self.bytes)?)
            {
                return Err(3);
            }
            expected = range(g.start, g.count, self.rows.len())?.end;
        }
        if expected != self.rows.len() {
            return Err(3);
        }
        for i in self.rows {
            if i.present & 7 != 7
                || i.kind > 5
                || !i.timestamp.is_finite()
                || !crate::versioned::valid_uuid(text(i.id, self.bytes)?)
            {
                return Err(3);
            }
            text(i.preview, self.bytes)?;
            for (field, bit) in [
                (i.string_data, 8),
                (i.image_file_name, 16),
                (i.image_content_hash, 32),
                (i.rtf_file_name, 256),
            ] {
                if i.present & bit != 0 {
                    text(field, self.bytes)?;
                }
            }
            if i.present & 128 != 0 && !valid_base64(text(i.rtf_data, self.bytes)?) {
                return Err(3);
            }
            if i.present & 64 != 0 {
                for &url in &self.urls[range(i.url_start, i.file_count, self.urls.len())?] {
                    text(url, self.bytes)?;
                }
            }
        }
        Ok(())
    }
}
struct URLs<'a> {
    spans: &'a [Span],
    bytes: &'a [u8],
}
impl Serialize for URLs<'_> {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut seq = s.serialize_seq(Some(self.spans.len()))?;
        for span in self.spans {
            seq.serialize_element(span.text(self.bytes).expect("validated URL span"))?;
        }
        seq.end()
    }
}
struct Record<'a> {
    item: &'a Item,
    archive: &'a Archive<'a>,
}
impl Serialize for Record<'_> {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let i = self.item;
        let a = self.archive;
        let t = |span: Span| span.text(a.bytes).expect("validated text span");
        let mut map = s.serialize_struct("Item", 5 + (i.present & 0x1f8).count_ones() as usize)?;
        map.serialize_field("id", t(i.id))?;
        map.serialize_field(
            "type",
            ["text", "url", "file", "image", "rtf", "unknown"][i.kind as usize],
        )?;
        map.serialize_field("timestamp", &i.timestamp)?;
        map.serialize_field("preview", t(i.preview))?;
        map.serialize_field("isPinned", &(i.pinned != 0))?;
        for (key, field, bit) in [
            ("stringData", i.string_data, 8),
            ("imageFileName", i.image_file_name, 16),
            ("imageContentHash", i.image_content_hash, 32),
        ] {
            if i.present & bit != 0 {
                map.serialize_field(key, t(field))?;
            }
        }
        if i.present & 64 != 0 {
            map.serialize_field(
                "fileURLs",
                &URLs {
                    spans: &a.urls[i.url_start..i.url_start + i.file_count],
                    bytes: a.bytes,
                },
            )?;
        }
        for (key, field, bit) in [
            ("rtfData", i.rtf_data, 128),
            ("rtfFileName", i.rtf_file_name, 256),
        ] {
            if i.present & bit != 0 {
                map.serialize_field(key, t(field))?;
            }
        }
        map.end()
    }
}
struct Items<'a> {
    rows: &'a [Item],
    archive: &'a Archive<'a>,
}
impl Serialize for Items<'_> {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut seq = s.serialize_seq(Some(self.rows.len()))?;
        for item in self.rows {
            seq.serialize_element(&Record {
                item,
                archive: self.archive,
            })?;
        }
        seq.end()
    }
}
struct GroupRecord<'a> {
    group: &'a Group,
    archive: &'a Archive<'a>,
}
impl Serialize for GroupRecord<'_> {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let g = self.group;
        let a = self.archive;
        let mut map = s.serialize_struct("Group", 3)?;
        map.serialize_field("id", g.id.text(a.bytes).expect("validated group UUID"))?;
        map.serialize_field("timestamp", &g.timestamp)?;
        map.serialize_field(
            "items",
            &Items {
                rows: &a.rows[g.start..g.start + g.count],
                archive: a,
            },
        )?;
        map.end()
    }
}
struct Groups<'a>(&'a Archive<'a>);
impl Serialize for Groups<'_> {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut seq = s.serialize_seq(Some(self.0.groups.len()))?;
        for group in self.0.groups {
            seq.serialize_element(&GroupRecord {
                group,
                archive: self.0,
            })?;
        }
        seq.end()
    }
}
impl Serialize for Archive<'_> {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut map = s.serialize_struct("Archive", if self.has_groups { 3 } else { 2 })?;
        map.serialize_field(
            "history",
            &Items {
                rows: &self.rows[..self.history_count],
                archive: self,
            },
        )?;
        map.serialize_field(
            "pinnedItems",
            &Items {
                rows: &self.rows[self.history_count..self.pinned_end],
                archive: self,
            },
        )?;
        if self.has_groups {
            map.serialize_field("groups", &Groups(self))?;
        }
        map.end()
    }
}
/// Native primitives only: canonical Unicode equality and FileManager enumeration/removal.
/// Returned name bytes remain valid until the next callback; no pointer survives this call.
#[repr(C)]
pub struct ResourceCleanup {
    context: *mut std::ffi::c_void,
    canonical: Option<unsafe extern "C" fn(*mut std::ffi::c_void, Bytes) -> Bytes>,
    enumerate: Option<unsafe extern "C" fn(*mut std::ffi::c_void, u8) -> usize>,
    name: Option<unsafe extern "C" fn(*mut std::ffi::c_void, usize) -> Bytes>,
    remove: Option<unsafe extern "C" fn(*mut std::ffi::c_void, usize)>,
}
pub struct ResourcePlan {
    kept: [std::collections::HashSet<Vec<u8>>; 2],
}
impl Archive<'_> {
    unsafe fn resource_plan(&self, callbacks: &ResourceCleanup) -> Option<ResourcePlan> {
        let canonical = callbacks.canonical?;
        let mut plan = ResourcePlan {
            kept: Default::default(),
        };
        for (kind, kept) in plan.kept.iter_mut().enumerate() {
            let mut raw_names = std::collections::HashSet::new();
            for row in self.rows {
                let (span, bit) = if kind == 0 {
                    (row.image_file_name, 16)
                } else {
                    (row.rtf_file_name, 256)
                };
                if row.present & bit == 0 {
                    continue;
                }
                let value = span
                    .text(self.bytes)
                    .expect("validated resource span")
                    .as_bytes();
                // Identical raw names have identical canonical names; borrow them only in this scope.
                if !raw_names.insert(value) {
                    continue;
                }
                // ASCII is already canonically composed; do not cross into Foundation for it.
                let normalized = if value.is_ascii() {
                    value
                } else {
                    let normalized = unsafe {
                        canonical(
                            callbacks.context,
                            Bytes {
                                data: value.as_ptr(),
                                length: value.len(),
                            },
                        )
                    };
                    unsafe { normalized.slice() }?
                };
                if !kept.contains(normalized) {
                    kept.insert(normalized.to_vec());
                }
            }
        }
        Some(plan)
    }
}
/// # Safety
/// Plan is live; callback context is live. Run synchronously after the native encoding wire is freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_resource_cleanup_run(
    plan: *const ResourcePlan,
    callbacks: *const ResourceCleanup,
) {
    let (Some(plan), Some(callbacks)) = (unsafe { plan.as_ref() }, unsafe { callbacks.as_ref() })
    else {
        return;
    };
    let (Some(enumerate), Some(name), Some(remove)) =
        (callbacks.enumerate, callbacks.name, callbacks.remove)
    else {
        return;
    };
    for (kind, kept) in plan.kept.iter().enumerate() {
        let count = unsafe { enumerate(callbacks.context, kind as u8) };
        // Validate all candidate names before any removals, matching the prior planner.
        let mut indices = Vec::new();
        for index in 0..count {
            let candidate = unsafe { name(callbacks.context, index) };
            let Some(candidate) = (unsafe { candidate.slice() }) else {
                return;
            };
            if !kept.contains(candidate) {
                indices.push(index);
            }
        }
        for index in indices {
            unsafe { remove(callbacks.context, index) };
        }
    }
}
/// # Safety
/// Destroy a live plan once after all synchronous calls finish.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_resource_cleanup_destroy(plan: *mut ResourcePlan) {
    if !plan.is_null() {
        drop(unsafe { Box::from_raw(plan) });
    }
}
/// # Safety
/// Same contract as write_spans_preparing_cleanup; cleanup is omitted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_write_spans(
    store: *mut Store,
    rows: *const Item,
    row_count: usize,
    history_count: usize,
    pinned_count: usize,
    urls: *const Span,
    url_count: usize,
    groups: *const Group,
    group_count: usize,
    has_groups: u8,
    bytes: Bytes,
) -> u32 {
    unsafe {
        aether_clipboard_archive_write_spans_preparing_cleanup(
            store,
            rows,
            row_count,
            history_count,
            pinned_count,
            urls,
            url_count,
            groups,
            group_count,
            has_groups,
            bytes,
            std::ptr::null(),
            std::ptr::null_mut(),
        )
    }
}
/// # Safety
/// Store is live and exclusively borrowed. All arrays/bytes are immutable and live until return.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_archive_write_spans_preparing_cleanup(
    store: *mut Store,
    rows: *const Item,
    row_count: usize,
    history_count: usize,
    pinned_count: usize,
    urls: *const Span,
    url_count: usize,
    groups: *const Group,
    group_count: usize,
    has_groups: u8,
    bytes: Bytes,
    cleanup: *const ResourceCleanup,
    plan: *mut *mut ResourcePlan,
) -> u32 {
    if let Some(plan) = unsafe { plan.as_mut() } {
        *plan = std::ptr::null_mut();
    }
    let result = (|| {
        let store = unsafe { store.as_mut() }.ok_or(3_u32)?;
        let archive = Archive {
            rows: unsafe { span(rows, row_count) }?,
            urls: unsafe { span(urls, url_count) }?,
            groups: unsafe { span(groups, group_count) }?,
            bytes: unsafe { bytes.slice() }.ok_or(3_u32)?,
            history_count,
            pinned_end: history_count.checked_add(pinned_count).ok_or(3_u32)?,
            has_groups: has_groups != 0,
        };
        archive.validate()?;
        let encoded = serde_json::to_vec(&archive).map_err(|_| 3_u32)?;
        store.write_compact(&encoded)?;
        drop(encoded);
        if let (Some(callbacks), Some(output)) =
            (unsafe { cleanup.as_ref() }, unsafe { plan.as_mut() })
        {
            if let Some(plan) = unsafe { archive.resource_plan(callbacks) } {
                *output = Box::into_raw(Box::new(plan));
            }
        }
        Ok(())
    })();
    result.err().unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn add(bytes: &mut Vec<u8>, value: &str) -> Span {
        let start = bytes.len();
        bytes.extend_from_slice(value.as_bytes());
        Span {
            start,
            length: value.len(),
        }
    }
    #[derive(Default)]
    struct Files {
        kind: u8,
        removed: Vec<(u8, usize)>,
        invalid: bool,
    }
    unsafe extern "C" fn canonical(_: *mut std::ffi::c_void, value: Bytes) -> Bytes {
        value
    }
    unsafe extern "C" fn enumerate(context: *mut std::ffi::c_void, kind: u8) -> usize {
        unsafe { &mut *context.cast::<Files>() }.kind = kind;
        2
    }
    unsafe extern "C" fn name(context: *mut std::ffi::c_void, index: usize) -> Bytes {
        let files = unsafe { &mut *context.cast::<Files>() };
        if files.invalid && index == 1 {
            return Bytes {
                data: std::ptr::null(),
                length: 1,
            };
        }
        let value: &[u8] = if index == 0 { b"keep" } else { b"old" };
        Bytes {
            data: value.as_ptr(),
            length: value.len(),
        }
    }
    unsafe extern "C" fn remove(context: *mut std::ffi::c_void, index: usize) {
        let files = unsafe { &mut *context.cast::<Files>() };
        files.removed.push((files.kind, index));
    }
    #[test]
    fn resource_plan_owns_names_and_validates_all_candidates_before_removal() {
        let mut files = Files::default();
        let callbacks = ResourceCleanup {
            context: (&mut files as *mut Files).cast(),
            canonical: Some(canonical),
            enumerate: Some(enumerate),
            name: Some(name),
            remove: Some(remove),
        };
        let mut bytes = b"keep".to_vec();
        let field = Span {
            start: 0,
            length: bytes.len(),
        };
        let unused = Span {
            start: 0,
            length: 0,
        };
        let rows = [Item {
            id: unused,
            preview: unused,
            string_data: unused,
            image_file_name: field,
            image_content_hash: unused,
            rtf_data: unused,
            rtf_file_name: field,
            timestamp: 0.,
            url_start: 0,
            file_count: 0,
            present: 16 | 256,
            kind: 5,
            pinned: 0,
        }];
        let plan = unsafe {
            Archive {
                rows: &rows,
                urls: &[],
                groups: &[],
                bytes: &bytes,
                history_count: 1,
                pinned_end: 1,
                has_groups: false,
            }
            .resource_plan(&callbacks)
        }
        .unwrap();
        bytes.fill(b'x');
        drop(bytes);
        unsafe { aether_clipboard_resource_cleanup_run(&plan, &callbacks) };
        assert_eq!(files.removed, [(0, 1), (1, 1)]);
        files.removed.clear();
        files.invalid = true;
        unsafe { aether_clipboard_resource_cleanup_run(&plan, &callbacks) };
        assert!(files.removed.is_empty());
        unsafe { aether_clipboard_resource_cleanup_run(std::ptr::null(), &callbacks) };
        unsafe { aether_clipboard_resource_cleanup_destroy(std::ptr::null_mut()) };
    }
    #[test]
    fn failed_save_resets_cleanup_output_without_any_callbacks() {
        let mut files = Files::default();
        let callbacks = ResourceCleanup {
            context: (&mut files as *mut Files).cast(),
            canonical: Some(canonical),
            enumerate: Some(enumerate),
            name: Some(name),
            remove: Some(remove),
        };
        let mut plan = std::ptr::dangling_mut::<ResourcePlan>();
        let status = unsafe {
            aether_clipboard_archive_write_spans_preparing_cleanup(
                std::ptr::null_mut(),
                std::ptr::null(),
                0,
                0,
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                0,
                Bytes {
                    data: std::ptr::null(),
                    length: 0,
                },
                &callbacks,
                &mut plan,
            )
        };
        assert_eq!(status, 3);
        assert!(plan.is_null());
        assert!(files.removed.is_empty());
    }
    #[test]
    fn every_presence_combination_streams_exact_fields_and_float_bits() {
        let mut bytes = Vec::new();
        let id = add(&mut bytes, "12345678-1234-5678-90AB-1234567890AB");
        let preview = add(&mut bytes, "合成\0cafe\u{301}👨‍👩‍👧‍👦");
        let empty = add(&mut bytes, "");
        let rtf = add(&mut bytes, "AAH/gCIK");
        let urls = [preview, empty, preview];
        for bits in 0..64 {
            let item = Item {
                id,
                preview,
                string_data: empty,
                image_file_name: preview,
                image_content_hash: empty,
                rtf_data: rtf,
                rtf_file_name: preview,
                timestamp: -0.0,
                url_start: 0,
                file_count: urls.len(),
                present: 7 | (bits << 3),
                kind: 4,
                pinned: 255,
            };
            let rows = [item];
            let groups = [Group {
                id,
                timestamp: -0.125,
                start: 1,
                count: 0,
            }];
            let a = Archive {
                rows: &rows,
                urls: &urls,
                groups: &groups,
                bytes: &bytes,
                history_count: 0,
                pinned_end: 1,
                has_groups: true,
            };
            a.validate().unwrap();
            let encoded = serde_json::to_vec(&a).unwrap();
            let value: serde_json::Value = serde_json::from_slice(&encoded).unwrap();
            let i = &value["pinnedItems"][0];
            assert_eq!(i["preview"], "合成\0cafe\u{301}👨‍👩‍👧‍👦");
            assert_eq!(i["type"], "rtf");
            assert_eq!(i["isPinned"], true);
            assert!(
                String::from_utf8(encoded)
                    .unwrap()
                    .contains("\"timestamp\":-0.0")
            );
            for (n, key) in [
                "stringData",
                "imageFileName",
                "imageContentHash",
                "fileURLs",
                "rtfData",
                "rtfFileName",
            ]
            .iter()
            .enumerate()
            {
                assert_eq!(i.get(key).is_some(), bits & (1 << n) != 0);
            }
            if bits & 8 != 0 {
                assert_eq!(
                    i["fileURLs"],
                    serde_json::json!(["合成\0cafe\u{301}👨‍👩‍👧‍👦", "", "合成\0cafe\u{301}👨‍👩‍👧‍👦"])
                );
            }
            assert_eq!(value["history"], serde_json::json!([]));
            assert_eq!(value["groups"][0]["items"], serde_json::json!([]));
        }
    }
    #[test]
    fn absent_fields_are_ignored_but_present_ranges_must_be_valid() {
        let mut bytes = Vec::new();
        let id = add(&mut bytes, "12345678-1234-5678-90AB-1234567890AB");
        let preview = add(&mut bytes, "");
        let invalid = Span {
            start: usize::MAX,
            length: usize::MAX,
        };
        let item = Item {
            id,
            preview,
            string_data: invalid,
            image_file_name: invalid,
            image_content_hash: invalid,
            rtf_data: invalid,
            rtf_file_name: invalid,
            timestamp: 1.0,
            url_start: usize::MAX,
            file_count: usize::MAX,
            present: 7,
            kind: 0,
            pinned: 0,
        };
        let mut rows = [item];
        let valid = |rows: &[Item], groups: &[Group], history_count, pinned_end, has_groups| {
            Archive {
                rows,
                urls: &[],
                groups,
                bytes: &bytes,
                history_count,
                pinned_end,
                has_groups,
            }
            .validate()
            .is_ok()
        };
        assert!(valid(&rows, &[], 1, 1, false));
        for bit in [8, 16, 32, 64, 128, 256] {
            rows[0].present = 7 | bit;
            assert!(!valid(&rows, &[], 1, 1, false));
        }
        rows[0].present = 7;
        assert!(!valid(&rows, &[], 2, 2, false));
        assert!(!valid(&rows, &[], 0, 0, false));
        assert!(!valid(
            &rows,
            &[Group {
                id,
                timestamp: 0.0,
                start: usize::MAX,
                count: 1
            }],
            1,
            1,
            true
        ));
        assert!(!valid(
            &rows,
            &[Group {
                id,
                timestamp: f64::NAN,
                start: 1,
                count: 0
            }],
            1,
            1,
            true
        ));
        let missing = unsafe {
            aether_clipboard_archive_write_spans(
                std::ptr::null_mut(),
                std::ptr::null(),
                0,
                0,
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                0,
                Bytes {
                    data: std::ptr::null(),
                    length: 0,
                },
            )
        };
        assert_eq!(missing, 3);
    }
}
