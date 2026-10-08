// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Actor-confined cache ownership. Documents remain independently retained by readers.
use crate::{SearchDocument, abi::Uuid};
use std::{
    collections::{HashMap, HashSet},
    ffi::c_void,
    sync::Arc,
};
struct Entry {
    document: Arc<SearchDocument>,
    active: bool,
}
pub struct Cache {
    entries: HashMap<Uuid, Entry>,
    clients: HashSet<Uuid>,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_search_cache_create() -> *mut Cache {
    Box::into_raw(Box::new(Cache {
        entries: HashMap::new(),
        clients: HashSet::new(),
    }))
}
/// # Safety
/// Cache is live and exclusively borrowed. Client updates are serialized with searches.
/// Returns one when no visible client remains; independent document readers stay valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_cache_visibility(
    cache: *mut Cache,
    client: Uuid,
    visible: u8,
) -> u8 {
    let Some(cache) = (unsafe { cache.as_mut() }) else {
        return 1;
    };
    if visible != 0 {
        cache.clients.insert(client);
    } else {
        cache.clients.remove(&client);
    }
    if cache.clients.is_empty() {
        cache.entries = HashMap::new();
        cache.clients = HashSet::new();
        1
    } else {
        0
    }
}
/// # Safety
/// Cache calls are serialized. begin/mark/prune constitute one active-source update.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_cache_begin(cache: *mut Cache) {
    if let Some(cache) = unsafe { cache.as_mut() } {
        for entry in cache.entries.values_mut() {
            entry.active = false;
        }
    }
}
/// # Safety
/// Cache is live and exclusively borrowed; missing ids require no placeholder allocation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_cache_mark(cache: *mut Cache, id: Uuid) {
    if let Some(entry) = unsafe { cache.as_mut() }.and_then(|c| c.entries.get_mut(&id)) {
        entry.active = true;
    }
}
/// # Safety
/// Cache is live and exclusively borrowed. Independent readers survive pruning.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_cache_prune(cache: *mut Cache) {
    if let Some(cache) = unsafe { cache.as_mut() } {
        cache.entries.retain(|_, v| v.active);
    }
}
/// # Safety
/// Cache is live and borrowed. Returns an owned document reference; destroy with document_destroy.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_cache_get(cache: *const Cache, id: Uuid) -> *mut c_void {
    unsafe { cache.as_ref() }
        .and_then(|c| c.entries.get(&id))
        .map_or(std::ptr::null_mut(), |v| {
            Arc::into_raw(v.document.clone()).cast_mut().cast()
        })
}
#[repr(C)]
pub struct CachedScore {
    pub score: i32,
    pub found: u8,
}
/// # Safety
/// Cache/query are live and borrowed; cache access is serialized. No document wrapper is allocated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_cache_score(
    cache: *const Cache,
    id: Uuid,
    query: *const c_void,
) -> CachedScore {
    let Some(entry) = (unsafe { cache.as_ref() }).and_then(|c| c.entries.get(&id)) else {
        return CachedScore {
            score: -1,
            found: 0,
        };
    };
    let score =
        unsafe { crate::aether_search_document_score(query, Arc::as_ptr(&entry.document).cast()) };
    CachedScore { score, found: 1 }
}
/// # Safety
/// Cache calls are serialized. Document is a live search document. Cache retains it independently.
/// First insertion wins, matching the original identity-based native cache.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_cache_insert(
    cache: *mut Cache,
    id: Uuid,
    document: *const c_void,
) {
    let Some(cache) = (unsafe { cache.as_mut() }) else {
        return;
    };
    if document.is_null() || cache.entries.contains_key(&id) {
        return;
    }
    let document = document.cast::<SearchDocument>();
    let owned = unsafe {
        Arc::increment_strong_count(document);
        Arc::from_raw(document)
    };
    cache.entries.insert(
        id,
        Entry {
            document: owned,
            active: true,
        },
    );
}
/// # Safety
/// Destroy a live cache exactly once after serialized access ends; null is allowed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_cache_destroy(cache: *mut Cache) {
    if !cache.is_null() {
        drop(unsafe { Box::from_raw(cache) });
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        aether_search_create, aether_search_destroy, aether_search_document_create,
        aether_search_document_destroy, aether_search_document_score,
    };
    #[test]
    fn cache_retains_documents_first_wins_and_readers_survive_pruning() {
        unsafe {
            let cache = aether_search_cache_create();
            let id = Uuid { bytes: [7; 16] };
            let first = Uuid { bytes: [1; 16] };
            let second = Uuid { bytes: [2; 16] };
            assert_eq!(aether_search_cache_visibility(cache, first, 1), 0);
            assert_eq!(aether_search_cache_visibility(cache, second, 1), 0);
            let query = aether_search_create(b"test".as_ptr(), 4, std::ptr::null(), 0, 0);
            let document = aether_search_document_create([query.cast_const()].as_ptr(), 1);
            aether_search_cache_insert(cache, id, document);
            aether_search_document_destroy(document);
            let empty = aether_search_document_create(std::ptr::null(), 0);
            aether_search_cache_insert(cache, id, empty);
            aether_search_document_destroy(empty);
            aether_search_cache_begin(cache);
            aether_search_cache_mark(cache, id);
            aether_search_cache_prune(cache);
            let score = aether_search_cache_score(cache, id, query);
            assert_eq!(score.found, 1);
            assert_eq!(score.score, 19996);
            let reader = aether_search_cache_get(cache, id);
            assert!(!reader.is_null());
            assert_eq!(aether_search_cache_visibility(cache, first, 0), 0);
            assert_eq!(aether_search_cache_score(cache, id, query).found, 1);
            assert_eq!(aether_search_cache_visibility(cache, second, 0), 1);
            assert_eq!((*cache).entries.capacity(), 0);
            assert_eq!(aether_search_document_score(query, reader), 19996);
            assert_eq!(aether_search_cache_visibility(cache, first, 1), 0);
            aether_search_cache_insert(cache, id, reader);
            assert_eq!(aether_search_cache_score(cache, id, query).found, 1);
            aether_search_cache_begin(cache);
            aether_search_cache_prune(cache);
            assert!(aether_search_cache_get(cache, id).is_null());
            assert_eq!(aether_search_cache_score(cache, id, query).found, 0);
            aether_search_cache_destroy(cache);
            assert_eq!(aether_search_document_score(query, reader), 19996);
            aether_search_document_destroy(reader);
            aether_search_destroy(query);
        }
    }
}
