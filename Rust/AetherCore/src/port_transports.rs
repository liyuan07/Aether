// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use std::collections::HashMap;
#[repr(C)]
pub struct Port {
    id: i64,
    tb_link: u8,
}
#[repr(C)]
pub struct Source {
    id: i64,
    active: u8,
    restricted: u8,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Row {
    hpm: i64,
    cio: i64,
    usb: i64,
    dp: i64,
    live_cio: i64,
    identity_cio: i64,
}
fn index(sources: &[Source], eligible: impl Fn(&Source) -> bool) -> HashMap<i64, i64> {
    let mut result = HashMap::new();
    for (i, source) in sources.iter().enumerate() {
        if eligible(source) {
            result.entry(source.id).or_insert(i as i64);
        }
    }
    result
}
unsafe fn span<'a, T>(pointer: *const T, count: usize) -> Option<&'a [T]> {
    if count == 0 {
        Some(&[])
    } else if pointer.is_null() {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(pointer, count) })
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_transports(
    ports: *const Port,
    count: usize,
    hpm: *const Source,
    hpm_count: usize,
    usb: *const Source,
    usb_count: usize,
    dp: *const Source,
    dp_count: usize,
    cio: *const Source,
    cio_count: usize,
    output: *mut Row,
    capacity: usize,
) -> usize {
    let (Some(ports), Some(hpm), Some(usb), Some(dp), Some(cio)) = (
        unsafe { span(ports, count) },
        unsafe { span(hpm, hpm_count) },
        unsafe { span(usb, usb_count) },
        unsafe { span(dp, dp_count) },
        unsafe { span(cio, cio_count) },
    ) else {
        return 0;
    };
    let hpm_index = index(hpm, |s| s.active != 0);
    let usb_index = index(usb, |s| s.active != 0 || s.restricted != 0);
    let dp_index = index(dp, |s| s.active != 0);
    let cio_index = index(cio, |_| true);
    let live_cio_index = index(cio, |s| s.active != 0);
    let selected = |map: &HashMap<i64, i64>, id| map.get(&id).copied().unwrap_or(-1);
    if !output.is_null() {
        for (i, port) in ports.iter().take(capacity).enumerate() {
            let cio_first = selected(&cio_index, port.id);
            let identity_cio =
                if cio_first >= 0 && cio[cio_first as usize].active != 0 && port.tb_link != 0 {
                    cio_first
                } else {
                    -1
                };
            unsafe {
                output.add(i).write(Row {
                    hpm: selected(&hpm_index, port.id),
                    cio: cio_first,
                    usb: selected(&usb_index, port.id),
                    dp: selected(&dp_index, port.id),
                    live_cio: selected(&live_cio_index, port.id),
                    identity_cio,
                });
            }
        }
    }
    count
}
