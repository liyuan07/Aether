// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use std::collections::{HashMap, HashSet};
fn ordered(apps: &[u64], prefs: &[u64]) -> Vec<usize> {
    let mut first = HashMap::new();
    for (i, &key) in apps.iter().enumerate() {
        first.entry(key).or_insert(i);
    }
    let mut rows: Vec<usize> = prefs
        .iter()
        .filter_map(|key| first.get(key).copied())
        .collect();
    let mut seen: HashSet<u64> = rows.iter().map(|&i| apps[i]).collect();
    rows.extend(
        apps.iter()
            .enumerate()
            .filter_map(|(i, &key)| seen.insert(key).then_some(i)),
    );
    rows
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Reference {
    source: u8,
    index: usize,
}
#[repr(C)]
pub struct Result {
    count: usize,
    valid: u8,
}
unsafe fn span<'a, T>(p: *const T, n: usize) -> Option<&'a [T]> {
    if n == 0 {
        Some(&[])
    } else if p.is_null() {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(p, n) })
    }
}
unsafe fn write<T: Copy>(rows: &[T], out: *mut T, cap: usize) {
    if !out.is_null() {
        unsafe {
            std::ptr::copy_nonoverlapping(rows.as_ptr(), out, rows.len().min(cap));
        }
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_app_order(
    apps: *const u64,
    n: usize,
    prefs: *const u64,
    m: usize,
    out: *mut usize,
    cap: usize,
) -> usize {
    match (unsafe { span(apps, n) }, unsafe { span(prefs, m) }) {
        (Some(apps), Some(prefs)) => {
            let rows = ordered(apps, prefs);
            unsafe {
                write(&rows, out, cap);
            }
            rows.len()
        }
        _ => 0,
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_app_move(
    apps: *const u64,
    n: usize,
    prefs: *const u64,
    m: usize,
    offsets: *const i64,
    k: usize,
    destination: i64,
    out: *mut Reference,
    cap: usize,
) -> Result {
    let none = || Result { count: 0, valid: 0 };
    let (Some(apps), Some(prefs), Some(offsets)) = (
        unsafe { span(apps, n) },
        unsafe { span(prefs, m) },
        unsafe { span(offsets, k) },
    ) else {
        return none();
    };
    let rows = ordered(apps, prefs);
    if offsets.is_empty()
        || destination < 0
        || destination as usize > rows.len()
        || offsets.iter().any(|&i| i < 0 || i as usize >= rows.len())
        || offsets.windows(2).any(|w| w[0] >= w[1])
    {
        return none();
    }
    let selected: HashSet<usize> = offsets.iter().map(|&i| i as usize).collect();
    let moving: Vec<usize> = offsets.iter().map(|&i| rows[i as usize]).collect();
    let insertion = destination as usize - offsets.iter().filter(|&&i| i < destination).count();
    let mut reordered: Vec<usize> = rows
        .iter()
        .enumerate()
        .filter_map(|(i, &row)| (!selected.contains(&i)).then_some(row))
        .collect();
    reordered.splice(insertion..insertion, moving);
    let mut seen = HashSet::new();
    let normalized: Vec<usize> = prefs
        .iter()
        .enumerate()
        .filter_map(|(i, &key)| seen.insert(key).then_some(i))
        .collect();
    let available: HashSet<u64> = reordered.iter().map(|&i| apps[i]).collect();
    let mut iterator = reordered.iter();
    let mut result: Vec<Reference> = normalized
        .iter()
        .map(|&i| {
            if available.contains(&prefs[i]) {
                Reference {
                    source: 0,
                    index: *iterator.next().unwrap(),
                }
            } else {
                Reference {
                    source: 1,
                    index: i,
                }
            }
        })
        .collect();
    result.extend(
        reordered
            .iter()
            .filter(|&&i| !seen.contains(&apps[i]))
            .map(|&index| Reference { source: 0, index }),
    );
    unsafe {
        write(&result, out, cap);
    }
    Result {
        count: result.len(),
        valid: 1,
    }
}
