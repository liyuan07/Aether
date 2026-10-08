// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use crate::abi::Bytes;
use crate::storage::{self, Buffer};
use crate::versioned;
use serde::{Deserialize, Serialize};
use std::{ffi::c_char, path::PathBuf};
#[derive(Serialize, Deserialize)]
struct Memo {
    id: String,
    title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    deadline: Option<f64>,
    #[serde(rename = "createdAt")]
    created_at: f64,
}
impl Memo {
    fn valid(&self) -> bool {
        versioned::valid_uuid(&self.id)
            && self.created_at.is_finite()
            && self.deadline.is_none_or(f64::is_finite)
    }
}
pub struct MemoStore {
    path: PathBuf,
    blocked: bool,
    items: Vec<Memo>,
}
fn read(path: &std::path::Path) -> Result<Vec<Memo>, u32> {
    let items: Vec<Memo> = versioned::read(path)?.unwrap_or_default();
    if !items.iter().all(Memo::valid) {
        return Err(2);
    }
    Ok(items)
}
impl MemoStore {
    fn load(&mut self) -> Result<(), u32> {
        match read(&self.path) {
            Ok(items) => {
                self.items = items;
                self.blocked = false;
                Ok(())
            }
            Err(e) => {
                self.blocked = true;
                Err(e)
            }
        }
    }
    fn add(&mut self, item: Memo) -> Result<(), u32> {
        if !item.valid() || item.title.is_empty() {
            return Err(3);
        }
        self.ensure_writable()?;
        let items: Vec<&Memo> = self.items.iter().chain(std::iter::once(&item)).collect();
        self.write(&items)?;
        self.items.push(item);
        Ok(())
    }
    fn ensure_writable(&mut self) -> Result<(), u32> {
        if self.blocked {
            return Err(2);
        }
        if let Err(e) = read(&self.path) {
            self.blocked = true;
            return Err(e);
        }
        Ok(())
    }
    fn write<T: Serialize + ?Sized>(&self, items: &T) -> Result<(), u32> {
        versioned::write(&self.path, items, false)
    }
    fn save(&mut self, items: Vec<Memo>) -> Result<(), u32> {
        self.ensure_writable()?;
        self.write(&items)?;
        self.items = items;
        Ok(())
    }
    fn order(&self) -> Vec<usize> {
        let mut indices: Vec<usize> = (0..self.items.len()).collect();
        indices.sort_by(|&a, &b| {
            let a = &self.items[a];
            let b = &self.items[b];
            let created = || {
                a.created_at
                    .partial_cmp(&b.created_at)
                    .unwrap_or(std::cmp::Ordering::Equal)
            };
            match (a.deadline, b.deadline) {
                (Some(x), Some(y)) => x
                    .partial_cmp(&y)
                    .unwrap_or(std::cmp::Ordering::Equal)
                    .then_with(created),
                (Some(_), None) => std::cmp::Ordering::Less,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (None, None) => created(),
            }
        });
        indices
    }
    fn result(&self, sorted: bool) -> *mut Buffer {
        let items: Vec<&Memo> = if sorted {
            self.order().iter().map(|&i| &self.items[i]).collect()
        } else {
            self.items.iter().collect()
        };
        match serde_json::to_vec(&items) {
            Ok(bytes) => storage::buffer(bytes, 0),
            Err(_) => storage::buffer(vec![], 2),
        }
    }
}
/// # Safety
/// Directory is a NUL-terminated OS path. Calls on a handle must be serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_memo_create(directory: *const c_char) -> *mut MemoStore {
    let Some(directory) = (unsafe { storage::path(directory) }) else {
        return std::ptr::null_mut();
    };
    Box::into_raw(Box::new(MemoStore {
        path: directory.join("items.json"),
        blocked: false,
        items: vec![],
    }))
}
/// # Safety
/// Destroy the handle exactly once after all borrowers finish.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_memo_destroy(store: *mut MemoStore) {
    if !store.is_null() {
        drop(unsafe { Box::from_raw(store) });
    }
}
/// # Safety
/// Store is live and exclusively borrowed for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_memo_load(store: *mut MemoStore) -> *mut Buffer {
    if store.is_null() {
        return storage::buffer(vec![], 2);
    }
    let s = unsafe { &mut *store };
    match s.load() {
        Ok(()) => s.result(false),
        Err(e) => storage::buffer(vec![], e),
    }
}
/// # Safety
/// Store is live; JSON is readable for length bytes; calls are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_memo_save(
    store: *mut MemoStore,
    json: *const u8,
    length: usize,
) -> u32 {
    if store.is_null() || json.is_null() {
        return 3;
    }
    let bytes = unsafe { std::slice::from_raw_parts(json, length) };
    let Ok(items) = serde_json::from_slice::<Vec<Memo>>(bytes) else {
        return 3;
    };
    if !items.iter().all(Memo::valid) {
        return 3;
    }
    unsafe { &mut *store }.save(items).err().unwrap_or(0)
}
/// # Safety
/// Store is live; item JSON is readable for length bytes; calls are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_memo_add(
    store: *mut MemoStore,
    json: *const u8,
    length: usize,
) -> u32 {
    if store.is_null() || json.is_null() {
        return 3;
    }
    let Ok(item) =
        serde_json::from_slice::<Memo>(unsafe { std::slice::from_raw_parts(json, length) })
    else {
        return 3;
    };
    unsafe { &mut *store }.add(item).err().unwrap_or(0)
}
/// # Safety
/// Store is live; ID is a readable NUL-terminated UTF-8 UUID; calls are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_memo_complete(store: *mut MemoStore, id: *const c_char) -> u32 {
    if store.is_null() || id.is_null() {
        return 3;
    }
    let Ok(id) = (unsafe { std::ffi::CStr::from_ptr(id) }).to_str() else {
        return 3;
    };
    let s = unsafe { &mut *store };
    if let Err(e) = s.ensure_writable() {
        return e;
    }
    let items: Vec<&Memo> = s
        .items
        .iter()
        .filter(|m| !m.id.eq_ignore_ascii_case(id))
        .collect();
    if let Err(e) = s.write(&items) {
        return e;
    }
    s.items.retain(|m| !m.id.eq_ignore_ascii_case(id));
    0
}
/// # Safety
/// Store is live and not concurrently mutated. Output owns its JSON bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_memo_snapshot(store: *const MemoStore, sorted: u8) -> *mut Buffer {
    if store.is_null() {
        return storage::buffer(vec![], 2);
    }
    unsafe { &*store }.result(sorted != 0)
}

