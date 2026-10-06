// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
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
    match read(&s.path) {
        Ok(items) => {
            s.items = items;
            s.blocked = false;
            s.result(false)
        }
        Err(e) => {
            s.blocked = true;
            storage::buffer(vec![], e)
        }
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
    if !item.valid() || item.title.is_empty() {
        return 3;
    }
    let s = unsafe { &mut *store };
    if let Err(e) = s.ensure_writable() {
        return e;
    }
    let items: Vec<&Memo> = s.items.iter().chain(std::iter::once(&item)).collect();
    if let Err(e) = s.write(&items) {
        return e;
    }
    s.items.push(item);
    0
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
