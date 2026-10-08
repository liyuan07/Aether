// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Immutable identity lookup shared by native display snapshots.
use crate::abi::Uuid;
use std::collections::HashMap;
pub struct Index {
    positions: HashMap<Uuid, usize>,
    unique: bool,
}
/// # Safety
/// IDs are readable for count entries during creation; no borrowed memory is retained.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_identity_index_create(
    ids: *const Uuid,
    count: usize,
) -> *mut Index {
    if count != 0 && ids.is_null() {
        return std::ptr::null_mut();
    }
    let ids = if count == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(ids, count) }
    };
    let mut positions = HashMap::with_capacity(count);
    let mut unique = true;
    for (index, id) in ids.iter().enumerate() {
        match positions.entry(*id) {
            std::collections::hash_map::Entry::Vacant(entry) => {
                entry.insert(index);
            }
            std::collections::hash_map::Entry::Occupied(_) => {
                unique = false;
            }
        }
    }
    Box::into_raw(Box::new(Index { positions, unique }))
}
/// # Safety
/// Index is live and immutable for the call; null yields not found.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_identity_index_find(index: *const Index, id: Uuid) -> isize {
    unsafe { index.as_ref() }
        .and_then(|index| index.positions.get(&id))
        .map_or(-1, |&position| position as isize)
}
/// # Safety
/// Index is live or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_identity_index_unique(index: *const Index) -> u8 {
    u8::from(unsafe { index.as_ref() }.is_some_and(|index| index.unique))
}
/// # Safety
/// Destroy exactly once after all concurrent reads end; null is allowed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_identity_index_destroy(index: *mut Index) {
    if !index.is_null() {
        drop(unsafe { Box::from_raw(index) });
    }
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct SearchFlow {
    generation: u64,
    revision: u64,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_search_flow_begin(mut state: SearchFlow) -> SearchFlow {
    state.generation = state.generation.wrapping_add(1);
    state
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_search_flow_current(
    state: SearchFlow,
    generation: u64,
    cancelled: u8,
) -> u8 {
    u8::from(cancelled == 0 && state.generation == generation)
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_search_flow_publish(mut state: SearchFlow, increment: u8) -> SearchFlow {
    if increment != 0 {
        state.revision = state.revision.wrapping_add(1);
    }
    state
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identities_are_owned_and_first_duplicate_wins() {
        unsafe {
            let id = Uuid { bytes: [1; 16] };
            let other = Uuid { bytes: [2; 16] };
            let mut ids = vec![id, other, id];
            let index = aether_identity_index_create(ids.as_ptr(), ids.len());
            ids.clear();
            assert_eq!(aether_identity_index_find(index, id), 0);
            assert_eq!(aether_identity_index_find(index, other), 1);
            assert_eq!(
                aether_identity_index_find(index, Uuid { bytes: [3; 16] }),
                -1
            );
            assert_eq!(aether_identity_index_unique(index), 0);
            aether_identity_index_destroy(index);
            let empty = aether_identity_index_create(std::ptr::null(), 0);
            assert_eq!(aether_identity_index_unique(empty), 1);
            aether_identity_index_destroy(empty);
        }
    }
    #[test]
    fn search_generation_rejects_late_and_cancelled_results_and_wraps() {
        let state = aether_search_flow_begin(SearchFlow {
            generation: u64::MAX,
            revision: u64::MAX,
        });
        assert_eq!(state.generation, 0);
        assert_eq!(aether_search_flow_current(state, u64::MAX, 0), 0);
        assert_eq!(aether_search_flow_current(state, 0, 1), 0);
        assert_eq!(aether_search_flow_current(state, 0, 0), 1);
        assert_eq!(aether_search_flow_publish(state, 0).revision, u64::MAX);
        assert_eq!(aether_search_flow_publish(state, 1).revision, 0);
    }
}