/// # Safety
/// Store is live and exclusively borrowed; output is writable for capacity indices.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_memo_order(
    store: *const MemoStore,
    output: *mut usize,
    capacity: usize,
) -> usize {
    if store.is_null() {
        return 0;
    }
    let items = &unsafe { &*store }.items;
    if capacity < items.len() || output.is_null() {
        return items.len();
    }
    let indices = unsafe { &*store }.order();
    unsafe {
        std::ptr::copy_nonoverlapping(indices.as_ptr(), output, indices.len());
    }
    indices.len()
}

// Borrowed views remain valid until the next mutation of their store.
#[repr(C)]
pub struct MemoView {
    id: Bytes,
    title: Bytes,
    created_at: f64,
    deadline: f64,
    has_deadline: u8,
}
impl MemoView {
    unsafe fn owned(self) -> Option<Memo> {
        let item = Memo {
            id: unsafe { self.id.text()? }.to_owned(),
            title: unsafe { self.title.text()? }.to_owned(),
            created_at: self.created_at,
            deadline: (self.has_deadline != 0).then_some(self.deadline),
        };
        item.valid().then_some(item)
    }
}
pub struct MemoWriter {
    items: Vec<Memo>,
    failed: bool,
}
/// # Safety
/// Store is live and exclusively borrowed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_memo_load_records(store: *mut MemoStore) -> u32 {
    let Some(s) = (unsafe { store.as_mut() }) else {
        return 2;
    };
    s.load().err().unwrap_or(0)
}
/// # Safety
/// Store is live and not concurrently mutated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_memo_count(store: *const MemoStore) -> usize {
    unsafe { store.as_ref() }.map_or(0, |s| s.items.len())
}
/// # Safety
/// Store is live; output is writable. Borrowed bytes must be copied before mutation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_memo_record(
    store: *const MemoStore,
    index: usize,
    output: *mut MemoView,
) -> u8 {
    let Some(item) = (unsafe { store.as_ref() }).and_then(|s| s.items.get(index)) else {
        return 0;
    };
    let Some(output) = (unsafe { output.as_mut() }) else {
        return 0;
    };
    *output = MemoView {
        id: Bytes {
            data: item.id.as_ptr(),
            length: item.id.len(),
        },
        title: Bytes {
            data: item.title.as_ptr(),
            length: item.title.len(),
        },
        created_at: item.created_at,
        deadline: item.deadline.unwrap_or(0.0),
        has_deadline: u8::from(item.deadline.is_some()),
    };
    1
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_memo_writer_create() -> *mut MemoWriter {
    Box::into_raw(Box::new(MemoWriter {
        items: vec![],
        failed: false,
    }))
}
/// # Safety
/// Writer is live and exclusively borrowed; view bytes are readable for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_memo_writer_append(writer: *mut MemoWriter, view: MemoView) -> u32 {
    let Some(writer) = (unsafe { writer.as_mut() }) else {
        return 3;
    };
    if writer.failed {
        return 3;
    }
    match unsafe { view.owned() } {
        Some(item) => {
            writer.items.push(item);
            0
        }
        None => {
            writer.failed = true;
            3
        }
    }
}
/// # Safety
/// Store and writer are live, distinct, exclusively borrowed. Writer is consumed on success.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_memo_save_records(
    store: *mut MemoStore,
    writer: *mut MemoWriter,
) -> u32 {
    let Some(s) = (unsafe { store.as_mut() }) else {
        return 3;
    };
    let Some(writer) = (unsafe { writer.as_mut() }) else {
        return 3;
    };
    if writer.failed {
        return 3;
    }
    if let Err(e) = s.ensure_writable().and_then(|()| s.write(&writer.items)) {
        return e;
    }
    s.items = std::mem::take(&mut writer.items);
    0
}
/// # Safety
/// Writer is live and destroyed exactly once after its borrowers finish.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_memo_writer_destroy(writer: *mut MemoWriter) {
    if !writer.is_null() {
        drop(unsafe { Box::from_raw(writer) });
    }
}
/// # Safety
/// Store is live and exclusively borrowed; view bytes are readable for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_memo_add_record(store: *mut MemoStore, view: MemoView) -> u32 {
    let Some(s) = (unsafe { store.as_mut() }) else {
        return 3;
    };
    let Some(item) = (unsafe { view.owned() }) else {
        return 3;
    };
    s.add(item).err().unwrap_or(0)
}
