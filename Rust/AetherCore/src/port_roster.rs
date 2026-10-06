// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use crate::port_policy::{self, Phy, TB};
use std::collections::{BTreeMap, HashMap};
#[repr(C)]
pub struct Hpm {
    id: i64,
    magsafe: u8,
}
#[repr(C)]
pub struct CC {
    id: i64,
    usb: u8,
    active: u8,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Row {
    port_id: i64,
    hpm: i64,
    phy: i64,
    tb: i64,
    power: i64,
    cc_active: u8,
}
#[repr(C)]
pub struct Result {
    count: usize,
    tb_count: usize,
    tier: u8,
}
fn plan(
    hpm: &[Hpm],
    phy: &[Phy],
    tb: &[TB],
    power: &[i64],
    cc: &[CC],
) -> (Vec<Row>, u8, Vec<usize>) {
    let tb_indices = port_policy::tb_plan(tb);
    let phy_indices = port_policy::phy_plan(phy);
    let tb_by_id: BTreeMap<i64, usize> = tb_indices.iter().map(|&i| (tb[i].socket, i)).collect();
    let direct = phy_indices.iter().any(|&i| phy[i].port > 0);
    let mut phy_by_id = HashMap::new();
    for &i in &phy_indices {
        if phy[i].port > 0 {
            phy_by_id.entry(phy[i].port).or_insert(i);
        }
    }
    let mut power_by_id = HashMap::new();
    for (i, &id) in power.iter().enumerate() {
        power_by_id.entry(id).or_insert(i);
    }
    let mut cc_by_id = HashMap::new();
    for c in cc {
        if c.usb != 0 {
            cc_by_id.entry(c.id).or_insert(c.active);
        }
    }
    let mut hpm_indices: Vec<usize> = (0..hpm.len()).filter(|&i| hpm[i].magsafe == 0).collect();
    hpm_indices.sort_by_key(|&i| hpm[i].id);
    let choose_phy = |id: i64, position: usize| {
        if direct {
            phy_by_id.get(&id).copied()
        } else {
            phy_indices.get(position).copied()
        }
    };
    let make = |id: i64, h: Option<usize>, p: Option<usize>, t: Option<usize>| Row {
        port_id: id,
        hpm: h.map_or(-1, |i| i as i64),
        phy: p.map_or(-1, |i| i as i64),
        tb: t.map_or(-1, |i| i as i64),
        power: power_by_id.get(&id).map_or(-1, |&i| i as i64),
        cc_active: *cc_by_id.get(&id).unwrap_or(&0),
    };
    if !hpm_indices.is_empty() {
        return (
            hpm_indices
                .iter()
                .enumerate()
                .map(|(position, &i)| {
                    make(
                        hpm[i].id,
                        Some(i),
                        choose_phy(hpm[i].id, position),
                        tb_by_id.get(&hpm[i].id).copied(),
                    )
                })
                .collect(),
            0,
            tb_indices,
        );
    }
    if !tb_by_id.is_empty() {
        return (
            tb_by_id
                .iter()
                .enumerate()
                .map(|(position, (&id, &i))| make(id, None, choose_phy(id, position), Some(i)))
                .collect(),
            1,
            tb_indices,
        );
    }
    let tier = if phy_indices.is_empty() { 2 } else { 0 };
    (
        phy_indices
            .iter()
            .map(|&i| {
                let id = if phy[i].port > 0 {
                    phy[i].port
                } else {
                    phy[i].id.checked_add(1).expect("PHY identifier overflow")
                };
                make(id, None, Some(i), None)
            })
            .collect(),
        tier,
        tb_indices,
    )
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
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_roster(
    hpm: *const Hpm,
    h: usize,
    phy: *const Phy,
    p: usize,
    tb: *const TB,
    t: usize,
    power: *const i64,
    w: usize,
    cc: *const CC,
    c: usize,
    out: *mut Row,
    capacity: usize,
    tb_out: *mut usize,
    tb_capacity: usize,
) -> Result {
    let (Some(hpm), Some(phy), Some(tb), Some(power), Some(cc)) = (
        unsafe { span(hpm, h) },
        unsafe { span(phy, p) },
        unsafe { span(tb, t) },
        unsafe { span(power, w) },
        unsafe { span(cc, c) },
    ) else {
        return Result {
            count: 0,
            tb_count: 0,
            tier: 2,
        };
    };
    let (rows, tier, tb_indices) = plan(hpm, phy, tb, power, cc);
    if !out.is_null() {
        unsafe {
            std::ptr::copy_nonoverlapping(rows.as_ptr(), out, capacity.min(rows.len()));
        }
    }
    if !tb_out.is_null() {
        unsafe {
            std::ptr::copy_nonoverlapping(
                tb_indices.as_ptr(),
                tb_out,
                tb_capacity.min(tb_indices.len()),
            );
        }
    }
    Result {
        count: rows.len(),
        tb_count: tb_indices.len(),
        tier,
    }
}
