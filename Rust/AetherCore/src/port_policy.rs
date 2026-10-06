// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use std::collections::BTreeMap;
#[repr(C)]
pub struct TB {
    pub(crate) socket: i64,
    pub(crate) width: i64,
}
#[repr(C)]
pub struct Phy {
    pub(crate) port: i64,
    pub(crate) id: i64,
    pub(crate) active: u8,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Tier {
    pub confirmed: u8,
    pub pending: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_port_tier_step(mut state: Tier, resolved: u8) -> Tier {
    if resolved <= state.confirmed || state.pending == resolved {
        state.confirmed = resolved;
        state.pending = 4;
    } else {
        state.pending = resolved;
    }
    state
}
unsafe fn span<'a, T>(ptr: *const T, count: usize) -> Option<&'a [T]> {
    if count == 0 {
        Some(&[])
    } else if ptr.is_null() {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(ptr, count) })
    }
}
unsafe fn output(rows: &[usize], ptr: *mut usize, capacity: usize) -> usize {
    if !ptr.is_null() {
        unsafe {
            std::ptr::copy_nonoverlapping(rows.as_ptr(), ptr, rows.len().min(capacity));
        }
    }
    rows.len()
}
pub(crate) fn tb_plan(rows: &[TB]) -> Vec<usize> {
    let mut best = BTreeMap::new();
    for (index, row) in rows.iter().enumerate() {
        if row.socket <= 0 {
            continue;
        }
        best.entry(row.socket)
            .and_modify(|selected: &mut usize| {
                if row.width > rows[*selected].width {
                    *selected = index;
                }
            })
            .or_insert(index);
    }
    best.into_values().collect()
}
pub(crate) fn phy_plan(rows: &[Phy]) -> Vec<usize> {
    if !rows.iter().any(|p| p.port > 0) {
        return (0..rows.len()).collect();
    }
    let mut best = BTreeMap::new();
    for (index, row) in rows.iter().enumerate() {
        let key = if row.port > 0 { row.port } else { row.id };
        best.entry(key)
            .and_modify(|selected: &mut usize| {
                if row.active != 0 && rows[*selected].active == 0 {
                    *selected = index;
                }
            })
            .or_insert(index);
    }
    best.into_values().collect()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_tb_plan(
    ptr: *const TB,
    count: usize,
    out: *mut usize,
    capacity: usize,
) -> usize {
    let Some(rows) = (unsafe { span(ptr, count) }) else {
        return 0;
    };
    unsafe { output(&tb_plan(rows), out, capacity) }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_phy_plan(
    ptr: *const Phy,
    count: usize,
    out: *mut usize,
    capacity: usize,
) -> usize {
    let Some(rows) = (unsafe { span(ptr, count) }) else {
        return 0;
    };
    unsafe { output(&phy_plan(rows), out, capacity) }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn missing_port_numbers_preserve_duplicates_and_order() {
        assert_eq!(
            phy_plan(&[
                Phy {
                    port: 0,
                    id: 3,
                    active: 0
                },
                Phy {
                    port: 0,
                    id: 3,
                    active: 1
                }
            ]),
            [0, 1]
        );
        assert_eq!(
            tb_plan(&[
                TB {
                    socket: 1,
                    width: 2
                },
                TB {
                    socket: 1,
                    width: 2
                },
                TB {
                    socket: 0,
                    width: 3
                }
            ]),
            [0]
        );
    }
}
