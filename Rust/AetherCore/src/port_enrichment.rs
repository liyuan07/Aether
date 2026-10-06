// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use std::collections::HashMap;
#[repr(C)]
pub struct Port {
    id: i64,
    magsafe: u8,
}
#[repr(C)]
pub struct Source {
    id: i64,
    flags: u8,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Row {
    display: i64,
    stats: i64,
    cable: i64,
    hpm: i64,
    device_start: usize,
    device_count: usize,
}
pub struct Plan {
    rows: Vec<Row>,
    devices: Vec<usize>,
}
#[repr(C)]
pub struct View {
    rows: *const Row,
    count: usize,
    devices: *const usize,
    device_count: usize,
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
fn index(sources: &[Source]) -> HashMap<i64, i64> {
    let mut result = HashMap::new();
    for (i, source) in sources.iter().enumerate() {
        if source.flags & 1 != 0 {
            result.entry(source.id).or_insert(i as i64);
        }
    }
    result
}
/// # Safety
/// All input spans are readable for the call. Returned plan is destroyed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_enrichment_create(
    ports: *const Port,
    count: usize,
    displays: *const Source,
    display_count: usize,
    stats: *const Source,
    stats_count: usize,
    cables: *const Source,
    cable_count: usize,
    hpm: *const Source,
    hpm_count: usize,
    devices: *const i64,
    device_count: usize,
) -> *mut Plan {
    let (Some(ports), Some(displays), Some(stats), Some(cables), Some(hpm), Some(devices)) = (
        unsafe { span(ports, count) },
        unsafe { span(displays, display_count) },
        unsafe { span(stats, stats_count) },
        unsafe { span(cables, cable_count) },
        unsafe { span(hpm, hpm_count) },
        unsafe { span(devices, device_count) },
    ) else {
        return std::ptr::null_mut();
    };
    let display_index = index(displays);
    let stats_index = index(stats);
    let cable_index = index(cables);
    let hpm_index = index(hpm);
    let mut grouped: HashMap<i64, Vec<usize>> = HashMap::new();
    for (i, id) in devices.iter().enumerate() {
        grouped.entry(*id).or_default().push(i);
    }
    let mut plan = Plan {
        rows: Vec::with_capacity(ports.len()),
        devices: Vec::new(),
    };
    for port in ports {
        let device_start = plan.devices.len();
        if let Some(indices) = grouped.get(&port.id) {
            plan.devices.extend_from_slice(indices);
        }
        // Select the first USB-C CC record before testing payload presence; an empty
        // first record must not fall through to a later cable identity.
        let cable = cable_index
            .get(&port.id)
            .copied()
            .filter(|&i| cables[i as usize].flags & 2 != 0)
            .unwrap_or(-1);
        let hpm = if port.magsafe != 0 {
            port.id
                .checked_sub(100)
                .and_then(|id| hpm_index.get(&id).copied())
                .unwrap_or(-1)
        } else {
            -1
        };
        plan.rows.push(Row {
            display: display_index.get(&port.id).copied().unwrap_or(-1),
            stats: stats_index.get(&port.id).copied().unwrap_or(-1),
            cable,
            hpm,
            device_start,
            device_count: plan.devices.len() - device_start,
        });
    }
    Box::into_raw(Box::new(plan))
}
/// # Safety
/// Plan stays live until borrowed rows and indices have been copied.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_enrichment_view(plan: *const Plan) -> View {
    unsafe { plan.as_ref() }.map_or(
        View {
            rows: std::ptr::null(),
            count: 0,
            devices: std::ptr::null(),
            device_count: 0,
        },
        |p| View {
            rows: p.rows.as_ptr(),
            count: p.rows.len(),
            devices: p.devices.as_ptr(),
            device_count: p.devices.len(),
        },
    )
}
/// # Safety
/// Destroy a live plan once, after its views are no longer used.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_enrichment_destroy(plan: *mut Plan) {
    if !plan.is_null() {
        drop(unsafe { Box::from_raw(plan) });
    }
}
#[repr(C)]
pub struct Selection {
    primary: i64,
    additional: usize,
}
/// # Safety
/// Hub flags span remains readable for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_usb_device_selection(hubs: *const u8, count: usize) -> Selection {
    let Some(hubs) = (unsafe { span(hubs, count) }) else {
        return Selection {
            primary: -1,
            additional: 0,
        };
    };
    let mut first = None;
    let mut real = 0_usize;
    for (i, hub) in hubs.iter().enumerate() {
        if *hub == 0 {
            first.get_or_insert(i);
            real += 1;
        }
    }
    Selection {
        primary: first
            .or_else(|| if count == 0 { None } else { Some(0) })
            .map_or(-1, |i| i as i64),
        additional: real.saturating_sub(1),
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_usb_device_class(code: i64) -> u8 {
    match code {
        0x09 => 1,
        0x01 => 2,
        0x0E => 3,
        0x08 => 4,
        0x0B => 5,
        0x11 => 6,
        0xE0 => 7,
        0xEF => 8,
        0xFF => 9,
        _ => 0,
    }
}
