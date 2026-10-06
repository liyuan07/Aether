// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use crate::{
    abi::Bytes,
    storage::{self, Buffer},
    versioned,
};
use serde::{Deserialize, Serialize};
use std::{
    ffi::c_char,
    path::{Path, PathBuf},
    sync::Arc,
};

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    id: String,
    key: String,
    value: Arc<str>,
    created_at: f64,
    updated_at: f64,
    #[serde(skip)]
    comparison: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Collection {
    id: String,
    name: String,
    created_at: f64,
    updated_at: f64,
    entries: Arc<Vec<Entry>>,
    #[serde(skip)]
    comparison: String,
}
impl Collection {
    fn valid(&self) -> bool {
        versioned::valid_uuid(&self.id)
            && self.created_at.is_finite()
            && self.updated_at.is_finite()
            && self.entries.iter().all(|e| {
                versioned::valid_uuid(&e.id) && e.created_at.is_finite() && e.updated_at.is_finite()
            })
    }
}
#[derive(Serialize, Deserialize)]
struct Envelope {
    #[serde(rename = "schemaVersion", deserialize_with = "versioned::integer")]
    version: i64,
    collections: Vec<Collection>,
}
fn read(path: &Path) -> Result<Vec<Collection>, u32> {
    let Some(bytes) = storage::read(path, true).map_err(|_| 2_u32)? else {
        return Ok(vec![]);
    };
    // Inspect the version before interpreting the payload of a future format.
    #[derive(Deserialize)]
    struct Version {
        #[serde(rename = "schemaVersion", deserialize_with = "versioned::integer")]
        value: i64,
    }
    if serde_json::from_slice::<Version>(&bytes)
        .map_err(|_| 2_u32)?
        .value
        != 1
    {
        return Err(4);
    }
    let value: Envelope = serde_json::from_slice(&bytes).map_err(|_| 2_u32)?;
    if !value.collections.iter().all(Collection::valid) {
        return Err(2);
    }
    Ok(value.collections)
}
pub struct Store {
    path: PathBuf,
    blocked: bool,
    collections: Vec<Collection>,
}
impl Store {
    fn load(&mut self) -> Result<(), u32> {
        match read(&self.path) {
            Ok(value) => {
                self.collections = value;
                self.blocked = false;
                Ok(())
            }
            Err(e) => {
                self.blocked = true;
                Err(e)
            }
        }
    }
    fn save(&mut self, value: Vec<Collection>) -> Result<(), u32> {
        if self.blocked {
            return Err(2);
        }
        if let Err(e) = read(&self.path) {
            self.blocked = true;
            return Err(e);
        }
        if !value.iter().all(Collection::valid) {
            return Err(3);
        }
        let envelope = Envelope {
            version: 1,
            collections: value,
        };
        let bytes = serde_json::to_vec_pretty(&envelope).map_err(|_| 3_u32)?;
        storage::write(&self.path, &bytes, true, false).map_err(|_| 3_u32)?;
        self.collections = envelope.collections;
        Ok(())
    }
}
#[derive(Deserialize)]
struct Comparisons {
    name: String,
    keys: Vec<String>,
}
#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
struct Command {
    action: u32,
    id: String,
    #[serde(rename = "collectionID")]
    collection_id: String,
    #[serde(rename = "entryID")]
    entry_id: String,
    name: String,
    key: String,
    value: String,
    comparison: String,
    nonempty: bool,
    date: f64,
    index: usize,
    collection: Option<Collection>,
    entry: Option<Entry>,
    keys: Vec<String>,
}
#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
struct Reply<'a> {
    error: u32,
    #[serde(rename = "existingID")]
    existing_id: Option<String>,
    #[serde(rename = "resultID")]
    result_id: Option<String>,
    selection: Option<String>,
    patch: Option<Patch<'a>>,
    deleted_collection: Option<Collection>,
    deleted_entry: Option<Entry>,
    index: usize,
}
#[derive(Serialize)]
struct Patch<'a> {
    kind: u32,
    index: usize,
    collection: Option<&'a Collection>,
}
fn output<T: Serialize>(value: Result<T, u32>) -> *mut Buffer {
    match value {
        Ok(value) => match serde_json::to_vec(&value) {
            Ok(bytes) => storage::buffer(bytes, 0),
            Err(_) => storage::buffer(vec![], 3),
        },
        Err(e) => storage::buffer(vec![], e),
    }
}
fn fail(error: u32, existing: Option<&str>) -> Reply<'static> {
    Reply {
        error,
        existing_id: existing.map(str::to_owned),
        ..Reply::default()
    }
}
fn apply(s: &mut Store, c: Command) -> Result<Reply<'_>, u32> {
    if c.action == 0 {
        return Ok(Reply {
            result_id: s
                .collections
                .iter()
                .find(|v| v.comparison == c.comparison)
                .map(|v| v.id.clone()),
            ..Reply::default()
        });
    }
    let mut next = s.collections.clone();
    let patch_index;
    let patch_kind;
    let mut reply = Reply::default();
    let collection_index = next
        .iter()
        .position(|v| v.id.eq_ignore_ascii_case(&c.collection_id));
    let same_name = |name: &str| next.iter().find(|v| v.comparison == name);
    match c.action {
        1 | 2 => {
            let (name, comparison) = if c.action == 2 {
                let mut index = 1;
                while same_name(&format!("常用 {index}")).is_some() {
                    index += 1;
                }
                let name = format!("常用 {index}");
                (name.clone(), name)
            } else {
                (c.name, c.comparison)
            };
            if name.is_empty() {
                return Ok(fail(200, None));
            }
            if let Some(existing) = same_name(&comparison) {
                return Ok(fail(201, Some(&existing.id)));
            }
            reply.result_id = Some(c.id.clone());
            reply.selection = Some(c.id.clone());
            patch_index = next.len();
            patch_kind = 1;
            next.push(Collection {
                id: c.id,
                name,
                created_at: c.date,
                updated_at: c.date,
                entries: Arc::new(vec![]),
                comparison,
            });
        }
        3 => {
            if c.name.is_empty() {
                return Ok(fail(200, None));
            }
            if let Some(existing) = same_name(&c.comparison) {
                if !existing.id.eq_ignore_ascii_case(&c.collection_id) {
                    return Ok(fail(201, Some(&existing.id)));
                }
            }
            let Some(i) = collection_index else {
                return Ok(fail(202, None));
            };
            patch_index = i;
            patch_kind = 2;
            next[i].name = c.name;
            next[i].comparison = c.comparison;
            next[i].updated_at = c.date;
        }
        4 => {
            let Some(i) = collection_index else {
                return Ok(fail(202, None));
            };
            patch_index = i;
            patch_kind = 3;
            reply.deleted_collection = Some(next.remove(i));
            reply.index = i;
            reply.selection = next.get(i).or_else(|| next.last()).map(|v| v.id.clone());
        }
        5 => {
            let Some(mut value) = c.collection else {
                return Ok(fail(202, None));
            };
            if same_name(&c.comparison).is_some() {
                return Ok(fail(201, None));
            }
            if value.entries.len() != c.keys.len() {
                return Err(3);
            }
            value.comparison = c.comparison;
            for (entry, key) in Arc::make_mut(&mut value.entries).iter_mut().zip(c.keys) {
                entry.comparison = key;
            }
            reply.selection = Some(value.id.clone());
            patch_index = c.index.min(next.len());
            patch_kind = 1;
            next.insert(patch_index, value);
        }
        6 | 7 => {
            if c.key.is_empty() {
                return Ok(fail(203, None));
            }
            if !c.nonempty {
                return Ok(fail(204, None));
            }
            let Some(i) = collection_index else {
                return Ok(fail(202, None));
            };
            patch_index = i;
            patch_kind = 2;
            let entry_index = next[i]
                .entries
                .iter()
                .position(|v| v.id.eq_ignore_ascii_case(&c.entry_id));
            if c.action == 7 && entry_index.is_none() {
                return Ok(fail(202, None));
            }
            if let Some(existing) = next[i].entries.iter().find(|v| {
                v.comparison == c.comparison
                    && (c.action == 6 || !v.id.eq_ignore_ascii_case(&c.entry_id))
            }) {
                return Ok(fail(205, Some(&existing.id)));
            }
            if c.action == 6 {
                reply.result_id = Some(c.id.clone());
                Arc::make_mut(&mut next[i].entries).push(Entry {
                    id: c.id,
                    key: c.key,
                    value: c.value.into(),
                    created_at: c.date,
                    updated_at: c.date,
                    comparison: c.comparison,
                });
            } else {
                let value = &mut Arc::make_mut(&mut next[i].entries)[entry_index.unwrap()];
                value.key = c.key;
                value.value = c.value.into();
                value.updated_at = c.date;
                value.comparison = c.comparison;
            }
            next[i].updated_at = c.date;
        }
        8 => {
            let Some(i) = collection_index else {
                return Ok(fail(202, None));
            };
            patch_index = i;
            patch_kind = 2;
            let Some(j) = next[i]
                .entries
                .iter()
                .position(|v| v.id.eq_ignore_ascii_case(&c.entry_id))
            else {
                return Ok(fail(202, None));
            };
            reply.deleted_entry = Some(Arc::make_mut(&mut next[i].entries).remove(j));
            reply.index = j;
            next[i].updated_at = c.date;
        }
        9 => {
            let Some(i) = collection_index else {
                return Ok(fail(202, None));
            };
            patch_index = i;
            patch_kind = 2;
            let Some(mut value) = c.entry else {
                return Ok(fail(202, None));
            };
            if next[i].entries.iter().any(|v| v.comparison == c.comparison) {
                return Ok(fail(205, None));
            }
            value.comparison = c.comparison;
            let at = c.index.min(next[i].entries.len());
            Arc::make_mut(&mut next[i].entries).insert(at, value);
            next[i].updated_at = c.date;
        }
        _ => return Err(3),
    }
    s.save(next)?;
    reply.patch = Some(Patch {
        kind: patch_kind,
        index: patch_index,
        collection: if patch_kind == 3 {
            None
        } else {
            s.collections.get(patch_index)
        },
    });
    Ok(reply)
}
/// # Safety
/// Path is a readable C string. Store calls must be serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_quick_create(path: *const c_char) -> *mut Store {
    let Some(path) = (unsafe { storage::path(path) }) else {
        return std::ptr::null_mut();
    };
    Box::into_raw(Box::new(Store {
        path: path.to_path_buf(),
        blocked: false,
        collections: vec![],
    }))
}
/// # Safety
/// Destroy a live handle once after all calls finish.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_quick_destroy(s: *mut Store) {
    if !s.is_null() {
        drop(unsafe { Box::from_raw(s) });
    }
}
/// # Safety
/// Handle is live and exclusively borrowed. Output owns its JSON bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_quick_load(s: *mut Store) -> *mut Buffer {
    let Some(s) = (unsafe { s.as_mut() }) else {
        return storage::buffer(vec![], 2);
    };
    output(s.load().map(|()| &s.collections))
}
/// # Safety
/// Handle is live and serialized; data span remains readable during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_quick_save(s: *mut Store, data: Bytes) -> u32 {
    let Some(s) = (unsafe { s.as_mut() }) else {
        return 3;
    };
    let Some(bytes) = (unsafe { data.slice() }) else {
        return 3;
    };
    let Ok(value) = serde_json::from_slice::<Vec<Collection>>(bytes) else {
        return 3;
    };
    s.save(value).err().unwrap_or(0)
}
/// Platform-generated normalization preserves Foundation's locale and String equality.
/// # Safety
/// Handle is live and serialized; borrowed span remains readable during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_quick_comparisons(s: *mut Store, data: Bytes) -> u32 {
    let Some(s) = (unsafe { s.as_mut() }) else {
        return 3;
    };
    let Some(bytes) = (unsafe { data.slice() }) else {
        return 3;
    };
    let Ok(values) = serde_json::from_slice::<Vec<Comparisons>>(bytes) else {
        return 3;
    };
    if values.len() != s.collections.len()
        || values
            .iter()
            .zip(&s.collections)
            .any(|(v, c)| v.keys.len() != c.entries.len())
    {
        return 3;
    }
    for (value, collection) in values.into_iter().zip(&mut s.collections) {
        collection.comparison = value.name;
        for (key, entry) in value
            .keys
            .into_iter()
            .zip(Arc::make_mut(&mut collection.entries).iter_mut())
        {
            entry.comparison = key;
        }
    }
    0
}
/// # Safety
/// Handle is live and serialized; borrowed command remains readable during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_quick_apply(s: *mut Store, command: Bytes) -> *mut Buffer {
    let Some(s) = (unsafe { s.as_mut() }) else {
        return storage::buffer(vec![], 3);
    };
    let Some(bytes) = (unsafe { command.slice() }) else {
        return storage::buffer(vec![], 3);
    };
    let Ok(c) = serde_json::from_slice::<Command>(bytes) else {
        return storage::buffer(vec![], 3);
    };
    output(apply(s, c))
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SearchCollection {
    pub match_kind: u8,
    pub timestamp: f64,
    pub start: usize,
    pub count: usize,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct SearchEntry {
    pub key_match: u8,
    pub value_match: u8,
    pub timestamp: f64,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct SearchSection {
    pub collection: usize,
    pub start: usize,
    pub count: usize,
    pub rank: isize,
}
/// Foundation preserves the native locale/substring semantics; Rust owns ranking and grouping.
/// # Safety
/// Input slices are readable for their counts; output slices writable for their capacities.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_quick_search(
    collections: *const SearchCollection,
    collection_count: usize,
    entries: *const SearchEntry,
    entry_count: usize,
    sections: *mut SearchSection,
    section_capacity: usize,
    indices: *mut usize,
    index_capacity: usize,
) -> usize {
    if collection_count == 0 || collections.is_null() || (entry_count > 0 && entries.is_null()) {
        return 0;
    }
    let collections = unsafe { std::slice::from_raw_parts(collections, collection_count) };
    let entries = if entry_count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(entries, entry_count) }
    };
    let mut results = vec![];
    let mut ranked_indices = vec![];
    for (i, c) in collections.iter().enumerate() {
        let Some(end) = c.start.checked_add(c.count) else {
            return 0;
        };
        if end > entries.len() {
            return 0;
        }
        let mut ranks = vec![];
        if c.match_kind == 1 {
            ranks.extend((c.start..end).map(|j| (j, 0_isize)));
        } else {
            for (j, e) in entries.iter().enumerate().take(end).skip(c.start) {
                let rank = if e.key_match == 1 {
                    1
                } else if e.key_match == 2 || c.match_kind == 2 {
                    2
                } else if e.key_match == 3 || e.value_match != 0 || c.match_kind == 3 {
                    3
                } else {
                    continue;
                };
                ranks.push((j, rank));
            }
            ranks.sort_by(|a, b| {
                a.1.cmp(&b.1)
                    .then_with(|| {
                        entries[b.0]
                            .timestamp
                            .partial_cmp(&entries[a.0].timestamp)
                            .unwrap_or(std::cmp::Ordering::Equal)
                    })
                    .then(a.0.cmp(&b.0))
            });
        }
        if c.match_kind == 0 && ranks.is_empty() {
            continue;
        }
        let rank = if c.match_kind == 1 {
            0
        } else {
            (if c.match_kind == 0 {
                isize::MAX
            } else {
                c.match_kind as isize
            })
            .min(ranks.first().map(|r| r.1).unwrap_or(isize::MAX))
        };
        let section = SearchSection {
            collection: i,
            start: ranked_indices.len(),
            count: ranks.len(),
            rank,
        };
        ranked_indices.extend(ranks.into_iter().map(|v| v.0));
        results.push(section);
    }
    results.sort_by(|a, b| {
        a.rank.cmp(&b.rank).then_with(|| {
            collections[b.collection]
                .timestamp
                .partial_cmp(&collections[a.collection].timestamp)
                .unwrap_or(std::cmp::Ordering::Equal)
        })
    });
    if results.len() > section_capacity
        || ranked_indices.len() > index_capacity
        || sections.is_null()
        || (indices.is_null() && !ranked_indices.is_empty())
    {
        return 0;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(results.as_ptr(), sections, results.len());
        if !ranked_indices.is_empty() {
            std::ptr::copy_nonoverlapping(ranked_indices.as_ptr(), indices, ranked_indices.len());
        }
    }
    results.len()
}
