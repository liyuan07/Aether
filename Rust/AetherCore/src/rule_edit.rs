// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Immutable identity index and rule edit plans. Native adapters own display records and effects.
use crate::{abi::Uuid, shortcuts::Key};
use std::collections::HashMap;
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Meta {
    pub id: Uuid,
    pub source: Key,
    pub enabled: u8,
}
pub struct Index {
    rows: Vec<Meta>,
    first: HashMap<Uuid, usize>,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Edit {
    pub index: isize,
    pub selection: isize,
    pub rescan: u8,
}
#[repr(C)]
pub struct Template {
    pub source: Key,
    pub enabled: u8,
    pub kind: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_rule_new_template() -> Template {
    Template {
        source: Key {
            code: 45,
            physical: 0,
            modifiers: 6,
        },
        enabled: 0,
        kind: 1,
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_rule_index_create(rows: *const Meta, count: usize) -> *mut Index {
    if count > 0 && rows.is_null() {
        return std::ptr::null_mut();
    }
    let rows = if count == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(rows, count) }.to_vec()
    };
    let mut first = HashMap::with_capacity(count);
    for (i, row) in rows.iter().enumerate() {
        first.entry(row.id).or_insert(i);
    }
    Box::into_raw(Box::new(Index { rows, first }))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_rule_index_find(index: *const Index, id: Uuid) -> isize {
    unsafe { index.as_ref() }
        .and_then(|i| i.first.get(&id))
        .map_or(-1, |&i| i as isize)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_rule_index_edit(
    index: *const Index,
    row: Meta,
    remove: u8,
) -> Edit {
    let mut result = Edit {
        index: -1,
        selection: -1,
        rescan: 0,
    };
    let Some(index) = (unsafe { index.as_ref() }) else {
        return result;
    };
    let Some(&i) = index.first.get(&row.id) else {
        return result;
    };
    result.index = i as isize;
    if remove != 0 {
        let remaining = index.rows.len() - 1;
        result.selection = if i < remaining {
            i as isize
        } else {
            remaining as isize - 1
        };
        result.rescan = 1;
    } else {
        result.rescan = u8::from(
            index.rows[i].source != row.source
                || (index.rows[i].enabled != 0) != (row.enabled != 0),
        );
    }
    result
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_rule_index_destroy(index: *mut Index) {
    if !index.is_null() {
        drop(unsafe { Box::from_raw(index) });
    }
}
/// Validates the entire move before touching output. Offsets must be strictly increasing.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_rule_move(
    count: usize,
    offsets: *const i64,
    k: usize,
    destination: i64,
    out: *mut usize,
    capacity: usize,
) -> u8 {
    if k == 0
        || offsets.is_null()
        || destination < 0
        || destination as usize > count
        || capacity < count
        || (count > 0 && out.is_null())
    {
        return 0;
    }
    let offsets = unsafe { std::slice::from_raw_parts(offsets, k) };
    if offsets.iter().any(|&i| i < 0 || i as usize >= count)
        || offsets.windows(2).any(|w| w[0] >= w[1])
    {
        return 0;
    }
    let insertion = destination as usize - offsets.iter().take_while(|&&i| i < destination).count();
    let mut rows = Vec::with_capacity(count);
    let mut next = 0;
    for i in 0..count {
        if next < k && offsets[next] as usize == i {
            next += 1;
        } else {
            rows.push(i);
        }
    }
    rows.splice(insertion..insertion, offsets.iter().map(|&i| i as usize));
    unsafe {
        std::ptr::copy_nonoverlapping(rows.as_ptr(), out, count);
    }
    1
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identity_ownership_duplicates_and_edit_effects() {
        unsafe {
            let id = Uuid { bytes: [3; 16] };
            let first = Meta {
                id,
                source: Key::default(),
                enabled: 0,
            };
            let mut rows = vec![
                first,
                Meta {
                    enabled: 1,
                    ..first
                },
            ];
            let index = aether_rule_index_create(rows.as_ptr(), rows.len());
            rows.clear();
            assert_eq!(aether_rule_index_find(index, id), 0);
            assert_eq!(aether_rule_index_edit(index, first, 0).rescan, 0);
            assert_eq!(
                aether_rule_index_edit(
                    index,
                    Meta {
                        enabled: 1,
                        ..first
                    },
                    0
                )
                .rescan,
                1
            );
            let removal = aether_rule_index_edit(index, first, 1);
            assert_eq!(
                (removal.index, removal.selection, removal.rescan),
                (0, 0, 1)
            );
            aether_rule_index_destroy(index);
            assert_eq!(aether_rule_index_find(std::ptr::null(), id), -1);
            assert!(aether_rule_index_create(std::ptr::null(), 1).is_null());
            aether_rule_index_destroy(std::ptr::null_mut());
        }
    }
    #[test]
    fn moves_reject_invalid_without_output_and_preserve_order() {
        unsafe {
            let mut out = [99; 5];
            assert_eq!(
                aether_rule_move(5, [1, 3].as_ptr(), 2, 5, out.as_mut_ptr(), 5),
                1
            );
            assert_eq!(out, [0, 2, 4, 1, 3]);
            for offsets in [vec![], vec![-1], vec![5], vec![2, 1], vec![1, 1]] {
                let mut out = [99; 5];
                assert_eq!(
                    aether_rule_move(5, offsets.as_ptr(), offsets.len(), 5, out.as_mut_ptr(), 5),
                    0
                );
                assert_eq!(out, [99; 5]);
            }
            assert_eq!(
                aether_rule_move(5, [0].as_ptr(), 1, 0, out.as_mut_ptr(), 4),
                0
            );
            assert_eq!(
                aether_rule_move(5, std::ptr::null(), 1, 0, out.as_mut_ptr(), 5),
                0
            );
        }
    }
}
