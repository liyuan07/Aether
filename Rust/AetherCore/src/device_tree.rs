// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use std::collections::{HashMap, HashSet};
fn parent(id: i64) -> Option<i64> {
    if id <= 0 || id > u32::MAX as i64 {
        return None;
    }
    let path = id & 0x00ff_ffff;
    if path == 0 {
        return None;
    }
    let mut zero = false;
    for shift in (0..6).rev().map(|i| i * 4) {
        if (path >> shift) & 15 == 0 {
            zero = true;
        } else if zero {
            return None;
        }
    }
    for shift in (0..6).map(|i| i * 4) {
        if (path >> shift) & 15 != 0 {
            let cleared = id & !(15 << shift);
            return (cleared & 0x00ff_ffff != 0).then_some(cleared);
        }
    }
    None
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Row {
    index: usize,
    depth: usize,
    parent_index: usize,
}
struct Topology<'a> {
    ids: &'a [i64],
    first: HashMap<i64, usize>,
}
impl<'a> Topology<'a> {
    fn new(ids: &'a [i64]) -> Self {
        let mut first = HashMap::with_capacity(ids.len());
        for (i, &id) in ids.iter().enumerate() {
            first.entry(id).or_insert(i);
        }
        Self { ids, first }
    }
    fn query(&self, id: i64, index: usize) -> Row {
        let parent_index = parent(id)
            .and_then(|p| self.first.get(&p))
            .copied()
            .unwrap_or(usize::MAX);
        let mut depth = 0;
        let mut current = id;
        for _ in 0..6 {
            match parent(current).filter(|p| self.first.contains_key(p)) {
                Some(p) => {
                    depth += 1;
                    current = p;
                }
                None => break,
            }
        }
        Row {
            index,
            depth,
            parent_index,
        }
    }
    fn plan(&self) -> Vec<Row> {
        let mut children: HashMap<i64, Vec<usize>> = HashMap::new();
        let mut roots = Vec::new();
        for (i, &id) in self.ids.iter().enumerate() {
            match parent(id) {
                Some(p) if self.first.contains_key(&p) => children.entry(p).or_default().push(i),
                _ => roots.push(i),
            }
        }
        let mut stack: Vec<usize> = roots.into_iter().rev().collect();
        let mut emitted = vec![false; self.ids.len()];
        let mut expanded = HashSet::new();
        let mut result = Vec::with_capacity(self.ids.len());
        while let Some(index) = stack.pop() {
            if emitted[index] {
                continue;
            }
            emitted[index] = true;
            let id = self.ids[index];
            result.push(self.query(id, index));
            // Duplicate parent IDs still emit separately, but their already-visited children need no rescan.
            if expanded.insert(id) {
                if let Some(rows) = children.get(&id) {
                    stack.extend(rows.iter().rev().copied());
                }
            }
        }
        result
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_device_parent(id: i64) -> i64 {
    parent(id).unwrap_or(0)
}
unsafe fn ids<'a>(ids: *const i64, count: usize) -> Option<&'a [i64]> {
    if count == 0 {
        Some(&[])
    } else if ids.is_null() {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(ids, count) })
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_device_query(input: *const i64, count: usize, id: i64) -> Row {
    let input = unsafe { ids(input, count) }.unwrap_or(&[]);
    Topology::new(input).query(id, usize::MAX)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_device_plan(
    input: *const i64,
    count: usize,
    output: *mut Row,
    capacity: usize,
) -> usize {
    let Some(input) = (unsafe { ids(input, count) }) else {
        return 0;
    };
    let rows = Topology::new(input).plan();
    if !output.is_null() {
        unsafe {
            std::ptr::copy_nonoverlapping(rows.as_ptr(), output, capacity.min(rows.len()));
        }
    }
    rows.len()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn duplicate_parent_emits_children_once_in_original_order() {
        let ids = [0x08200000, 0x08200000, 0x08210000, 0x08210000, 0x08211000];
        let rows = Topology::new(&ids).plan();
        assert_eq!(
            rows.iter().map(|r| r.index).collect::<Vec<_>>(),
            [0, 2, 4, 3, 1]
        );
        assert_eq!(rows[2].depth, 2);
        assert_eq!(rows[2].parent_index, 2);
        assert_eq!(parent(0x08201000), None);
    }
}
