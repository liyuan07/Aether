// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use std::collections::{BTreeMap, HashMap, HashSet};
#[repr(C)]
pub struct Hpm {
    id: i64,
    key: u64,
    empty: u8,
    magsafe: u8,
}
#[repr(C)]
pub struct Channel {
    key: u64,
    channel: i64,
    empty: u8,
}
#[repr(C)]
pub struct Port {
    id: i64,
    key: u64,
    usb: u8,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Pair {
    port_id: i64,
    index: usize,
}
#[repr(C)]
pub struct Recovery {
    hpm: i64,
    channel: i64,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Disagreement {
    offset: usize,
    channel: i64,
    ordinal: i64,
    keyed: i64,
}
fn recover(hpm: &[Hpm], channels: &[Channel]) -> Recovery {
    let none = || Recovery {
        hpm: -1,
        channel: -1,
    };
    let missing: Vec<usize> = (0..hpm.len())
        .filter(|&i| hpm[i].magsafe == 0 && hpm[i].empty != 0)
        .collect();
    if missing.len() != 1 {
        return none();
    }
    let claimed: HashSet<u64> = hpm.iter().filter(|p| p.empty == 0).map(|p| p.key).collect();
    let spare: Vec<usize> = (0..channels.len())
        .filter(|&i| channels[i].empty == 0 && !claimed.contains(&channels[i].key))
        .collect();
    if spare.len() != 1 || channels.len() != hpm.len() {
        return none();
    }
    let mut usb: Vec<usize> = (0..hpm.len()).filter(|&i| hpm[i].magsafe == 0).collect();
    usb.sort_by_key(|&i| hpm[i].id);
    let offset = usb.iter().position(|&i| hpm[i].empty != 0).unwrap();
    if channels[spare[0]].channel != offset as i64 + 1 {
        return none();
    }
    Recovery {
        hpm: missing[0] as i64,
        channel: spare[0] as i64,
    }
}
fn ordinal(offsets: &[i64], ids: &[i64]) -> Vec<Pair> {
    if offsets.is_empty()
        || ids.is_empty()
        || !(offsets.len() == ids.len() || offsets.len() == ids.len() + 1)
    {
        return Vec::new();
    }
    let mut first = HashMap::new();
    for (i, &offset) in offsets.iter().enumerate() {
        first.entry(offset).or_insert(i);
    }
    let mut result = BTreeMap::new();
    for (offset, &id) in ids.iter().enumerate() {
        if let Some(&i) = first.get(&(offset as i64)) {
            result.insert(id, i);
        }
    }
    result
        .into_iter()
        .map(|(port_id, index)| Pair { port_id, index })
        .collect()
}
fn cross(ordinal: &[i64], ids: &[i64], channels: &[Channel], ports: &[Port]) -> Vec<Disagreement> {
    if ordinal.is_empty() || channels.is_empty() {
        return Vec::new();
    }
    let attributed: HashSet<i64> = ordinal.iter().copied().collect();
    let mut matches: HashMap<u64, Vec<i64>> = HashMap::new();
    for port in ports {
        if port.usb != 0 && port.key != 0 {
            matches.entry(port.key).or_default().push(port.id);
        }
    }
    let mut indices: HashMap<i64, Vec<&Channel>> = HashMap::new();
    for channel in channels {
        indices.entry(channel.channel).or_default().push(channel);
    }
    let mut result = Vec::new();
    for (offset, &id) in ids.iter().enumerate() {
        if !attributed.contains(&id) {
            continue;
        }
        let channel = offset as i64 + 1;
        let Some(group) = indices.get(&channel).filter(|v| v.len() == 1) else {
            continue;
        };
        let Some(ports) = matches.get(&group[0].key).filter(|v| v.len() == 1) else {
            continue;
        };
        if ports[0] != id {
            result.push(Disagreement {
                offset,
                channel,
                ordinal: id,
                keyed: ports[0],
            });
        }
    }
    result
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
unsafe fn write<T: Copy>(rows: &[T], out: *mut T, cap: usize) -> usize {
    if !out.is_null() {
        unsafe {
            std::ptr::copy_nonoverlapping(rows.as_ptr(), out, cap.min(rows.len()));
        }
    }
    rows.len()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_identity_recover(
    hpm: *const Hpm,
    h: usize,
    channels: *const Channel,
    c: usize,
) -> Recovery {
    match (unsafe { span(hpm, h) }, unsafe { span(channels, c) }) {
        (Some(h), Some(c)) => recover(h, c),
        _ => Recovery {
            hpm: -1,
            channel: -1,
        },
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_pd_ordinal(
    offsets: *const i64,
    p: usize,
    ids: *const i64,
    n: usize,
    out: *mut Pair,
    cap: usize,
) -> usize {
    match (unsafe { span(offsets, p) }, unsafe { span(ids, n) }) {
        (Some(p), Some(ids)) => unsafe { write(&ordinal(p, ids), out, cap) },
        _ => 0,
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_pd_cross(
    ordinal: *const i64,
    o: usize,
    ids: *const i64,
    n: usize,
    channels: *const Channel,
    c: usize,
    ports: *const Port,
    p: usize,
    out: *mut Disagreement,
    cap: usize,
) -> usize {
    match (
        unsafe { span(ordinal, o) },
        unsafe { span(ids, n) },
        unsafe { span(channels, c) },
        unsafe { span(ports, p) },
    ) {
        (Some(o), Some(ids), Some(c), Some(p)) => unsafe { write(&cross(o, ids, c, p), out, cap) },
        _ => 0,
    }
}
